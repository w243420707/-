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
    "web_config": { "admin_password": "admin", "public_domain": "" },
    "telegram_config": { "bot_token": "", "admin_id": "" },
    "log_config": { "max_mb": 50, "backups": 3, "retention_days": 7 },
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
import uuid
from datetime import datetime, timedelta
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
            created_at TIMESTAMP DEFAULT (datetime('now', '+08:00')),
            updated_at TIMESTAMP DEFAULT (datetime('now', '+08:00')),
            source TEXT DEFAULT 'relay',
            tracking_id TEXT UNIQUE,
            opened_at TIMESTAMP,
            open_count INTEGER DEFAULT 0
        )''')
        
        # Check and add source column safely
        try:
            cursor = conn.execute("PRAGMA table_info(queue)")
            cols = [c[1] for c in cursor.fetchall()]
            if 'source' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN source TEXT DEFAULT 'relay'")
            if 'tracking_id' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN tracking_id TEXT UNIQUE")
            if 'opened_at' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN opened_at TIMESTAMP")
            if 'open_count' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN open_count INTEGER DEFAULT 0")
        except Exception as e:
            print(f"DB Init Warning: {e}")

        # Optimization: Indexes & WAL
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_status ON queue (status)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_node_status ON queue (assigned_node, status)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_created ON queue (created_at)")
        except: pass

        conn.execute('''CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT UNIQUE,
            created_at TIMESTAMP DEFAULT (datetime('now', '+08:00'))
        )''')

        conn.execute('''CREATE TABLE IF NOT EXISTS drafts (
            id INTEGER PRIMARY KEY,
            content TEXT,
            updated_at TIMESTAMP DEFAULT (datetime('now', '+08:00'))
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
        
        # Load Balancing: Routing > Weighted
        rcpt = envelope.rcpt_tos[0] if envelope.rcpt_tos else ''
        
        # --- Redundant Send Logic (3 Nodes) ---
        # 1. Select candidates (Ignore routing rules for relay, use all enabled nodes)
        candidates = pool 
        
        # 2. Randomly select up to 3 unique nodes
        selected_nodes = []
        if len(candidates) <= 3:
            selected_nodes = candidates
        else:
            selected_nodes = random.sample(candidates, 3)
            
        if not selected_nodes:
             logger.warning("❌ No suitable nodes found for redundancy")
             return '451 Temporary failure: No suitable nodes'

        logger.info(f"📥 Received | From: {envelope.mail_from} | To: {envelope.rcpt_tos} | Redundant Nodes: {[n['name'] for n in selected_nodes]}")
        
        # 3. Queue for all selected nodes (No Direct Send anymore to ensure async redundancy)
        try:
            with get_db() as conn:
                for node in selected_nodes:
                    node_name = node.get('name', 'Unknown')
                    conn.execute(
                        "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, last_error, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now', '+08:00'), datetime('now', '+08:00'))",
                        (envelope.mail_from, json.dumps(envelope.rcpt_tos), envelope.content, node_name, 'pending', 'relay', None)
                    )
            return '250 OK: Queued for redundant delivery'
        except Exception as e:
            logger.error(f"❌ DB Error: {e}")
            return '451 Temporary failure: DB Error'

# --- Queue Worker (Consumer) ---
def worker_thread():
    logger.info("👷 Queue Worker Started (Smart Rate Limiting)")
    
    # Runtime state tracking
    node_next_send_time = {}  # { 'node_name': timestamp }
    node_hourly_counts = {}   # { 'node_name': { 'hour': 10, 'count': 50 } }
    last_cleanup_time = 0

    while True:
        try:
            cfg = load_config()
            
            # --- Auto Cleanup (Once per hour) ---
            if time.time() - last_cleanup_time > 3600:
                try:
                    days = int(cfg.get('log_config', {}).get('retention_days', 7))
                    if days > 0:
                        with get_db() as conn:
                            conn.execute(f"DELETE FROM queue WHERE status IN ('sent', 'failed') AND updated_at < datetime('now', '+08:00', '-{days} days')")
                        logger.info(f"🧹 Auto-cleaned records older than {days} days")
                except Exception as e:
                    logger.error(f"Cleanup failed: {e}")
                last_cleanup_time = time.time()

            pool_cfg = {n['name']: n for n in cfg.get('downstream_pool', [])}
            
            # Global Bulk Control
            bulk_ctrl = cfg.get('bulk_control', {}).get('status', 'running')
            
            now = time.time()
            
            # 1. Identify nodes that are currently cooling down (for BULK only)
            # If a node is cooling, we should NOT fetch BULK tasks for it, 
            # but we MUST fetch RELAY tasks for it.
            blocked_nodes = []
            for name, next_time in node_next_send_time.items():
                if now < next_time:
                    blocked_nodes.append(name)
            
            # 2. Fetch pending items with smart filtering
            # Priority: Relay tasks (source != 'bulk') should be processed first (Jump Queue)
            with get_db() as conn:
                if bulk_ctrl == 'paused':
                    # If paused, only fetch non-bulk (relay)
                    rows = conn.execute("SELECT * FROM queue WHERE status='pending' AND source != 'bulk' ORDER BY id ASC LIMIT 50").fetchall()
                elif blocked_nodes:
                    # Fetch: (All Non-Bulk) OR (Bulk for Non-Blocked Nodes)
                    placeholders = ','.join(['?'] * len(blocked_nodes))
                    query = f"SELECT * FROM queue WHERE status='pending' AND (source != 'bulk' OR assigned_node NOT IN ({placeholders})) ORDER BY CASE WHEN source='relay' THEN 0 ELSE 1 END, id ASC LIMIT 50"
                    rows = conn.execute(query, tuple(blocked_nodes)).fetchall()
                else:
                    # Fetch everything, but prioritize relay
                    rows = conn.execute("SELECT * FROM queue WHERE status='pending' ORDER BY CASE WHEN source='relay' THEN 0 ELSE 1 END, id ASC LIMIT 50").fetchall()

            if not rows:
                time.sleep(1)
                continue

            did_work = False

            for row in rows:
                row_id = row['id']
                node_name = row['assigned_node']
                source = row['source']
                is_bulk = (source == 'bulk')
                
                node = pool_cfg.get(node_name)
                
                # Re-route if node removed or disabled
                if not node or not node.get('enabled', True):
                    active_nodes = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
                    if active_nodes:
                        new_node = random.choice(active_nodes)
                        logger.info(f"🔄 Re-routing ID:{row_id} from '{node_name}' to '{new_node['name']}'")
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET assigned_node=?, status='pending' WHERE id=?", (new_node['name'], row_id))
                    else:
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET status='failed', last_error='No active nodes available' WHERE id=?", (row_id,))
                    continue

                # --- Rate Limiting Checks (BULK ONLY) ---
                if is_bulk:
                    # A. Interval Check
                    if now < node_next_send_time.get(node_name, 0):
                        continue # Should be filtered by SQL, but double check

                    # B. Hourly Limit Check
                    max_ph = int(node.get('max_per_hour', 0))
                    if max_ph > 0:
                        current_hour = (datetime.utcnow() + timedelta(hours=8)).hour
                        # Reset/Init counter
                        if node_name not in node_hourly_counts or node_hourly_counts[node_name]['hour'] != current_hour:
                            with get_db() as conn:
                                cnt = conn.execute(
                                    "SELECT COUNT(*) FROM queue WHERE assigned_node=? AND status='sent' AND updated_at > datetime('now', '+08:00', '-1 hour')", 
                                    (node_name,)
                                ).fetchone()[0]
                            node_hourly_counts[node_name] = {'hour': current_hour, 'count': cnt}
                        
                        if node_hourly_counts[node_name]['count'] >= max_ph:
                            # Limit reached, block this node for a while (e.g. 1 min)
                            node_next_send_time[node_name] = now + 60 
                            continue

                # --- Processing ---
                did_work = True
                
                # Mark processing
                with get_db() as conn:
                    conn.execute("UPDATE queue SET status='processing', updated_at=datetime('now', '+08:00') WHERE id=?", (row_id,))

                error_msg = ""
                success = False
                
                try:
                    sender = node.get('sender_email') or row['mail_from'] or node.get('username')
                    rcpt_tos = json.loads(row['rcpt_tos'])
                    msg_content = row['content']

                    # Header rewrite
                    if node.get('sender_email'):
                        try:
                            msg = message_from_bytes(msg_content)
                            if 'From' in msg: del msg['From']
                            msg['From'] = node['sender_email']
                            msg_content = msg.as_bytes()
                        except: pass

                    with smtplib.SMTP(node['host'], int(node['port']), timeout=20) as s:
                        if node.get('encryption') in ['tls', 'ssl']: s.starttls()
                        if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                        s.sendmail(sender, rcpt_tos, msg_content)
                    
                    success = True
                    logger.info(f"✅ Sent ID:{row_id} via {node_name} (Source: {source})")
                    
                    # Update hourly count (All traffic counts towards limit)
                    if node_name in node_hourly_counts:
                        node_hourly_counts[node_name]['count'] += 1

                except Exception as e:
                    error_msg = str(e)
                    logger.error(f"⚠️ Failed ID:{row_id} via {node_name}: {e}")

                # Update DB
                with get_db() as conn:
                    if success:
                        conn.execute("UPDATE queue SET status='sent', updated_at=datetime('now', '+08:00') WHERE id=?", (row_id,))
                    else:
                        conn.execute("UPDATE queue SET status='failed', last_error=?, updated_at=datetime('now', '+08:00') WHERE id=?", (error_msg, row_id))

                # --- Set Next Available Time ---
                # We update the cooling timer for ALL successful sends to pace the connection,
                # BUT only Bulk items will respect it in the next loop.
                global_limit = cfg.get('limit_config', {})
                min_int = int(node.get('min_interval') or global_limit.get('min_interval', 1))
                max_int = int(node.get('max_interval') or global_limit.get('max_interval', 5))
                
                delay = random.uniform(min_int, max_int)
                node_next_send_time[node_name] = time.time() + delay

            if not did_work:
                time.sleep(0.5)

        except Exception as e:
            logger.error(f"Worker Error: {e}")
            time.sleep(5)

# --- Web App ---
app = Flask(__name__)
# Persistent Secret Key to prevent session logout on restart
try:
    _cfg = load_config()
    if 'secret_key' not in _cfg.get('web_config', {}):
        if 'web_config' not in _cfg: _cfg['web_config'] = {}
        _cfg['web_config']['secret_key'] = os.urandom(24).hex()
        save_config(_cfg)
    app.secret_key = bytes.fromhex(_cfg['web_config']['secret_key'])
except:
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
    # Auto rebalance after save
    try:
        rebalance_queue_internal()
    except Exception as e:
        logger.error(f"Auto-rebalance failed: {e}")
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
        
        # Open stats
        try:
            opened = conn.execute("SELECT COUNT(*) FROM queue WHERE open_count > 0").fetchone()[0]
            total['opened'] = opened
        except: total['opened'] = 0

        # Speed stats (Sent in last hour)
        try:
            speed = conn.execute("SELECT COUNT(*) FROM queue WHERE status='sent' AND updated_at > datetime('now', '+08:00', '-1 hour')").fetchone()[0]
            total['speed_ph'] = speed
        except: total['speed_ph'] = 0

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
    try:
        limit = int(request.args.get('limit', 50))
    except: limit = 50
    with get_db() as conn:
        rows = conn.execute("SELECT id, mail_from, rcpt_tos, assigned_node, status, retry_count, last_error, created_at FROM queue ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return jsonify([dict(r) for r in rows])

@app.route('/api/domain/stats')
@login_required
def api_domain_stats():
    """Get top 9 recipient domains by count"""
    with get_db() as conn:
        rows = conn.execute("SELECT rcpt_tos FROM queue").fetchall()
    
    domain_count = {}
    for row in rows:
        try:
            rcpts = json.loads(row['rcpt_tos']) if row['rcpt_tos'] else []
            for email in rcpts:
                if '@' in email:
                    domain = email.split('@')[-1].lower().strip()
                    if domain:
                        domain_count[domain] = domain_count.get(domain, 0) + 1
        except: pass
    
    # Sort by count descending, take top 9
    sorted_domains = sorted(domain_count.items(), key=lambda x: x[1], reverse=True)[:9]
    result = [{'domain': d, 'count': c} for d, c in sorted_domains]
    
    # Calculate "other" count
    top_total = sum(c for d, c in sorted_domains)
    all_total = sum(domain_count.values())
    other_count = all_total - top_total
    if other_count > 0:
        result.append({'domain': '__other__', 'count': other_count})
    
    return jsonify(result)

def select_weighted_node(nodes, global_limit):
    if not nodes: return None
    try:
        weights = []
        for node in nodes:
            # Calculate theoretical speed (Emails/Hour)
            min_i = float(node.get('min_interval') or global_limit.get('min_interval', 1))
            max_i = float(node.get('max_interval') or global_limit.get('max_interval', 5))
            avg_i = (min_i + max_i) / 2
            if avg_i <= 0.01: avg_i = 0.01
            
            speed = 3600 / avg_i
            
            # Cap by hourly limit
            max_ph = int(node.get('max_per_hour', 0))
            if max_ph > 0: speed = min(speed, max_ph)
            
            weights.append(speed)
            
        return random.choices(nodes, weights=weights, k=1)[0]
    except:
        return random.choice(nodes)

def select_node_for_recipient(pool, recipient, global_limit, source='relay'):
    # pool is list of node dicts
    if not pool: return None
    try:
        domain = recipient.split('@')[-1].lower().strip()
    except:
        domain = ""
        
    specific_nodes = []
    wildcard_nodes = []
    
    for node in pool:
        # Filter by source capability
        if source == 'bulk' and not node.get('allow_bulk', True):
            continue

        rules = node.get('routing_rules', '')
        if not rules or not rules.strip():
            wildcard_nodes.append(node)
        else:
            # Check if domain matches any rule
            allowed = [d.strip().lower() for d in rules.split(',') if d.strip()]
            if domain in allowed:
                specific_nodes.append(node)
    
    # Priority: Specific > Wildcard > All (Fallback)
    candidates = specific_nodes if specific_nodes else wildcard_nodes
    
    # If no candidates found (e.g. all nodes are bulk-disabled but source is bulk), 
    # we might return None or fallback to pool (but respecting allow_bulk).
    # Let's filter the original pool by allow_bulk just in case.
    if not candidates:
        candidates = [n for n in pool if (source != 'bulk' or n.get('allow_bulk', True))]
    
    return select_weighted_node(candidates, global_limit)

def bulk_import_task(raw_recipients, subjects, bodies, pool):
    try:
        # Process recipients in background to avoid blocking
        recipients = [r.strip() for r in raw_recipients.split('\n') if r.strip()]
        random.shuffle(recipients) # Shuffle for better distribution
        
        cfg = load_config()
        limit_cfg = cfg.get('limit_config', {})
        tracking_base = cfg.get('web_config', {}).get('public_domain', '').rstrip('/')

        charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        # Chat corpus for anti-spam
        chat_corpus = [
            "晚安，愿你梦想成真。", "嘿，祝你每一天都精彩。", "想去打羽毛球，期待已久了。",
            "下午好，愿你梦想成真。", "打算去公园散步，有点累但很开心。", "下午好，祝你工作顺利。",
            "你好，祝你万事如意。", "嘿，愿你快乐。", "后天打算去露营，觉得很充实。",
            "打算去逛街，觉得生活很美好。", "这时候要去学做饭，觉得很充实。", "约了朋友吃饭，觉得很充实。",
            "下午好，祝你每一天都精彩。", "要去骑行，感觉很放松。", "打算去练瑜伽，觉得很充实。",
            "今天准备去图书馆，希望能有好天气。", "想去看电影，有点累但很开心。", "晚上好，祝你心想事成。",
            "要去博物馆，觉得很充实。", "要去骑行，有点累但很开心。", "最近要去健身房锻炼，期待已久了。",
            "下周准备在家大扫除，希望能一切顺利。", "哈喽，祝你心想事成。", "晚安，祝你工作顺利。",
            "嘿，愿你身体健康。", "明天想去看电影，希望能一切顺利。", "准备去图书馆，感觉很放松。",
            "这时候想去听音乐会，心情特别好。", "哈喽，祝你万事如意。", "中午好，祝你开心。",
            "后天准备在家大扫除，期待已久了。", "准备去图书馆，希望能一切顺利。", "晚安，祝你万事如意。",
            "打算去看画展，有点累但很开心。", "这时候想去钓鱼，感觉充满了能量。", "明天想去看电影，心情特别好。",
            "明天要去咖啡店坐坐，觉得很充实。", "准备在家看书，希望能遇到有趣的人。", "中午好，祝你工作顺利。",
            "周末打算去爬山，希望能一切顺利。", "准备在家看书，期待已久了。", "下午好，愿你快乐。",
            "中午好，愿你身体健康。", "下午好，祝你开心。", "这时候要去骑行，觉得生活很美好。",
            "早安，祝你心想事成。", "想去打羽毛球，希望能有好天气。", "最近准备去野餐，感觉很放松。",
            "明天打算去练瑜伽，希望能遇到有趣的人。", "假期要去博物馆，觉得生活很美好。", "早上好，愿你有个好梦。",
            "嘿，祝你心想事成。", "你好，祝你工作顺利。", "今天想去海边走走，觉得生活很美好。",
            "想去打羽毛球，觉得很充实。", "下午好，希望你天天好心情。", "打算去露营，感觉很放松。",
            "下周准备去游泳，感觉很放松。", "要去博物馆，感觉很放松。", "下周准备在家大扫除，希望能有好天气。",
            "下周打算去爬山，希望能一切顺利。", "下周想去听音乐会，觉得很充实。", "周末要去健身房锻炼，觉得很充实。",
            "想去钓鱼，希望能有好天气。", "晚安，祝你开心。", "周末准备在家看书，心情特别好。",
            "准备去野餐，期待已久了。", "晚上好，愿你快乐。", "想去海边走走，希望能一切顺利。",
            "想去海边走走，觉得很充实。", "打算去爬山，期待已久了。", "准备去跑步，希望能有好天气。",
            "下周打算去练瑜伽，觉得很充实。", "想去打羽毛球，感觉充满了能量。", "周末要去博物馆，心情特别好。",
            "早安，愿你身体健康。", "最近打算去看画展，希望能遇到有趣的人。", "这时候约了朋友吃饭，觉得生活很美好。",
            "晚安，愿你快乐。", "下周想去看电影，希望能一切顺利。", "打算去逛街，希望能一切顺利。",
            "打算去练瑜伽，觉得生活很美好。", "准备在家看书，希望能有好天气。", "打算去练瑜伽，心情特别好。",
            "后天准备在家大扫除，心情特别好。", "下周打算去露营，觉得很充实。", "想去打羽毛球，有点累但很开心。",
            "最近打算去练瑜伽，心情特别好。", "打算去露营，希望能一切顺利。", "准备去野餐，希望能有好天气。",
            "准备去游泳，希望能有好天气。", "你好，愿你有个好梦。", "早安，祝你每一天都精彩。",
            "这时候要去超市买菜，有点累但很开心。", "下周想去听音乐会，期待已久了。", "你好，愿你快乐。",
            "今天准备在家大扫除，有点累但很开心。", "假期打算去逛街，希望能遇到有趣的人。", "下周想去钓鱼，希望能遇到有趣的人。",
            "明天要去超市买菜，希望能遇到有趣的人。", "嘿，愿你有个好梦。", "今天要去健身房锻炼，感觉充满了能量。",
            "中午好，祝你每一天都精彩。", "你好，希望你天天好心情。", "这时候准备去游泳，希望能遇到有趣的人。",
            "要去骑行，觉得生活很美好。", "最近想去听音乐会，希望能有好天气。", "想去听音乐会，觉得生活很美好。",
            "后天打算去练瑜伽，感觉很放松。", "明天打算去公园散步，希望能有好天气。", "准备去图书馆，期待已久了。",
            "要去学做饭，希望能一切顺利。", "周末打算去练瑜伽，期待已久了。", "早上好，祝你开心。",
            "准备去野餐，希望能一切顺利。", "准备去游泳，期待已久了。", "下周要去健身房锻炼，感觉很放松。",
            "准备去图书馆，感觉充满了能量。", "你好，愿你梦想成真。", "最近准备去图书馆，感觉充满了能量。",
            "想去滑雪，觉得很充实。", "假期要去学做饭，希望能遇到有趣的人。", "打算去练瑜伽，希望能一切顺利。",
            "嘿，祝你工作顺利。", "准备在家看书，心情特别好。", "打算去看画展，希望能一切顺利。",
            "后天想去海边走走，感觉充满了能量。", "明天打算去爬山，希望能一切顺利。", "周末要去骑行，感觉很放松。",
            "最近想去看电影，觉得很充实。", "后天要去咖啡店坐坐，希望能一切顺利。", "下周要去健身房锻炼，觉得生活很美好。",
            "嘿，祝你开心。", "早上好，愿你梦想成真。", "后天想去看电影，有点累但很开心。",
            "想去海边走走，有点累但很开心。", "准备去跑步，觉得生活很美好。", "这时候准备去跑步，感觉很放松。",
            "这时候准备去跑步，希望能有好天气。", "后天打算去练瑜伽，觉得生活很美好。", "打算去看画展，期待已久了。",
            "假期约了朋友吃饭，希望能一切顺利。", "周末要去咖啡店坐坐，觉得很充实。", "今天想去滑雪，希望能有好天气。",
            "下周想去海边走走，感觉充满了能量。", "打算去公园散步，希望能遇到有趣的人。", "准备在家大扫除，感觉很放松。",
            "准备在家大扫除，心情特别好。", "今天约了朋友吃饭，有点累但很开心。", "后天要去学做饭，希望能一切顺利。",
            "下周打算去公园散步，期待已久了。", "今天打算去公园散步，觉得很充实。", "下午好，祝你心想事成。",
            "哈喽，愿你梦想成真。", "你好，愿你身体健康。", "这时候约了朋友吃饭，希望能一切顺利。",
            "准备在家大扫除，觉得很充实。", "想去看电影，希望能一切顺利。", "早安，愿你梦想成真。",
            "准备去游泳，感觉充满了能量。", "要去学做饭，有点累但很开心。", "想去听音乐会，感觉很放松。",
            "打算去露营，希望能有好天气。", "准备去游泳，有点累但很开心。", "准备去野餐，觉得很充实。",
            "这时候打算去逛街，有点累但很开心。", "今天准备去跑步，觉得生活很美好。", "早安，愿你有个好梦。",
            "想去看电影，感觉很放松。", "要去超市买菜，觉得很充实。", "准备去野餐，希望能遇到有趣的人。",
            "打算去逛街，感觉很放松。", "这时候想去看电影，期待已久了。", "晚安，愿你身体健康。",
            "后天想去钓鱼，期待已久了。", "要去学做饭，觉得很充实。", "假期想去钓鱼，感觉很放松。",
            "最近想去滑雪，希望能有好天气。", "想去打羽毛球，感觉很放松。", "想去看电影，希望能遇到有趣的人。",
            "打算去爬山，感觉充满了能量。", "下周打算去看画展，感觉很放松。", "要去咖啡店坐坐，觉得生活很美好。",
            "今天想去钓鱼，觉得生活很美好。", "今天想去打羽毛球，感觉充满了能量。", "后天准备去野餐，希望能遇到有趣的人。",
            "早安，希望你天天好心情。", "这时候要去骑行，希望能遇到有趣的人。", "中午好，愿你有个好梦。",
            "周末想去看电影，希望能遇到有趣的人。", "哈喽，希望你天天好心情。", "这时候约了朋友吃饭，期待已久了。",
            "打算去看画展，觉得很充实。", "最近准备去跑步，希望能一切顺利。", "打算去公园散步，期待已久了。",
            "约了朋友吃饭，感觉充满了能量。", "你好，祝你开心。", "后天打算去逛街，觉得生活很美好。",
            "哈喽，愿你身体健康。", "周末要去健身房锻炼，心情特别好。", "下午好，愿你身体健康。",
            "中午好，愿你快乐。", "今天要去骑行，期待已久了。", "最近准备在家看书，感觉很放松。",
            "今天想去滑雪，期待已久了。", "假期打算去露营，期待已久了。", "想去听音乐会，希望能有好天气。",
            "早安，愿你快乐。", "下午好，愿你有个好梦。", "假期想去海边走走，期待已久了。",
            "后天打算去看画展，感觉很放松。", "哈喽，祝你每一天都精彩。", "下周打算去逛街，希望能有好天气。",
            "想去钓鱼，感觉充满了能量。", "周末准备在家大扫除，感觉很放松。", "中午好，希望你天天好心情。",
            "明天要去骑行，希望能有好天气。", "这时候想去海边走走，感觉很放松。", "准备在家大扫除，希望能一切顺利。",
            "后天打算去练瑜伽，期待已久了。", "明天想去听音乐会，感觉充满了能量。", "晚安，希望你天天好心情。",
            "哈喽，祝你工作顺利。", "明天要去健身房锻炼，有点累但很开心。", "打算去练瑜伽，希望能遇到有趣的人。",
            "明天要去咖啡店坐坐，心情特别好。", "后天想去看电影，觉得很充实。", "这时候要去超市买菜，觉得生活很美好。",
            "这时候约了朋友吃饭，希望能遇到有趣的人。", "你好，祝你每一天都精彩。", "想去听音乐会，心情特别好。",
            "今天要去咖啡店坐坐，希望能有好天气。", "早上好，希望你天天好心情。", "今天打算去露营，心情特别好。",
            "后天打算去公园散步，感觉充满了能量。", "打算去看画展，希望能有好天气。", "早安，祝你万事如意。",
            "想去打羽毛球，觉得生活很美好。", "晚上好，希望你天天好心情。", "早上好，祝你每一天都精彩。",
            "这时候打算去露营，觉得很充实。", "周末要去学做饭，心情特别好。", "这时候要去骑行，希望能有好天气。",
            "假期准备去图书馆，觉得很充实。", "打算去爬山，觉得生活很美好。", "后天准备去图书馆，希望能有好天气。",
            "嘿，愿你梦想成真。", "约了朋友吃饭，希望能遇到有趣的人。", "假期准备去游泳，希望能一切顺利。",
            "这时候准备在家大扫除，希望能有好天气。", "想去滑雪，希望能有好天气。", "下周打算去公园散步，希望能遇到有趣的人。",
            "准备在家看书，感觉很放松。", "最近想去钓鱼，有点累但很开心。", "想去看电影，期待已久了。",
            "想去钓鱼，希望能一切顺利。", "今天准备去野餐，有点累但很开心。", "要去博物馆，有点累但很开心。",
            "晚上好，愿你有个好梦。", "晚上好，祝你万事如意。", "早上好，愿你身体健康。",
            "后天想去滑雪，感觉很放松。", "最近想去听音乐会，感觉充满了能量。", "准备在家大扫除，感觉充满了能量。",
            "准备去野餐，感觉很放松。", "打算去练瑜伽，期待已久了。", "准备在家看书，有点累但很开心。",
            "打算去练瑜伽，感觉很放松。", "下周打算去露营，有点累但很开心。", "中午好，祝你心想事成。",
            "今天准备在家大扫除，觉得很充实。", "要去学做饭，觉得生活很美好。", "这时候要去健身房锻炼，感觉充满了能量。",
            "今天打算去看画展，觉得很充实。", "要去咖啡店坐坐，感觉充满了能量。", "今天想去海边走走，感觉充满了能量。",
            "最近准备去跑步，希望能有好天气。", "明天要去咖啡店坐坐，感觉充满了能量。", "晚安，愿你有个好梦。",
            "周末要去学做饭，觉得很充实。", "晚安，祝你心想事成。", "要去博物馆，感觉充满了能量。",
            "要去健身房锻炼，希望能一切顺利。", "晚上好，愿你身体健康。", "明天准备去野餐，感觉很放松。",
            "周末想去听音乐会，心情特别好。", "打算去露营，觉得生活很美好。", "周末要去超市买菜，希望能一切顺利。",
            "明天准备去跑步，觉得生活很美好。", "后天要去超市买菜，觉得很充实。", "要去健身房锻炼，觉得很充实。",
            "哈喽，祝你开心。", "准备去野餐，有点累但很开心。", "打算去爬山，希望能遇到有趣的人。",
            "想去滑雪，有点累但很开心。", "下周想去听音乐会，心情特别好。", "要去骑行，希望能遇到有趣的人。",
            "今天准备在家看书，感觉很放松。", "下周准备在家大扫除，感觉很放松。", "要去健身房锻炼，感觉很放松。",
            "假期想去海边走走，觉得生活很美好。", "下周准备去野餐，觉得生活很美好。", "打算去看画展，心情特别好。",
            "准备在家看书，感觉充满了能量。", "周末想去看电影，心情特别好。", "假期约了朋友吃饭，觉得很充实。",
            "下周想去打羽毛球，心情特别好。", "假期准备去跑步，希望能有好天气。", "今天想去打羽毛球，期待已久了。",
            "后天想去滑雪，希望能有好天气。", "准备去跑步，期待已久了。", "今天准备去游泳，希望能一切顺利。",
            "后天要去博物馆，希望能遇到有趣的人。", "打算去逛街，希望能有好天气。", "明天准备去游泳，感觉充满了能量。",
            "准备在家看书，觉得很充实。", "今天准备在家看书，感觉充满了能量。", "周末想去滑雪，希望能遇到有趣的人。",
            "明天想去海边走走，期待已久了。", "早安，祝你开心。", "要去超市买菜，有点累但很开心。",
            "准备在家看书，希望能一切顺利。", "要去咖啡店坐坐，有点累但很开心。", "下周打算去逛街，感觉充满了能量。",
            "准备去游泳，希望能遇到有趣的人。", "下周准备在家大扫除，期待已久了。", "要去学做饭，希望能有好天气。",
            "要去咖啡店坐坐，感觉很放松。", "假期打算去公园散步，觉得生活很美好。", "想去打羽毛球，希望能一切顺利。",
            "今天打算去练瑜伽，感觉很放松。", "明天准备在家看书，感觉很放松。", "下周要去健身房锻炼，感觉充满了能量。",
            "要去博物馆，希望能遇到有趣的人。", "周末要去学做饭，期待已久了。", "这时候想去打羽毛球，感觉很放松。",
            "假期要去学做饭，期待已久了。", "要去咖啡店坐坐，希望能一切顺利。", "后天要去健身房锻炼，觉得生活很美好。",
            "这时候准备在家大扫除，觉得生活很美好。", "后天准备在家大扫除，感觉充满了能量。", "今天要去博物馆，觉得很充实。",
            "哈喽，愿你有个好梦。", "想去看电影，感觉充满了能量。", "准备去图书馆，希望能遇到有趣的人。",
            "这时候准备在家看书，希望能遇到有趣的人。", "想去钓鱼，觉得生活很美好。", "早安，祝你工作顺利。",
            "要去咖啡店坐坐，期待已久了。", "想去滑雪，感觉充满了能量。", "今天打算去露营，感觉充满了能量。",
            "明天想去滑雪，有点累但很开心。", "想去海边走走，感觉很放松。", "晚上好，祝你开心。",
            "周末要去博物馆，有点累但很开心。", "最近打算去练瑜伽，期待已久了。", "后天要去超市买菜，希望能遇到有趣的人。",
            "今天想去滑雪，觉得生活很美好。", "打算去爬山，希望能有好天气。", "周末准备去跑步，期待已久了。",
            "要去咖啡店坐坐，心情特别好。", "想去滑雪，期待已久了。", "打算去爬山，感觉很放松。",
            "周末打算去露营，感觉很放松。", "最近想去看电影，感觉很放松。", "早上好，祝你工作顺利。",
            "这时候准备去图书馆，有点累但很开心。", "明天准备去跑步，希望能有好天气。", "周末想去打羽毛球，希望能有好天气。",
            "今天想去打羽毛球，觉得生活很美好。", "周末准备去跑步，希望能遇到有趣的人。", "最近要去健身房锻炼，感觉很放松。",
            "今天要去健身房锻炼，感觉很放松。", "后天想去听音乐会，感觉很放松。", "这时候打算去看画展，有点累但很开心。",
            "下周想去听音乐会，感觉很放松。", "要去超市买菜，希望能有好天气。", "想去听音乐会，觉得很充实。",
            "要去健身房锻炼，感觉充满了能量。", "准备去游泳，感觉很放松。", "嘿，祝你万事如意。",
            "假期打算去看画展，期待已久了。", "下周准备去游泳，希望能一切顺利。", "要去超市买菜，心情特别好。",
            "准备去野餐，感觉充满了能量。", "今天打算去露营，希望能遇到有趣的人。", "后天约了朋友吃饭，觉得生活很美好。",
            "要去骑行，希望能一切顺利。", "要去骑行，心情特别好。", "最近想去打羽毛球，心情特别好。",
            "假期打算去逛街，觉得很充实。", "准备在家大扫除，希望能遇到有趣的人。", "周末准备去图书馆，希望能一切顺利。",
            "下周想去钓鱼，感觉很放松。", "周末准备去野餐，感觉很放松。", "假期要去健身房锻炼，感觉充满了能量。",
            "下周要去超市买菜，心情特别好。", "明天想去打羽毛球，心情特别好。", "最近打算去逛街，感觉充满了能量。",
            "中午好，祝你万事如意。", "周末打算去看画展，希望能一切顺利。", "假期打算去爬山，心情特别好。",
            "明天打算去爬山，有点累但很开心。", "打算去看画展，感觉很放松。", "打算去爬山，希望能一切顺利。",
            "后天要去健身房锻炼，觉得很充实。", "打算去爬山，觉得很充实。", "今天打算去练瑜伽，心情特别好。",
            "下周打算去露营，感觉很放松。", "假期准备去游泳，有点累但很开心。", "下午好，祝你万事如意。",
            "约了朋友吃饭，有点累但很开心。", "假期要去咖啡店坐坐，觉得生活很美好。", "下周打算去练瑜伽，觉得生活很美好。",
            "嘿，希望你天天好心情。", "今天要去超市买菜，有点累但很开心。", "周末要去超市买菜，觉得生活很美好。",
            "准备去野餐，心情特别好。", "中午好，愿你梦想成真。", "周末准备在家大扫除，觉得生活很美好。",
            "这时候想去看电影，希望能遇到有趣的人。", "约了朋友吃饭，希望能一切顺利。", "明天想去滑雪，心情特别好。",
            "明天想去打羽毛球，有点累但很开心。", "假期要去健身房锻炼，希望能有好天气。", "后天准备去野餐，希望能一切顺利。",
            "打算去逛街，心情特别好。", "明天打算去露营，心情特别好。", "周末打算去逛街，希望能一切顺利。",
            "今天想去钓鱼，感觉充满了能量。", "想去海边走走，希望能有好天气。", "准备去跑步，觉得很充实。",
            "打算去公园散步，觉得生活很美好。", "下周要去咖啡店坐坐，有点累但很开心。", "晚上好，祝你工作顺利。",
            "下周要去健身房锻炼，希望能遇到有趣的人。", "打算去逛街，觉得很充实。", "后天约了朋友吃饭，心情特别好。",
            "这时候想去滑雪，期待已久了。", "假期想去滑雪，感觉充满了能量。", "要去博物馆，希望能一切顺利。",
            "这时候准备去野餐，感觉很放松。", "这时候想去滑雪，感觉充满了能量。", "最近要去健身房锻炼，觉得很充实。",
            "今天想去听音乐会，觉得很充实。", "最近想去看电影，希望能一切顺利。", "明天想去滑雪，希望能有好天气。",
            "下周要去超市买菜，希望能有好天气。", "打算去公园散步，心情特别好。", "打算去逛街，希望能遇到有趣的人。",
            "哈喽，愿你快乐。", "想去看电影，觉得很充实。", "明天要去博物馆，心情特别好。",
            "这时候打算去公园散步，希望能遇到有趣的人。", "今天准备在家看书，心情特别好。", "假期准备在家大扫除，期待已久了。",
            "后天打算去公园散步，感觉很放松。", "下周打算去露营，感觉充满了能量。", "晚安，祝你每一天都精彩。",
            "要去健身房锻炼，期待已久了。", "明天准备去图书馆，感觉充满了能量。", "准备在家大扫除，希望能有好天气。",
            "准备去跑步，感觉充满了能量。", "假期准备在家大扫除，感觉很放松。", "假期想去看电影，有点累但很开心。",
            "这时候打算去看画展，心情特别好。", "下周想去海边走走，心情特别好。", "周末打算去爬山，心情特别好。",
            "早上好，祝你心想事成。", "下周想去看电影，觉得很充实。", "最近打算去看画展，觉得很充实。",
            "周末要去学做饭，希望能遇到有趣的人。", "后天准备去跑步，感觉很放松。", "后天准备去野餐，觉得生活很美好。",
            "想去钓鱼，有点累但很开心。", "周末想去钓鱼，希望能遇到有趣的人。", "最近准备去跑步，觉得生活很美好。",
            "晚上好，愿你梦想成真。", "后天要去博物馆，感觉很放松。", "周末打算去练瑜伽，希望能遇到有趣的人。",
            "明天打算去爬山，希望能有好天气。", "后天想去打羽毛球，期待已久了。", "这时候打算去练瑜伽，觉得生活很美好。",
            "这时候想去听音乐会，期待已久了。", "打算去练瑜伽，希望能有好天气。", "要去博物馆，期待已久了。",
            "想去滑雪，感觉很放松。", "假期想去打羽毛球，觉得很充实。", "想去看电影，希望能有好天气。",
            "晚上好，祝你每一天都精彩。", "后天打算去露营，希望能有好天气。", "假期想去滑雪，希望能遇到有趣的人。",
            "下周打算去露营，期待已久了。", "要去骑行，期待已久了。", "要去健身房锻炼，觉得生活很美好。",
            "假期打算去看画展，心情特别好。", "周末约了朋友吃饭，有点累但很开心。", "今天打算去练瑜伽，有点累但很开心。",
            "要去博物馆，希望能有好天气。", "最近打算去逛街，感觉很放松。",
        ]
        
        tasks = []
        count = 0
        
        for rcpt in recipients:
            try:
                # Randomize
                rand_sub = ''.join(random.choices(charset, k=6))
                # Select 5-10 random sentences to simulate normal chat
                rand_chat = ' '.join(random.choices(chat_corpus, k=random.randint(5, 10)))
                
                # Randomly select subject and body
                current_subject = random.choice(subjects) if subjects else "(No Subject)"
                current_body = random.choice(bodies) if bodies else ""

                tracking_id = str(uuid.uuid4())
                tracking_html = ""
                if tracking_base:
                    tracking_url = f"{tracking_base}/track/{tracking_id}"
                    tracking_html = f"<img src='{tracking_url}' width='1' height='1' style='display:none;'>"

                # footer removed
                final_subject = f"{current_subject} {rand_sub}"
                # Insert hidden chat content
                final_body = f"{current_body}<div style='display:none;opacity:0;font-size:0;line-height:0;max-height:0;overflow:hidden;'>{rand_chat}</div>{tracking_html}"

                msg = MIMEText(final_body, 'html', 'utf-8')
                msg['Subject'] = final_subject
                msg['From'] = '' # Placeholder, worker will fill
                msg['To'] = rcpt
                msg['Date'] = formatdate(localtime=True)
                msg['Message-ID'] = make_msgid()

                node = select_node_for_recipient(pool, rcpt, limit_cfg, source='bulk')
                node_name = node.get('name', 'Unknown') if node else 'No_Node_Available'
                
                tasks.append(('', json.dumps([rcpt]), msg.as_bytes(), node_name, 'pending', 'bulk', tracking_id, datetime.utcnow() + timedelta(hours=8), datetime.utcnow() + timedelta(hours=8)))
                count += 1
                
                if len(tasks) >= 500:
                    with get_db() as conn:
                        conn.executemany(
                            "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, tracking_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            tasks
                        )
                    tasks = []
            except Exception as e:
                logger.error(f"Error preparing email for {rcpt}: {e}")
                continue

        if tasks:
            with get_db() as conn:
                conn.executemany(
                    "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, tracking_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
        raw_subject = data.get('subject', '(No Subject)')
        raw_recipients = data.get('recipients', '')
        
        if not raw_recipients.strip(): return jsonify({"error": "No recipients"}), 400
        
        # Parse multiple subjects (one per line)
        subjects = [s.strip() for s in raw_subject.split('\n') if s.strip()]
        if not subjects: subjects = ['(No Subject)']

        # Parse multiple bodies
        # 1. Try 'bodies' list (new format)
        bodies = data.get('bodies', [])
        # 2. Fallback to 'body' string (old format, separated by |||)
        if not bodies and 'body' in data:
             raw_body = data.get('body', '')
             bodies = [b.strip() for b in raw_body.split('|||') if b.strip()]
        
        # Ensure bodies is a list of strings
        if isinstance(bodies, str): bodies = [bodies]
        bodies = [str(b).strip() for b in bodies if str(b).strip()]
        
        if not bodies: bodies = ['']

        cfg = load_config()
        pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
        if not pool: return jsonify({"error": "No enabled nodes available"}), 500

        # Start background task with raw string
        threading.Thread(target=bulk_import_task, args=(raw_recipients, subjects, bodies, pool)).start()
                
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
                conn.execute("INSERT INTO contacts (email, created_at) VALUES (?, datetime('now', '+08:00'))", (e,))
                added += 1
            except sqlite3.IntegrityError:
                pass
    return jsonify({"added": added})

@app.route('/api/contacts/list')
@login_required
def api_contacts_list():
    limit = request.args.get('limit', -1, type=int)
    offset = request.args.get('offset', 0, type=int)
    query = "SELECT email FROM contacts ORDER BY id DESC"
    params = ()
    if limit > 0:
        query += " LIMIT ? OFFSET ?"
        params = (limit, offset)
    with get_db() as conn:
        rows = conn.execute(query, params).fetchall()
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

@app.route('/api/draft', methods=['GET', 'POST'])
@login_required
def api_draft():
    if request.method == 'POST':
        try:
            content = json.dumps(request.json)
            with get_db() as conn:
                conn.execute("INSERT OR REPLACE INTO drafts (id, content, updated_at) VALUES (1, ?, datetime('now', '+08:00'))", (content,))
            return jsonify({"status": "ok"})
        except Exception as e:
            return jsonify({"error": str(e)}), 500
    else:
        with get_db() as conn:
            row = conn.execute("SELECT content FROM drafts WHERE id=1").fetchone()
        if row:
            return jsonify(json.loads(row['content']))
        return jsonify({})

@app.route('/api/queue/clear', methods=['POST'])
@login_required
def api_queue_clear():
    with get_db() as conn:
        conn.execute("DELETE FROM queue WHERE status IN ('sent', 'failed', 'processing')")
    return jsonify({"status": "ok"})

def rebalance_queue_internal():
    cfg = load_config()
    pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
    if not pool: return 0
    
    count = 0
    limit_cfg = cfg.get('limit_config', {})
    
    with get_db() as conn:
        cursor = conn.execute("SELECT id, rcpt_tos, source FROM queue WHERE status='pending'")
        rows = cursor.fetchall()
        if not rows: return 0
        
        updates = []
        for r in rows:
            try:
                rcpts = json.loads(r['rcpt_tos'])
                rcpt = rcpts[0] if rcpts else ''
            except: rcpt = ''
            
            node = select_node_for_recipient(pool, rcpt, limit_cfg, source=r['source'])
            if node:
                updates.append((node['name'], r['id']))
        
        if updates:
            conn.executemany("UPDATE queue SET assigned_node=? WHERE id=?", updates)
            count = len(updates)
    return count

@app.route('/api/queue/rebalance', methods=['POST'])
@login_required
def api_queue_rebalance():
    try:
        count = rebalance_queue_internal()
        return jsonify({"status": "ok", "count": count})
    except Exception as e:
        logger.error(f"Rebalance error: {e}")
        return jsonify({"error": str(e)}), 500

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

TRACKING_GIF = base64.b64decode(b'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')

@app.route('/track/<tid>')
def track_email(tid):
    try:
        with get_db() as conn:
            conn.execute("UPDATE queue SET opened_at=datetime('now', '+08:00'), open_count=open_count+1 WHERE tracking_id=?", (tid,))
    except Exception as e:
        logger.error(f"Tracking error: {e}")
    return TRACKING_GIF, 200, {'Content-Type': 'image/gif', 'Cache-Control': 'no-cache, no-store, must-revalidate'}

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
        :root { --sidebar-width: 240px; --primary-color: #4361ee; }
        
        [data-bs-theme="light"] {
            --bg-color: #f8f9fa;
            --sidebar-bg: #ffffff;
            --sidebar-border: #eeeeee;
            --card-bg: #ffffff;
            --hover-bg: #f8f9fa;
            --active-bg: #eef2ff;
            --text-main: #212529;
            --text-muted: #6c757d;
            --input-bg: #ffffff;
            --input-border: #dee2e6;
            --code-bg: #f8f9fa;
        }
        
        [data-bs-theme="dark"] {
            --bg-color: #0d1117;
            --sidebar-bg: #161b22;
            --sidebar-border: #30363d;
            --card-bg: #212529;
            --hover-bg: #2c3036;
            --active-bg: #1f2937;
            --text-main: #e6edf3;
            --text-muted: #8b949e;
            --input-bg: #0d1117;
            --input-border: #30363d;
            --code-bg: #161b22;
        }

        body { background-color: var(--bg-color); color: var(--text-main); font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; overflow-x: hidden; }
        
        /* Sidebar */
        .sidebar { width: var(--sidebar-width); height: 100vh; position: fixed; left: 0; top: 0; background: var(--sidebar-bg); border-right: 1px solid var(--sidebar-border); z-index: 1000; display: flex; flex-direction: column; }
        .sidebar-header { padding: 1.5rem; display: flex; align-items: center; gap: 0.75rem; border-bottom: 1px solid var(--sidebar-border); }
        .logo-icon { width: 32px; height: 32px; background: var(--primary-color); color: #fff; border-radius: 8px; display: flex; align-items: center; justify-content: center; font-size: 1.2rem; }
        .nav-menu { padding: 1.5rem 1rem; flex: 1; }
        .nav-item { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 1rem; color: var(--text-muted); text-decoration: none; border-radius: 8px; margin-bottom: 0.5rem; transition: all 0.2s; cursor: pointer; }
        .nav-item:hover { background: var(--hover-bg); color: var(--primary-color); }
        .nav-item.active { background: var(--active-bg); color: var(--primary-color); font-weight: 600; }
        .nav-item i { font-size: 1.2rem; }
        
        /* Main Content */
        .main-content { margin-left: var(--sidebar-width); padding: 2rem; min-height: 100vh; }
        
        /* Cards */
        .card { border: none; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.03); background: var(--card-bg); transition: transform 0.2s; }
        .stat-card:hover { transform: translateY(-2px); }
        .card-header { background: transparent; border-bottom: 1px solid var(--sidebar-border); padding: 1.25rem; font-weight: 600; color: var(--text-main); }
        
        /* Status Colors */
        .text-pending { color: #f59e0b; } .bg-pending-subtle { background: #fffbeb; }
        .text-processing { color: #3b82f6; } .bg-processing-subtle { background: #eff6ff; }
        .text-sent { color: #10b981; } .bg-sent-subtle { background: #ecfdf5; }
        .text-failed { color: #ef4444; } .bg-failed-subtle { background: #fef2f2; }
        
        /* Drag & Drop */
        [draggable="true"] { cursor: grab; }
        [draggable="true"]:active { cursor: grabbing; }
        .dragging { opacity: 0.5; }
        .drag-over { position: relative; }
        .drag-over::before { content: ''; position: absolute; top: 0; left: 0; right: 0; bottom: 0; border: 2px dashed var(--primary-color); border-radius: 12px; background: rgba(67, 97, 238, 0.1); z-index: 10; pointer-events: none; }

        [data-bs-theme="dark"] .bg-pending-subtle { background: #451a03; }
        [data-bs-theme="dark"] .bg-processing-subtle { background: #172554; }
        [data-bs-theme="dark"] .bg-sent-subtle { background: #064e3b; }
        [data-bs-theme="dark"] .bg-failed-subtle { background: #450a0a; }
        
        /* Utils */
        .btn-primary { background: var(--primary-color); border-color: var(--primary-color); }
        .table-custom th { font-weight: 600; color: var(--text-muted); background: var(--hover-bg); border-bottom: 2px solid var(--sidebar-border); }
        .table-custom td { vertical-align: middle; color: var(--text-main); border-bottom: 1px solid var(--sidebar-border); }
        
        /* Dark Mode Overrides */
        .bg-theme-light { background-color: var(--code-bg) !important; }
        .text-theme-main { color: var(--text-main) !important; }
        .border-theme { border-color: var(--sidebar-border) !important; }
        
        [data-bs-theme="dark"] .form-control, [data-bs-theme="dark"] .form-select {
            background-color: var(--input-bg);
            border-color: var(--input-border);
            color: var(--text-main);
        }
        [data-bs-theme="dark"] .form-control:focus {
            background-color: var(--input-bg);
            color: var(--text-main);
            border-color: var(--primary-color);
        }
        [data-bs-theme="dark"] .btn-light {
            background-color: var(--hover-bg);
            border-color: var(--sidebar-border);
            color: var(--text-main);
        }
        [data-bs-theme="dark"] .btn-light:hover {
            background-color: var(--active-bg);
        }
        [data-bs-theme="dark"] .btn-white {
            background-color: var(--card-bg);
            border-color: var(--sidebar-border);
            color: var(--text-main);
        }
        [data-bs-theme="dark"] .bg-light { background-color: var(--hover-bg) !important; }
        [data-bs-theme="dark"] .bg-white { background-color: var(--card-bg) !important; }
        
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
        <div class="d-md-none p-3 border-bottom d-flex justify-content-between align-items-center sticky-top" style="background: var(--sidebar-bg)">
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
                    <div class="fw-bold text-theme-main">SMTP Relay</div>
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
                <div class="btn-group w-100 mb-2" role="group">
                    <button type="button" class="btn btn-sm" :class="theme=='light'?'btn-primary':'btn-outline-secondary'" @click="setTheme('light')"><i class="bi bi-sun-fill"></i></button>
                    <button type="button" class="btn btn-sm" :class="theme=='auto'?'btn-primary':'btn-outline-secondary'" @click="setTheme('auto')"><i class="bi bi-circle-half"></i></button>
                    <button type="button" class="btn btn-sm" :class="theme=='dark'?'btn-primary':'btn-outline-secondary'" @click="setTheme('dark')"><i class="bi bi-moon-stars-fill"></i></button>
                </div>
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
                                    <div class="small text-muted">
                                        进度: [[ progressPercent ]]% ([[ qStats.total.sent || 0 ]] / [[ totalMails ]])
                                        <span class="ms-2 badge bg-theme-light text-theme-main border border-theme">[[ qStats.total.speed_ph || 0 ]] 封/小时</span>
                                    </div>
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
                    <div class="col-md-2 col-6">
                        <div class="card stat-card h-100">
                            <div class="card-body">
                                <div class="d-flex justify-content-between align-items-start mb-2">
                                    <div class="p-2 rounded bg-info-subtle text-info"><i class="bi bi-eye-fill"></i></div>
                                    <span class="badge rounded-pill border text-muted">Opens</span>
                                </div>
                                <h2 class="fw-bold mb-0">[[ qStats.total.opened || 0 ]]</h2>
                                <div class="small text-muted">已打开</div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-2 col-6" v-for="(label, key) in {'pending': '待发送', 'processing': '发送中', 'sent': '已成功', 'failed': '已失败'}" :key="key">
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
                    <div class="col-md-2 col-6">
                        <div class="card stat-card h-100">
                            <div class="card-body">
                                <div class="d-flex justify-content-between align-items-start mb-2">
                                    <div class="p-2 rounded bg-primary-subtle text-primary"><i class="bi bi-cursor-fill"></i></div>
                                    <span class="badge rounded-pill border text-muted">Rate</span>
                                </div>
                                <h2 class="fw-bold mb-0">[[ clickRate ]]</h2>
                                <div class="small text-muted">点击率</div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Node Status -->
                <div class="card mb-4">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <span>节点健康状态</span>
                        <button class="btn btn-sm btn-outline-primary" @click="rebalanceQueue" :disabled="rebalancing">
                            <i class="bi" :class="rebalancing?'bi-hourglass-split':'bi-shuffle'"></i> 
                            [[ rebalancing ? '分配中...' : '重分配待发任务' ]]
                        </button>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-custom table-hover mb-0">
                            <thead><tr><th>节点名称</th><th class="text-center">堆积</th><th class="text-center">成功</th><th class="text-center">失败</th><th>预计时长</th><th>预计结束</th></tr></thead>
                            <tbody>
                                <template v-for="(s, name) in qStats.nodes" :key="name">
                                <tr v-if="(s.pending || 0) > 0">
                                    <td class="fw-medium">[[ name ]]</td>
                                    <td class="text-center"><span class="badge bg-warning text-dark">[[ s.pending || 0 ]]</span></td>
                                    <td class="text-center text-success">[[ s.sent || 0 ]]</td>
                                    <td class="text-center text-danger">[[ s.failed || 0 ]]</td>
                                    <td class="text-muted small">[[ getEstDuration(name, s.pending) ]]</td>
                                    <td class="text-muted small">[[ getEstFinishTime(name, s.pending) ]]</td>
                                </tr>
                                </template>
                                <tr v-if="!hasPendingNodes"><td colspan="6" class="text-center text-muted py-4">暂无待发任务节点</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Recent Logs -->
                <div class="card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <span>最近投递记录 <span class="text-muted small fw-normal ms-2" v-if="totalMails > 100">(仅显示最新 100 条 / 共 [[ totalMails ]] 条)</span></span>
                        <button class="btn btn-sm btn-outline-danger" @click="clearQueue">清理历史</button>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-custom table-hover mb-0">
                            <thead><tr><th class="ps-4">ID</th><th>详情</th><th>节点</th><th>状态</th><th>时间</th></tr></thead>
                            <tbody>
                                <tr v-for="m in qList" :key="m.id">
                                    <td class="ps-4 text-muted">#[[ m.id ]]</td>
                                    <td>
                                        <div class="fw-bold text-theme-main">[[ m.mail_from ]]</div>
                                        <div class="text-muted small text-truncate" style="max-width: 250px;">[[ m.rcpt_tos ]]</div>
                                    </td>
                                    <td><span class="badge bg-theme-light text-theme-main border border-theme">[[ m.assigned_node ]]</span></td>
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
                                    <textarea v-model="bulk.subject" class="form-control form-control-lg" rows="3" placeholder="输入主题 (每行一个，系统随机选择，并自动追加随机码)"></textarea>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label fw-bold">邮件正文 (HTML)</label>
                                    <div v-for="(item, index) in bulk.bodyList" :key="index" class="mb-3 p-2 border rounded position-relative">
                                        <div class="d-flex justify-content-between align-items-center mb-2">
                                            <span class="badge bg-secondary">模板 [[ index + 1 ]]</span>
                                            <button v-if="bulk.bodyList.length > 1" @click="removeBody(index)" class="btn btn-sm btn-outline-danger py-0 px-2" title="删除"><i class="bi bi-trash"></i></button>
                                        </div>
                                        <div class="row g-2">
                                            <div class="col-md-6">
                                                <textarea v-model="bulk.bodyList[index]" class="form-control font-monospace bg-theme-light" rows="10" placeholder="输入HTML内容..."></textarea>
                                            </div>
                                            <div class="col-md-6">
                                                <div class="border rounded h-100 overflow-hidden" style="background-color: #fff; min-height: 200px; max-height: 250px;">
                                                    <preview-frame :content="bulk.bodyList[index]"></preview-frame>
                                                </div>
                                            </div>
                                        </div>
                                    </div>
                                    <button class="btn btn-sm btn-outline-primary" @click="addBody"><i class="bi bi-plus-lg"></i> 添加正文模板</button>
                                    <div class="form-text mt-2">系统会从上述模板中随机选择一个发送。会自动在末尾插入隐形随机码和退订链接。</div>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="col-lg-4">
                        <div class="card h-100">
                            <div class="card-header">收件人列表</div>
                            <div class="card-body d-flex flex-column">
                                <div class="d-flex gap-2 mb-2">
                                    <button class="btn btn-outline-success flex-grow-1" @click="saveContacts"><i class="bi bi-cloud-upload"></i> 保存当前</button>
                                    <button class="btn btn-outline-danger" @click="clearContacts"><i class="bi bi-trash"></i> 清空</button>
                                </div>
                                
                                <div v-if="contactCount > 50000" class="mb-2">
                                    <div class="d-flex flex-wrap gap-2" style="max-height: 150px; overflow-y: auto;">
                                        <button v-for="i in Math.ceil(contactCount / 50000)" :key="i" 
                                                class="btn btn-outline-primary btn-sm flex-grow-1" 
                                                @click="loadContacts(i-1)">
                                            分组[[ i ]] ([[ getGroupRange(i) ]])
                                        </button>
                                    </div>
                                </div>
                                <button v-else class="btn btn-outline-primary w-100 mb-2" @click="loadContacts(0)">
                                    <i class="bi bi-cloud-download"></i> 加载全部 ([[ contactCount ]])
                                </button>

                                <textarea v-model="bulk.recipients" class="form-control flex-grow-1 mb-3" placeholder="每行一个邮箱地址..." style="min-height: 200px;"></textarea>
                                <div class="d-flex justify-content-between align-items-center mb-3">
                                    <span class="fw-bold">当前输入: [[ recipientCount ]] 人</span>
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
                            <div class="card-header">数据与日志 (Storage)</div>
                            <div class="card-body">
                                <div class="mb-3">
                                    <label class="form-label">历史记录保留天数</label>
                                    <div class="input-group">
                                        <input type="number" v-model.number="config.log_config.retention_days" class="form-control" placeholder="7">
                                        <span class="input-group-text">天</span>
                                    </div>
                                    <div class="form-text">超过此时间的成功/失败记录将被自动删除 (0=不删除)</div>
                                </div>
                                <div class="row g-3">
                                    <div class="col-6">
                                        <label class="form-label">日志文件大小</label>
                                        <div class="input-group">
                                            <input type="number" v-model.number="config.log_config.max_mb" class="form-control" placeholder="50">
                                            <span class="input-group-text">MB</span>
                                        </div>
                                    </div>
                                    <div class="col-6">
                                        <label class="form-label">日志备份数</label>
                                        <input type="number" v-model.number="config.log_config.backups" class="form-control" placeholder="3">
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
                                <div class="mb-3">
                                    <label class="form-label">追踪域名 (Tracking URL)</label>
                                    <input type="text" v-model="config.web_config.public_domain" class="form-control" placeholder="http://YOUR_IP:8080">
                                    <div class="form-text">用于生成邮件打开追踪链接，请填写公网可访问地址。</div>
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
                            <div class="card-body bg-theme-light">
                                <div v-if="config.downstream_pool.length === 0" class="text-center py-5 text-muted">
                                    暂无节点，请点击右上角添加
                                </div>
                                <div class="row g-3">
                                    <div v-for="(n, i) in config.downstream_pool" :key="i" class="col-md-6 col-xl-4"
                                         draggable="true"
                                         @dragstart="onDragStart($event, i)"
                                         @dragover.prevent="onDragOver($event, i)"
                                         @drop="onDrop($event, i)"
                                         @dragend="onDragEnd"
                                         :class="{'dragging': draggingIndex === i, 'drag-over': dragOverIndex === i && draggingIndex !== i}">
                                        <div class="card h-100 shadow-sm" :style="draggingIndex === i ? 'opacity: 0.5' : ''">
                                            <div class="card-header d-flex justify-content-between align-items-center py-2 bg-transparent">
                                                <div class="d-flex align-items-center gap-2 flex-grow-1" style="cursor:pointer; min-width: 0;" @click="n.expanded = !n.expanded">
                                                    <i class="bi text-muted" :class="n.expanded ? 'bi-chevron-down' : 'bi-chevron-right'"></i>
                                                    <div class="form-check form-switch" @click.stop title="启用/禁用节点">
                                                        <input class="form-check-input" type="checkbox" v-model="n.enabled" style="width: 2em; height: 1em;">
                                                    </div>
                                                    <div class="form-check form-switch" @click.stop title="允许群发 (Bulk)">
                                                        <input class="form-check-input" :class="n.allow_bulk ? 'bg-warning border-warning' : ''" type="checkbox" v-model="n.allow_bulk" style="width: 2em; height: 1em;">
                                                    </div>
                                                    <span class="fw-bold text-truncate" :title="n.name">[[ n.name ]]</span>
                                                </div>
                                                <div class="d-flex gap-1 flex-shrink-0">
                                                    <button class="btn btn-sm btn-outline-secondary py-0 px-2" @click.stop="moveNode(i, -1)" :disabled="i === 0" title="上移"><i class="bi bi-arrow-up"></i></button>
                                                    <button class="btn btn-sm btn-outline-secondary py-0 px-2" @click.stop="moveNode(i, 1)" :disabled="i === config.downstream_pool.length - 1" title="下移"><i class="bi bi-arrow-down"></i></button>
                                                    <button class="btn btn-sm btn-outline-success py-0 px-2" @click.stop="copyNode(i)" title="复制节点"><i class="bi bi-copy"></i></button>
                                                    <button class="btn btn-sm btn-outline-primary py-0 px-2" @click.stop="save" title="保存配置"><i class="bi bi-save"></i></button>
                                                    <button class="btn btn-sm btn-outline-danger py-0 px-2" @click.stop="delNode(i)" title="删除节点"><i class="bi bi-trash"></i></button>
                                                </div>
                                            </div>
                                            <div class="card-body" v-show="n.expanded">
                                                <div class="row g-2">
                                                    <div class="col-12">
                                                        <label class="small text-muted">备注名称</label>
                                                        <input v-model="n.name" class="form-control form-control-sm" placeholder="备注">
                                                    </div>
                                                    <div class="col-8">
                                                        <label class="small text-muted">Host</label>
                                                        <input v-model="n.host" class="form-control form-control-sm" placeholder="smtp.example.com">
                                                    </div>
                                                    <div class="col-4">
                                                        <label class="small text-muted">Port</label>
                                                        <input v-model.number="n.port" class="form-control form-control-sm" placeholder="587">
                                                    </div>
                                                    <div class="col-6">
                                                        <label class="small text-muted">加密</label>
                                                        <select v-model="n.encryption" class="form-select form-select-sm">
                                                            <option value="none">None</option>
                                                            <option value="tls">TLS</option>
                                                            <option value="ssl">SSL</option>
                                                        </select>
                                                    </div>
                                                    <div class="col-6">
                                                        <label class="small text-muted">Sender Rewrite</label>
                                                        <input v-model="n.sender_email" class="form-control form-control-sm" placeholder="可选">
                                                    </div>
                                                    <div class="col-12">
                                                        <label class="small text-muted">Username</label>
                                                        <input v-model="n.username" class="form-control form-control-sm">
                                                    </div>
                                                    <div class="col-12">
                                                        <label class="small text-muted">Password</label>
                                                        <input v-model="n.password" type="text" class="form-control form-control-sm">
                                                    </div>
                                                    <div class="col-12"><hr class="my-2"></div>
                                                    <div class="col-4">
                                                        <label class="small text-muted">Max/Hr</label>
                                                        <input v-model.number="n.max_per_hour" type="number" class="form-control form-control-sm" placeholder="0">
                                                    </div>
                                                    <div class="col-4">
                                                        <label class="small text-muted">Min(s)</label>
                                                        <input v-model.number="n.min_interval" type="number" class="form-control form-control-sm" placeholder="1">
                                                    </div>
                                                    <div class="col-4">
                                                        <label class="small text-muted">Max(s)</label>
                                                        <input v-model.number="n.max_interval" type="number" class="form-control form-control-sm" placeholder="5">
                                                    </div>
                                                    <div class="col-12">
                                                        <div class="form-check form-switch my-1">
                                                            <input class="form-check-input" type="checkbox" v-model="n.allow_bulk" :id="'allowBulk'+i">
                                                            <label class="form-check-label small" :for="'allowBulk'+i">允许群发 (Allow Bulk)</label>
                                                        </div>
                                                    </div>
                                                    <div class="col-12">
                                                        <label class="small text-muted">分流规则</label>
                                                        <div class="d-flex flex-wrap gap-1 mb-1">
                                                            <button class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="(!n.routing_rules)?'btn-primary':'btn-outline-secondary'" @click="n.routing_rules=''">通用</button>
                                                            <template v-for="d in topDomains" :key="d.domain">
                                                                <button v-if="d.domain !== '__other__'" class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="hasDomain(n, d.domain)?'btn-success':'btn-outline-secondary'" @click="toggleDomain(n, d.domain)" :title="d.count + '封'">[[ formatDomainLabel(d.domain) ]]</button>
                                                                <span v-else class="btn btn-sm py-0 px-1 btn-outline-secondary" style="font-size: 0.7rem; cursor: default;" :title="d.count + '封'"><i class="bi bi-three-dots"></i> 其他</span>
                                                            </template>
                                                            <span v-if="topDomains.length === 0" class="text-muted small">暂无数据</span>
                                                        </div>
                                                        <input v-model="n.routing_rules" class="form-control form-control-sm" placeholder="域名...">
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
        const app = createApp({
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
                    bulk: { sender: '', subject: '', recipients: '', body: '', bodyList: [''] },
                    sending: false,
                    contactCount: 0,
                    bulkStatus: 'running',
                    rebalancing: false,
                    theme: 'auto',
                    draggingIndex: null,
                    dragOverIndex: null,
                    topDomains: []
                }
            },
            computed: {
                hasPendingNodes() {
                    return Object.values(this.qStats.nodes).some(n => (n.pending || 0) > 0);
                },
                clickRate() {
                    const sent = (this.qStats.total.sent || 0) + (this.qStats.total.failed || 0); // Use sent+failed or just sent? Usually sent.
                    // Actually, click rate is usually Opens / Delivered.
                    // But here 'sent' means delivered (or at least accepted by relay).
                    // Let's use sent.
                    const s = this.qStats.total.sent || 0;
                    if(s === 0) return '0.00%';
                    return (((this.qStats.total.opened || 0) / s) * 100).toFixed(2) + '%';
                },
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
                if(!this.config.log_config) this.config.log_config = { max_mb: 50, backups: 3, retention_days: 7 };
                this.config.downstream_pool.forEach(n => { 
                    if(n.enabled === undefined) n.enabled = true; 
                    if(n.allow_bulk === undefined) n.allow_bulk = true;
                    if(n.expanded === undefined) n.expanded = false;
                });
                
                // Auto-load draft
                this.loadDraft();
                
                // Load theme
                const savedTheme = localStorage.getItem('theme') || 'auto';
                this.setTheme(savedTheme);

                this.fetchQueue();
                this.fetchContactCount();
                this.fetchBulkStatus();
                this.fetchTopDomains();
                setInterval(() => {
                    this.fetchQueue();
                    this.fetchBulkStatus();
                }, 5000);
            },
            watch: {
                bulk: {
                    handler(v) { this.debouncedSaveDraft(); },
                    deep: true
                }
            },
            methods: {
                setTheme(t) {
                    this.theme = t;
                    localStorage.setItem('theme', t);
                    const html = document.documentElement;
                    if (t === 'auto') {
                        if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
                            html.setAttribute('data-bs-theme', 'dark');
                        } else {
                            html.setAttribute('data-bs-theme', 'light');
                        }
                    } else {
                        html.setAttribute('data-bs-theme', t);
                    }
                },
                async loadDraft() {
                    try {
                        const res = await fetch('/api/draft');
                        const data = await res.json();
                        if (data && Object.keys(data).length > 0) {
                            this.bulk = data;
                            // Migration check
                            if (!this.bulk.bodyList || this.bulk.bodyList.length === 0) {
                                if (this.bulk.body) {
                                    this.bulk.bodyList = this.bulk.body.split('|||').map(x => x.trim()).filter(x => x);
                                }
                                if (!this.bulk.bodyList || this.bulk.bodyList.length === 0) {
                                    this.bulk.bodyList = [''];
                                }
                            }
                        }
                    } catch(e) { console.error("Failed to load draft", e); }
                },
                debouncedSaveDraft: (() => {
                    let timer;
                    return function() {
                        if(timer) clearTimeout(timer);
                        timer = setTimeout(async () => {
                            try {
                                await fetch('/api/draft', {
                                    method: 'POST',
                                    headers: {'Content-Type': 'application/json'},
                                    body: JSON.stringify(this.bulk)
                                });
                            } catch(e) { console.error("Failed to save draft", e); }
                        }, 1000);
                    }
                })(),
                addBody() { this.bulk.bodyList.push(''); },
                removeBody(i) { if(this.bulk.bodyList.length > 1) this.bulk.bodyList.splice(i, 1); },
                getEstDuration(name, pending) {
                    if (!pending || pending <= 0) return '-';
                    const speed = this.getNodeSpeed(name);
                    const seconds = pending / speed;
                    if (seconds < 60) return '< 1m';
                    const h = Math.floor(seconds / 3600);
                    const m = Math.floor((seconds % 3600) / 60);
                    if (h > 0) return `${h}h ${m}m`;
                    return `${m}m`;
                },
                getEstFinishTime(name, pending) {
                    if (!pending || pending <= 0) return '-';
                    const speed = this.getNodeSpeed(name);
                    const seconds = pending / speed;
                    const finish = new Date(Date.now() + seconds * 1000);
                    const y = finish.getFullYear();
                    const mo = (finish.getMonth() + 1).toString().padStart(2, '0');
                    const da = finish.getDate().toString().padStart(2, '0');
                    const h = finish.getHours().toString().padStart(2, '0');
                    const m = finish.getMinutes().toString().padStart(2, '0');
                    return `${y}-${mo}-${da} ${h}:${m}`;
                },
                getNodeSpeed(name) {
                    const node = this.config.downstream_pool.find(n => n.name === name);
                    if (!node) return 0.1;
                    const global = this.config.limit_config || {};
                    const min_i = parseFloat(node.min_interval || global.min_interval || 1);
                    const max_i = parseFloat(node.max_interval || global.max_interval || 5);
                    let avg_i = (min_i + max_i) / 2;
                    if (avg_i <= 0.01) avg_i = 0.01;
                    let speed = 1 / avg_i;
                    const max_ph = parseInt(node.max_per_hour || 0);
                    if (max_ph > 0) {
                        if ((max_ph / 3600) < speed) speed = max_ph / 3600;
                    }
                    return speed;
                },
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
                async fetchTopDomains() {
                    try {
                        const res = await fetch('/api/domain/stats');
                        this.topDomains = await res.json();
                    } catch(e) { this.topDomains = []; }
                },
                formatDomainLabel(domain) {
                    const map = {
                        'qq.com': 'QQ',
                        'gmail.com': 'Gmail',
                        '163.com': '163',
                        '126.com': '126',
                        'outlook.com': 'Outlook',
                        'hotmail.com': 'Hotmail',
                        'yahoo.com': 'Yahoo',
                        'sina.com': '新浪',
                        'sohu.com': '搜狐',
                        'foxmail.com': 'Foxmail',
                        'icloud.com': 'iCloud',
                        'aliyun.com': '阿里云'
                    };
                    return map[domain.toLowerCase()] || domain;
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
                        
                        // Check for session expiry (HTML response instead of JSON)
                        const ct = res.headers.get("content-type");
                        if (ct && ct.indexOf("application/json") === -1) {
                            alert('会话已过期，请刷新页面重新登录');
                            window.location.reload();
                            return;
                        }

                        const data = await res.json();
                        alert(`成功新增 ${data.added} 个`);
                        this.fetchContactCount();
                    } catch(e) { alert('失败: ' + e); }
                },
                getGroupRange(i) {
                     const start = (i-1)*50000 + 1;
                     const end = Math.min(i*50000, this.contactCount);
                     return `${start}-${end}`;
                },
                async loadContacts(groupIndex) {
                    if(this.bulk.recipients && !confirm('覆盖当前输入框?')) return;
                    try {
                        let url = '/api/contacts/list';
                        if (this.contactCount > 50000) {
                            const limit = 50000;
                            const offset = groupIndex * limit;
                            url += `?limit=${limit}&offset=${offset}`;
                        }
                        const res = await fetch(url);
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
                hasDomain(n, d) {
                    if(!n.routing_rules) return false;
                    return n.routing_rules.split(',').map(x=>x.trim()).includes(d);
                },
                toggleDomain(n, d) {
                    let rules = n.routing_rules ? n.routing_rules.split(',').map(x=>x.trim()).filter(x=>x) : [];
                    if(rules.includes(d)) {
                        rules = rules.filter(x=>x!==d);
                    } else {
                        rules.push(d);
                    }
                    n.routing_rules = rules.join(',');
                },
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node-'+Math.floor(Math.random()*1000), host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '', enabled: true, allow_bulk: true, routing_rules: '', expanded: true }); 
                },
                delNode(i) { if(confirm('删除此节点?')) this.config.downstream_pool.splice(i, 1); },
                copyNode(i) {
                    const original = this.config.downstream_pool[i];
                    const copy = JSON.parse(JSON.stringify(original));
                    copy.name = original.name + '-Copy';
                    copy.expanded = true;
                    this.config.downstream_pool.splice(i + 1, 0, copy);
                },
                moveNode(i, direction) {
                    const newIndex = i + direction;
                    if (newIndex < 0 || newIndex >= this.config.downstream_pool.length) return;
                    const pool = this.config.downstream_pool;
                    const temp = pool[i];
                    this.$set(pool, i, pool[newIndex]);
                    this.$set(pool, newIndex, temp);
                },
                onDragStart(e, i) {
                    this.draggingIndex = i;
                    e.dataTransfer.effectAllowed = 'move';
                    e.dataTransfer.setData('text/plain', i);
                },
                onDragOver(e, i) {
                    this.dragOverIndex = i;
                },
                onDrop(e, targetIndex) {
                    const sourceIndex = this.draggingIndex;
                    if (sourceIndex === null || sourceIndex === targetIndex) return;
                    const pool = this.config.downstream_pool;
                    const item = pool.splice(sourceIndex, 1)[0];
                    pool.splice(targetIndex, 0, item);
                    this.draggingIndex = null;
                    this.dragOverIndex = null;
                },
                onDragEnd() {
                    this.draggingIndex = null;
                    this.dragOverIndex = null;
                },
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
                            // User requested limit 100 to prevent freezing
                            const res2 = await fetch('/api/queue/list?limit=100');
                            this.qList = await res2.json();
                        }
                    } catch(e) { console.error(e); }
                },
                async sendBulk() {
                    // Sync bodyList to body for compatibility or just use bodyList
                    // We will send 'bodies' array
                    const validBodies = this.bulk.bodyList.filter(b => b.trim());
                    if(!this.bulk.subject || validBodies.length === 0) return alert('请填写完整信息 (至少一个正文)');
                    if(!confirm(`确认发送给 ${this.recipientCount} 人?`)) return;
                    this.sending = true;
                    try {
                        const payload = {
                            ...this.bulk,
                            bodies: validBodies
                        };
                        const res = await fetch('/api/send/bulk', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify(payload)
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
                },
                async rebalanceQueue() {
                    if(!confirm('确定要将所有【待发送】邮件重新随机分配给当前启用的节点吗？\n\n这通常用于：\n1. 新增节点后，让其立即参与当前任务\n2. 某个节点堆积过多，需要分流')) return;
                    this.rebalancing = true;
                    try {
                        const res = await fetch('/api/queue/rebalance', { method: 'POST' });
                        const data = await res.json();
                        if(res.ok) {
                            alert(`成功重分配 ${data.count} 个任务`);
                            this.fetchQueue();
                        } else {
                            alert('错误: ' + data.error);
                        }
                    } catch(e) { alert('失败: ' + e); }
                    this.rebalancing = false;
                }
            }
        });

        app.component('preview-frame', {
            props: ['content'],
            template: '<iframe ref="frm" style="width:100%;height:100%;border:none;"></iframe>',
            mounted() { this.update(); },
            updated() { this.update(); },
            watch: { content() { this.update(); } },
            methods: {
                update() {
                    const doc = this.$refs.frm.contentDocument || this.$refs.frm.contentWindow.document;
                    doc.open();
                    doc.write(this.content || '<div style="text-align:center;color:#999;padding-top:2rem;font-family:sans-serif;font-size:12px;">实时预览区域</div>');
                    doc.close();
                }
            }
        });

        app.mount('#app');
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
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
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
