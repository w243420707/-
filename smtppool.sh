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
    "bulk_control": { "status": "running" },
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
        
        # Check and add source column safely
        try:
            cursor = conn.execute("PRAGMA table_info(queue)")
            cols = [c[1] for c in cursor.fetchall()]
            if 'source' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN source TEXT DEFAULT 'relay'")
        except Exception as e:
            print(f"DB Init Warning: {e}")

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
            
            # Rate Limiting & Manual Control (Bulk Only)
            limit_cfg = cfg.get('limit_config', {})
            bulk_ctrl = cfg.get('bulk_control', {}).get('status', 'running')
            max_ph = int(limit_cfg.get('max_per_hour', 0))
            
            # Pause if manually paused OR rate limited
            bulk_paused = (bulk_ctrl == 'paused')
            
            if not bulk_paused and max_ph > 0:
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
                        # Only fetch relay mails, skip bulk
                        cursor = conn.execute("SELECT * FROM queue WHERE status='pending' AND source!='bulk' LIMIT 5")
                    except:
                        # Fallback if source column missing (shouldn't happen)
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
                    else:
                        conn.execute("UPDATE queue SET status='failed', last_error=?, updated_at=CURRENT_TIMESTAMP WHERE id=?", (error_msg, row_id))
                        send_telegram(f"❌ Mail ID:{row_id} Failed permanently via {node_name}\nErr: {error_msg}")
                
                # Random Interval (Bulk Only)
                is_bulk = False
                try:
                    if row['source'] == 'bulk': is_bulk = True
                except: pass
                
                if is_bulk:
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

def bulk_import_task(raw_recipients, subject, body, pool):
    try:
        # Process recipients in background to avoid blocking
        recipients = [r.strip() for r in raw_recipients.split('\n') if r.strip()]
        random.shuffle(recipients) # Shuffle for better distribution
        
        charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        tasks = []
        count = 0
        
        for rcpt in recipients:
            try:
                # Randomize
                rand_sub = ''.join(random.choices(charset, k=6))
                rand_body = ''.join(random.choices(charset, k=12))
                
                # footer removed
                final_subject = f"{subject} {rand_sub}"
                final_body = f"{body}<div style='display:none;opacity:0;font-size:0'>{rand_body}</div>"

                msg = MIMEText(final_body, 'html', 'utf-8')
                msg['Subject'] = final_subject
                msg['From'] = '' # Placeholder, worker will fill
                msg['To'] = rcpt
                msg['Date'] = formatdate(localtime=True)
                msg['Message-ID'] = make_msgid()

                node = random.choice(pool)
                node_name = node.get('name', 'Unknown')
                
                tasks.append(('', json.dumps([rcpt]), msg.as_bytes(), node_name, 'pending', 'bulk'))
                count += 1
                
                if len(tasks) >= 500:
                    with get_db() as conn:
                        conn.executemany(
                            "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source) VALUES (?, ?, ?, ?, ?, ?)",
                            tasks
                        )
                    tasks = []
            except Exception as e:
                logger.error(f"Error preparing email for {rcpt}: {e}")
                continue

        if tasks:
            with get_db() as conn:
                conn.executemany(
                    "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source) VALUES (?, ?, ?, ?, ?, ?)",
                    tasks
                )
        logger.info(f"Bulk import finished: {count} emails processed")
    except Exception as e:
        logger.error(f"Bulk import task failed: {e}")

@app.route('/api/send/bulk', methods=['POST'])
@login_required
def api_send_bulk():
    try:
        data = request.json
        subject = data.get('subject', '(No Subject)')
        body = data.get('body', '')
        raw_recipients = data.get('recipients', '')
        
        if not raw_recipients.strip(): return jsonify({"error": "No recipients"}), 400
        
        cfg = load_config()
        pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
        if not pool: return jsonify({"error": "No enabled nodes available"}), 500

        # Start background task with raw string
        threading.Thread(target=bulk_import_task, args=(raw_recipients, subject, body, pool)).start()
                
        return jsonify({"status": "ok", "count": "Processing in background"})
    except Exception as e:
        logger.error(f"Bulk send error: {e}")
        return jsonify({"error": str(e)}), 500

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
        conn.execute("DELETE FROM queue WHERE status IN ('sent', 'failed', 'processing')")
    return jsonify({"status": "ok"})
@app.route('/api/bulk/control', methods=['POST'])
@login_required
def api_bulk_control():
    action = request.json.get('action')
    cfg = load_config()
    if 'bulk_control' not in cfg: cfg['bulk_control'] = {'status': 'running'}
    
    if action == 'pause':
        cfg['bulk_control']['status'] = 'paused'
        save_config(cfg)
    elif action == 'resume':
        cfg['bulk_control']['status'] = 'running'
        save_config(cfg)
    elif action == 'stop':
        # Stop means clear pending bulk
        with get_db() as conn:
            conn.execute("DELETE FROM queue WHERE (status='pending' OR status='processing') AND source='bulk'")
        # Also pause to be safe? No, just clear queue is enough for "Stop" usually.
        # But user might want to stop and then resume later with new list.
        
    return jsonify({"status": "ok", "current": cfg['bulk_control']['status']})

@app.route('/api/bulk/status')
@login_required
def api_bulk_status():
    cfg = load_config()
    return jsonify(cfg.get('bulk_control', {'status': 'running'}))


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
        :root { --sidebar-width: 240px; --primary-color: #4361ee; --bg-color: #f8f9fa; }
        body { background-color: var(--bg-color); font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; overflow-x: hidden; }
        
        /* Sidebar */
        .sidebar { width: var(--sidebar-width); height: 100vh; position: fixed; left: 0; top: 0; background: #fff; border-right: 1px solid #eee; z-index: 1000; display: flex; flex-direction: column; }
        .sidebar-header { padding: 1.5rem; display: flex; align-items: center; gap: 0.75rem; border-bottom: 1px solid #f0f0f0; }
        .logo-icon { width: 32px; height: 32px; background: var(--primary-color); color: #fff; border-radius: 8px; display: flex; align-items: center; justify-content: center; font-size: 1.2rem; }
        .nav-menu { padding: 1.5rem 1rem; flex: 1; }
        .nav-item { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 1rem; color: #666; text-decoration: none; border-radius: 8px; margin-bottom: 0.5rem; transition: all 0.2s; cursor: pointer; }
        .nav-item:hover { background: #f8f9fa; color: var(--primary-color); }
        .nav-item.active { background: #eef2ff; color: var(--primary-color); font-weight: 600; }
        .nav-item i { font-size: 1.2rem; }
        
        /* Main Content */
        .main-content { margin-left: var(--sidebar-width); padding: 2rem; min-height: 100vh; }
        
        /* Cards */
        .card { border: none; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.03); background: #fff; transition: transform 0.2s; }
        .stat-card:hover { transform: translateY(-2px); }
        .card-header { background: transparent; border-bottom: 1px solid #f0f0f0; padding: 1.25rem; font-weight: 600; }
        
        /* Status Colors */
        .text-pending { color: #f59e0b; } .bg-pending-subtle { background: #fffbeb; }
        .text-processing { color: #3b82f6; } .bg-processing-subtle { background: #eff6ff; }
        .text-sent { color: #10b981; } .bg-sent-subtle { background: #ecfdf5; }
        .text-failed { color: #ef4444; } .bg-failed-subtle { background: #fef2f2; }
        
        /* Utils */
        .btn-primary { background: var(--primary-color); border-color: var(--primary-color); }
        .table-custom th { font-weight: 600; color: #666; background: #f8f9fa; border-bottom: 2px solid #eee; }
        .table-custom td { vertical-align: middle; }
        
        @media (max-width: 768px) {
            .sidebar { transform: translateX(-100%); transition: transform 0.3s; }
            .sidebar.show { transform: translateX(0); }
            .main-content { margin-left: 0; padding: 1rem; }
            .mobile-toggle { display: block !important; }
        }
    </style>
</head>
<body>
    <div id="app">
        <!-- Mobile Toggle -->
        <div class="d-md-none p-3 bg-white border-bottom d-flex justify-content-between align-items-center sticky-top">
            <div class="d-flex align-items-center gap-2">
                <div class="logo-icon" style="width: 28px; height: 28px;"><i class="bi bi-send-fill"></i></div>
                <span class="fw-bold">SMTP Relay</span>
            </div>
            <button class="btn btn-light" @click="mobileMenu = !mobileMenu"><i class="bi bi-list fs-4"></i></button>
        </div>

        <!-- Sidebar -->
        <div class="sidebar" :class="{show: mobileMenu}">
            <div class="sidebar-header">
                <div class="logo-icon"><i class="bi bi-send-fill"></i></div>
                <div>
                    <div class="fw-bold text-dark">SMTP Relay</div>
                    <div class="small text-muted" style="font-size: 0.75rem;">Pro Manager</div>
                </div>
            </div>
            <div class="nav-menu">
                <div class="nav-item" :class="{active: tab=='queue'}" @click="tab='queue'; mobileMenu=false">
                    <i class="bi bi-grid-1x2-fill"></i> <span>运行监控</span>
                </div>
                <div class="nav-item" :class="{active: tab=='send'}" @click="tab='send'; mobileMenu=false">
                    <i class="bi bi-envelope-paper-fill"></i> <span>邮件群发</span>
                </div>
                <div class="nav-item" :class="{active: tab=='settings'}" @click="tab='settings'; mobileMenu=false">
                    <i class="bi bi-gear-fill"></i> <span>系统设置</span>
                </div>
            </div>
            <div class="p-3 border-top">
                <button class="btn btn-light w-100 text-start mb-2" @click="showPwd = !showPwd">
                    <i class="bi bi-key me-2"></i> 修改密码
                </button>
                <button class="btn btn-danger w-100 text-start" @click="saveAndRestart">
                    <i class="bi bi-power me-2"></i> 重启服务
                </button>
            </div>
        </div>

        <!-- Main Content -->
        <div class="main-content">
            <!-- Password Modal -->
            <div v-if="showPwd" class="card mb-4 border-warning" style="border-left: 4px solid #ffc107;">
                <div class="card-body d-flex align-items-center justify-content-between">
                    <div class="d-flex align-items-center gap-3">
                        <div class="bg-warning bg-opacity-10 p-2 rounded text-warning"><i class="bi bi-shield-lock fs-4"></i></div>
                        <div>
                            <h6 class="mb-1 fw-bold">修改管理员密码</h6>
                            <div class="input-group input-group-sm" style="max-width: 300px;">
                                <input type="text" v-model="config.web_config.admin_password" class="form-control" placeholder="输入新密码">
                                <button class="btn btn-dark" @click="save">保存</button>
                            </div>
                        </div>
                    </div>
                    <button class="btn-close" @click="showPwd = false"></button>
                </div>
            </div>

            <!-- Dashboard / Queue -->
            <div v-if="tab=='queue'" class="fade-in">
                <div class="d-flex justify-content-between align-items-center mb-4">
                    <h4 class="fw-bold mb-0">运行监控</h4>
                    <div class="d-flex gap-2">
                        <button class="btn btn-white border shadow-sm" @click="fetchQueue"><i class="bi bi-arrow-clockwise"></i></button>
                    </div>
                </div>

                <!-- Bulk Control Panel -->
                <div class="card mb-4 border-0 shadow-sm" v-if="totalMails > 0 || bulkStatus == 'paused'">
                    <div class="card-body">
                        <div class="d-flex justify-content-between align-items-center">
                            <div class="d-flex align-items-center gap-3">
                                <div class="p-2 rounded-circle" :class="statusClass">
                                    <i class="bi" :class="statusIcon"></i>
                                </div>
                                <div>
                                    <h6 class="fw-bold mb-0">群发任务 [[ statusText ]]</h6>
                                    <div class="small text-muted">进度: [[ progressPercent ]]% ([[ qStats.total.sent || 0 ]] / [[ totalMails ]])</div>
                                </div>
                            </div>
                            <div class="btn-group">
                                <template v-if="!isFinished">
                                    <button v-if="bulkStatus=='running'" class="btn btn-warning text-white" @click="controlBulk('pause')"><i class="bi bi-pause-fill"></i> 暂停</button>
                                    <button v-else class="btn btn-success" @click="controlBulk('resume')"><i class="bi bi-play-fill"></i> 继续</button>
                                    <button class="btn btn-danger" @click="controlBulk('stop')"><i class="bi bi-stop-fill"></i> 停止</button>
                                </template>
                                <button v-else class="btn btn-outline-primary" @click="clearQueue"><i class="bi bi-check-all"></i> 完成并清理</button>
                            </div>
                        </div>
                        <div class="progress mt-3" style="height: 6px;">
                            <div class="progress-bar" :class="isFinished?'bg-success':'bg-primary'" :style="{width: progressPercent + '%'}"></div>
                        </div>
                    </div>
                </div>

                <!-- Stats Cards -->
                <div class="row g-4 mb-4">
                    <div class="col-md-3 col-6" v-for="(label, key) in {'pending': '待发送', 'processing': '发送中', 'sent': '已成功', 'failed': '已失败'}" :key="key">
                        <div class="card stat-card h-100">
                            <div class="card-body">
                                <div class="d-flex justify-content-between align-items-start mb-2">
                                    <div class="p-2 rounded" :class="'bg-'+key+'-subtle text-'+key">
                                        <i class="bi" :class="getStatusIcon(key)"></i>
                                    </div>
                                    <span class="badge rounded-pill border text-muted">Total</span>
                                </div>
                                <h2 class="fw-bold mb-0">[[ qStats.total[key] || 0 ]]</h2>
                                <div class="small text-muted">[[ label ]]</div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Node Status -->
                <div class="card mb-4">
                    <div class="card-header">节点健康状态</div>
                    <div class="table-responsive">
                        <table class="table table-custom table-hover mb-0">
                            <thead><tr><th>节点名称</th><th class="text-center">堆积</th><th class="text-center">成功</th><th class="text-center">失败</th></tr></thead>
                            <tbody>
                                <tr v-for="(s, name) in qStats.nodes" :key="name">
                                    <td class="fw-medium">[[ name ]]</td>
                                    <td class="text-center"><span class="badge bg-warning text-dark">[[ s.pending || 0 ]]</span></td>
                                    <td class="text-center text-success">[[ s.sent || 0 ]]</td>
                                    <td class="text-center text-danger">[[ s.failed || 0 ]]</td>
                                </tr>
                                <tr v-if="Object.keys(qStats.nodes).length === 0"><td colspan="4" class="text-center text-muted py-4">暂无节点数据</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Recent Logs -->
                <div class="card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <span>最近投递记录</span>
                        <button class="btn btn-sm btn-outline-danger" @click="clearQueue">清理历史</button>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-custom table-hover mb-0">
                            <thead><tr><th class="ps-4">ID</th><th>详情</th><th>节点</th><th>状态</th><th>时间</th></tr></thead>
                            <tbody>
                                <tr v-for="m in qList" :key="m.id">
                                    <td class="ps-4 text-muted">#[[ m.id ]]</td>
                                    <td>
                                        <div class="fw-bold text-dark">[[ m.mail_from ]]</div>
                                        <div class="text-muted small text-truncate" style="max-width: 250px;">[[ m.rcpt_tos ]]</div>
                                    </td>
                                    <td><span class="badge bg-light text-dark border">[[ m.assigned_node ]]</span></td>
                                    <td>
                                        <span class="badge" :class="'bg-'+m.status+'-subtle text-'+m.status">[[ m.status ]]</span>
                                        <div v-if="m.last_error" class="text-danger small mt-1" style="font-size: 0.7rem;">[[ m.last_error ]]</div>
                                    </td>
                                    <td class="text-muted small">[[ m.created_at ]]</td>
                                </tr>
                                <tr v-if="qList.length===0"><td colspan="5" class="text-center py-5 text-muted">暂无记录</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- Send Tab -->
            <div v-if="tab=='send'" class="fade-in">
                <h4 class="fw-bold mb-4">邮件群发</h4>
                <div class="row g-4">
                    <div class="col-lg-8">
                        <div class="card h-100">
                            <div class="card-body">
                                <div class="mb-3">
                                    <label class="form-label fw-bold">邮件主题</label>
                                    <input v-model="bulk.subject" class="form-control form-control-lg" placeholder="输入主题 (系统会自动追加随机码)">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label fw-bold">邮件正文 (HTML)</label>
                                    <textarea v-model="bulk.body" class="form-control font-monospace bg-light" rows="15" placeholder="<html>...</html>"></textarea>
                                    <div class="form-text">系统会自动在末尾插入隐形随机码和退订链接。</div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="col-lg-4">
                        <div class="card h-100">
                            <div class="card-header bg-white">收件人列表</div>
                            <div class="card-body d-flex flex-column">
                                <div class="d-flex gap-2 mb-3">
                                    <button class="btn btn-outline-primary flex-grow-1" @click="loadContacts"><i class="bi bi-cloud-download"></i> 加载全部</button>
                                    <button class="btn btn-outline-success flex-grow-1" @click="saveContacts"><i class="bi bi-cloud-upload"></i> 保存当前</button>
                                </div>
                                <textarea v-model="bulk.recipients" class="form-control flex-grow-1 mb-3" placeholder="每行一个邮箱地址..." style="min-height: 200px;"></textarea>
                                <div class="d-flex justify-content-between align-items-center mb-3">
                                    <span class="fw-bold">[[ recipientCount ]] 人</span>
                                    <button class="btn btn-sm btn-link text-danger text-decoration-none" @click="clearContacts">清空通讯录</button>
                                </div>
                                <button class="btn btn-primary w-100 py-3 fw-bold" @click="sendBulk" :disabled="sending || recipientCount === 0">
                                    <span v-if="sending" class="spinner-border spinner-border-sm me-2"></span>
                                    <i v-else class="bi bi-send-fill me-2"></i>
                                    [[ sending ? '正在提交...' : '确认发送' ]]
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Settings Tab -->
            <div v-if="tab=='settings'" class="fade-in">
                <div class="d-flex justify-content-between align-items-center mb-4">
                    <h4 class="fw-bold mb-0">系统设置</h4>
                    <button class="btn btn-primary" @click="save" :disabled="saving">
                        <span v-if="saving" class="spinner-border spinner-border-sm me-2"></span>
                        保存配置
                    </button>
                </div>

                <div class="row g-4">
                    <div class="col-md-6">
                        <div class="card h-100">
                            <div class="card-header">发送策略 (Rate Limiting)</div>
                            <div class="card-body">
                                <div class="mb-3">
                                    <label class="form-label">每小时最大发送量</label>
                                    <div class="input-group">
                                        <input type="number" v-model.number="config.limit_config.max_per_hour" class="form-control">
                                        <span class="input-group-text">封</span>
                                    </div>
                                    <div class="form-text">设为 0 则不限制</div>
                                </div>
                                <div class="row g-3">
                                    <div class="col-6">
                                        <label class="form-label">最小间隔</label>
                                        <div class="input-group">
                                            <input type="number" v-model.number="config.limit_config.min_interval" class="form-control">
                                            <span class="input-group-text">秒</span>
                                        </div>
                                    </div>
                                    <div class="col-6">
                                        <label class="form-label">最大间隔</label>
                                        <div class="input-group">
                                            <input type="number" v-model.number="config.limit_config.max_interval" class="form-control">
                                            <span class="input-group-text">秒</span>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="col-md-6">
                        <div class="card h-100">
                            <div class="card-header">基础配置</div>
                            <div class="card-body">
                                <div class="mb-3">
                                    <label class="form-label">监听端口</label>
                                    <input type="number" v-model.number="config.server_config.port" class="form-control">
                                </div>
                                <div class="row g-3">
                                    <div class="col-6">
                                        <label class="form-label">认证账号</label>
                                        <input v-model="config.server_config.username" class="form-control">
                                    </div>
                                    <div class="col-6">
                                        <label class="form-label">认证密码</label>
                                        <input v-model="config.server_config.password" class="form-control">
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="col-12">
                        <div class="card">
                            <div class="card-header d-flex justify-content-between align-items-center">
                                <span>下游节点池 (Load Balancing)</span>
                                <button class="btn btn-sm btn-outline-primary" @click="addNode"><i class="bi bi-plus-lg"></i> 添加节点</button>
                            </div>
                            <div class="card-body bg-light">
                                <div v-if="config.downstream_pool.length === 0" class="text-center py-5 text-muted">
                                    暂无节点，请点击右上角添加
                                </div>
                                <div v-for="(n, i) in config.downstream_pool" :key="i" class="card mb-3 shadow-sm">
                                    <div class="card-body">
                                        <div class="d-flex justify-content-between align-items-center mb-3">
                                            <div class="d-flex align-items-center gap-3">
                                                <div class="form-check form-switch">
                                                    <input class="form-check-input" type="checkbox" v-model="n.enabled" style="width: 3em; height: 1.5em;">
                                                </div>
                                                <span class="fw-bold fs-5">[[ n.name ]]</span>
                                                <span class="badge" :class="n.enabled!==false?'bg-success':'bg-secondary'">[[ n.enabled!==false?'启用':'禁用' ]]</span>
                                            </div>
                                            <button class="btn btn-sm btn-outline-danger" @click="delNode(i)"><i class="bi bi-trash"></i></button>
                                        </div>
                                        <div class="row g-3">
                                            <div class="col-md-3">
                                                <label class="small text-muted">备注名称</label>
                                                <input v-model="n.name" class="form-control" placeholder="备注">
                                            </div>
                                            <div class="col-md-3">
                                                <label class="small text-muted">Host</label>
                                                <input v-model="n.host" class="form-control" placeholder="smtp.example.com">
                                            </div>
                                            <div class="col-md-2">
                                                <label class="small text-muted">Port</label>
                                                <input v-model.number="n.port" class="form-control" placeholder="587">
                                            </div>
                                            <div class="col-md-2">
                                                <label class="small text-muted">加密</label>
                                                <select v-model="n.encryption" class="form-select">
                                                    <option value="none">None</option>
                                                    <option value="tls">TLS</option>
                                                    <option value="ssl">SSL</option>
                                                </select>
                                            </div>
                                            <div class="col-md-2">
                                                <label class="small text-muted">Sender Rewrite</label>
                                                <input v-model="n.sender_email" class="form-control" placeholder="可选">
                                            </div>
                                            <div class="col-md-6">
                                                <label class="small text-muted">Username</label>
                                                <input v-model="n.username" class="form-control">
                                            </div>
                                            <div class="col-md-6">
                                                <label class="small text-muted">Password</label>
                                                <input v-model="n.password" type="password" class="form-control">
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
                    mobileMenu: false,
                    config: {{ config | tojson }},
                    saving: false,
                    showPwd: false,
                    qStats: { total: {}, nodes: {} },
                    qList: [],
                    bulk: { sender: '', subject: '', recipients: '', body: '' },
                    sending: false,
                    contactCount: 0,
                    bulkStatus: 'running'
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
                },
                isFinished() {
                    const t = this.qStats.total;
                    return this.totalMails > 0 && (t.pending||0) === 0 && (t.processing||0) === 0;
                },
                statusText() {
                    if(this.bulkStatus === 'paused') return '已暂停';
                    if(this.isFinished) return '已完成';
                    return '进行中';
                },
                statusClass() {
                    if(this.bulkStatus === 'paused') return 'bg-warning-subtle text-warning';
                    if(this.isFinished) return 'bg-success-subtle text-success';
                    return 'bg-primary-subtle text-primary';
                },
                statusIcon() {
                    if(this.bulkStatus === 'paused') return 'bi-pause-circle-fill';
                    if(this.isFinished) return 'bi-check-circle-fill';
                    return 'bi-lightning-charge-fill';
                }
            },
            mounted() {
                if(!this.config.limit_config) this.config.limit_config = { max_per_hour: 0, min_interval: 1, max_interval: 5 };
                this.config.downstream_pool.forEach(n => { if(n.enabled === undefined) n.enabled = true; });
                
                // Auto-load draft
                const draft = localStorage.getItem('smtp_draft');
                if(draft) { try { this.bulk = JSON.parse(draft); } catch(e){} }

                this.fetchQueue();
                this.fetchContactCount();
                this.fetchBulkStatus();
                setInterval(() => {
                    this.fetchQueue();
                    this.fetchBulkStatus();
                }, 5000);
            },
            watch: {
                bulk: {
                    handler(v) { localStorage.setItem('smtp_draft', JSON.stringify(v)); },
                    deep: true
                }
            },
            methods: {
                getStatusColor(key) {
                    const map = { 'pending': 'pending', 'processing': 'processing', 'sent': 'sent', 'failed': 'failed' };
                    return map[key] || 'secondary';
                },
                getStatusIcon(key) {
                    const map = { 'pending': 'bi-hourglass-split', 'processing': 'bi-send', 'sent': 'bi-check-circle', 'failed': 'bi-x-circle' };
                    return map[key] || 'bi-question-circle';
                },
                async fetchContactCount() {
                    try {
                        const res = await fetch('/api/contacts/count');
                        const data = await res.json();
                        this.contactCount = data.count;
                    } catch(e) {}
                },
                async fetchBulkStatus() {
                    try {
                        const res = await fetch('/api/bulk/status');
                        const data = await res.json();
                        this.bulkStatus = data.status;
                    } catch(e) {}
                },
                async controlBulk(action) {
                    if(action === 'stop' && !confirm('确定停止并清空所有待发送的群发邮件吗？')) return;
                    try {
                        const res = await fetch('/api/bulk/control', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({action: action})
                        });
                        const data = await res.json();
                        this.bulkStatus = data.current;
                        if(action === 'stop') {
                            alert('已停止并清空待发队列');
                            this.fetchQueue();
                        }
                    } catch(e) { alert('操作失败: ' + e); }
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
