#!/bin/bash

# =========================================================
# SMTP Relay Manager - 自动重启完善版
# 特性：修改端口自动重启 | Web改密 | 完整功能闭环
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

    # 备份逻辑
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}⚠️  备份旧配置...${PLAIN}"
        cp "$CONFIG_FILE" /tmp/smtp_config_backup.json
    fi

    # 清理代码
    rm -rf "$APP_DIR/templates"
    rm -f "$APP_DIR/app.py"
    mkdir -p "$APP_DIR/templates"
    mkdir -p "$LOG_DIR"

    # Python 环境
    if [ ! -d "$VENV_DIR" ]; then
        cd "$APP_DIR"
        python3 -m venv venv
    fi
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install flask requests aiosmtpd

    # 恢复配置
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

    # =========================================================
    # 1. 写入 app.py (增加自动重启逻辑)
    # =========================================================
    echo -e "${GREEN}📝 写入后端代码 (含自动重启逻辑)...${PLAIN}"
    cat > "$APP_DIR/app.py" << 'EOF'
import os
import sys
import json
import logging
import smtplib
import requests
import random
import threading
import time
from logging.handlers import RotatingFileHandler
from aiosmtpd.controller import Controller
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')
LOG_FILE = '/var/log/smtp-relay/app.log'

# 全局变量，记录启动时的端口
CURRENT_PORT = 587

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

class RelayHandler:
    async def handle_DATA(self, server, session, envelope):
        cfg = load_config()
        pool = cfg.get('downstream_pool', [])
        logger.info(f"📥 Recv | From: {envelope.mail_from} | To: {envelope.rcpt_tos}")
        
        if not pool: return '451 Temporary failure: No nodes'
        
        random.shuffle(pool)
        success, last_err = False, ""
        
        for node in pool:
            try:
                # Sender Rewrite
                sender = node.get('sender_email') or envelope.mail_from
                
                with smtplib.SMTP(node['host'], int(node['port']), timeout=15) as s:
                    if node.get('encryption') in ['tls', 'ssl']: s.starttls()
                    if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                    s.sendmail(sender, envelope.rcpt_tos, envelope.content)
                
                success = True
                logger.info(f"✅ Sent via {node['name']} as {sender}")
                break
            except Exception as e:
                last_err = str(e)
                logger.error(f"⚠️ Node {node['name']} Failed: {e}")
        
        if success: return '250 OK'
        send_telegram(f"❌ All nodes failed! Last: {last_err}")
        return '451 Temporary failure'

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
        <h3>Login</h3><input type="password" name="password" placeholder="Password" style="padding:10px;width:100%;margin:15px 0;border:1px solid #ddd;border-radius:4px">
        <button style="width:100%;padding:10px;background:#0d6efd;color:#fff;border:none;border-radius:4px;cursor:pointer">Sign In</button>
    </form></body>'''

@app.route('/')
@login_required
def index(): return render_template('index.html', config=load_config())

@app.route('/api/save', methods=['POST'])
@login_required
def api_save():
    new_config = request.json
    
    # 检查端口是否变化
    new_port = int(new_config.get('server_config', {}).get('port', 587))
    port_changed = (new_port != CURRENT_PORT)
    
    save_config(new_config)
    
    # 重载日志
    global logger
    logger = setup_logging()
    
    if port_changed:
        # 启动一个延时线程来自杀，给前端留出收到 Response 的时间
        def restart_server():
            time.sleep(1)
            logger.info(f"♻️ Port changed to {new_port}, restarting service...")
            os._exit(0) # 退出当前进程，Supervisor 会自动重启它
            
        threading.Thread(target=restart_server).start()
        return jsonify({"status": "restarting", "msg": "Port changed. Service is restarting..."})
    
    return jsonify({"status": "ok", "msg": "Configuration saved."})

def start_services():
    cfg = load_config()
    global CURRENT_PORT
    CURRENT_PORT = int(cfg.get('server_config', {}).get('port', 587))
    
    print(f"Starting SMTP on port {CURRENT_PORT}...")
    Controller(RelayHandler(), hostname='0.0.0.0', port=CURRENT_PORT).start()

    print("Starting Web on port 8080...")
    app.run(host='0.0.0.0', port=8080, debug=False, use_reloader=False)

if __name__ == '__main__':
    start_services()
EOF

    # =========================================================
    # 2. 写入前端模板 (增加重启提示)
    # =========================================================
    echo -e "${GREEN}📝 写入前端模板...${PLAIN}"
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
    </style>
</head>
<body class="bg-light">
    <div id="app" class="container py-5">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h3>🚀 SMTP Relay 控制台</h3>
            <div>
                <button class="btn btn-outline-secondary me-2" @click="showPwd = !showPwd">修改密码</button>
                <button class="btn btn-success" @click="save" :disabled="saving" v-text="saving ? btnText : '保存配置'"></button>
            </div>
        </div>

        <div v-if="showPwd" class="card mb-4 border-warning">
            <div class="card-header bg-warning text-dark fw-bold">⚠️ 修改 Web 面板登录密码</div>
            <div class="card-body d-flex align-items-center">
                <input type="text" v-model="config.web_config.admin_password" class="form-control me-2" placeholder="输入新密码">
                <button class="btn btn-warning text-nowrap" @click="save">保存并生效</button>
            </div>
        </div>

        <div class="row mb-4">
            <div class="col-md-6">
                <div class="card h-100 shadow-sm">
                    <div class="card-header bg-primary text-white">监听设置</div>
                    <div class="card-body">
                        <div class="mb-2"><label>端口 (修改后自动重启)</label><input type="number" v-model.number="config.server_config.port" class="form-control"></div>
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
                        <div class="col-12"><div class="section-title">连接信息</div></div>
                        <div class="col-md-3"><label class="small text-muted">备注名</label><input v-model="n.name" class="form-control"></div>
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
    <script>
        const { createApp } = Vue;
        createApp({
            data() { return { config: {{ config|tojson }}, saving: false, showPwd: false, btnText: '保存中...' } },
            methods: {
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node', host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '' }); 
                },
                delNode(i) { if(confirm('确定删除?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    this.btnText = '保存中...';
                    try {
                        const res = await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        const data = await res.json();
                        
                        if (data.status === 'restarting') {
                            this.btnText = '正在重启...';
                            alert('⚠️ 端口已修改，服务正在重启！\n请等待约 5 秒，然后手动刷新页面。');
                            // 简单的等待逻辑
                            setTimeout(() => { window.location.reload(); }, 5000);
                        } else {
                            alert('✅ ' + data.msg + (this.showPwd ? ' 密码已修改。' : ''));
                            this.showPwd = false;
                        }
                    } catch(e) { alert('失败: ' + e); }
                    this.saving = false;
                }
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF

    # Supervisor
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

    # 防火墙
    ufw allow 8080/tcp >/dev/null 2>&1
    ufw allow 587/tcp >/dev/null 2>&1
    iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
    iptables -I INPUT 1 -p tcp --dport 587 -j ACCEPT
    if dpkg -l | grep -q netfilter-persistent; then netfilter-persistent save >/dev/null 2>&1; fi

    # 重启
    supervisorctl reread >/dev/null
    supervisorctl update >/dev/null
    supervisorctl restart smtp-web

    echo -e "${GREEN}✅ 完美版更新完成！${PLAIN}"
    echo -e "功能：修改端口后点击保存，服务将自动重启以应用更改。"
}

uninstall_smtp() {
    echo -e "${YELLOW}⚠️  警告: 确定卸载? [y/n]: ${PLAIN}"
    read -p "选择: " choice
    if [[ "$choice" == "y" ]]; then
        supervisorctl stop smtp-web
        rm -f /etc/supervisor/conf.d/smtp_web.conf
        supervisorctl reread
        supervisorctl update
        rm -rf "$APP_DIR" "$LOG_DIR"
        echo -e "${GREEN}已卸载${PLAIN}"
    fi
}

show_menu() {
    clear
    echo -e "============================================"
    echo -e "   🚀 SMTP Relay Manager 自动重启版 "
    echo -e "============================================"
    echo -e "${GREEN}1.${PLAIN} 安装 / 更新 (含自动重启特性)"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看日志"
    echo -e "${GREEN}6.${PLAIN} 命令行重置密码"
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
           echo -e "✅ 密码已重置" ;;
        0) uninstall_smtp ;;
        *) echo -e "无效" ;;
    esac
}

show_menu
