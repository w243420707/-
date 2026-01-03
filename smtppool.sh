#!/bin/bash

# ============================================================
# SMTP Relay Manager v3.0 (Ultimate Edition)
# 功能：SMTP转发核心 + WebUI管理 + TG机器人 + 日志动态管理
# ============================================================

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="/opt/smtp-relay"

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本 (sudo bash install.sh)${NC}"
  exit 1
fi

# ============================================================
# 核心函数：写入所有 Python 代码文件
# ============================================================
write_core_code() {
    echo -e "${BLUE}>>> 正在写入核心系统代码...${NC}"
    mkdir -p ${PROJECT_DIR}/templates
    mkdir -p ${PROJECT_DIR}/static

# ---------------- Server.py (SMTP 接收端) ----------------
cat > ${PROJECT_DIR}/server.py << 'EOF'
import asyncio
import logging
import json
import uuid
import redis
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult, LoginPassword

def load_config():
    with open('config.json', 'r') as f:
        return json.load(f)['server_config']

r = redis.Redis(host='localhost', port=6379, db=0)
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
logger = logging.getLogger("SMTP_Server")

class CustomAuthenticator:
    def __call__(self, server, session, envelope, mechanism, auth_data):
        fail_nothandled = AuthResult(success=False, handled=False)
        if mechanism not in ("LOGIN", "PLAIN") or not isinstance(auth_data, LoginPassword):
            return fail_nothandled

        username = auth_data.login.decode("utf-8")
        password = auth_data.password.decode("utf-8")
        
        try:
            conf = load_config()
            if conf['username'] == username and conf['password'] == password:
                return AuthResult(success=True)
        except:
            pass
        return AuthResult(success=False, handled=False)

class RelayHandler:
    async def handle_DATA(self, server, session, envelope):
        try:
            task = {
                "id": str(uuid.uuid4()),
                "original_sender": envelope.mail_from,
                "recipients": envelope.rcpt_tos,
                "raw_data": envelope.content.decode('latin1')
            }
            r.lpush('email_queue', json.dumps(task))
            return '250 OK: Queued'
        except Exception as e:
            logger.error(f"Error: {e}")
            return '451 Temporary failure'

if __name__ == '__main__':
    conf = load_config()
    handler = RelayHandler()
    auth = CustomAuthenticator()
    controller = Controller(handler, hostname=conf['host'], port=conf['port'], authenticator=auth, auth_require_tls=False)
    controller.start()
    print(f"Server running on port {conf['port']}")
    try:
        asyncio.get_event_loop().run_forever()
    except KeyboardInterrupt:
        controller.stop()
EOF

# ---------------- Worker.py (SMTP 发送端) ----------------
cat > ${PROJECT_DIR}/worker.py << 'EOF'
import redis
import json
import smtplib
import ssl
import time
from email.policy import default
from email.parser import Parser

def load_pool():
    with open('config.json', 'r') as f:
        return json.load(f)['downstream_pool']

r = redis.Redis(host='localhost', port=6379, db=0)

def process_headers(raw_data_str, downstream_config, original_real_sender):
    msg = Parser(policy=default).parsestr(raw_data_str)
    # 强制替换 From 为下游节点要求的发件人，防止 550 错误
    app_defined_from = msg.get('From')
    if 'From' in msg: del msg['From']
    msg['From'] = downstream_config['sender_email']
    # 如果没有 Reply-To，将原始发件人设为 Reply-To
    if not msg['Reply-To']:
        msg['Reply-To'] = app_defined_from if app_defined_from else original_real_sender
    return msg

def send_mail(msg_obj, recipients, config):
    try:
        context = ssl.create_default_context()
        if config['encryption'] == 'ssl':
            server = smtplib.SMTP_SSL(config['host'], config['port'], context=context)
        else:
            server = smtplib.SMTP(config['host'], config['port'])
            if config['encryption'] == 'tls':
                server.starttls(context=context)
        
        if config['username']:
            server.login(config['username'], config['password'])
            
        server.send_message(msg_obj, to_addrs=recipients)
        server.quit()
        return True
    except Exception as e:
        print(f"Failed via {config['host']}: {e}")
        return False

def run():
    print("Worker started...")
    pool_index = 0
    
    while True:
        queue_item = r.brpop('email_queue', timeout=5)
        if not queue_item: continue
        
        pool = load_pool()
        if not pool:
            print("Pool is empty! Requeuing...")
            r.rpush('email_queue', queue_item[1])
            time.sleep(5)
            continue
            
        _, data_bytes = queue_item
        task = json.loads(data_bytes)
        
        # 轮询获取节点
        node = pool[pool_index % len(pool)]
        pool_index += 1
        
        try:
            email_msg = process_headers(task['raw_data'], node, task['original_sender'])
            success = send_mail(email_msg, task['recipients'], node)
            
            if not success:
                print("Send failed, requeuing task...")
                r.rpush('email_queue', json.dumps(task))
                time.sleep(2)
        except Exception as e:
             print(f"Critical Error: {e}")
             # 严重错误也要重试，避免丢信
             r.rpush('email_queue', json.dumps(task))
             time.sleep(2)

if __name__ == '__main__':
    run()
EOF

# ---------------- Bot.py (Telegram 机器人) ----------------
cat > ${PROJECT_DIR}/bot.py << 'EOF'
import logging
import json
import subprocess
import asyncio
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, ContextTypes, CommandHandler, CallbackQueryHandler

logging.basicConfig(level=logging.INFO)
CONFIG_FILE = 'config.json'

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f, indent=4)

conf = load_config()
TOKEN = conf['telegram_config'].get('bot_token', '')
ADMIN_ID = str(conf['telegram_config'].get('admin_id', ''))

if not TOKEN:
    print("Bot token not configured, exiting.")
    exit(0)

def admin_only(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        uid = str(update.effective_user.id)
        if uid != ADMIN_ID:
            return
        return await func(update, context)
    return wrapper

@admin_only
async def start(update: Update, context):
    await update.message.reply_text("🤖 **SMTP Relay Bot**\n\n/status - 查看状态\n/list - 节点管理\n/restart - 重启服务")

@admin_only
async def status(update: Update, context):
    c = load_config()
    log_limit = c.get('log_config', {}).get('max_mb', 'N/A')
    await update.message.reply_text(
        f"📊 **系统状态**\n"
        f"✅ 端口: `{c['server_config']['port']}`\n"
        f"🌍 节点数: {len(c['downstream_pool'])}\n"
        f"📝 日志限制: {log_limit} MB"
    )

@admin_only
async def list_nodes(update: Update, context):
    c = load_config()
    pool = c['downstream_pool']
    if not pool:
        await update.message.reply_text("📭 下游池为空")
        return

    for i, n in enumerate(pool):
        kb = [[InlineKeyboardButton("🗑 删除此节点", callback_data=f"del_{i}")]]
        info = f"🔹 **节点 {i+1}: {n.get('name')}**\nHost: `{n['host']}`"
        await update.message.reply_text(info, reply_markup=InlineKeyboardMarkup(kb))

async def btn_handler(update: Update, context):
    query = update.callback_query
    await query.answer()
    
    if str(query.from_user.id) != ADMIN_ID: return

    if query.data.startswith("del_"):
        idx = int(query.data.split("_")[1])
        c = load_config()
        if idx < len(c['downstream_pool']):
            deleted = c['downstream_pool'].pop(idx)
            save_config(c)
            # 重启 worker 使配置生效
            subprocess.run(["supervisorctl", "restart", "smtp-worker"], check=False)
            await query.edit_message_text(f"✅ 已删除: {deleted['host']}")
        else:
            await query.edit_message_text("❌ 删除失败，索引过期")

@admin_only
async def restart_srv(update: Update, context):
    msg = await update.message.reply_text("🔄 正在重启所有服务...")
    subprocess.run(["supervisorctl", "restart", "all"], check=False)
    await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=msg.message_id, text="✅ 服务已重启")

if __name__ == '__main__':
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler('start', start))
    app.add_handler(CommandHandler('status', status))
    app.add_handler(CommandHandler('list', list_nodes))
    app.add_handler(CommandHandler('restart', restart_srv))
    app.add_handler(CallbackQueryHandler(btn_handler))
    app.run_polling()
EOF

# ---------------- App.py (WebUI 后端 + 动态Supervisor生成) ----------------
cat > ${PROJECT_DIR}/app.py << 'EOF'
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
import json
import os
import subprocess

app = Flask(__name__)
app.secret_key = os.urandom(24)
CONFIG_FILE = 'config.json'
SUPERVISOR_CONF = '/etc/supervisor/conf.d/smtp_relay.conf'
PROJECT_DIR = '/opt/smtp-relay'

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f, indent=4)

def update_supervisor_conf(data):
    # 获取日志配置，默认 50MB, 3个备份
    log_mb = data.get('log_config', {}).get('max_mb', 50)
    backups = data.get('log_config', {}).get('backups', 3)
    
    # 检查 Bot 是否需要启动
    bot_section = ""
    if data.get('telegram_config', {}).get('bot_token'):
        bot_section = f"""
[program:smtp-bot]
directory={PROJECT_DIR}
command={PROJECT_DIR}/venv/bin/python3 bot.py
autostart=true
autorestart=true
stdout_logfile=/var/log/smtp_bot.out.log
stdout_logfile_maxbytes={log_mb}MB
stdout_logfile_backups={backups}
stderr_logfile=/var/log/smtp_bot.err.log
stderr_logfile_maxbytes={log_mb}MB
stderr_logfile_backups={backups}
"""

    content = f"""[program:smtp-server]
directory={PROJECT_DIR}
command={PROJECT_DIR}/venv/bin/python3 server.py
autostart=true
autorestart=true
stdout_logfile=/var/log/smtp_server.out.log
stdout_logfile_maxbytes={log_mb}MB
stdout_logfile_backups={backups}
stderr_logfile=/var/log/smtp_server.err.log
stderr_logfile_maxbytes={log_mb}MB
stderr_logfile_backups={backups}

[program:smtp-worker]
directory={PROJECT_DIR}
command={PROJECT_DIR}/venv/bin/python3 worker.py
autostart=true
autorestart=true
stdout_logfile=/var/log/smtp_worker.out.log
stdout_logfile_maxbytes={log_mb}MB
stdout_logfile_backups={backups}
stderr_logfile=/var/log/smtp_worker.err.log
stderr_logfile_maxbytes={log_mb}MB
stderr_logfile_backups={backups}

[program:smtp-web]
directory={PROJECT_DIR}
command={PROJECT_DIR}/venv/bin/gunicorn -w 1 -b 0.0.0.0:8080 app:app
autostart=true
autorestart=true
stdout_logfile=/var/log/smtp_web.out.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/smtp_web.err.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3

{bot_section}
"""
    with open(SUPERVISOR_CONF, 'w') as f:
        f.write(content)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        conf = load_config()
        if request.form['password'] == conf['web_config']['admin_password']:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error="密码错误")
    return render_template('login.html')

@app.route('/')
def index():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('index.html', config=load_config())

@app.route('/api/save', methods=['POST'])
def save_settings():
    if not session.get('logged_in'): return jsonify({'status': 'error'}), 403
    data = request.json
    
    # 防止 TG 配置被前端覆盖丢失
    current = load_config()
    data['telegram_config'] = current.get('telegram_config', {})
    
    save_config(data)
    
    try:
        # 1. 更新 Supervisor 配置文件
        update_supervisor_conf(data)
        
        # 2. 刷新 Supervisor
        subprocess.run(["supervisorctl", "reread"], check=True)
        subprocess.run(["supervisorctl", "update"], check=True)
        subprocess.run(["supervisorctl", "restart", "all"], check=True)
        
        return jsonify({'status': 'success', 'msg': '保存成功！日志策略已更新，服务已重启。'})
    except Exception as e:
        return jsonify({'status': 'error', 'msg': str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

# ---------------- HTML Templates ----------------
cat > ${PROJECT_DIR}/templates/login.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>登录 - SMTP Admin</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>body{display:flex;justify-content:center;align-items:center;height:100vh;background:#f8f9fa}.card{width:100%;max-width:350px}</style>
</head>
<body>
    <div class="card shadow p-4">
        <h4 class="text-center mb-3">SMTP Relay</h4>
        {% if error %}<div class="alert alert-danger">{{error}}</div>{% endif %}
        <form method="POST">
            <input type="password" name="password" class="form-control mb-3" placeholder="输入管理员密码" required>
            <button class="btn btn-primary w-100">登录</button>
        </form>
    </div>
</body>
</html>
EOF

cat > ${PROJECT_DIR}/templates/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>SMTP Relay Manager</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        .pool-item { background: #fff; border: 1px solid #ddd; padding: 15px; margin-bottom: 10px; border-radius: 8px; position: relative; }
        .btn-del { position: absolute; top: 10px; right: 10px; }
    </style>
</head>
<body class="bg-light">
    <div id="app" class="container py-5">
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h3>🚀 SMTP Relay 控制台</h3>
            <button class="btn btn-success" @click="save" :disabled="saving">
                {{ saving ? '重启中...' : '保存配置并应用' }}
            </button>
        </div>

        <div class="row mb-4">
            <!-- Server Config -->
            <div class="col-md-6">
                <div class="card h-100 shadow-sm">
                    <div class="card-header bg-primary text-white">Server 监听设置</div>
                    <div class="card-body">
                        <div class="mb-2">
                            <label>监听端口</label>
                            <input type="number" v-model.number="config.server_config.port" class="form-control">
                        </div>
                        <div class="mb-2">
                            <label>认证账号</label>
                            <input v-model="config.server_config.username" class="form-control">
                        </div>
                        <div class="mb-2">
                            <label>认证密码</label>
                            <input v-model="config.server_config.password" class="form-control">
                        </div>
                    </div>
                </div>
            </div>
            
            <!-- Log Config -->
            <div class="col-md-6">
                <div class="card h-100 shadow-sm">
                    <div class="card-header bg-info text-white">日志与系统</div>
                    <div class="card-body">
                        <div class="row">
                            <div class="col-6 mb-2">
                                <label>单文件限制 (MB)</label>
                                <input type="number" v-model.number="config.log_config.max_mb" class="form-control">
                            </div>
                            <div class="col-6 mb-2">
                                <label>保留备份数</label>
                                <input type="number" v-model.number="config.log_config.backups" class="form-control">
                            </div>
                        </div>
                        <div class="alert alert-secondary mt-2 p-2 small">
                            <small>注：修改此处并保存后，系统会自动重写 Supervisor 配置并重启服务。有效防止硬盘被日志写满。</small>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Pool Config -->
        <div class="card shadow-sm">
            <div class="card-header d-flex justify-content-between align-items-center bg-dark text-white">
                <span>下游节点池 (轮询)</span>
                <button class="btn btn-sm btn-light" @click="addNode">+ 添加节点</button>
            </div>
            <div class="card-body bg-light">
                <div v-if="config.downstream_pool.length === 0" class="text-center text-muted py-3">
                    暂无节点，请点击添加
                </div>
                <div v-for="(n, i) in config.downstream_pool" :key="i" class="pool-item shadow-sm">
                    <button class="btn btn-danger btn-sm btn-del" @click="delNode(i)">删除</button>
                    <div class="row g-2">
                        <div class="col-md-3">
                            <label class="small text-muted">备注名称</label>
                            <input v-model="n.name" class="form-control" placeholder="节点名称">
                        </div>
                        <div class="col-md-3">
                            <label class="small text-muted">Host 地址</label>
                            <input v-model="n.host" class="form-control" placeholder="smtp.example.com">
                        </div>
                        <div class="col-md-2">
                            <label class="small text-muted">端口</label>
                            <input v-model.number="n.port" class="form-control">
                        </div>
                        <div class="col-md-4">
                            <label class="small text-muted">加密方式</label>
                            <select v-model="n.encryption" class="form-select">
                                <option value="none">无 / STARTTLS (587/25)</option>
                                <option value="tls">TLS 强制</option>
                                <option value="ssl">SSL (465)</option>
                            </select>
                        </div>
                        <div class="col-md-4">
                            <label class="small text-muted">账号</label>
                            <input v-model="n.username" class="form-control">
                        </div>
                        <div class="col-md-4">
                            <label class="small text-muted">密码</label>
                            <input v-model="n.password" class="form-control">
                        </div>
                        <div class="col-md-4">
                            <label class="small text-muted">发信邮箱 (From)</label>
                            <input v-model="n.sender_email" class="form-control" placeholder="必须匹配账号">
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
                        name: '新节点', host: '', port: 587, encryption: 'none',
                        username: '', password: '', sender_email: ''
                    });
                },
                delNode(i) {
                    if(confirm('确定删除该节点吗？')) this.config.downstream_pool.splice(i, 1);
                },
                async save() {
                    this.saving = true;
                    try {
                        const res = await fetch('/api/save', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify(this.config)
                        });
                        const d = await res.json();
                        alert(d.msg);
                    } catch(e) {
                        alert('保存失败，请检查网络或日志');
                    }
                    this.saving = false;
                }
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF
}

# ============================================================
# 功能：安装 (Install)
# ============================================================
do_install() {
    echo -e "${GREEN}>>> [1/5] 安装系统依赖...${NC}"
    apt update -y
    apt install -y python3-pip python3-venv redis-server supervisor git ufw curl
    
    # 确保 Redis 启动
    systemctl enable redis-server
    systemctl start redis-server

    echo -e "${GREEN}>>> [2/5] 配置初始化...${NC}"
    # 交互式配置
    read -p "设置 Server 监听端口 [默认: 587]: " IN_PORT
    PORT=${IN_PORT:-587}
    
    read -p "设置 Server 连接密码 [默认: 123456]: " IN_APP_PASS
    APP_PASS=${IN_APP_PASS:-123456}
    
    read -p "设置 WebUI 管理密码 [默认: admin]: " IN_WEB_PASS
    WEB_PASS=${IN_WEB_PASS:-admin}
    
    echo -e "${YELLOW}--- Telegram 机器人设置 (可选，回车跳过) ---${NC}"
    read -p "Bot Token: " BOT_TOKEN
    read -p "Admin ID: " ADMIN_ID

    mkdir -p ${PROJECT_DIR}
    cd ${PROJECT_DIR}
    
    # 创建虚拟环境
    if [ ! -d "venv" ]; then
        python3 -m venv venv
    fi
    echo -e "${GREEN}>>> [3/5] 安装 Python 库...${NC}"
    ${PROJECT_DIR}/venv/bin/pip install aiosmtpd redis flask gunicorn python-telegram-bot

    # 生成 config.json
    cat > config.json << EOF
{
    "server_config": {
        "host": "0.0.0.0",
        "port": ${PORT},
        "username": "myapp",
        "password": "${APP_PASS}"
    },
    "web_config": {
        "admin_password": "${WEB_PASS}"
    },
    "telegram_config": {
        "bot_token": "${BOT_TOKEN}",
        "admin_id": "${ADMIN_ID}"
    },
    "log_config": {
        "max_mb": 50,
        "backups": 3
    },
    "downstream_pool": []
}
EOF

    # 写入代码
    write_core_code
    
    echo -e "${GREEN}>>> [4/5] 生成 Supervisor 初始配置...${NC}"
    # 首次运行使用 Python 脚本生成 supervisor 配置，确保逻辑一致性
    ${PROJECT_DIR}/venv/bin/python3 -c "import app, json; app.update_supervisor_conf(json.load(open('config.json')))"
    
    echo -e "${GREEN}>>> [5/5] 启动服务...${NC}"
    supervisorctl reread
    supervisorctl update
    supervisorctl restart all
    
    # 防火墙
    ufw allow ${PORT}/tcp
    ufw allow 8080/tcp
    
    IP=$(curl -s ifconfig.me)
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}   ✅ 安装成功！   ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "WebUI 面板: http://${IP}:8080"
    echo -e "   密码: ${WEB_PASS}"
    echo -e "SMTP 地址:  ${IP}:${PORT}"
    echo -e "   密码: ${APP_PASS}"
    echo -e ""
    echo -e "请登录 WebUI 添加你的第一个发信节点。"
}

# ============================================================
# 功能：更新 (Update) - 仅更新代码，保留配置
# ============================================================
do_update() {
    if [ ! -d "${PROJECT_DIR}" ]; then echo -e "${RED}错误：未找到安装目录，无法更新。${NC}"; return; fi
    
    echo -e "${BLUE}>>> 开始更新流程...${NC}"
    
    # 1. 补丁：检查旧版 config.json 是否缺少 log_config
    ${PROJECT_DIR}/venv/bin/python3 -c "
import json
try:
    with open('config.json','r') as f: d=json.load(f)
    changed = False
    if 'log_config' not in d:
        d['log_config'] = {'max_mb': 50, 'backups': 3}
        changed = True
    if changed:
        with open('config.json','w') as f: json.dump(d,f,indent=4)
        print('已自动补全配置文件结构。')
except: pass"

    # 2. 更新依赖
    ${PROJECT_DIR}/venv/bin/pip install aiosmtpd redis flask gunicorn python-telegram-bot --upgrade
    
    # 3. 覆盖代码
    write_core_code
    
    # 4. 重新生成 Supervisor 配置 (以防 Python 代码变更导致生成逻辑变化)
    ${PROJECT_DIR}/venv/bin/python3 -c "import app, json; app.update_supervisor_conf(json.load(open('config.json')))"
    
    # 5. 重启
    supervisorctl reread
    supervisorctl update
    supervisorctl restart all
    
    echo -e "${GREEN}✅ 更新完成！${NC}"
}

# ============================================================
# 功能：卸载 (Uninstall)
# ============================================================
do_uninstall() {
    echo -e "${RED}⚠️  警告：这将删除所有程序文件和配置！${NC}"
    read -p "确认继续? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi
    
    supervisorctl stop all
    rm -rf ${PROJECT_DIR}
    rm /etc/supervisor/conf.d/smtp_relay.conf
    supervisorctl reread
    supervisorctl update
    
    echo -e "${GREEN}✅ 已卸载清理。${NC} (防火墙规则请手动检查 ufw status)"
}

# ============================================================
# 菜单入口
# ============================================================
clear
echo -e "${GREEN}################################################${NC}"
echo -e "${GREEN}#      SMTP Relay Manager v3.0 (Web控制版)     #${NC}"
echo -e "${GREEN}################################################${NC}"
echo -e "1. 安装 (Install)"
echo -e "2. 更新 (Update) - 保留配置"
echo -e "3. 卸载 (Uninstall)"
echo -e "0. 退出"
echo -e ""
read -p "请选择: " choice

case $choice in
    1) do_install ;;
    2) do_update ;;
    3) do_uninstall ;;
    *) exit ;;
esac
