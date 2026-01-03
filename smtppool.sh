#!/bin/bash

# =========================================================
# SMTP Relay Manager - 终极全能版
# 功能清单：Web面板 | 多节点轮询 | Sender重写 | TG通知
#          日志轮转 | 500错误修复 | 防火墙修复 | 菜单管理系统
# =========================================================

# --- 基础配置 ---
APP_DIR="/opt/smtp-relay"
LOG_DIR="/var/log/smtp-relay"
VENV_DIR="$APP_DIR/venv"
CONFIG_FILE="$APP_DIR/config.json"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 必须使用 root 用户运行此脚本 (sudo -i)${PLAIN}"
    exit 1
fi

# =========================================================
# 1. 安装与更新逻辑
# =========================================================
install_smtp() {
    echo -e "${GREEN}🚀 正在初始化环境...${PLAIN}"

    # 1.1 安装系统依赖
    apt-get update -y
    apt-get install -y python3 python3-venv python3-pip supervisor git ufw curl

    # 1.2 备份配置文件 (更新模式)
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}⚠️  检测到旧配置，正在备份...${PLAIN}"
        cp "$CONFIG_FILE" /tmp/smtp_config_backup.json
    fi

    # 1.3 清理旧代码 (保留目录结构，不删日志)
    # 删除旧的 templates 和 app.py，确保代码更新到最新
    rm -rf "$APP_DIR/templates"
    rm -f "$APP_DIR/app.py"
    
    mkdir -p "$APP_DIR/templates"
    mkdir -p "$LOG_DIR"

    # 1.4 配置 Python 虚拟环境
    echo -e "${GREEN}🐍 配置 Python 环境...${PLAIN}"
    if [ ! -d "$VENV_DIR" ]; then
        cd "$APP_DIR"
        python3 -m venv venv
    fi
    # 安装依赖：flask(Web), requests(TG), aiosmtpd(SMTP核心)
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install flask requests aiosmtpd

    # 1.5 恢复配置文件
    if [ -f "/tmp/smtp_config_backup.json" ]; then
        mv "/tmp/smtp_config_backup.json" "$CONFIG_FILE"
        echo -e "${GREEN}✅ 已恢复旧配置${PLAIN}"
    else
        # 初始化默认配置
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
    # 2. 写入核心程序 app.py (包含所有后端逻辑)
    # =========================================================
    echo -e "${GREEN}📝 写入核心代码 (Web + SMTP + LogRotation + SenderRewrite)...${PLAIN}"
    cat > "$APP_DIR/app.py" << 'EOF'
import os
import json
import logging
import smtplib
import requests
import random
import time
import threading
from logging.handlers import RotatingFileHandler
from aiosmtpd.controller import Controller
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')
LOG_FILE = '/var/log/smtp-relay/app.log'

# --- 配置 ---
def load_config():
    if not os.path.exists(CONFIG_FILE): return {}
    try:
        with open(CONFIG_FILE, 'r') as f: return json.load(f)
    except: return {}

def save_config(data):
    with open(CONFIG_FILE, 'w') as f: json.dump(data, f, indent=4)

# --- 日志轮转系统 ---
def setup_logging():
    cfg = load_config()
    log_cfg = cfg.get('log_config', {})
    max_mb = log_cfg.get('max_mb', 50)
    backups = log_cfg.get('backups', 3)
    
    logger = logging.getLogger('SMTP-Relay')
    logger.setLevel(logging.INFO)
    logger.handlers = [] # 清除旧handler
    
    # 限制日志大小，防止爆盘
    handler = RotatingFileHandler(LOG_FILE, maxBytes=max_mb*1024*1024, backupCount=backups)
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger

logger = setup_logging()

# --- Telegram 通知 ---
def send_telegram(msg):
    cfg = load_config()
    tg = cfg.get('telegram_config', {})
    token = tg.get('bot_token')
    chat_id = tg.get('admin_id')
    if token and chat_id:
        try:
            requests.post(f"https://api.telegram.org/bot{token}/sendMessage", json={"chat_id": chat_id, "text": msg}, timeout=5)
        except: pass

# --- SMTP 转发核心 ---
class RelayHandler:
    async def handle_DATA(self, server, session, envelope):
        cfg = load_config()
        pool = cfg.get('downstream_pool', [])
        
        logger.info(f"📥 收到邮件 | From: {envelope.mail_from} | To: {envelope.rcpt_tos}")
        
        if not pool:
            logger.error("❌ 无下游节点")
            return '451 Temporary failure: No nodes'

        success = False
        last_error = ""
        random.shuffle(pool) # 负载均衡
        
        for node in pool:
            try:
                # 【关键逻辑】Sender Email 覆盖/伪造
                # 如果节点设置了 sender_email，则强制使用它作为 MAIL FROM
                real_sender = node.get('sender_email') if node.get('sender_email') else envelope.mail_from
                
                logger.info(f"🔄 尝试节点: {node['name']} | 使用发件人: {real_sender}")
                
                with smtplib.SMTP(node['host'], int(node['port']), timeout=15) as s:
                    enc = node.get('encryption', 'none')
                    if enc == 'tls': s.starttls()
                    elif enc == 'ssl': s.starttls() # 简易兼容
                    
                    if node.get('username') and node.get('password'):
                        s.login(node['username'], node.get('password'))
                    
                    # 发送邮件 (使用 real_sender)
                    s.sendmail(real_sender, envelope.rcpt_tos, envelope.content)
                
                success = True
                msg = f"✅ 转发成功 | 节点: {node['name']} | From: {real_sender}"
                logger.info(msg)
                # send_telegram(msg) # 可选：成功也通知
                break 
                
            except Exception as e:
                last_error = str(e)
                logger.error(f"⚠️ 节点 {node['name']} 失败: {e}")
                continue

        if success:
            return '250 OK'
        else:
            err_msg = f"❌ 所有节点失败! 最后错误: {last_error}"
            logger.error(err_msg)
            send_telegram(err_msg)
            return '451 Temporary failure'

# --- Web 后端 ---
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
    error = None
    if request.method == 'POST':
        pwd = cfg.get('web_config', {}).get('admin_password', 'admin')
        if request.form.get('password') == pwd:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else: error = '密码错误'
    
    return f'''
    <body style="display:flex;justify-content:center;align-items:center;height:100vh;background:#f0f2f5;font-family:sans-serif">
    <form method="post" style="background:#fff;padding:40px;border-radius:8px;box-shadow:0 4px 12px rgba(0,0,0,0.1);text-align:center;width:300px">
        <h3 style="margin-bottom:20px">系统登录</h3>
        <input type="password" name="password" style="padding:10px;width:100%;box-sizing:border-box;margin-bottom:15px;border:1px solid #ddd;border-radius:4px" placeholder="输入密码">
        <button style="width:100%;padding:10px;background:#0d6efd;color:#fff;border:none;border-radius:4px;cursor:pointer">登录</button>
        <p style="color:red;margin-top:10px">{error if error else ''}</p>
    </form></body>
    '''

@app.route('/')
@login_required
def index():
    return render_template('index.html', config=load_config())

@app.route('/api/save', methods=['POST'])
@login_required
def api_save():
    save_config(request.json)
    global logger
    logger = setup_logging() # 重载日志配置
    return jsonify({"status": "ok"})

# --- 启动逻辑 ---
def start_services():
    cfg = load_config()
    port = int(cfg.get('server_config', {}).get('port', 587))
    
    print(f"Starting SMTP Server on port {port}...")
    # Controller 自带线程管理
    Controller(RelayHandler(), hostname='0.0.0.0', port=port).start()

    print("Starting Web Server on port 8080...")
    app.run(host='0.0.0.0', port=8080, debug=False, use_reloader=False)

if __name__ == '__main__':
    start_services()
EOF

    # =========================================================
    # 3. 写入前端模板 index.html (包含 Sender Email 字段 + Vue修复)
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
            <!-- 修复：使用 v-text 避免 Jinja2 报错 -->
            <button class="btn btn-success" @click="save" :disabled="saving" v-text="saving ? '保存中...' : '保存配置'">
            </button>
        </div>

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
                            <!-- Sender Email 字段 -->
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
            data() { return { config: {{ config|tojson }}, saving: false } },
            methods: {
                addNode() { 
                    this.config.downstream_pool.push({ 
                        name: 'Node-' + (this.config.downstream_pool.length + 1), 
                        host: '', port: 587, encryption: 'none', 
                        username: '', password: '', sender_email: '' 
                    }); 
                },
                delNode(i) { if(confirm('确定删除?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        alert('保存成功！如修改了监听端口，请在脚本菜单中选择重启服务。');
                    } catch(e) { alert('失败: ' + e); }
                    this.saving = false;
                }
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF

    # =========================================================
    # 4. 配置 Supervisor (直接调用 Python, 弃用 Gunicorn)
    # =========================================================
    echo -e "${GREEN}🛡️ 配置 Supervisor 守护进程...${PLAIN}"
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

    # =========================================================
    # 5. 防火墙修复 (UFW + IPTables 双保险)
    # =========================================================
    echo -e "${GREEN}🔥 修复防火墙端口 (8080 & 587)...${PLAIN}"
    ufw allow 8080/tcp >/dev/null 2>&1
    ufw allow 587/tcp >/dev/null 2>&1
    # 强制插队到第一条，解决云厂商安全组问题
    iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
    iptables -I INPUT 1 -p tcp --dport 587 -j ACCEPT
    if dpkg -l | grep -q netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    fi

    # =========================================================
    # 6. 重启应用
    # =========================================================
    echo -e "${GREEN}🔄 重启服务...${PLAIN}"
    supervisorctl reread >/dev/null
    supervisorctl update >/dev/null
    supervisorctl restart smtp-web

    echo -e "=================================================="
    echo -e "${GREEN}✅ 安装/更新 成功！功能已全部就绪。${PLAIN}"
    echo -e "🌐 面板地址: http://$(curl -s ifconfig.me):8080"
    echo -e "🔑 默认密码: admin"
    echo -e "📧 SMTP端口: 587"
    echo -e "=================================================="
}

# =========================================================
# 卸载逻辑
# =========================================================
uninstall_smtp() {
    echo -e "${YELLOW}⚠️  警告: 此操作将删除所有文件和配置！${PLAIN}"
    read -p "确认卸载? [y/n]: " choice
    if [[ "$choice" == "y" ]]; then
        echo "停止服务..."
        supervisorctl stop smtp-web
        rm -f /etc/supervisor/conf.d/smtp_web.conf
        supervisorctl reread
        supervisorctl update

        echo "删除文件..."
        rm -rf "$APP_DIR"
        rm -rf "$LOG_DIR"
        echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
    else
        echo "已取消。"
    fi
}

# =========================================================
# 菜单系统
# =========================================================
show_menu() {
    clear
    echo -e "============================================"
    echo -e "   🚀 SMTP Relay Manager 终极管理脚本 "
    echo -e "============================================"
    echo -e "${GREEN}1.${PLAIN} 安装 / 更新 (保留配置)"
    echo -e "${GREEN}2.${PLAIN} 启动服务"
    echo -e "${GREEN}3.${PLAIN} 停止服务"
    echo -e "${GREEN}4.${PLAIN} 重启服务"
    echo -e "${GREEN}5.${PLAIN} 查看实时日志"
    echo -e "${GREEN}6.${PLAIN} 修改面板密码"
    echo -e "${RED}0.${PLAIN} 彻底卸载"
    echo -e "============================================"
    read -p "请输入选项 [0-6]: " num

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
           echo -e "${GREEN}✅ 密码修改成功，请重启服务生效。${PLAIN}"
           ;;
        0) uninstall_smtp ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
}

# 入口
show_menu
