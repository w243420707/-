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
                    "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status) VALUES (?, ?, ?, ?, ?)",
                    (envelope.mail_from, json.dumps(envelope.rcpt_tos), envelope.content, node_name, 'pending')
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
            pool = {n['name']: n for n in cfg.get('downstream_pool', [])}
            
            with get_db() as conn:
                # Fetch pending items
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
                        sender = node.get('sender_email') or row['mail_from']
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
                        # Retry logic
                        if row['retry_count'] < 3:
                            conn.execute("UPDATE queue SET status='pending', retry_count=retry_count+1, last_error=?, updated_at=CURRENT_TIMESTAMP WHERE id=?", (error_msg, row_id))
                        else:
                            conn.execute("UPDATE queue SET status='failed', last_error=?, updated_at=CURRENT_TIMESTAMP WHERE id=?", (error_msg, row_id))
                            send_telegram(f"❌ Mail ID:{row_id} Failed permanently via {node_name}\nErr: {error_msg}")

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
    return '''<body style="display:flex;justify-content:center;align-items:center;height:100vh;background:#f0f2f5;font-family:sans-serif">
    <form method="post" style="background:#fff;padding:40px;border-radius:8px;box-shadow:0 4px 12px rgba(0,0,0,0.1);text-align:center">
        <h3>系统登录</h3><input type="password" name="password" placeholder="输入密码" style="padding:10px;width:100%;margin:15px 0;border:1px solid #ddd;border-radius:4px">
        <button style="width:100%;padding:10px;background:#0d6efd;color:#fff;border:none;border-radius:4px;cursor:pointer">登录</button>
    </form></body>'''

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
    <title>SMTP Relay Manager</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        :root { --primary-color: #4361ee; --bg-color: #f3f4f6; }
        body { background-color: var(--bg-color); font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; color: #374151; }
        .navbar { background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.05); padding: 0.75rem 0; }
        .navbar-brand { font-weight: 700; color: var(--primary-color); font-size: 1.25rem; }
        .card { border: none; border-radius: 12px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05), 0 2px 4px -1px rgba(0,0,0,0.03); transition: transform 0.2s; }
        .card:hover { transform: translateY(-2px); }
        .stat-card { border-left: 4px solid transparent; }
        .stat-card.pending { border-color: #f59e0b; }
        .stat-card.processing { border-color: #3b82f6; }
        .stat-card.sent { border-color: #10b981; }
        .stat-card.failed { border-color: #ef4444; }
        .stat-value { font-size: 2rem; font-weight: 700; line-height: 1; margin-bottom: 0.5rem; }
        .stat-label { color: #6b7280; font-size: 0.875rem; font-weight: 500; text-transform: uppercase; letter-spacing: 0.05em; }
        .nav-pills .nav-link { border-radius: 8px; color: #4b5563; font-weight: 500; padding: 0.75rem 1.5rem; transition: all 0.2s; }
        .nav-pills .nav-link.active { background-color: var(--primary-color); color: #fff; box-shadow: 0 4px 6px -1px rgba(67, 97, 238, 0.4); }
        .table thead th { background-color: #f9fafb; color: #6b7280; font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.05em; border-bottom: 1px solid #e5e7eb; }
        .badge { padding: 0.5em 0.75em; font-weight: 600; border-radius: 6px; }
        .badge-soft-warning { background-color: #fffbeb; color: #b45309; }
        .badge-soft-info { background-color: #eff6ff; color: #1d4ed8; }
        .badge-soft-success { background-color: #ecfdf5; color: #047857; }
        .badge-soft-danger { background-color: #fef2f2; color: #b91c1c; }
        .badge-soft-secondary { background-color: #f3f4f6; color: #4b5563; }
        .node-card { border: 1px solid #e5e7eb; }
        .node-card.disabled { opacity: 0.6; background-color: #f9fafb; }
        .form-label { font-size: 0.875rem; font-weight: 500; color: #374151; margin-bottom: 0.4rem; }
        .form-control, .form-select { border-radius: 8px; border-color: #d1d5db; padding: 0.6rem 0.8rem; font-size: 0.9rem; }
        .form-control:focus { border-color: var(--primary-color); box-shadow: 0 0 0 3px rgba(67, 97, 238, 0.15); }
        .btn { border-radius: 8px; font-weight: 500; padding: 0.5rem 1rem; transition: all 0.2s; }
        .btn-primary { background-color: var(--primary-color); border-color: var(--primary-color); }
        .btn-primary:hover { background-color: #3651d4; }
        .fade-enter-active, .fade-leave-active { transition: opacity 0.2s ease; }
        .fade-enter-from, .fade-leave-to { opacity: 0; }
    </style>
</head>
<body>
    <div id="app">
        <!-- Navbar -->
        <nav class="navbar navbar-expand-lg sticky-top mb-4">
            <div class="container">
                <a class="navbar-brand" href="#"><i class="bi bi-send-check-fill me-2"></i>SMTP Relay Manager</a>
                <div class="d-flex align-items-center">
                    <button class="btn btn-light text-secondary me-2 btn-sm" @click="showPwd = !showPwd" title="修改密码"><i class="bi bi-key"></i></button>
                    <div class="btn-group">
                        <button class="btn btn-primary" @click="save" :disabled="saving">
                            <span v-if="saving" class="spinner-border spinner-border-sm me-1"></span>
                            <i v-else class="bi bi-save me-1"></i> 保存配置
                        </button>
                        <button class="btn btn-danger" @click="saveAndRestart" :disabled="saving" title="保存并重启服务">
                            <i class="bi bi-power"></i>
                        </button>
                    </div>
                </div>
            </div>
        </nav>

        <div class="container pb-5">
            <!-- Password Modal (Inline) -->
            <transition name="fade">
                <div v-if="showPwd" class="alert alert-warning shadow-sm d-flex align-items-center mb-4" role="alert">
                    <i class="bi bi-exclamation-triangle-fill me-2 fs-4"></i>
                    <div class="flex-grow-1">
                        <div class="fw-bold">修改 Web 面板登录密码</div>
                        <div class="d-flex mt-2">
                            <input type="text" v-model="config.web_config.admin_password" class="form-control form-control-sm me-2" style="max-width: 200px;" placeholder="输入新密码">
                            <button class="btn btn-warning btn-sm text-white" @click="save">确认修改</button>
                        </div>
                    </div>
                    <button type="button" class="btn-close" @click="showPwd = false"></button>
                </div>
            </transition>

            <!-- Navigation Pills -->
            <ul class="nav nav-pills mb-4 justify-content-center">
                <li class="nav-item">
                    <a class="nav-link" :class="{active: tab=='queue'}" @click="tab='queue'" href="#"><i class="bi bi-envelope-paper me-2"></i>邮件队列监控</a>
                </li>
                <li class="nav-item ms-2">
                    <a class="nav-link" :class="{active: tab=='settings'}" @click="tab='settings'" href="#"><i class="bi bi-sliders me-2"></i>系统配置管理</a>
                </li>
            </ul>

            <!-- Queue View -->
            <div v-if="tab=='queue'">
                <!-- Stats Cards -->
                <div class="row g-3 mb-4">
                    <div class="col-md-3 col-6">
                        <div class="card stat-card pending h-100 p-3">
                            <div class="d-flex justify-content-between align-items-start">
                                <div>
                                    <div class="stat-label">待发送 (Pending)</div>
                                    <div class="stat-value text-warning">[[ qStats.total.pending || 0 ]]</div>
                                </div>
                                <div class="bg-warning bg-opacity-10 p-2 rounded text-warning"><i class="bi bi-hourglass-split fs-4"></i></div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 col-6">
                        <div class="card stat-card processing h-100 p-3">
                            <div class="d-flex justify-content-between align-items-start">
                                <div>
                                    <div class="stat-label">发送中 (Sending)</div>
                                    <div class="stat-value text-primary">[[ qStats.total.processing || 0 ]]</div>
                                </div>
                                <div class="bg-primary bg-opacity-10 p-2 rounded text-primary"><i class="bi bi-send fs-4"></i></div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 col-6">
                        <div class="card stat-card sent h-100 p-3">
                            <div class="d-flex justify-content-between align-items-start">
                                <div>
                                    <div class="stat-label">已成功 (Sent)</div>
                                    <div class="stat-value text-success">[[ qStats.total.sent || 0 ]]</div>
                                </div>
                                <div class="bg-success bg-opacity-10 p-2 rounded text-success"><i class="bi bi-check-circle fs-4"></i></div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 col-6">
                        <div class="card stat-card failed h-100 p-3">
                            <div class="d-flex justify-content-between align-items-start">
                                <div>
                                    <div class="stat-label">已失败 (Failed)</div>
                                    <div class="stat-value text-danger">[[ qStats.total.failed || 0 ]]</div>
                                </div>
                                <div class="bg-danger bg-opacity-10 p-2 rounded text-danger"><i class="bi bi-x-circle fs-4"></i></div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Node Performance -->
                <div class="card mb-4">
                    <div class="card-header bg-white py-3">
                        <h6 class="mb-0 fw-bold"><i class="bi bi-bar-chart-fill me-2 text-primary"></i>节点性能统计</h6>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-hover align-middle mb-0">
                            <thead><tr><th class="ps-4">节点名称</th><th class="text-center">待发送</th><th class="text-center">成功</th><th class="text-center">失败</th><th class="text-end pe-4">状态</th></tr></thead>
                            <tbody>
                                <tr v-for="(s, name) in qStats.nodes" :key="name">
                                    <td class="ps-4 fw-bold text-dark">[[ name ]]</td>
                                    <td class="text-center"><span class="badge badge-soft-warning">[[ s.pending || 0 ]]</span></td>
                                    <td class="text-center"><span class="badge badge-soft-success">[[ s.sent || 0 ]]</span></td>
                                    <td class="text-center"><span class="badge badge-soft-danger">[[ s.failed || 0 ]]</span></td>
                                    <td class="text-end pe-4">
                                        <span class="badge badge-soft-secondary">Active</span>
                                    </td>
                                </tr>
                                <tr v-if="Object.keys(qStats.nodes).length === 0"><td colspan="5" class="text-center py-4 text-muted">暂无节点活动数据</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Queue List -->
                <div class="card">
                    <div class="card-header bg-white py-3 d-flex justify-content-between align-items-center">
                        <h6 class="mb-0 fw-bold"><i class="bi bi-list-task me-2 text-primary"></i>最近邮件记录</h6>
                        <div>
                            <button class="btn btn-sm btn-outline-primary me-2" @click="fetchQueue"><i class="bi bi-arrow-clockwise"></i> 刷新</button>
                            <button class="btn btn-sm btn-outline-danger" @click="clearQueue"><i class="bi bi-trash"></i> 清理历史</button>
                        </div>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-hover align-middle mb-0">
                            <thead><tr><th class="ps-4">ID</th><th>发件人 / 收件人</th><th>分发节点</th><th>状态</th><th>重试</th><th class="text-end pe-4">时间</th></tr></thead>
                            <tbody>
                                <tr v-for="m in qList" :key="m.id">
                                    <td class="ps-4 text-muted small">#[[ m.id ]]</td>
                                    <td>
                                        <div class="fw-bold text-dark">[[ m.mail_from ]]</div>
                                        <div class="text-muted small text-truncate" style="max-width: 250px;">[[ m.rcpt_tos ]]</div>
                                    </td>
                                    <td><span class="badge badge-soft-secondary"><i class="bi bi-hdd-network me-1"></i>[[ m.assigned_node ]]</span></td>
                                    <td>
                                        <span v-if="m.status=='pending'" class="badge badge-soft-warning">Pending</span>
                                        <span v-else-if="m.status=='processing'" class="badge badge-soft-info">Sending</span>
                                        <span v-else-if="m.status=='sent'" class="badge badge-soft-success">Sent</span>
                                        <span v-else class="badge badge-soft-danger">Failed</span>
                                        <div v-if="m.last_error" class="text-danger small mt-1" style="font-size: 0.75rem;"><i class="bi bi-exclamation-circle me-1"></i>[[ m.last_error ]]</div>
                                    </td>
                                    <td><span class="text-muted small">[[ m.retry_count ]]</span></td>
                                    <td class="text-end pe-4 text-muted small">[[ m.created_at ]]</td>
                                </tr>
                                <tr v-if="qList.length===0"><td colspan="6" class="text-center py-5 text-muted">
                                    <i class="bi bi-inbox fs-1 d-block mb-2"></i>
                                    暂无邮件记录
                                </td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>

            <!-- Settings View -->
            <div v-if="tab=='settings'">
                <div class="row g-4 mb-4">
                    <div class="col-md-6">
                        <div class="card h-100">
                            <div class="card-header bg-white py-3 fw-bold text-primary"><i class="bi bi-hdd-rack me-2"></i>监听设置</div>
                            <div class="card-body">
                                <div class="mb-3">
                                    <label class="form-label">服务端口 <span class="badge bg-light text-dark border ms-1">重启生效</span></label>
                                    <input type="number" v-model.number="config.server_config.port" class="form-control">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">认证账号</label>
                                    <input v-model="config.server_config.username" class="form-control">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">认证密码</label>
                                    <input v-model="config.server_config.password" class="form-control">
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-6">
                        <div class="card h-100">
                            <div class="card-header bg-white py-3 fw-bold text-info"><i class="bi bi-bell me-2"></i>通知与日志</div>
                            <div class="card-body">
                                <div class="row g-3">
                                    <div class="col-12">
                                        <label class="form-label">Telegram Bot Token</label>
                                        <input v-model="config.telegram_config.bot_token" class="form-control" placeholder="123456:ABC-DEF...">
                                    </div>
                                    <div class="col-12">
                                        <label class="form-label">Chat ID</label>
                                        <input v-model="config.telegram_config.admin_id" class="form-control" placeholder="12345678">
                                    </div>
                                    <div class="col-6">
                                        <label class="form-label">日志大小 (MB)</label>
                                        <input type="number" v-model.number="config.log_config.max_mb" class="form-control">
                                    </div>
                                    <div class="col-6">
                                        <label class="form-label">保留份数</label>
                                        <input type="number" v-model.number="config.log_config.backups" class="form-control">
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="card">
                    <div class="card-header bg-white py-3 d-flex justify-content-between align-items-center">
                        <h6 class="mb-0 fw-bold"><i class="bi bi-diagram-3 me-2 text-primary"></i>下游节点池 (Load Balancing)</h6>
                        <button class="btn btn-sm btn-primary" @click="addNode"><i class="bi bi-plus-lg me-1"></i>添加节点</button>
                    </div>
                    <div class="card-body bg-light">
                        <div v-if="config.downstream_pool.length === 0" class="text-center py-5 text-muted">
                            <i class="bi bi-cloud-slash fs-1 d-block mb-2"></i>
                            暂无转发节点，请点击右上角添加
                        </div>
                        
                        <div v-for="(n, i) in config.downstream_pool" :key="i" class="card node-card mb-3 shadow-sm" :class="{'disabled': n.enabled === false}">
                            <div class="card-body">
                                <div class="d-flex justify-content-between align-items-center mb-3 border-bottom pb-2">
                                    <div class="d-flex align-items-center">
                                        <div class="form-check form-switch me-3">
                                            <input class="form-check-input" type="checkbox" :id="'sw'+i" v-model="n.enabled" style="width: 3em; height: 1.5em;">
                                        </div>
                                        <div>
                                            <h6 class="mb-0 fw-bold">[[ n.name ]]</h6>
                                            <small :class="n.enabled!==false?'text-success':'text-muted'">
                                                <i class="bi" :class="n.enabled!==false?'bi-check-circle-fill':'bi-pause-circle-fill'"></i>
                                                [[ n.enabled!==false ? '运行中' : '已暂停' ]]
                                            </small>
                                        </div>
                                    </div>
                                    <div class="d-flex align-items-center">
                                        <span v-if="qStats.nodes && qStats.nodes[n.name] && qStats.nodes[n.name].pending" class="badge bg-warning text-dark me-3">
                                            <i class="bi bi-hourglass-split me-1"></i>待发: [[ qStats.nodes[n.name].pending ]]
                                        </span>
                                        <button class="btn btn-outline-danger btn-sm" @click="delNode(i)"><i class="bi bi-trash"></i></button>
                                    </div>
                                </div>

                                <div class="row g-3">
                                    <div class="col-md-3">
                                        <label class="form-label text-muted small">备注名称</label>
                                        <input v-model="n.name" class="form-control form-control-sm">
                                    </div>
                                    <div class="col-md-4">
                                        <label class="form-label text-muted small">SMTP Host</label>
                                        <input v-model="n.host" class="form-control form-control-sm" placeholder="smtp.example.com">
                                    </div>
                                    <div class="col-md-2">
                                        <label class="form-label text-muted small">Port</label>
                                        <input v-model.number="n.port" class="form-control form-control-sm">
                                    </div>
                                    <div class="col-md-3">
                                        <label class="form-label text-muted small">加密方式</label>
                                        <select v-model="n.encryption" class="form-select form-select-sm">
                                            <option value="none">STARTTLS / 无</option>
                                            <option value="tls">TLS</option>
                                            <option value="ssl">SSL (465)</option>
                                        </select>
                                    </div>
                                    <div class="col-md-4">
                                        <label class="form-label text-muted small">SMTP 账号</label>
                                        <input v-model="n.username" class="form-control form-control-sm">
                                    </div>
                                    <div class="col-md-4">
                                        <label class="form-label text-muted small">SMTP 密码</label>
                                        <input v-model="n.password" class="form-control form-control-sm" type="password">
                                    </div>
                                    <div class="col-md-4">
                                        <label class="form-label text-primary small fw-bold">强制发件人 (Sender Rewrite)</label>
                                        <input v-model="n.sender_email" class="form-control form-control-sm" placeholder="留空则不修改">
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
            data() { return { 
                config: {{ config|tojson }}, 
                saving: false, 
                showPwd: false,
                tab: 'queue',
                qStats: { total: {}, nodes: {} },
                qList: []
            }},
            mounted() {
                this.config.downstream_pool.forEach(n => { if(n.enabled === undefined) n.enabled = true; });
                this.fetchQueue();
                setInterval(this.fetchQueue, 5000);
            },
            methods: {
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node-'+Math.floor(Math.random()*1000), host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '', enabled: true }); 
                },
                delNode(i) { if(confirm('确定删除该节点吗?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        alert('保存成功！' + (this.showPwd ? '密码已修改。' : ''));
                        this.showPwd = false;
                    } catch(e) { alert('失败: ' + e); }
                    this.saving = false;
                },
                async saveAndRestart() {
                    if(!confirm('确定保存配置并重启服务吗？\n重启期间服务将短暂不可用(约5-10秒)。')) return;
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        await fetch('/api/restart', { method: 'POST' });
                        alert('正在重启...请稍后刷新页面。');
                    } catch(e) { alert('操作失败: ' + e); }
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
                async clearQueue() {
                    if(!confirm('确定清理所有已完成和失败的记录吗？(Pending状态不会被清理)')) return;
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
