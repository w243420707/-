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
        pool = cfg.get('downstream_pool', [])
        
        if not pool:
            logger.warning("❌ No downstream nodes available")
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
                error_msg = ""
                success = False
                
                if not node:
                    error_msg = f"Node '{node_name}' removed from config"
                else:
                    try:
                        sender = node.get('sender_email') or row['mail_from']
                        rcpt_tos = json.loads(row['rcpt_tos'])
                        
                        with smtplib.SMTP(node['host'], int(node['port']), timeout=20) as s:
                            if node.get('encryption') in ['tls', 'ssl']: s.starttls()
                            if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                            s.sendmail(sender, rcpt_tos, row['content'])
                        
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

@app.route('/api/queue/stats')
@login_required
def api_queue_stats():
    with get_db() as conn:
        # Total stats
        total = dict(conn.execute("SELECT status, COUNT(*) as c FROM queue GROUP BY status").fetchall())
        # Per node pending
        nodes = dict(conn.execute("SELECT assigned_node, COUNT(*) as c FROM queue WHERE status='pending' GROUP BY assigned_node").fetchall())
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
<html>
<head>
    <title>SMTP Relay Manager</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        .pool-item { background: #fff; border: 1px solid #ddd; padding: 15px; margin-bottom: 15px; border-radius: 8px; position: relative; }
        .btn-del { position: absolute; top: 10px; right: 10px; z-index: 10; }
        .section-title { font-size: 0.9rem; font-weight: bold; color: #6c757d; margin-bottom: 10px; text-transform: uppercase; letter-spacing: 1px; }
        .nav-tabs .nav-link { cursor: pointer; }
    </style>
</head>
<body class="bg-light">
    <div id="app" class="container py-5">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h3>🚀 SMTP Relay 控制台</h3>
            <div>
                <button class="btn btn-outline-secondary me-2" @click="showPwd = !showPwd">修改密码</button>
                <button class="btn btn-success" @click="save" :disabled="saving" v-text="saving ? '保存中...' : '保存配置'"></button>
            </div>
        </div>

        <!-- 密码修改弹窗 -->
        <div v-if="showPwd" class="card mb-4 border-warning">
            <div class="card-header bg-warning text-dark fw-bold">⚠️ 修改 Web 面板登录密码</div>
            <div class="card-body d-flex align-items-center">
                <input type="text" v-model="config.web_config.admin_password" class="form-control me-2" placeholder="输入新密码">
                <button class="btn btn-warning text-nowrap" @click="save">保存并生效</button>
            </div>
        </div>

        <ul class="nav nav-tabs mb-4">
            <li class="nav-item"><a class="nav-link" :class="{active: tab=='settings'}" @click="tab='settings'">⚙️ 配置管理</a></li>
            <li class="nav-item"><a class="nav-link" :class="{active: tab=='queue'}" @click="tab='queue'">📨 邮件队列</a></li>
        </ul>

        <!-- Settings Tab -->
        <div v-show="tab=='settings'">
            <div class="row mb-4">
                <div class="col-md-6">
                    <div class="card h-100 shadow-sm">
                        <div class="card-header bg-primary text-white">监听设置</div>
                        <div class="card-body">
                            <div class="mb-2"><label>端口 (需重启生效)</label><input type="number" v-model.number="config.server_config.port" class="form-control"></div>
                            <div class="mb-2"><label>认证账号</label><input v-model="config.server_config.username" class="form-control"></div>
                            <div class="mb-2"><label>认证密码</label><input v-model="config.server_config.password" class="form-control"></div>
                        </div>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="card h-100 shadow-sm">
                        <div class="card-header bg-info text-white">通知与日志</div>
                        <div class="card-body">
                            <div class="row g-2">
                                <div class="col-md-6"><label>TG Bot Token</label><input v-model="config.telegram_config.bot_token" class="form-control"></div>
                                <div class="col-md-6"><label>Chat ID</label><input v-model="config.telegram_config.admin_id" class="form-control"></div>
                                <div class="col-md-6"><label>日志大小 (MB)</label><input type="number" v-model.number="config.log_config.max_mb" class="form-control"></div>
                                <div class="col-md-6"><label>保留份数</label><input type="number" v-model.number="config.log_config.backups" class="form-control"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="card shadow-sm">
                <div class="card-header d-flex justify-content-between align-items-center bg-dark text-white">
                    <span>下游节点池 (Load Balancing)</span>
                    <button class="btn btn-sm btn-light" @click="addNode">+ 添加节点</button>
                </div>
                <div class="card-body bg-light">
                    <div v-if="config.downstream_pool.length === 0" class="text-center text-muted py-5">暂无转发节点</div>
                    
                    <div v-for="(n, i) in config.downstream_pool" :key="i" class="pool-item shadow-sm">
                        <button class="btn btn-danger btn-sm btn-del" @click="delNode(i)">删除</button>
                        <div class="row g-3">
                            <div class="col-12 d-flex align-items-center">
                                <div class="section-title mb-0 me-3">连接信息</div>
                                <span v-if="qStats.nodes && qStats.nodes[n.name]" class="badge bg-warning text-dark">
                                    待发送: [[ qStats.nodes[n.name].c ]]
                                </span>
                            </div>
                            <div class="col-md-3"><label class="small text-muted">备注名 (唯一)</label><input v-model="n.name" class="form-control"></div>
                            <div class="col-md-4"><label class="small text-muted">Host</label><input v-model="n.host" class="form-control"></div>
                            <div class="col-md-2"><label class="small text-muted">Port</label><input v-model.number="n.port" class="form-control"></div>
                            <div class="col-md-3"><label class="small text-muted">加密</label>
                                <select v-model="n.encryption" class="form-select">
                                    <option value="none">STARTTLS / 无</option>
                                    <option value="tls">TLS</option>
                                    <option value="ssl">SSL (465)</option>
                                </select>
                            </div>
                            <div class="col-12"><div class="section-title">认证与发件人</div></div>
                            <div class="col-md-4"><label class="small text-muted">SMTP 账号</label><input v-model="n.username" class="form-control"></div>
                            <div class="col-md-4"><label class="small text-muted">SMTP 密码</label><input v-model="n.password" class="form-control"></div>
                            <div class="col-md-4">
                                <label class="small text-muted fw-bold text-primary">Sender Email (覆盖)</label>
                                <input v-model="n.sender_email" class="form-control" placeholder="强制修改 MAIL FROM">
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Queue Tab -->
        <div v-show="tab=='queue'">
            <div class="row mb-3 g-3">
                <div class="col-md-3"><div class="card bg-warning text-dark h-100"><div class="card-body text-center"><h3>[[ (qStats.total && qStats.total.pending && qStats.total.pending.c) || 0 ]]</h3><small>待发送 (Pending)</small></div></div></div>
                <div class="col-md-3"><div class="card bg-info text-white h-100"><div class="card-body text-center"><h3>[[ (qStats.total && qStats.total.processing && qStats.total.processing.c) || 0 ]]</h3><small>发送中 (Processing)</small></div></div></div>
                <div class="col-md-3"><div class="card bg-success text-white h-100"><div class="card-body text-center"><h3>[[ (qStats.total && qStats.total.sent && qStats.total.sent.c) || 0 ]]</h3><small>已成功 (Sent)</small></div></div></div>
                <div class="col-md-3"><div class="card bg-danger text-white h-100"><div class="card-body text-center"><h3>[[ (qStats.total && qStats.total.failed && qStats.total.failed.c) || 0 ]]</h3><small>已失败 (Failed)</small></div></div></div>
            </div>
            
            <div class="d-flex justify-content-between mb-2">
                <button class="btn btn-sm btn-primary" @click="fetchQueue">🔄 刷新列表</button>
                <button class="btn btn-sm btn-outline-danger" @click="clearQueue">🗑️ 清理已完成/失败记录</button>
            </div>

            <div class="table-responsive bg-white shadow-sm rounded">
                <table class="table table-hover mb-0">
                    <thead class="table-light"><tr><th>ID</th><th>From / To</th><th>Node</th><th>Status</th><th>Retry</th><th>Time</th></tr></thead>
                    <tbody>
                        <tr v-for="m in qList" :key="m.id">
                            <td>#[[ m.id ]]</td>
                            <td>
                                <div class="small fw-bold">[[ m.mail_from ]]</div>
                                <div class="small text-muted text-truncate" style="max-width:200px">[[ m.rcpt_tos ]]</div>
                            </td>
                            <td><span class="badge bg-secondary">[[ m.assigned_node ]]</span></td>
                            <td>
                                <span v-if="m.status=='pending'" class="badge bg-warning text-dark">Pending</span>
                                <span v-else-if="m.status=='processing'" class="badge bg-info">Sending</span>
                                <span v-else-if="m.status=='sent'" class="badge bg-success">Sent</span>
                                <span v-else class="badge bg-danger">Failed</span>
                                <div v-if="m.last_error" class="text-danger small mt-1" style="font-size:0.75rem">[[ m.last_error ]]</div>
                            </td>
                            <td>[[ m.retry_count ]]</td>
                            <td><small class="text-muted">[[ m.created_at ]]</small></td>
                        </tr>
                        <tr v-if="qList.length===0"><td colspan="6" class="text-center py-4 text-muted">暂无数据</td></tr>
                    </tbody>
                </table>
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
                tab: 'settings',
                qStats: { total: {}, nodes: {} },
                qList: []
            }},
            mounted() {
                this.fetchQueue();
                setInterval(this.fetchQueue, 5000); // Auto refresh every 5s
            },
            methods: {
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node-'+Math.floor(Math.random()*1000), host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '' }); 
                },
                delNode(i) { if(confirm('确定删除?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        alert('保存成功！' + (this.showPwd ? '密码已修改。' : ''));
                        this.showPwd = false;
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

    echo -e "${GREEN}✅ 更新完成！${PLAIN}"
    echo -e "请刷新 Web 页面，右上角已增加 [修改密码] 按钮。"
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
    echo -e "${GREEN}1.${PLAIN} 安装 / 更新 (Web端新增改密功能)"
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
