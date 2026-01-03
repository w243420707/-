#!/bin/bash

# ============================================================
# SMTP Relay Manager - 全能管理脚本
# 包含：安装、代码热更新、卸载清理
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
  echo -e "${RED}错误：请使用 root 权限运行此脚本。${NC}"
  exit 1
fi

# ============================================================
# 函数：写入核心代码 (用于安装和更新)
# ============================================================
write_core_code() {
    echo -e "${BLUE}>>> 正在写入/更新 Python 核心代码...${NC}"
    mkdir -p ${PROJECT_DIR}/templates
    mkdir -p ${PROJECT_DIR}/static

# --- server.py ---
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
        except: pass
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

# --- worker.py ---
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
    app_defined_from = msg.get('From')
    if 'From' in msg: del msg['From']
    msg['From'] = downstream_config['sender_email']
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
            print("Pool empty! Requeuing...")
            r.rpush('email_queue', queue_item[1])
            time.sleep(5)
            continue
        _, data_bytes = queue_item
        task = json.loads(data_bytes)
        node = pool[pool_index % len(pool)]
        pool_index += 1
        email_msg = process_headers(task['raw_data'], node, task['original_sender'])
        success = send_mail(email_msg, task['recipients'], node)
        if not success:
            r.rpush('email_queue', json.dumps(task))
            time.sleep(2)

if __name__ == '__main__':
    run()
EOF

# --- app.py (WebUI) ---
cat > ${PROJECT_DIR}/app.py << 'EOF'
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
import json
import os
import subprocess

app = Flask(__name__)
app.secret_key = os.urandom(24)
CONFIG_FILE = 'config.json'

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f, indent=4)

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
    current = load_config()
    data['telegram_config'] = current.get('telegram_config', {})
    save_config(data)
    try:
        subprocess.run(["supervisorctl", "restart", "smtp-server", "smtp-worker"], check=False)
        return jsonify({'status': 'success', 'msg': '保存成功，服务已重启'})
    except Exception as e:
        return jsonify({'status': 'error', 'msg': str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

# --- bot.py (Telegram) ---
cat > ${PROJECT_DIR}/bot.py << 'EOF'
import logging
import json
import subprocess
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

if not TOKEN or not ADMIN_ID:
    print("Bot not configured.")
    exit(0)

def admin_only(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        if str(update.effective_user.id) != ADMIN_ID: return
        return await func(update, context)
    return wrapper

@admin_only
async def start(update: Update, context):
    await update.message.reply_text("🤖 **SMTP Bot**\n/status - 状态\n/list - 节点管理\n/restart - 重启")

@admin_only
async def status(update: Update, context):
    c = load_config()
    await update.message.reply_text(f"✅ 端口: {c['server_config']['port']}\n🌍 节点: {len(c['downstream_pool'])}")

@admin_only
async def list_nodes(update: Update, context):
    c = load_config()
    if not c['downstream_pool']: await update.message.reply_text("📭 空池"); return
    for i, n in enumerate(c['downstream_pool']):
        kb = [[InlineKeyboardButton("🗑 删除", callback_data=f"del_{i}")]]
        await update.message.reply_text(f"🔹 **{n.get('name')}**\nHost: {n['host']}", reply_markup=InlineKeyboardMarkup(kb))

async def btn(update: Update, context):
    q = update.callback_query
    await q.answer()
    if str(q.from_user.id) != ADMIN_ID: return
    if q.data.startswith("del_"):
        idx = int(q.data.split("_")[1])
        c = load_config()
        if idx < len(c['downstream_pool']):
            n = c['downstream_pool'].pop(idx)
            save_config(c)
            subprocess.run(["supervisorctl", "restart", "smtp-worker"], check=False)
            await q.edit_message_text(f"✅ 已删除 {n['host']}")
        else: await q.edit_message_text("❌ 索引无效")

@admin_only
async def restart(update: Update, context):
    msg = await update.message.reply_text("🔄 重启中...")
    subprocess.run(["supervisorctl", "restart", "all"], check=False)
    await context.bot.edit_message_text(chat_id=update.effective_chat.id, message_id=msg.message_id, text="✅ 完成")

if __name__ == '__main__':
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler('start', start))
    app.add_handler(CommandHandler('status', status))
    app.add_handler(CommandHandler('list', list_nodes))
    app.add_handler(CommandHandler('restart', restart))
    app.add_handler(CallbackQueryHandler(btn))
    app.run_polling()
EOF

# --- Templates ---
cat > ${PROJECT_DIR}/templates/login.html << 'EOF'
<!DOCTYPE html><html><head><title>Login</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet"><style>body{display:flex;justify-content:center;align-items:center;height:100vh;background:#f8f9fa}.card{width:350px}</style></head><body><div class="card shadow p-4"><h4 class="text-center mb-3">SMTP Admin</h4>{% if error %}<div class="alert alert-danger">{{error}}</div>{% endif %}<form method="POST"><input type="password" name="password" class="form-control mb-3" placeholder="Password" required><button class="btn btn-primary w-100">Login</button></form></div></body></html>
EOF

cat > ${PROJECT_DIR}/templates/index.html << 'EOF'
<!DOCTYPE html><html><head><title>SMTP Relay</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet"><script src="https://unpkg.com/vue@3/dist/vue.global.js"></script></head><body class="bg-light"><div id="app" class="container py-5"><div class="d-flex justify-content-between mb-4"><h3>SMTP Relay Manager</h3><button class="btn btn-success" @click="save" :disabled="saving">{{ saving ? 'Saving...' : 'Save & Restart' }}</button></div><div class="card mb-3"><div class="card-header">Server Config</div><div class="card-body row g-3"><div class="col-md-4"><label>Port</label><input type="number" v-model.number="config.server_config.port" class="form-control"></div><div class="col-md-4"><label>User</label><input v-model="config.server_config.username" class="form-control"></div><div class="col-md-4"><label>Pass</label><input v-model="config.server_config.password" class="form-control"></div></div></div><div class="card"><div class="card-header d-flex justify-content-between"><span>Downstream Pool</span><button class="btn btn-sm btn-primary" @click="addNode">+ Add</button></div><div class="card-body"><div v-for="(n, i) in config.downstream_pool" :key="i" class="border p-3 mb-2 rounded position-relative bg-white"><button class="btn btn-danger btn-sm position-absolute top-0 end-0 m-2" @click="delNode(i)">Del</button><div class="row g-2"><div class="col-3"><input v-model="n.name" class="form-control" placeholder="Name"></div><div class="col-3"><input v-model="n.host" class="form-control" placeholder="Host"></div><div class="col-2"><input v-model.number="n.port" class="form-control" placeholder="Port"></div><div class="col-4"><select v-model="n.encryption" class="form-select"><option value="none">None/STARTTLS</option><option value="tls">TLS</option><option value="ssl">SSL</option></select></div><div class="col-4"><input v-model="n.username" class="form-control" placeholder="User"></div><div class="col-4"><input v-model="n.password" class="form-control" placeholder="Pass"></div><div class="col-4"><input v-model="n.sender_email" class="form-control" placeholder="Sender Email"></div></div></div></div></div></div><script>Vue.createApp({data(){return{config:{{config|tojson}},saving:false}},methods:{addNode(){this.config.downstream_pool.push({name:'New',host:'',port:587,encryption:'none',username:'',password:'',sender_email:''})},delNode(i){if(confirm('Sure?'))this.config.downstream_pool.splice(i,1)},async save(){this.saving=true;await fetch('/api/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(this.config)});alert('Saved & Restarted');this.saving=false;}}}).mount('#app');</script></body></html>
EOF
}

# ============================================================
# 功能：安装 (Install)
# ============================================================
do_install() {
    if [ -f "${PROJECT_DIR}/config.json" ]; then
        echo -e "${YELLOW}检测到已安装！建议选择 [更新] 选项，否则将覆盖配置文件。${NC}"
        read -p "是否强制覆盖安装？(y/n): " confirm
        if [ "$confirm" != "y" ]; then return; fi
    fi

    echo -e "${GREEN}>>> 1. 安装系统依赖...${NC}"
    apt update -y
    apt install -y python3-pip python3-venv redis-server supervisor git ufw curl
    systemctl enable redis-server
    systemctl start redis-server

    echo -e "${GREEN}>>> 2. 配置基本信息...${NC}"
    read -p "SMTP 端口 (默认 587): " SMTP_PORT
    SMTP_PORT=${SMTP_PORT:-587}
    read -p "App连接密码 (默认 123456): " APP_PASS
    APP_PASS=${APP_PASS:-123456}
    read -p "WebUI密码 (默认 admin): " WEB_PASS
    WEB_PASS=${WEB_PASS:-admin}
    read -p "TG Bot Token (可选): " BOT_TOKEN
    read -p "TG Admin ID (可选): " ADMIN_ID

    mkdir -p ${PROJECT_DIR}
    cd ${PROJECT_DIR}
    python3 -m venv venv
    ${PROJECT_DIR}/venv/bin/pip install aiosmtpd redis flask gunicorn python-telegram-bot

    echo -e "${GREEN}>>> 3. 生成配置...${NC}"
    cat > config.json << EOF
{
    "server_config": { "host": "0.0.0.0", "port": ${SMTP_PORT}, "username": "myapp", "password": "${APP_PASS}" },
    "web_config": { "admin_password": "${WEB_PASS}" },
    "telegram_config": { "bot_token": "${BOT_TOKEN}", "admin_id": "${ADMIN_ID}" },
    "downstream_pool": []
}
EOF

    write_core_code
    configure_supervisor
    
    ufw allow ${SMTP_PORT}/tcp
    ufw allow 8080/tcp
    
    echo -e "${GREEN}✅ 安装完成！${NC}"
    echo -e "WebUI: http://$(curl -s ifconfig.me):8080"
}

# ============================================================
# 功能：更新 (Update)
# ============================================================
do_update() {
    if [ ! -d "${PROJECT_DIR}" ]; then
        echo -e "${RED}错误：未找到安装目录，请先执行安装。${NC}"
        return
    fi
    echo -e "${BLUE}>>> 开始更新流程 (仅更新代码，保留 config.json)...${NC}"
    
    # 更新 Python 依赖 (防止依赖变动)
    ${PROJECT_DIR}/venv/bin/pip install aiosmtpd redis flask gunicorn python-telegram-bot --upgrade

    # 重新写入代码
    write_core_code

    # 重启服务
    echo -e "${BLUE}>>> 重启 Supervisor 服务...${NC}"
    configure_supervisor
    supervisorctl reread
    supervisorctl update
    supervisorctl restart all
    
    echo -e "${GREEN}✅ 更新完成！配置数据已保留。${NC}"
}

# ============================================================
# 功能：配置 Supervisor
# ============================================================
configure_supervisor() {
    # 动态检查是否启用 Bot
    BOT_CONF=""
    if grep -q "bot_token" ${PROJECT_DIR}/config.json && grep -q "admin_id" ${PROJECT_DIR}/config.json; then
        # 简单判断，如果 json 里 token 不为空
        if [ $(grep "bot_token" ${PROJECT_DIR}/config.json | grep -v '""' | wc -l) -gt 0 ]; then
            BOT_CONF="[program:smtp-bot]\ndirectory=${PROJECT_DIR}\ncommand=${PROJECT_DIR}/venv/bin/python3 bot.py\nautostart=true\nautorestart=true\nstderr_logfile=/var/log/smtp_bot.err.log\nstdout_logfile=/var/log/smtp_bot.out.log"
        fi
    fi

    echo -e "${BLUE}>>> 刷新 Supervisor 配置...${NC}"
    cat > /etc/supervisor/conf.d/smtp_relay.conf << EOF
[program:smtp-server]
directory=${PROJECT_DIR}
command=${PROJECT_DIR}/venv/bin/python3 server.py
autostart=true
autorestart=true
stderr_logfile=/var/log/smtp_server.err.log
stdout_logfile=/var/log/smtp_server.out.log

[program:smtp-worker]
directory=${PROJECT_DIR}
command=${PROJECT_DIR}/venv/bin/python3 worker.py
autostart=true
autorestart=true
stderr_logfile=/var/log/smtp_worker.err.log
stdout_logfile=/var/log/smtp_worker.out.log

[program:smtp-web]
directory=${PROJECT_DIR}
command=${PROJECT_DIR}/venv/bin/gunicorn -w 1 -b 0.0.0.0:8080 app:app
autostart=true
autorestart=true
stderr_logfile=/var/log/smtp_web.err.log
stdout_logfile=/var/log/smtp_web.out.log

$(echo -e $BOT_CONF)
EOF
}

# ============================================================
# 功能：卸载 (Uninstall)
# ============================================================
do_uninstall() {
    echo -e "${RED}⚠️  警告：这将删除所有程序文件、日志和配置信息！${NC}"
    read -p "确认卸载？(y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    echo -e "${BLUE}>>> 停止进程...${NC}"
    supervisorctl stop all
    
    echo -e "${BLUE}>>> 删除文件...${NC}"
    rm -rf ${PROJECT_DIR}
    rm /etc/supervisor/conf.d/smtp_relay.conf
    
    echo -e "${BLUE}>>> 刷新 Supervisor...${NC}"
    supervisorctl reread
    supervisorctl update

    echo -e "${BLUE}>>> 清理防火墙 (8080)...${NC}"
    ufw delete allow 8080/tcp
    # 注意：SMTP 端口不确定是多少，建议用户手动清理

    echo -e "${GREEN}✅ 卸载完成。${NC}"
}

# ============================================================
# 主菜单
# ============================================================
clear
echo -e "${GREEN}################################################${NC}"
echo -e "${GREEN}#          SMTP Relay 脚本管理器 v2.0          #${NC}"
echo -e "${GREEN}################################################${NC}"
echo -e "1. ${GREEN}安装 (Install)${NC}"
echo -e "2. ${BLUE}更新 (Update)${NC} - 升级代码，保留配置"
echo -e "3. ${RED}卸载 (Uninstall)${NC}"
echo -e "0. 退出 (Exit)"
echo -e ""
read -p "请选择 [1-3]: " choice

case $choice in
    1) do_install ;;
    2) do_update ;;
    3) do_uninstall ;;
    0) exit ;;
    *) echo -e "${RED}无效输入${NC}" ;;
esac
