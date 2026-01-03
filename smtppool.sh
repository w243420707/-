#!/bin/bash

# =========================================================
# SMTP Relay Manager - 终极完美版 (含Web端改密)
# =========================================================

APP_DIR="/opt/smtp-relay"
LOG_DIR="/var/log/smtp-relay"
VENV_DIR="$APP_DIR/venv"
CONFIG_FILE="$APP_DIR/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 必须使用 root 用户运行 (sudo -i)${PLAIN}"
    exit 1
fi

install_smtp() {
    echo -e "${GREEN}🚀 初始化环境...${PLAIN}"
    apt-get update -y
    apt-get install -y python3 python3-venv python3-pip supervisor git ufw curl

    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}⚠️  备份旧配置...${PLAIN}"
        cp "$CONFIG_FILE" /tmp/smtp_config_backup.json
    fi

    rm -rf "$APP_DIR/templates"
    rm -f "$APP_DIR/app.py"
    mkdir -p "$APP_DIR/templates"
    mkdir -p "$LOG_DIR"

    if [ ! -d "$VENV_DIR" ]; then
        cd "$APP_DIR"
        python3 -m venv venv
    fi
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install flask requests aiosmtpd

    if [ -f "/tmp/smtp_config_backup.json" ]; then
        mv "/tmp/smtp_config_backup.json" "$CONFIG_FILE"
        echo -e "${GREEN}✅ 已恢复配置${PLAIN}"
    else
        echo -e "${YELLOW}⚙️  生成默认配置...${PLAIN}"
        cat > "$CONFIG_FILE" << EOF
{
    "server_config": { "host": "0.0.0.0", "port": 587, "username": "myapp", "password": "123" },
    "web_config": { "admin_password": "admin" },
    "telegram_config": { "bot_token": "", "admin_id": "" },
    "log_config": { "max_mb": 50, "backups": 3 },
    "limit_config": { "max_per_hour": 0, "min_interval": 1, "max_interval": 5 },
    "downstream_pool": []
}
EOF
    fi

    # --- 1. 写入 app.py (后端增加队列与数据库支持) ---
    cat > "$APP_DIR/app.py" << 'EOF'
import os
import json
import logging
import smtplib
import requests
import random
import threading
import sqlite3
import time
import base64
from datetime import datetime
from email import message_from_bytes
from email.mime.text import MIMEText
from email.utils import formatdate, make_msgid
from logging.handlers import RotatingFileHandler
from aiosmtpd.controller import Controller
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')
DB_FILE = os.path.join(BASE_DIR, 'queue.db')
LOG_FILE = '/var/log/smtp-relay/app.log'

# --- Database ---
def get_db():
    conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as conn:
        conn.execute('''CREATE TABLE IF NOT EXISTS queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mail_from TEXT,
            rcpt_tos TEXT,
            content BLOB,
            status TEXT DEFAULT 'pending',
            assigned_node TEXT,
            retry_count INTEGER DEFAULT 0,
            last_error TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )''')
        try:
            conn.execute("ALTER TABLE queue ADD COLUMN source TEXT DEFAULT 'relay'")
        except:
            pass
        conn.execute('''CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT UNIQUE,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )''')

# --- Config & Logging ---
def load_config():
    if not os.path.exists(CONFIG_FILE): return {}
    try:
        with open(CONFIG_FILE, 'r') as f: return json.load(f)
    except: return {}

def save_config(data):
    with open(CONFIG_FILE, 'w') as f: json.dump(data, f, indent=4)

def setup_logging():
    cfg = load_config()
    log_cfg = cfg.get('log_config', {})
    logger = logging.getLogger('SMTP-Relay')
    logger.setLevel(logging.INFO)
    logger.handlers = []
    handler = RotatingFileHandler(LOG_FILE, maxBytes=log_cfg.get('max_mb', 50)*1024*1024, backupCount=log_cfg.get('backups', 3))
    handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
    logger.addHandler(handler)
    return logger

logger = setup_logging()

def send_telegram(msg):
    cfg = load_config()
    tg = cfg.get('telegram_config', {})
    if tg.get('bot_token') and tg.get('admin_id'):
        try: requests.post(f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage", json={"chat_id": tg['admin_id'], "text": msg}, timeout=5)
        except: pass

# --- SMTP Handler (Producer) ---
class RelayHandler:
    async def handle_DATA(self, server, session, envelope):
        cfg = load_config()
        all_pool = cfg.get('downstream_pool', [])
        # Filter enabled nodes (default True)
        pool = [n for n in all_pool if n.get('enabled', True)]
        
        if not pool:
            logger.warning("❌ No enabled downstream nodes available")
            return '451 Temporary failure: No nodes'
        
        # Load Balancing: Randomly assign a node at reception
        node = random.choice(pool)
        node_name = node.get('name', 'Unknown')
        
        logger.info(f"📥 Received | From: {envelope.mail_from} | To: {envelope.rcpt_tos} | Assigned: {node_name}")
        
        try:
            with get_db() as conn:
                conn.execute(
                    "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source) VALUES (?, ?, ?, ?, ?, ?)",
                    (envelope.mail_from, json.dumps(envelope.rcpt_tos), envelope.content, node_name, 'pending', 'relay')
                )
            return '250 OK: Queued for delivery'
        except Exception as e:
            logger.error(f"❌ DB Error: {e}")
            return '451 Temporary failure: DB Error'

# --- Queue Worker (Consumer) ---
def worker_thread():
    logger.info("👷 Queue Worker Started")
    while True:
        try:
            cfg = load_config()
            
            # Rate Limiting (Bulk Only)
            limit_cfg = cfg.get('limit_config', {})
            max_ph = int(limit_cfg.get('max_per_hour', 0))
            bulk_paused = False
            
            if max_ph > 0:
                with get_db() as conn:
                    try:
                        cnt = conn.execute("SELECT COUNT(*) FROM queue WHERE status='sent' AND source='bulk' AND updated_at > datetime('now', '-1 hour')").fetchone()[0]
                        if cnt >= max_ph:
                            bulk_paused = True
                    except: pass

            pool = {n['name']: n for n in cfg.get('downstream_pool', [])}
            
            with get_db() as conn:
                # Fetch pending items
                if bulk_paused:
                    try:
                        cursor = conn.execute("SELECT * FROM queue WHERE status='pending' AND source!='bulk' LIMIT 5")
                    except:
                        cursor = conn.execute("SELECT * FROM queue WHERE status='pending' LIMIT 5")
                else:
                    cursor = conn.execute("SELECT * FROM queue WHERE status='pending' LIMIT 5")
                rows = cursor.fetchall()
            
            if not rows:
                time.sleep(2)
                continue
                
            for row in rows:
                row_id = row['id']
                node_name = row['assigned_node']
                
                # Mark as processing
                with get_db() as conn:
                    conn.execute("UPDATE queue SET status='processing', updated_at=CURRENT_TIMESTAMP WHERE id=?", (row_id,))
                
                node = pool.get(node_name)

                # Re-route if disabled
                if node and not node.get('enabled', True):
                    active_nodes = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
                    if active_nodes:
                        new_node = random.choice(active_nodes)
                        logger.info(f"🔄 Re-routing ID:{row_id} from disabled '{node_name}' to '{new_node['name']}'")
                        node = new_node
                        node_name = node['name']
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET assigned_node=? WHERE id=?", (node_name, row_id))
                    else:
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET status='pending' WHERE id=?", (row_id,))
                        time.sleep(1)
                        continue

                error_msg = ""
                success = False
                
                if not node:
                    error_msg = f"Node '{node_name}' removed from config"
                else:
                    try:
                        sender = node.get('sender_email') or row['mail_from'] or node.get('username')
                        rcpt_tos = json.loads(row['rcpt_tos'])
                        msg_content = row['content']

                        # 强制修改邮件头 From
                        if node.get('sender_email'):
                            try:
                                msg = message_from_bytes(msg_content)
                                if 'From' in msg: del msg['From']
                                msg['From'] = node['sender_email']
                                msg_content = msg.as_bytes()
                            except Exception as parse_err:
                                logger.warning(f"Header rewrite failed: {parse_err}")

                        with smtplib.SMTP(node['host'], int(node['port']), timeout=20) as s:
                            if node.get('encryption') in ['tls', 'ssl']: s.starttls()
                            if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                            s.sendmail(sender, rcpt_tos, msg_content)
                        
                        success = True
                        logger.info(f"✅ Sent ID:{row_id} via {node_name}")
                    except Exception as e:
                        error_msg = str(e)
                        logger.error(f"⚠️ Failed ID:{row_id} via {node_name}: {e}")
                
                # Update final status
                with get_db() as conn:
                    if success:
                        conn.execute("UPDATE queue SET status='sent', updated_at=CURRENT_TIMESTAMP WHERE id=?", (row_id,))
                    else: (Bulk Only)
                is_bulk = False
                try:
                    if row['source'] == 'bulk': is_bulk = True
                except: pass
                
                if is_bulk:
                    min_int = int(limit_cfg.get('min_interval', 1))
                    max_int = int(limit_cfg.get('max_interval', 5))
                    if max_int > 0:
                            else:
                            conn.execute("UPDATE queue SET status='failed', last_error=?, updated_at=CURRENT_TIMESTAMP WHERE id=?", (error_msg, row_id))
                            send_telegram(f"❌ Mail ID:{row_id} Failed permanently via {node_name}\nErr: {error_msg}")
                
                # Random Interval
                min_int = int(limit_cfg.get('min_interval', 1))
                max_int = int(limit_cfg.get('max_interval', 5))
                if max_int > 0:
                    time.sleep(random.uniform(min_int, max_int))

        except Exception as e:
            logger.error(f"Worker Error: {e}")
            time.sleep(5)

# --- Web App ---
app = Flask(__name__)
app.secret_key = os.urandom(24)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'): return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

@app.route('/login', methods=['GET', 'POST'])
def login():
    cfg = load_config()
    if request.method == 'POST':
        if request.form.get('password') == cfg.get('web_config', {}).get('admin_password', 'admin'):
            session['logged_in'] = True
            return redirect(url_for('index'))
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>登录 - SMTP Relay Manager</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <style>
        body { background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%); height: 100vh; display: flex; align-items: center; justify-content: center; }
        .login-card { border: none; border-radius: 1rem; box-shadow: 0 10px 25px rgba(0,0,0,0.1); overflow: hidden; width: 100%; max-width: 400px; }
        .card-header { background: #fff; border-bottom: none; padding-top: 2rem; text-align: center; }
        .btn-primary { padding: 0.6rem; font-weight: 500; }
    </style>
</head>
<body>
    <div class="card login-card">
        <div class="card-header">
            <div class="bg-primary text-white rounded-circle d-inline-flex align-items-center justify-content-center mb-3" style="width: 64px; height: 64px;">
                <i class="bi bi-shield-lock-fill fs-2"></i>
            </div>
            <h4 class="fw-bold text-dark">系统登录</h4>
            <p class="text-muted small">SMTP Relay Manager</p>
        </div>
        <div class="card-body p-4">
            <form method="post">
                <div class="mb-3">
                    <div class="input-group">
                        <span class="input-group-text bg-light border-end-0"><i class="bi bi-key"></i></span>
                        <input type="password" name="password" class="form-control border-start-0 ps-0" placeholder="请输入管理员密码" required autofocus>
                    </div>
                </div>
                <button type="submit" class="btn btn-primary w-100 mb-3">立即登录</button>
            </form>
        </div>
    </div>
</body>
</html>
'''

@app.route('/')
@login_required
def index(): return render_template('index.html', config=load_config())

@app.route('/api/save', methods=['POST'])
@login_required
def api_save():
    save_config(request.json)
    global logger
    logger = setup_logging()
    return jsonify({"status": "ok"})

@app.route('/api/restart', methods=['POST'])
@login_required
def api_restart():
    def restart_server():
        time.sleep(1)
        os._exit(0)
    threading.Thread(target=restart_server).start()
    return jsonify({"status": "restarting"})

@app.route('/api/queue/stats')
@login_required
def api_queue_stats():
    with get_db() as conn:
        # Total stats
        rows = conn.execute("SELECT status, COUNT(*) as c FROM queue GROUP BY status").fetchall()
        total = {r['status']: r['c'] for r in rows}
        
        # Node stats
        rows = conn.execute("SELECT assigned_node, status, COUNT(*) as c FROM queue GROUP BY assigned_node, status").fetchall()
        nodes = {}
        for r in rows:
            n = r['assigned_node']
            if n not in nodes: nodes[n] = {}
            nodes[n][r['status']] = r['c']
            
    return jsonify({"total": total, "nodes": nodes})

@app.route('/api/queue/list')
@login_required
def api_queue_list():
    limit = request.args.get('limit', 50)
    with get_db() as conn:
        rows = conn.execute(f"SELECT id, mail_from, rcpt_tos, assigned_node, status, retry_count, last_error, created_at FROM queue ORDER BY id DESC LIMIT {limit}").fetchall()
    return jsonify([dict(r) for r in rows])

@app.route('/api/send/bulk', methods=['POST'])
@login_required
def api_send_bulk():
    data = request.json
    # sender = data.get('sender', '') # Deprecated: Use node's sender
    subject = data.get('subject', '(No Subject)')
    body = data.get('body', '')
    recipients = [r.strip() for r in data.get('recipients', '').split('\n') if r.strip()]
    
    if not recipients: return jsonify({"error": "No recipients"}), 400
    
    cfg = load_config()
    pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
    if not pool: return jsonify({"error": "No enabled nodes available"}), 500

    count = 0
    charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    
    with get_db() as conn:
        for rcpt in recipients:
            # Randomize
            rand_sub = ''.join(random.choices(charset, k=6))
            rand_body = ''.join(random.choices(charset, k=12))
            
            footer = "<br><br><hr><p style='color:#999;font-size:12px;text-align:center;'>如需退订此邮件，请到官网联系在线客服即可。</p>"
            final_subject = f"{subject} {rand_sub}"
            final_body = f"{body}{footer}<div style='display:none;opacity:0;font-size:0'>{rand_body}</div>"

            msg = MIMEText(final_body, 'html', 'utf-8')
            msg['Subject'] = final_subject
            msg['From'] = '' # Placeholder, worker will fill
            msg['To'] = rcpt
            msg['Date'] = formatdate(localtime=True)
            msg['Message-ID'] = make_msgid(), source) VALUES (?, ?, ?, ?, ?, ?)",
                ('', json.dumps([rcpt]), msg.as_bytes(), node_name, 'pending', 'bulk
            node = random.choice(pool)
            node_name = node.get('name', 'Unknown')
            
            conn.execute(
                "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status) VALUES (?, ?, ?, ?, ?)",
                ('', json.dumps([rcpt]), msg.as_bytes(), node_name, 'pending')
            )
            count += 1
            
    return jsonify({"status": "ok", "count": count})

@app.route('/api/contacts/import', methods=['POST'])
@login_required
def api_contacts_import():
    emails = request.json.get('emails', [])
    emails = [e.strip() for e in emails if e.strip()]
    added = 0
    with get_db() as conn:
        for e in emails:
            try:
                conn.execute("INSERT INTO contacts (email) VALUES (?)", (e,))
                added += 1
            except sqlite3.IntegrityError:
                pass
    return jsonify({"added": added})

@app.route('/api/contacts/list')
@login_required
def api_contacts_list():
    with get_db() as conn:
        rows = conn.execute("SELECT email FROM contacts ORDER BY id DESC").fetchall()
    return jsonify([r['email'] for r in rows])

@app.route('/api/contacts/count')
@login_required
def api_contacts_count():
    with get_db() as conn:
        c = conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0]
    return jsonify({"count": c})

@app.route('/api/contacts/clear', methods=['POST'])
@login_required
def api_contacts_clear():
    with get_db() as conn:
        conn.execute("DELETE FROM contacts")
    return jsonify({"status": "ok"})

@app.route('/api/queue/clear', methods=['POST'])
@login_required
def api_queue_clear():
    with get_db() as conn:
        conn.execute("DELETE FROM queue WHERE status IN ('sent', 'failed')")
    return jsonify({"status": "ok"})

def start_services():
    init_db()
    cfg = load_config()
    port = int(cfg.get('server_config', {}).get('port', 587))
    print(f"SMTP Port: {port}")
    
    # Start SMTP Server
    Controller(RelayHandler(), hostname='0.0.0.0', port=port).start()
    
    # Start Worker
    t = threading.Thread(target=worker_thread, daemon=True)
    t.start()
    
    app.run(host='0.0.0.0', port=8080, debug=False, use_reloader=False)

if __name__ == '__main__':
    start_services()
EOF

    # --- 2. 写入 index.html (前端增加队列管理) ---
    cat > "$APP_DIR/templates/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>SMTP Relay Pro</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        :root { --primary-bg: #f8f9fa; }
        body { background-color: var(--primary-bg); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; }
        .main-card { border: none; box-shadow: 0 0.5rem 1rem rgba(0, 0, 0, 0.05); border-radius: 1rem; overflow: hidden; }
        .nav-tabs .nav-link { border: none; color: #6c757d; padding: 1rem 1.5rem; font-weight: 500; }
        .nav-tabs .nav-link.active { color: #0d6efd; border-bottom: 3px solid #0d6efd; background: transparent; }
        .nav-tabs .nav-link:hover { color: #0d6efd; }
        .stat-card { transition: transform 0.2s; border: none; border-radius: 1rem; }
        .stat-card:hover { transform: translateY(-3px); }
        .table-custom th { background-color: #f8f9fa; font-weight: 600; text-transform: uppercase; font-size: 0.8rem; letter-spacing: 0.5px; }
        .status-badge { font-size: 0.75rem; padding: 0.35em 0.65em; }
        .btn-icon { display: inline-flex; align-items: center; gap: 0.5rem; }
    </style>
</head>
<body>
    <div id="app" class="container py-4">
        <!-- Header -->
        <header class="d-flex justify-content-between align-items-center mb-4">
            <div class="d-flex align-items-center">
                <div class="bg-primary text-white rounded-circle p-2 me-3 d-flex align-items-center justify-content-center" style="width: 48px; height: 48px;">
                    <i class="bi bi-send-fill fs-4"></i>
                </div>
                <div>
                    <h4 class="mb-0 fw-bold">SMTP Relay Manager</h4>
                    <small class="text-muted">高性能邮件中继系统</small>
                </div>
            </div>
            <div class="d-flex gap-2">
                <button class="btn btn-light text-primary" @click="showPwd = !showPwd">
                    <i class="bi bi-key-fill"></i> <span class="d-none d-md-inline">改密</span>
                </button>
                <button class="btn btn-primary btn-icon" @click="save" :disabled="saving">
                    <span v-if="saving" class="spinner-border spinner-border-sm"></span>
                    <i v-else class="bi bi-save"></i> <span>保存配置</span>
                </button>
                <button class="btn btn-danger btn-icon" @click="saveAndRestart" :disabled="saving">
                    <i class="bi bi-power"></i> <span>重启服务</span>
                </button>
            </div>
        </header>

        <!-- Password Change Alert -->
        <div v-if="showPwd" class="alert alert-light border shadow-sm mb-4">
            <div class="d-flex align-items-center justify-content-between">
                <div class="d-flex align-items-center gap-3">
                    <i class="bi bi-shield-lock fs-3 text-warning"></i>
                    <div>
                        <h6 class="mb-1">修改管理员密码</h6>
                        <div class="input-group input-group-sm">
                            <input type="text" v-model="config.web_config.admin_password" class="form-control" placeholder="新密码">
                            <button class="btn btn-success" @click="save">确认修改</button>
                        </div>
                    </div>
                </div>
                <button type="button" class="btn-close" @click="showPwd = false"></button>
            </div>
        </div>

        <!-- Main Content -->
        <div class="main-card bg-white">
            <!-- Tabs -->
            <ul class="nav nav-tabs px-4 pt-2">
                <li class="nav-item">
                    <a class="nav-link" :class="{active: tab=='queue'}" href="#" @click.prevent="tab='queue'">
                        <i class="bi bi-activity me-2"></i>运行监控
                    </a>
                </li>
                <li class="nav-item">
                    <a class="nav-link" :class="{active: tab=='send'}" href="#" @click.prevent="tab='send'">
                        <i class="bi bi-envelope-plus me-2"></i>邮件群发
                    </a>
                </li>
                <li class="nav-item">
                    <a class="nav-link" :class="{active: tab=='settings'}" href="#" @click.prevent="tab='settings'">
                        <i class="bi bi-gear me-2"></i>系统设置
                    </a>
                </li>
            </ul>

            <div class="p-4">
                <!-- Queue Tab -->
                <div v-if="tab=='queue'" class="fade-in">
                    <!-- Progress Bar -->
                    <div class="card mb-4 shadow-sm" v-if="totalMails > 0">
                        <div class="card-body">
                            <div class="d-flex justify-content-between mb-1">
                                <span class="fw-bold small text-muted">群发进度</span>
                                <span class="fw-bold small text-primary">[[ progressPercent ]]%</span>
                            </div>
                            <div class="progress" style="height: 20px;">
                                <div class="progress-bar progress-bar-striped progress-bar-animated" :class="progressPercent==100?'bg-success':'bg-primary'" role="progressbar" :style="{width: progressPercent + '%'}"></div>
                            </div>
                            <div class="text-center small text-muted mt-2">
                                已发送: [[ qStats.total.sent || 0 ]] / 总任务: [[ totalMails ]]
                            </div>
                        </div>
                    </div>

                    <!-- Stats Grid -->
                    <div class="row g-4 mb-4">
                        <div class="col-md-3 col-6" v-for="(label, key) in {'pending': '待发送', 'processing': '发送中', 'sent': '已成功', 'failed': '已失败'}" :key="key">
                            <div class="stat-card p-3 h-100" :class="'bg-'+getStatusColor(key)+'-subtle'">
                                <div class="d-flex justify-content-between">
                                    <div>
                                        <div class="text-muted small fw-bold text-uppercase">[[ label ]]</div>
                                        <div class="fs-2 fw-bold" :class="'text-'+getStatusColor(key)">[[ qStats.total[key] || 0 ]]</div>
                                    </div>
                                    <i :class="'bi bi-'+getStatusIcon(key)+' fs-1 text-'+getStatusColor(key)+' opacity-50'"></i>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Node Status -->
                    <div class="card border mb-4">
                        <div class="card-header bg-white py-3">
                            <h6 class="mb-0 fw-bold">节点实时状态</h6>
                        </div>
                        <div class="table-responsive">
                            <table class="table table-custom table-hover mb-0 align-middle">
                                <thead><tr><th>节点名称</th><th class="text-center">队列堆积</th><th class="text-center">成功数</th><th class="text-center">失败数</th></tr></thead>
                                <tbody>
                                    <tr v-for="(s, name) in qStats.nodes" :key="name">
                                        <td class="fw-medium">[[ name ]]</td>
                                        <td class="text-center"><span class="badge bg-warning text-dark">[[ s.pending || 0 ]]</span></td>
                                        <td class="text-center text-success">[[ s.sent || 0 ]]</td>
                                        <td class="text-center text-danger">[[ s.failed || 0 ]]</td>
                                    </tr>
                                    <tr v-if="Object.keys(qStats.nodes).length === 0"><td colspan="4" class="text-center text-muted py-3">暂无活动数据</td></tr>
                                </tbody>
                            </table>
                        </div>
                    </div>

                    <!-- Recent Logs -->
                    <div class="d-flex justify-content-between align-items-center mb-3">
                        <h5 class="mb-0 fw-bold">最近投递记录</h5>
                        <div class="btn-group">
                            <button class="btn btn-sm btn-outline-secondary" @click="fetchQueue"><i class="bi bi-arrow-clockwise"></i> 刷新</button>
                            <button class="btn btn-sm btn-outline-danger" @click="clearQueue"><i class="bi bi-trash"></i> 清理历史</button>
                        </div>
                    </div>
                    <div class="table-responsive border rounded">
                        <table class="table table-custom table-hover mb-0 align-middle">
                            <thead><tr><th class="ps-3">ID</th><th>发件人 / 收件人</th><th>节点</th><th>状态</th><th>时间</th></tr></thead>
                            <tbody>
                                <tr v-for="m in qList" :key="m.id">
                                    <td class="ps-3 text-muted">#[[ m.id ]]</td>
                                    <td>
                                        <div class="fw-bold">[[ m.mail_from ]]</div>
                                        <div class="text-muted small text-truncate" style="max-width: 300px;">[[ m.rcpt_tos ]]</div>
                                    </td>
                                    <td><span class="badge bg-light text-dark border">[[ m.assigned_node ]]</span></td>
                                    <td>
                                        <span class="badge status-badge" :class="'bg-'+getStatusColor(m.status)">[[ m.status ]]</span>
                                        <div v-if="m.last_error" class="text-danger small mt-1" style="font-size: 0.75rem;">[[ m.last_error ]]</div>
                                    </td>
                                    <td class="text-muted small">[[ m.created_at ]]</td>
                                </tr>
                                <tr v-if="qList.length===0"><td colspan="5" class="text-center py-5 text-muted">暂无记录</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Send Tab -->
                <div v-if="tab=='send'" class="fade-in">
                    <div class="row g-4">
                        <div class="col-lg-8">
                            <div class="card border h-100">
                                <div class="card-body">
                                    <h6 class="card-title fw-bold mb-3">邮件内容编辑</h6>
                                    <div class="mb-3">
                                        <label class="form-label text-muted small">主题 (Subject)</label>
                                        <input v-model="bulk.subject" class="form-control" placeholder="邮件主题 (自动追加随机码)">
                                    </div>
                                    <div class="mb-3">
                                        <label class="form-label text-muted small">正文 (HTML支持)</label>
                                        <textarea v-model="bulk.body" class="form-control font-monospace" rows="12" placeholder="<html>...</html> (自动插入隐形随机码)"></textarea>
                                    </div>
                                </div>
                            </div>
                        </div>
                        <div class="col-lg-4">
                            <div class="card border h-100">
                                <div class="card-body d-flex flex-column">
                                    <h6 class="card-title fw-bold mb-3">收件人管理</h6>
                                    <div class="mb-2 d-flex gap-2">
                                        <button class="btn btn-sm btn-outline-primary flex-grow-1" @click="loadContacts">
                                            <i class="bi bi-database-down"></i> 加载全部 ([[ contactCount ]])
                                        </button>
                                        <button class="btn btn-sm btn-outline-success flex-grow-1" @click="saveContacts">
                                            <i class="bi bi-person-plus"></i> 保存当前
                                        </button>
                                    </div>
                                    <textarea v-model="bulk.recipients" class="form-control flex-grow-1 mb-3" placeholder="每行一个邮箱地址..." style="min-height: 200px;"></textarea>
                                    <div class="d-flex justify-content-between align-items-center mb-3">
                                        <span class="text-muted small">共 [[ recipientCount ]] 人</span>
                                        <button class="btn btn-sm btn-outline-danger" @click="clearContacts"><i class="bi bi-trash"></i> 清空库</button>
                                    </div>
                                    <button class="btn btn-primary w-100 py-2" @click="sendBulk" :disabled="sending || recipientCount === 0">
                                        <span v-if="sending" class="spinner-border spinner-border-sm me-2"></span>
                                        <i v-else class="bi bi-send-fill me-2"></i>
                                        [[ sending ? '发送中...' : '确认发送' ]]
                                    </button>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Settings Tab -->
                <div v-if="tab=='settings'" class="fade-in">
                    <div class="row g-4">
                        <!-- Sending Policy -->
                        <div class="col-md-6">
                            <div class="card border h-100">
                                <div class="card-header bg-white fw-bold">发送策略控制</div>
                                <div class="card-body">
                                    <div class="mb-3">
                                        <label class="form-label small text-muted">每小时最大发送量 (0为不限)</label>
                                        <input type="number" v-model.number="config.limit_config.max_per_hour" class="form-control">
                                    </div>
                                    <div class="row g-3">
                                        <div class="col-6">
                                            <label class="form-label small text-muted">最小间隔(秒)</label>
                                            <input type="number" v-model.number="config.limit_config.min_interval" class="form-control">
                                        </div>
                                        <div class="col-6">
                                            <label class="form-label small text-muted">最大间隔(秒)</label>
                                            <input type="number" v-model.number="config.limit_config.max_interval" class="form-control">
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Basic Config -->
                        <div class="col-md-6">
                            <div class="card border h-100">
                                <div class="card-header bg-white fw-bold">基础监听配置</div>
                                <div class="card-body">
                                    <div class="mb-3">
                                        <label class="form-label small text-muted">监听端口 (重启生效)</label>
                                        <input type="number" v-model.number="config.server_config.port" class="form-control">
                                    </div>
                                    <div class="row g-3">
                                        <div class="col-6">
                                            <label class="form-label small text-muted">认证账号</label>
                                            <input v-model="config.server_config.username" class="form-control">
                                        </div>
                                        <div class="col-6">
                                            <label class="form-label small text-muted">认证密码</label>
                                            <input v-model="config.server_config.password" class="form-control">
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                        <!-- Notification -->
                        <div class="col-md-6">
                            <div class="card border h-100">
                                <div class="card-header bg-white fw-bold">通知与日志</div>
                                <div class="card-body">
                                    <div class="row g-3 mb-3">
                                        <div class="col-8">
                                            <label class="form-label small text-muted">TG Bot Token</label>
                                            <input v-model="config.telegram_config.bot_token" class="form-control form-control-sm">
                                        </div>
                                        <div class="col-4">
                                            <label class="form-label small text-muted">Chat ID</label>
                                            <input v-model="config.telegram_config.admin_id" class="form-control form-control-sm">
                                        </div>
                                    </div>
                                    <div class="row g-3">
                                        <div class="col-6">
                                            <label class="form-label small text-muted">日志大小(MB)</label>
                                            <input type="number" v-model.number="config.log_config.max_mb" class="form-control form-control-sm">
                                        </div>
                                        <div class="col-6">
                                            <label class="form-label small text-muted">保留份数</label>
                                            <input type="number" v-model.number="config.log_config.backups" class="form-control form-control-sm">
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                        
                        <!-- Node Pool -->
                        <div class="col-12">
                            <div class="card border">
                                <div class="card-header bg-white d-flex justify-content-between align-items-center">
                                    <span class="fw-bold">下游节点池 (Load Balancing)</span>
                                    <button class="btn btn-sm btn-primary" @click="addNode"><i class="bi bi-plus-lg"></i> 添加节点</button>
                                </div>
                                <div class="card-body bg-light p-3">
                                    <div v-if="config.downstream_pool.length === 0" class="text-center py-4 text-muted">
                                        暂无节点，请添加
                                    </div>
                                    <div v-for="(n, i) in config.downstream_pool" :key="i" class="card mb-3 shadow-sm">
                                        <div class="card-body">
                                            <div class="d-flex justify-content-between align-items-center mb-3">
                                                <div class="d-flex align-items-center gap-3">
                                                    <div class="form-check form-switch">
                                                        <input class="form-check-input" type="checkbox" v-model="n.enabled" style="width: 2.5em; height: 1.25em;">
                                                    </div>
                                                    <span class="fw-bold">[[ n.name ]]</span>
                                                    <span class="badge" :class="n.enabled!==false?'bg-success':'bg-secondary'">[[ n.enabled!==false?'启用':'禁用' ]]</span>
                                                </div>
                                                <button class="btn btn-sm btn-outline-danger" @click="delNode(i)"><i class="bi bi-trash"></i></button>
                                            </div>
                                            <div class="row g-2">
                                                <div class="col-md-2"><input v-model="n.name" class="form-control form-control-sm" placeholder="备注"></div>
                                                <div class="col-md-3"><input v-model="n.host" class="form-control form-control-sm" placeholder="Host"></div>
                                                <div class="col-md-1"><input v-model.number="n.port" class="form-control form-control-sm" placeholder="Port"></div>
                                                <div class="col-md-2">
                                                    <select v-model="n.encryption" class="form-select form-select-sm">
                                                        <option value="none">None</option>
                                                        <option value="tls">TLS</option>
                                                        <option value="ssl">SSL</option>
                                                    </select>
                                                </div>
                                                <div class="col-md-2"><input v-model="n.username" class="form-control form-control-sm" placeholder="User"></div>
                                                <div class="col-md-2"><input v-model="n.password" type="password" class="form-control form-control-sm" placeholder="Pass"></div>
                                                <div class="col-md-12 mt-2">
                                                    <div class="input-group input-group-sm">
                                                        <span class="input-group-text">Sender Rewrite</span>
                                                        <input v-model="n.sender_email" class="form-control" placeholder="强制修改发件人地址 (留空不修改)">
                                                    </div>
                                                </div>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const { createApp } = Vue;
        createApp({
            delimiters: ['[[', ']]'],
            data() {
                return {
                    tab: 'queue',
                    config: {{ config | tojson }},
                    saving: false,
                    showPwd: false,
                    qStats: { total: {}, nodes: {} },
                    qList: [],
                    bulk: { sender: '', subject: '', recipients: '', body: '' },
                    sending: false,
                    contactCount: 0
                }
            },
            computed: {
                recipientCount() { return this.bulk.recipients ? this.bulk.recipients.split('\n').filter(r => r.trim()).length : 0; },
                totalMails() {
                    const t = this.qStats.total;
                    return (t.pending||0) + (t.processing||0) + (t.sent||0) + (t.failed||0);
                },
                progressPercent() {
                    if(this.totalMails === 0) return 0;
                    return Math.round(((this.qStats.total.sent||0) / this.totalMails) * 100);
                }
            },
            mounted() {
                if(!this.config.limit_config) this.config.limit_config = { max_per_hour: 0, min_interval: 1, max_interval: 5 };
                this.config.downstream_pool.forEach(n => { if(n.enabled === undefined) n.enabled = true; });
                this.fetchQueue();
                this.fetchContactCount();
                setInterval(this.fetchQueue, 5000);
            },
            methods: {
                getStatusColor(status) {
                    const map = { 'pending': 'warning', 'processing': 'primary', 'sent': 'success', 'failed': 'danger' };
                    return map[status] || 'secondary';
                },
                getStatusIcon(status) {
                    const map = { 'pending': 'hourglass-split', 'processing': 'send', 'sent': 'check-circle', 'failed': 'x-circle' };
                    return map[status] || 'question-circle';
                },
                async fetchContactCount() {
                    try {
                        const res = await fetch('/api/contacts/count');
                        const data = await res.json();
                        this.contactCount = data.count;
                    } catch(e) {}
                },
                async saveContacts() {
                    const emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                    if(emails.length === 0) return alert('输入框为空');
                    if(!confirm(`确定保存 ${emails.length} 个邮箱? (自动去重)`)) return;
                    try {
                        const res = await fetch('/api/contacts/import', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({emails: emails})
                        });
                        const data = await res.json();
                        alert(`成功新增 ${data.added} 个`);
                        this.fetchContactCount();
                    } catch(e) { alert('失败: ' + e); }
                },
                async loadContacts() {
                    if(this.bulk.recipients && !confirm('覆盖当前输入框?')) return;
                    try {
                        const res = await fetch('/api/contacts/list');
                        const emails = await res.json();
                        this.bulk.recipients = emails.join('\n');
                    } catch(e) { alert('失败: ' + e); }
                },
                async clearContacts() {
                    if(!confirm('⚠️ 确定清空通讯录?')) return;
                    try {
                        await fetch('/api/contacts/clear', { method: 'POST' });
                        this.fetchContactCount();
                        alert('已清空');
                    } catch(e) { alert('失败: ' + e); }
                },
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node-'+Math.floor(Math.random()*1000), host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '', enabled: true }); 
                },
                delNode(i) { if(confirm('删除此节点?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        alert('保存成功');
                        this.showPwd = false;
                    } catch(e) { alert('失败: ' + e); }
                    this.saving = false;
                },
                async saveAndRestart() {
                    if(!confirm('保存并重启服务?')) return;
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        await fetch('/api/restart', { method: 'POST' });
                        alert('正在重启...请稍后刷新');
                    } catch(e) { alert('失败: ' + e); }
                    this.saving = false;
                },
                async fetchQueue() {
                    try {
                        const res1 = await fetch('/api/queue/stats');
                        this.qStats = await res1.json();
                        if(this.tab === 'queue') {
                            const res2 = await fetch('/api/queue/list?limit=50');
                            this.qList = await res2.json();
                        }
                    } catch(e) { console.error(e); }
                },
                async sendBulk() {
                    if(!this.bulk.subject || !this.bulk.body) return alert('请填写完整信息');
                    if(!confirm(`确认发送给 ${this.recipientCount} 人?`)) return;
                    this.sending = true;
                    try {
                        const res = await fetch('/api/send/bulk', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify(this.bulk)
                        });
                        const data = await res.json();
                        if(res.ok) {
                            alert(`已加入队列: ${data.count} 封`);
                            this.bulk.recipients = ''; 
                            this.tab = 'queue';
                            this.fetchQueue();
                        } else {
                            alert('错误: ' + data.error);
                        }
                    } catch(e) { alert('失败: ' + e); }
                    this.sending = false;
                },
                async clearQueue() {
                    if(!confirm('清理历史记录? (保留Pending)')) return;
                    await fetch('/api/queue/clear', { method: 'POST' });
                    this.fetchQueue();
                }
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF

    cat > /etc/supervisor/conf.d/smtp_web.conf << EOF
[program:smtp-web]
directory=$APP_DIR
command=$VENV_DIR/bin/python3 app.py
autostart=true
autorestart=true
stderr_logfile=$LOG_DIR/err.log
stdout_logfile=$LOG_DIR/out.log
user=root
EOF

    ufw allow 8080/tcp >/dev/null 2>&1
    ufw allow 587/tcp >/dev/null 2>&1
    iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
    iptables -I INPUT 1 -p tcp --dport 587 -j ACCEPT
    if dpkg -l | grep -q netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1; fi

    supervisorctl reread >/dev/null
    supervisorctl update >/dev/null
    supervisorctl restart smtp-web

    # Get IP
    IP=$(curl -s ifconfig.me || echo "你的服务器IP")

    echo -e "${GREEN}✅ 安装/更新完成！${PLAIN}"
    echo -e "==============================================="
    echo -e " Web 管理面板: http://${IP}:8080"
    echo -e " 默认密码:     admin"
    echo -e "-----------------------------------------------"
    echo -e " SMTP 服务器:  ${IP}:587"
    echo -e " SMTP 账号:    myapp (默认)"
    echo -e " SMTP 密码:    123   (默认)"
    echo -e "-----------------------------------------------"
    echo -e " 安装目录:     $APP_DIR"
    echo -e " 日志目录:     $LOG_DIR"
    echo -e "==============================================="
    echo -e "如果无法访问，请检查防火墙端口 8080/587 是否开放。"
}

uninstall_smtp() {
    echo -e "${YELLOW}⚠️  警告: 即将卸载!${PLAIN}"
    read -p "确认? [y/n]: " choice
    if [[ "$choice" == "y" ]]; then
        supervisorctl stop smtp-web
        rm -f /etc/supervisor/conf.d/smtp_web.conf
        supervisorctl reread
        supervisorctl update
        rm -rf "$APP_DIR" "$LOG_DIR"
        echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
    fi
}

show_menu() {
    clear
    echo -e "============================================"
    echo -e "   🚀 SMTP Relay Manager 管理脚本 "
    echo -e "============================================"
    echo -e "${GREEN}1.${PLAIN} 安装 / 更新 "
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看日志"
    echo -e "${GREEN}6.${PLAIN} 命令行强制重置密码"
    echo -e "${RED}0.${PLAIN} 卸载"
    echo -e "============================================"
    read -p "选择: " num

    case "$num" in
        1) install_smtp ;;
        2) supervisorctl start smtp-web ;;
        3) supervisorctl stop smtp-web ;;
        4) supervisorctl restart smtp-web ;;
        5) tail -f $LOG_DIR/app.log ;;
        6) 
           read -p "新密码: " new_pass
           cd $APP_DIR
           $VENV_DIR/bin/python3 -c "import json; f='config.json'; d=json.load(open(f)); d['web_config']['admin_password']='$new_pass'; json.dump(d, open(f,'w'), indent=4)"
           echo -e "${GREEN}✅ 密码已重置${PLAIN}"
           ;;
        0) uninstall_smtp ;;
        *) echo -e "${RED}无效${PLAIN}" ;;
    esac
}

show_menu
