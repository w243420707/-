#!/bin/bash

# ==========================================
# SMTP Relay Manager - 最终修复版一键安装脚本
# ==========================================

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 用户运行此脚本 (sudo -i)"
  exit
fi

echo "🚀 开始安装 SMTP Relay Manager..."

# 2. 更新系统并安装基础依赖
echo "📦 更新系统并安装依赖..."
apt-get update -y
apt-get install -y python3 python3-venv python3-pip supervisor git ufw curl

# 3. 创建目录结构
echo "📂 创建项目目录..."
rm -rf /opt/smtp-relay  # 为了防止旧文件冲突，先清理
mkdir -p /opt/smtp-relay/templates
mkdir -p /var/log/smtp-relay

# 4. 创建 Python 虚拟环境
echo "🐍 配置 Python 环境..."
cd /opt/smtp-relay
python3 -m venv venv
./venv/bin/pip install --upgrade pip
# 安装 Flask 依赖
./venv/bin/pip install flask requests

# ==========================================
# 5. 写入核心代码 (已修复 Vue/Jinja2 冲突)
# ==========================================

echo "📝 写入 Web 后端 (app.py)..."
cat > /opt/smtp-relay/app.py << 'EOF'
import os
import json
import signal
import sys
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps

# 配置路径
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')

app = Flask(__name__)
app.secret_key = os.urandom(24)

# 默认配置
DEFAULT_CONFIG = {
    "server_config": {"host": "0.0.0.0", "port": 587, "username": "myapp", "password": "123"},
    "web_config": {"admin_password": "admin"},
    "telegram_config": {"bot_token": "", "admin_id": ""},
    "log_config": {"max_mb": 50, "backups": 3},
    "downstream_pool": []
}

def load_config():
    if not os.path.exists(CONFIG_FILE):
        save_config(DEFAULT_CONFIG)
        return DEFAULT_CONFIG
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except:
        return DEFAULT_CONFIG

def save_config(data):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(data, f, indent=4)

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/login', methods=['GET', 'POST'])
def login():
    config = load_config()
    error = None
    if request.method == 'POST':
        password_input = request.form.get('password')
        if password_input == config['web_config']['admin_password']:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            error = '密码错误'
    
    # 简单的内嵌登录页
    return f'''
    <!DOCTYPE html>
    <html>
    <head><title>Login</title><meta name="viewport" content="width=device-width, initial-scale=1"></head>
    <body style="display:flex;justify-content:center;align-items:center;height:100vh;background:#f0f2f5;font-family:sans-serif;">
        <form method="post" style="background:white;padding:30px;border-radius:8px;box-shadow:0 2px 10px rgba(0,0,0,0.1);text-align:center;width:300px;">
            <h3 style="margin-bottom:20px;">系统登录</h3>
            <input type="password" name="password" placeholder="输入密码" required style="width:100%;padding:10px;margin-bottom:15px;box-sizing:border-box;border:1px solid #ddd;border-radius:4px;">
            <button type="submit" style="width:100%;padding:10px;background:#0d6efd;color:white;border:none;border-radius:4px;cursor:pointer;">登录</button>
            <p style="color:red;margin-top:10px;font-size:14px;">{error if error else ''}</p>
        </form>
    </body>
    </html>
    '''

@app.route('/')
@login_required
def index():
    return render_template('index.html', config=load_config())

@app.route('/api/save', methods=['POST'])
@login_required
def api_save():
    new_config = request.json
    save_config(new_config)
    # 触发重启
    def restart():
        import time
        time.sleep(1)
        os.kill(os.getpid(), signal.SIGTERM)
    from threading import Thread
    Thread(target=restart).start()
    return jsonify({"status": "ok"})

if __name__ == '__main__':
    # 绑定 0.0.0.0 确保外网可访问
    app.run(host='0.0.0.0', port=8080)
EOF

echo "📝 写入 Web 前端模板 (index.html - 已修复 Vue/Jinja2 冲突)..."
cat > /opt/smtp-relay/templates/index.html << 'EOF'
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
            <!-- 修复点：使用 v-text 防止 Jinja2 报错 -->
            <button class="btn btn-success" @click="save" :disabled="saving" v-text="saving ? '服务重启中...' : '保存配置并重启'">
            </button>
        </div>

        <div class="row mb-4">
            <div class="col-md-6">
                <div class="card h-100 shadow-sm">
                    <div class="card-header bg-primary text-white">Server 监听设置</div>
                    <div class="card-body">
                        <div class="mb-2"><label>监听端口</label><input type="number" v-model.number="config.server_config.port" class="form-control"></div>
                        <div class="mb-2"><label>认证账号</label><input v-model="config.server_config.username" class="form-control"></div>
                        <div class="mb-2"><label>认证密码</label><input v-model="config.server_config.password" class="form-control"></div>
                    </div>
                </div>
            </div>
            <div class="col-md-6">
                <div class="card h-100 shadow-sm">
                    <div class="card-header bg-info text-white">日志与系统</div>
                    <div class="card-body">
                        <div class="row">
                            <div class="col-6 mb-2"><label>单文件限制 (MB)</label><input type="number" v-model.number="config.log_config.max_mb" class="form-control"></div>
                            <div class="col-6 mb-2"><label>保留备份数</label><input type="number" v-model.number="config.log_config.backups" class="form-control"></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="card shadow-sm">
            <div class="card-header d-flex justify-content-between align-items-center bg-dark text-white">
                <span>下游节点池</span>
                <button class="btn btn-sm btn-light" @click="addNode">+ 添加节点</button>
            </div>
            <div class="card-body bg-light">
                <div v-if="config.downstream_pool.length === 0" class="text-center text-muted py-3">暂无节点，请点击添加</div>
                <div v-for="(n, i) in config.downstream_pool" :key="i" class="pool-item shadow-sm">
                    <button class="btn btn-danger btn-sm btn-del" @click="delNode(i)">删除</button>
                    <div class="row g-2">
                        <div class="col-md-3"><label class="small text-muted">名称</label><input v-model="n.name" class="form-control"></div>
                        <div class="col-md-3"><label class="small text-muted">Host</label><input v-model="n.host" class="form-control"></div>
                        <div class="col-md-2"><label class="small text-muted">端口</label><input v-model.number="n.port" class="form-control"></div>
                        <div class="col-md-4"><label class="small text-muted">加密</label>
                            <select v-model="n.encryption" class="form-select">
                                <option value="none">无 / STARTTLS</option>
                                <option value="tls">TLS</option>
                                <option value="ssl">SSL</option>
                            </select>
                        </div>
                        <div class="col-md-4"><label class="small text-muted">账号</label><input v-model="n.username" class="form-control"></div>
                        <div class="col-md-4"><label class="small text-muted">密码</label><input v-model="n.password" class="form-control"></div>
                        <div class="col-md-4"><label class="small text-muted">Sender Email</label><input v-model="n.sender_email" class="form-control"></div>
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
                addNode() { this.config.downstream_pool.push({ name: '新节点', host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '' }); },
                delNode(i) { if(confirm('确定删除?')) this.config.downstream_pool.splice(i, 1); },
                async save() {
                    this.saving = true;
                    try {
                        await fetch('/api/save', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(this.config) });
                        alert('保存成功，服务重启中，请稍后刷新页面...');
                        setTimeout(() => location.reload(), 2000);
                    } catch(e) { alert('保存失败: ' + e); }
                    this.saving = false;
                }
            }
        }).mount('#app');
    </script>
</body>
</html>
EOF

echo "⚙️ 初始化配置文件..."
cat > /opt/smtp-relay/config.json << EOF
{
    "server_config": {
        "host": "0.0.0.0",
        "port": 587,
        "username": "myapp",
        "password": "123"
    },
    "web_config": {
        "admin_password": "admin"
    },
    "telegram_config": {
        "bot_token": "",
        "admin_id": ""
    },
    "log_config": {
        "max_mb": 50,
        "backups": 3
    },
    "downstream_pool": []
}
EOF

# ==========================================
# 6. 配置 Supervisor 守护进程 (弃用 Gunicorn，使用 Python 直接启动)
# ==========================================
echo "🛡️ 配置 Supervisor 守护进程..."
cat > /etc/supervisor/conf.d/smtp_web.conf << EOF
[program:smtp-web]
directory=/opt/smtp-relay
command=/opt/smtp-relay/venv/bin/python3 app.py
autostart=true
autorestart=true
stderr_logfile=/var/log/smtp-relay/web.err.log
stdout_logfile=/var/log/smtp-relay/web.out.log
user=root
EOF

# ==========================================
# 7. 终极网络/防火墙修复
# ==========================================
echo "🔥 开放防火墙端口..."
# UFW
ufw allow 8080/tcp
ufw allow 587/tcp
# Iptables 强制插入规则 (解决 Oracle/AWS 疑难杂症)
iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
iptables -I INPUT 1 -p tcp --dport 587 -j ACCEPT
# 保存规则 (如果安装了 netfilter-persistent)
if dpkg -l | grep -q netfilter-persistent; then
    netfilter-persistent save
fi

# ==========================================
# 8. 启动服务
# ==========================================
echo "🔄 重启 Supervisor 服务..."
supervisorctl reread
supervisorctl update
supervisorctl restart smtp-web

echo "=================================================="
echo "✅ 安装成功！"
echo "🌐 Web 面板地址: http://$(curl -s ifconfig.me):8080"
echo "🔑 默认密码: admin"
echo "⚠️  注意: 如果无法访问，请务必去云服务商后台(Security Group)放行 8080 端口"
echo "=================================================="
