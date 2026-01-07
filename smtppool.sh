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
    "downstream_pool": [],
    "node_groups": []
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
import functools
from datetime import datetime, timedelta
from email import message_from_bytes
from email.header import decode_header
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.utils import formatdate, make_msgid, formataddr
from logging.handlers import RotatingFileHandler
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import SMTP as SMTPServer, AuthResult, LoginPassword
from flask import Flask, render_template, request, jsonify, redirect, url_for, session
from functools import wraps

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')
DB_FILE = os.path.join(BASE_DIR, 'queue.db')
LOG_FILE = '/var/log/smtp-relay/app.log'

# --- Database ---
def db_retry(max_retries=3, delay=0.5):
    """Decorator for retrying database operations on lock"""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_retries):
                try:
                    return func(*args, **kwargs)
                except sqlite3.OperationalError as e:
                    if 'locked' in str(e) and attempt < max_retries - 1:
                        time.sleep(delay * (attempt + 1))
                        continue
                    raise
            return func(*args, **kwargs)
        return wrapper
    return decorator

def get_db():
    conn = sqlite3.connect(DB_FILE, check_same_thread=False, timeout=60)
    conn.row_factory = sqlite3.Row
    # 启用WAL模式提高并发性能
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA busy_timeout=60000')  # 60秒超时
    conn.execute('PRAGMA synchronous=NORMAL')  # 平衡性能和安全
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
            if 'subject' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN subject TEXT")
            if 'smtp_user' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN smtp_user TEXT")
            if 'scheduled_at' not in cols:
                conn.execute("ALTER TABLE queue ADD COLUMN scheduled_at TIMESTAMP")
        except Exception as e:
            print(f"DB Init Warning: {e}")

        # Optimization: Indexes & WAL
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_status ON queue (status)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_scheduled ON queue (scheduled_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_node_status ON queue (assigned_node, status)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_created ON queue (created_at)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_source ON queue (source)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_tracking ON queue (tracking_id)")
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

        conn.execute('''CREATE TABLE IF NOT EXISTS smtp_users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            email_limit INTEGER DEFAULT 0,
            email_sent INTEGER DEFAULT 0,
            hourly_sent INTEGER DEFAULT 0,
            hourly_reset_at TIMESTAMP,
            expires_at TIMESTAMP,
            enabled INTEGER DEFAULT 1,
            created_at TIMESTAMP DEFAULT (datetime('now', '+08:00')),
            last_used_at TIMESTAMP
        )''')
        
        # Check and add smtp_users columns safely
        try:
            cursor = conn.execute("PRAGMA table_info(smtp_users)")
            cols = [c[1] for c in cursor.fetchall()]
            if 'last_used_at' not in cols:
                conn.execute("ALTER TABLE smtp_users ADD COLUMN last_used_at TIMESTAMP")
            if 'hourly_sent' not in cols:
                conn.execute("ALTER TABLE smtp_users ADD COLUMN hourly_sent INTEGER DEFAULT 0")
            if 'hourly_reset_at' not in cols:
                conn.execute("ALTER TABLE smtp_users ADD COLUMN hourly_reset_at TIMESTAMP")
        except: pass

# --- Config Cache (TTL-based) ---
_config_cache = {'data': None, 'time': 0, 'ttl': 3}  # 3 seconds TTL

def load_config(use_cache=True):
    """Load config with optional caching (default 3s TTL)"""
    global _config_cache
    now = time.time()
    if use_cache and _config_cache['data'] is not None and (now - _config_cache['time']) < _config_cache['ttl']:
        return _config_cache['data']
    if not os.path.exists(CONFIG_FILE): return {}
    try:
        with open(CONFIG_FILE, 'r') as f:
            data = json.load(f)
            _config_cache['data'] = data
            _config_cache['time'] = now
            return data
    except: return {}

def save_config(data):
    global _config_cache
    with open(CONFIG_FILE, 'w') as f: json.dump(data, f, indent=4)
    _config_cache['data'] = data  # Update cache immediately
    _config_cache['time'] = time.time()

def invalidate_config_cache():
    """Force reload config on next access"""
    global _config_cache
    _config_cache['data'] = None
    _config_cache['time'] = 0

# --- Chat Corpus (Module-level constant for memory efficiency) ---
CHAT_CORPUS = [
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
    "早安，愿你有个好梦。", "周末打算去露营，感觉很放松。", "最近想去看电影，感觉很放松。",
    "准备去野餐，感觉充满了能量。", "今天打算去露营，希望能遇到有趣的人。", "后天约了朋友吃饭，觉得生活很美好。",
    "要去骑行，希望能一切顺利。", "要去骑行，心情特别好。", "最近想去打羽毛球，心情特别好。",
    "假期打算去逛街，觉得很充实。", "准备在家大扫除，希望能遇到有趣的人。", "周末准备去图书馆，希望能一切顺利。",
    "下周想去钓鱼，感觉很放松。", "周末准备去野餐，感觉很放松。", "假期要去健身房锻炼，感觉充满了能量。",
]

# --- Config & Logging ---

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

# --- SMTP Authenticator ---
class SMTPAuthenticator:
    def __call__(self, server, session, envelope, mechanism, auth_data):
        fail_result = AuthResult(success=False, handled=True)
        logger.info(f"🔐 SMTP认证尝试: 方式={mechanism}, 数据类型={type(auth_data)}")
        try:
            # Decode auth data
            if isinstance(auth_data, LoginPassword):
                username = auth_data.login.decode('utf-8') if isinstance(auth_data.login, bytes) else auth_data.login
                password = auth_data.password.decode('utf-8') if isinstance(auth_data.password, bytes) else auth_data.password
                logger.info(f"🔐 用户名: {username}")
            elif mechanism == 'PLAIN':
                # PLAIN format: \0username\0password
                data = auth_data.decode('utf-8') if isinstance(auth_data, bytes) else auth_data
                parts = data.split('\x00')
                username = parts[1] if len(parts) > 1 else ''
                password = parts[2] if len(parts) > 2 else ''
                logger.info(f"🔐 PLAIN认证用户: {username}")
            else:
                logger.warning(f"❌ SMTP Auth unsupported mechanism: {mechanism}")
                return fail_result
            
            # Verify user
            with get_db() as conn:
                user = conn.execute(
                    "SELECT * FROM smtp_users WHERE username=? AND password=? AND enabled=1",
                    (username, password)
                ).fetchone()
                
                if not user:
                    logger.warning(f"❌ SMTP Auth failed: {username}")
                    return fail_result
                
                # Check expiry
                if user['expires_at']:
                    expires = datetime.strptime(user['expires_at'], '%Y-%m-%d %H:%M:%S')
                    if datetime.now() > expires:
                        logger.warning(f"❌ SMTP Auth expired: {username}")
                        return fail_result
                
                # Check hourly limit - reset if hour changed
                now = datetime.now()
                current_hour = now.strftime('%Y-%m-%d %H:00:00')
                hourly_sent = user['hourly_sent'] or 0
                hourly_reset_at = user['hourly_reset_at']
                
                # Reset hourly count if hour changed
                if hourly_reset_at != current_hour:
                    hourly_sent = 0
                    conn.execute(
                        "UPDATE smtp_users SET hourly_sent=0, hourly_reset_at=? WHERE id=?",
                        (current_hour, user['id'])
                    )
                
                # Check hourly limit
                if user['email_limit'] > 0 and hourly_sent >= user['email_limit']:
                    logger.warning(f"❌ SMTP Auth hourly limit reached: {username} ({hourly_sent}/{user['email_limit']}/h)")
                    return fail_result
                
                # Store username in session for later use
                session.smtp_user = username
                session.smtp_user_id = user['id']
                logger.info(f"✅ SMTP认证成功: {username} (小时已发: {hourly_sent}/{user['email_limit']})")
                return AuthResult(success=True)
        except Exception as e:
            logger.error(f"SMTP认证错误: {e}")
            return fail_result

# --- SMTP Handler (Producer) ---
class RelayHandler:
    async def handle_DATA(self, server, session, envelope):
        cfg = load_config()
        all_pool = cfg.get('downstream_pool', [])
        # Filter enabled nodes (default True)
        pool = [n for n in all_pool if n.get('enabled', True)]
        
        # Debug logging
        all_node_names = [n.get('name', '?') for n in all_pool]
        enabled_node_names = [n.get('name', '?') for n in pool]
        logger.info(f"📋 节点列表: {all_node_names}, 已启用: {enabled_node_names}")
        
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
             logger.warning("❌ 无可用节点")
             return '451 Temporary failure: No suitable nodes'

        # Extract subject from email content (before logging)
        subject = ''
        smtp_user = getattr(session, 'smtp_user', None)
        try:
            msg = message_from_bytes(envelope.content)
            raw_subject = msg.get('Subject', '')
            # Decode MIME encoded subject
            if raw_subject:
                decoded_parts = decode_header(raw_subject)
                subject_parts = []
                for part, encoding in decoded_parts:
                    if isinstance(part, bytes):
                        subject_parts.append(part.decode(encoding or 'utf-8', errors='replace'))
                    else:
                        subject_parts.append(part)
                subject = ''.join(subject_parts)[:100]  # Limit to 100 chars
        except:
            pass

        subject_short = subject[:30] if subject else '(无主题)'
        logger.info(f"📥 收到邮件 | 发件人: {envelope.mail_from} | 收件人: {envelope.rcpt_tos[0] if envelope.rcpt_tos else '?'} | 主题: {subject_short} | 节点: {[n['name'] for n in selected_nodes]}")
        
        # 3. Queue for all selected nodes (No Direct Send anymore to ensure async redundancy)
        try:
            with get_db() as conn:
                for node in selected_nodes:
                    node_name = node.get('name', 'Unknown')
                    conn.execute(
                        "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, last_error, subject, smtp_user, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now', '+08:00'), datetime('now', '+08:00'))",
                        (envelope.mail_from, json.dumps(envelope.rcpt_tos), envelope.content, node_name, 'pending', 'relay', None, subject, smtp_user)
                    )
                
                # Auto-save relay recipients to contacts list
                for rcpt_email in envelope.rcpt_tos:
                    rcpt_email = rcpt_email.strip()
                    if rcpt_email and '@' in rcpt_email:
                        try:
                            conn.execute("INSERT INTO contacts (email, created_at) VALUES (?, datetime('now', '+08:00'))", (rcpt_email,))
                        except sqlite3.IntegrityError:
                            pass  # Already exists, ignore
                
                # Update SMTP user sent count (both total and hourly)
                if hasattr(session, 'smtp_user_id'):
                    current_hour = datetime.now().strftime('%Y-%m-%d %H:00:00')
                    conn.execute(
                        """UPDATE smtp_users SET 
                           email_sent = email_sent + ?, 
                           hourly_sent = CASE WHEN hourly_reset_at = ? THEN hourly_sent + ? ELSE ? END,
                           hourly_reset_at = ?,
                           last_used_at = datetime('now', '+08:00') 
                           WHERE id = ?""",
                        (len(envelope.rcpt_tos), current_hour, len(envelope.rcpt_tos), len(envelope.rcpt_tos), current_hour, session.smtp_user_id)
                    )
                            
            return '250 OK: Queued for redundant delivery'
        except Exception as e:
            logger.error(f"❌ 数据库错误: {e}")
            return '451 Temporary failure: DB Error'

# --- Queue Worker (Consumer) ---
def worker_thread():
    logger.info("👷 Queue Worker Started (Smart Rate Limiting)")
    
    # Runtime state tracking
    node_next_send_time = {}  # { 'node_name': timestamp }
    node_hourly_counts = {}   # { 'node_name': { 'hour': 10, 'count': 50 } }
    last_cleanup_time = 0
    last_stuck_check_time = 0
    
    # 日志汇总计数器
    log_batch_counter = {'success': 0, 'fail': 0, 'last_log_time': time.time()}
    LOG_BATCH_SIZE = 10  # 每10封输出一次汇总
    
    # 发送速度统计
    speed_stats = {'minute_start': time.time(), 'minute_count': 0, 'total_sent': 0}

    while True:
        try:
            cfg = load_config()
            now = time.time()
            
            # --- Reset stuck 'processing' items (every 2 minutes) ---
            if now - last_stuck_check_time > 120:
                for retry in range(3):
                    try:
                        with get_db() as conn:
                            stuck = conn.execute("UPDATE queue SET status='pending' WHERE status='processing' AND updated_at < datetime('now', '+08:00', '-5 minutes')").rowcount
                            if stuck > 0:
                                logger.info(f"🔄 已重置 {stuck} 个卡住的任务")
                        break
                    except sqlite3.OperationalError as e:
                        if 'locked' in str(e) and retry < 2:
                            time.sleep(0.5 * (retry + 1))
                            continue
                        logger.error(f"卡住任务检查失败: {e}")
                    except Exception as e:
                        logger.error(f"卡住任务检查失败: {e}")
                        break
                last_stuck_check_time = now
            
            # --- Auto Cleanup (Once per hour) ---
            if now - last_cleanup_time > 3600:
                try:
                    days = int(cfg.get('log_config', {}).get('retention_days', 7))
                    if days > 0:
                        # Calculate cutoff date in Python to avoid SQL injection
                        cutoff = (datetime.utcnow() + timedelta(hours=8) - timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S')
                        with get_db() as conn:
                            conn.execute("DELETE FROM queue WHERE status IN ('sent', 'failed') AND updated_at < ?", (cutoff,))
                        logger.info(f"🧹 自动清理了 {days} 天前的旧记录")
                except Exception as e:
                    logger.error(f"自动清理失败: {e}")
                last_cleanup_time = now

            # --- Activate Scheduled Emails (every loop) ---
            # Change status from 'scheduled' to 'pending' when scheduled_at time has passed
            for retry in range(3):
                try:
                    current_time = (datetime.utcnow() + timedelta(hours=8)).strftime('%Y-%m-%d %H:%M:%S')
                    with get_db() as conn:
                        activated = conn.execute(
                            "UPDATE queue SET status='pending' WHERE status='scheduled' AND scheduled_at <= ?",
                            (current_time,)
                        ).rowcount
                        if activated > 0:
                            logger.info(f"⏰ 已激活 {activated} 封定时邮件")
                    break
                except sqlite3.OperationalError as e:
                    if 'locked' in str(e) and retry < 2:
                        time.sleep(0.5 * (retry + 1))
                        continue
                    logger.error(f"定时邮件激活失败: {e}")
                except Exception as e:
                    logger.error(f"定时邮件激活失败: {e}")
                    break

            pool_cfg = {n['name']: n for n in cfg.get('downstream_pool', [])}
            
            # Global Bulk Control
            bulk_ctrl = cfg.get('bulk_control', {}).get('status', 'running')
            
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
                
                # Get recipient domain for routing check
                try:
                    rcpt_tos = json.loads(row['rcpt_tos'])
                    rcpt_domain = rcpt_tos[0].split('@')[-1].lower().strip() if rcpt_tos else ''
                except:
                    rcpt_domain = ''
                
                # Re-route if node removed or disabled
                if not node or not node.get('enabled', True):
                    active_nodes = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
                    new_node = select_node_for_recipient(active_nodes, rcpt_tos[0] if rcpt_tos else '', cfg.get('limit_config', {}), source=source) if active_nodes else None
                    if new_node:
                        logger.info(f"🔄 重新分配 ID:{row_id} 从 '{node_name}' 到 '{new_node['name']}'")
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET assigned_node=?, status='pending' WHERE id=?", (new_node['name'], row_id))
                    else:
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET status='failed', last_error='No active nodes available' WHERE id=?", (row_id,))
                    continue

                # Re-route bulk mails if node's allow_bulk is disabled
                if is_bulk and not node.get('allow_bulk', True):
                    bulk_nodes = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True) and n.get('allow_bulk', True)]
                    new_node = select_node_for_recipient(bulk_nodes, rcpt_tos[0] if rcpt_tos else '', cfg.get('limit_config', {}), source=source) if bulk_nodes else None
                    if new_node:
                        logger.info(f"🔄 群发重新分配 ID:{row_id} 从 '{node_name}' (禁止群发) 到 '{new_node['name']}'")
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET assigned_node=?, status='pending' WHERE id=?", (new_node['name'], row_id))
                    else:
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET status='failed', last_error='No bulk-enabled nodes available' WHERE id=?", (row_id,))
                    continue

                # Re-route if domain is excluded by current node's routing rules
                rules = node.get('routing_rules', '')
                if rules and rules.strip():
                    excluded = [d.strip().lower() for d in rules.split(',') if d.strip()]
                    if rcpt_domain in excluded:
                        # Find another node that doesn't exclude this domain
                        available_nodes = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True) and (not is_bulk or n.get('allow_bulk', True))]
                        new_node = select_node_for_recipient(available_nodes, rcpt_tos[0] if rcpt_tos else '', cfg.get('limit_config', {}), source=source)
                        if new_node:
                            logger.info(f"🔄 重新分配 ID:{row_id} 从 '{node_name}' (域名{rcpt_domain}被排除) 到 '{new_node['name']}'")
                            with get_db() as conn:
                                conn.execute("UPDATE queue SET assigned_node=?, status='pending' WHERE id=?", (new_node['name'], row_id))
                        else:
                            with get_db() as conn:
                                conn.execute("UPDATE queue SET status='failed', last_error='No node available for domain: ' || ? WHERE id=?", (rcpt_domain, row_id))
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
                            logger.warning(f"⚠️ 节点 {node_name} 已达小时限额 ({node_hourly_counts[node_name]['count']}/{max_ph})，暂停60秒")
                            continue
                        elif node_hourly_counts[node_name]['count'] >= max_ph * 0.8:
                            # 80% warning
                            logger.warning(f"⚠️ 节点 {node_name} 已达 80% 小时限额 ({node_hourly_counts[node_name]['count']}/{max_ph})")

                # --- Processing ---
                did_work = True
                
                # Mark processing
                with get_db() as conn:
                    conn.execute("UPDATE queue SET status='processing', updated_at=datetime('now', '+08:00') WHERE id=?", (row_id,))

                # Double check node still exists (in case config changed during batch processing)
                fresh_cfg = load_config()
                fresh_pool = {n['name']: n for n in fresh_cfg.get('downstream_pool', [])}
                node = fresh_pool.get(node_name)
                if not node or not node.get('enabled', True):
                    # Node was deleted/disabled, re-route
                    active_nodes = [n for n in fresh_cfg.get('downstream_pool', []) if n.get('enabled', True)]
                    new_node = select_node_for_recipient(active_nodes, rcpt_tos[0] if rcpt_tos else '', fresh_cfg.get('limit_config', {}), source=source) if active_nodes else None
                    if new_node:
                        logger.info(f"🔄 紧急重新分配 ID:{row_id} 从已删除/禁用节点 '{node_name}' 到 '{new_node['name']}'")
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET assigned_node=?, status='pending' WHERE id=?", (new_node['name'], row_id))
                    else:
                        with get_db() as conn:
                            conn.execute("UPDATE queue SET status='failed', last_error='Node deleted and no alternatives' WHERE id=?", (row_id,))
                    continue

                error_msg = ""
                success = False
                
                try:
                    # Build sender address
                    sender = None
                    if node.get('sender_domain'):
                        domain = node['sender_domain']
                        if node.get('sender_random'):
                            # Random 6-char prefix
                            prefix = ''.join(random.choices('abcdefghijklmnopqrstuvwxyz0123456789', k=6))
                        else:
                            prefix = node.get('sender_prefix', 'mail')
                        sender = f"{prefix}@{domain}"
                    elif node.get('sender_email'):
                        sender = node['sender_email']
                    else:
                        sender = row['mail_from'] or node.get('username')
                    
                    rcpt_tos = json.loads(row['rcpt_tos'])
                    msg_content = row['content']

                    # Header rewrite
                    if sender and (node.get('sender_domain') or node.get('sender_email')):
                        try:
                            msg = message_from_bytes(msg_content)
                            if 'From' in msg: del msg['From']
                            msg['From'] = sender
                            msg_content = msg.as_bytes()
                        except: pass

                    # Handle different encryption modes
                    encryption = node.get('encryption', 'none')
                    host = node['host']
                    port = int(node['port'])
                    
                    if encryption == 'ssl':
                        # SSL mode (usually port 465) - use SMTP_SSL
                        with smtplib.SMTP_SSL(host, port, timeout=30) as s:
                            if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                            s.sendmail(sender, rcpt_tos, msg_content)
                    else:
                        # None or TLS mode (usually port 25/587) - use SMTP with optional STARTTLS
                        with smtplib.SMTP(host, port, timeout=30) as s:
                            if encryption == 'tls':
                                s.starttls()
                            if node.get('username') and node.get('password'): s.login(node['username'], node['password'])
                            s.sendmail(sender, rcpt_tos, msg_content)
                    
                    success = True
                    # 汇总日志：每10封输出一次
                    log_batch_counter['success'] += 1
                    speed_stats['minute_count'] += 1
                    speed_stats['total_sent'] += 1
                    
                    # 每分钟输出一次速度统计
                    if time.time() - speed_stats['minute_start'] >= 60:
                        logger.info(f"📊 发送速度: {speed_stats['minute_count']} 封/分钟 | 本次总计: {speed_stats['total_sent']} 封")
                        speed_stats['minute_start'] = time.time()
                        speed_stats['minute_count'] = 0
                    
                    if log_batch_counter['success'] >= LOG_BATCH_SIZE or (time.time() - log_batch_counter['last_log_time']) > 10:
                        logger.info(f"✅ 发送成功 {log_batch_counter['success']} 封 | 最近: {rcpt_tos[0] if rcpt_tos else '未知'} | 节点: {node_name} | 来源: {source}")
                        log_batch_counter['success'] = 0
                        log_batch_counter['last_log_time'] = time.time()
                    
                    # Update hourly count (All traffic counts towards limit)
                    if node_name in node_hourly_counts:
                        node_hourly_counts[node_name]['count'] += 1

                except Exception as e:
                    error_msg = str(e)
                    # 失败日志汇总
                    log_batch_counter['fail'] += 1
                    if log_batch_counter['fail'] >= LOG_BATCH_SIZE or (time.time() - log_batch_counter['last_log_time']) > 10:
                        logger.error(f"❌ 发送失败 {log_batch_counter['fail']} 封 | 最近: {rcpt_tos[0] if rcpt_tos else '未知'} | 节点: {node_name} | 错误: {e}")
                        log_batch_counter['fail'] = 0
                        log_batch_counter['last_log_time'] = time.time()

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
            logger.error(f"工作线程错误: {e}")
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
    # Get old config to detect changes
    old_cfg = load_config(use_cache=False)
    old_nodes = set(n['name'] for n in old_cfg.get('downstream_pool', []) if n.get('enabled', True))
    
    save_config(request.json)
    global logger
    logger = setup_logging()
    
    # Get new config
    new_cfg = load_config(use_cache=False)
    new_nodes = set(n['name'] for n in new_cfg.get('downstream_pool', []) if n.get('enabled', True))
    
    # Check if new nodes were added
    added_nodes = new_nodes - old_nodes
    
    # Auto rebalance after save (in background thread to avoid blocking)
    def async_rebalance():
        try:
            if added_nodes:
                # New nodes added - do a force rebalance to distribute load
                logger.info(f"🆕 检测到新节点: {added_nodes}, 正在强制重分配...")
                result = force_rebalance_internal()
                count = result.get('count', 0) if isinstance(result, dict) else 0
                if count > 0:
                    logger.info(f"✅ 添加新节点后强制重分配了 {count} 个任务")
            else:
                # Normal rebalance (only fix invalid assignments)
                count = rebalance_queue_internal()
                if count > 0:
                    logger.info(f"✅ 保存配置后自动重分配了 {count} 个任务")
        except Exception as e:
            logger.error(f"自动重分配失败: {e}")
    threading.Thread(target=async_rebalance, daemon=True).start()
    return jsonify({"status": "ok"})

@app.route('/api/restart', methods=['POST'])
@login_required
def api_restart():
    def restart_server():
        time.sleep(1)
        os._exit(0)
    threading.Thread(target=restart_server).start()
    return jsonify({"status": "restarting"})

@app.route('/api/logs')
@login_required
def api_logs():
    """获取最近的日志"""
    lines = int(request.args.get('lines', 100))
    try:
        log_file = LOG_FILE
        if not os.path.exists(log_file):
            return jsonify({"logs": []})
        
        # 读取最后 N 行
        with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
            all_lines = f.readlines()
            recent = all_lines[-lines:] if len(all_lines) > lines else all_lines
            # 反转顺序，最新的在前
            recent.reverse()
            return jsonify({"logs": [l.strip() for l in recent if l.strip()]})
    except Exception as e:
        return jsonify({"logs": [], "error": str(e)})

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
        rows = conn.execute("SELECT id, mail_from, rcpt_tos, assigned_node, status, retry_count, last_error, created_at, subject, smtp_user FROM queue ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return jsonify([dict(r) for r in rows])

@app.route('/api/domain/stats')
@login_required
def api_domain_stats():
    """Get top 9 recipient domains by count, rest as 'other'"""
    with get_db() as conn:
        # Only count pending emails for routing relevance
        rows = conn.execute("SELECT rcpt_tos FROM queue WHERE status='pending'").fetchall()
    
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
    sorted_domains = sorted(domain_count.items(), key=lambda x: x[1], reverse=True)
    top9 = sorted_domains[:9]
    result = [{'domain': d, 'count': c} for d, c in top9]
    
    # Calculate "other" - include all remaining domains as a list
    if len(sorted_domains) > 9:
        other_domains = [d for d, c in sorted_domains[9:]]
        other_count = sum(c for d, c in sorted_domains[9:])
        result.append({'domain': '__other__', 'count': other_count, 'domains': other_domains})
    
    return jsonify(result)

def select_weighted_node(nodes, global_limit, queue_counts=None):
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
            
            # Factor in current queue load (nodes with fewer pending items get higher weight)
            if queue_counts:
                pending = queue_counts.get(node['name'], 0)
                # Use inverse of pending count as multiplier (more pending = lower weight)
                # Stronger penalty for high load
                load_factor = 1 / (1 + (pending / 50) ** 0.7)
                speed = speed * load_factor
            
            # Factor in flexibility (nodes with no exclusion rules should get more tasks)
            rules = node.get('routing_rules', '')
            if rules and rules.strip():
                excluded_count = len([d for d in rules.split(',') if d.strip()])
                # Reduce weight for nodes with many exclusions
                flexibility_factor = 1 / (1 + excluded_count * 0.3)
                speed = speed * flexibility_factor
            
            weights.append(max(speed, 0.1))  # Ensure minimum weight
            
        return random.choices(nodes, weights=weights, k=1)[0]
    except:
        return random.choice(nodes)

def get_queue_counts_by_node():
    """Get pending queue count for each node"""
    try:
        with get_db() as conn:
            rows = conn.execute(
                "SELECT assigned_node, COUNT(*) as cnt FROM queue WHERE status IN ('pending', 'scheduled') GROUP BY assigned_node"
            ).fetchall()
            return {r['assigned_node']: r['cnt'] for r in rows}
    except:
        return {}

def select_node_for_recipient(pool, recipient, global_limit, source='relay', force_assign=False, queue_counts=None):
    # pool is list of node dicts
    if not pool: return None
    try:
        domain = recipient.split('@')[-1].lower().strip()
    except:
        domain = ""
    
    # Get queue counts if not provided (for load-aware selection)
    if queue_counts is None:
        queue_counts = get_queue_counts_by_node()
        
    candidates = []
    excluded_candidates = []  # Nodes that have this domain excluded
    
    for node in pool:
        # Filter by source capability
        if source == 'bulk' and not node.get('allow_bulk', True):
            continue

        # routing_rules now contains EXCLUDED domains
        rules = node.get('routing_rules', '')
        if not rules or not rules.strip():
            # No exclusion rules, this node accepts all domains
            candidates.append(node)
        else:
            # Check if domain is in the exclusion list
            excluded = [d.strip().lower() for d in rules.split(',') if d.strip()]
            if domain not in excluded:
                # Domain is NOT excluded, so this node can handle it
                candidates.append(node)
            else:
                # Domain is excluded, but keep track for force_assign
                excluded_candidates.append(node)
    
    # Normal mode: only use non-excluded candidates
    if candidates:
        return select_weighted_node(candidates, global_limit, queue_counts)
    
    # Force assign mode: if no normal candidates, use excluded nodes (ignoring their rules)
    if force_assign and excluded_candidates:
        return select_weighted_node(excluded_candidates, global_limit, queue_counts)
    
    return None

def bulk_import_task(raw_recipients, subjects, bodies, pool, scheduled_at=None):
    try:
        # Process recipients in background to avoid blocking
        recipients = [r.strip() for r in raw_recipients.split('\n') if r.strip()]
        random.shuffle(recipients) # Shuffle for better distribution
        
        cfg = load_config()
        limit_cfg = cfg.get('limit_config', {})
        tracking_base = cfg.get('web_config', {}).get('public_domain', '').rstrip('/')

        charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        # Use module-level CHAT_CORPUS for memory efficiency
        chat_corpus = CHAT_CORPUS
        
        # Calculate scheduled time (default: now)
        schedule_time = None
        if scheduled_at:
            try:
                schedule_time = datetime.strptime(scheduled_at, '%Y-%m-%dT%H:%M')
            except:
                schedule_time = None
        
        # Placeholder to remove old chat_corpus definition
        _removed_chat_corpus = [
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
]  # Empty placeholder, using CHAT_CORPUS module constant
        
        tasks = []
        count = 0
        
        for rcpt in recipients:
            try:
                # === Anti-Spam Randomization ===
                rand_sub = ''.join(random.choices(charset, k=random.randint(4, 8)))
                # Select random sentences to simulate normal chat
                rand_chat = ' '.join(random.choices(chat_corpus, k=random.randint(5, 12)))
                
                # Randomly select subject and body
                current_subject = random.choice(subjects) if subjects else "(No Subject)"
                current_body = random.choice(bodies) if bodies else ""

                tracking_id = str(uuid.uuid4())
                tracking_html = ""
                if tracking_base:
                    tracking_url = f"{tracking_base}/track/{tracking_id}"
                    tracking_html = f"<img src='{tracking_url}' width='1' height='1' alt='' style='display:none;border:0;'>"

                # === Enhanced Subject Randomization ===
                # Randomly choose subject format
                subject_formats = [
                    f"{current_subject} {rand_sub}",
                    f"{current_subject} - {rand_sub}",
                    f"Re: {current_subject}",
                    f"Fwd: {current_subject}",
                    f"{current_subject}",
                    f"{current_subject} #{rand_sub[:4]}",
                ]
                final_subject = random.choice(subject_formats)
                
                # === Build More Natural Email ===
                # Extract recipient name from email for personalization
                rcpt_name = rcpt.split('@')[0].replace('.', ' ').replace('_', ' ').replace('-', ' ').title()[:20]
                
                # Random greetings and closings
                greetings = ['', f'Hi,', f'Hello,', f'Hey,', f'{rcpt_name},', f'Hi {rcpt_name},', f'Dear {rcpt_name},', '你好，', '您好，', '']
                closings = ['', 'Best,', 'Thanks,', 'Cheers,', 'Regards,', '祝好', '谢谢', '']
                
                greeting = random.choice(greetings)
                closing = random.choice(closings)
                
                # Build HTML with more natural structure
                # Hidden content placed more naturally throughout
                hidden_style = 'color:transparent;font-size:1px;line-height:1px;max-height:0;opacity:0;overflow:hidden;mso-hide:all;'
                hidden_words = rand_chat.split()
                hidden_chunks = [' '.join(hidden_words[i:i+3]) for i in range(0, len(hidden_words), 3)]
                
                # Interleave hidden content with visible content
                body_parts = current_body.split('</p>')
                enhanced_body = ""
                for i, part in enumerate(body_parts):
                    enhanced_body += part
                    if part.strip() and i < len(hidden_chunks):
                        enhanced_body += f'<span style="{hidden_style}">{hidden_chunks[i]}</span>'
                    if part.strip() and '<p' in part.lower():
                        enhanced_body += '</p>'
                
                # Build final body with natural wrapping
                final_body = f'''<div style="font-family:Arial,sans-serif;font-size:14px;line-height:1.6;">
{f"<p>{greeting}</p>" if greeting else ""}
{enhanced_body if enhanced_body else current_body}
<span style="{hidden_style}">{random.choice(hidden_chunks) if hidden_chunks else rand_chat[:50]}</span>
{f"<p>{closing}</p>" if closing else ""}
{tracking_html}
</div>'''

                # === Create Multipart Email (HTML + Plain Text) ===
                # Plain text version makes it look more like a normal email
                plain_text = f"{greeting}\n\n{current_body.replace('<br>', chr(10)).replace('<br/>', chr(10)).replace('</p>', chr(10))}\n\n{closing}".strip()
                # Remove HTML tags from plain text
                import re
                plain_text = re.sub(r'<[^>]+>', '', plain_text)
                
                msg = MIMEMultipart('alternative')
                msg['Subject'] = final_subject
                msg['From'] = '' # Placeholder, worker will fill
                msg['To'] = rcpt
                
                # Randomize date slightly (within last few minutes)
                date_offset = random.randint(0, 180)  # 0-3 minutes ago
                msg['Date'] = formatdate(localtime=True, timeval=time.time() - date_offset)
                
                # More natural Message-ID format
                msg_domain = rcpt.split('@')[-1] if '@' in rcpt else 'mail.local'
                msg['Message-ID'] = f"<{uuid.uuid4().hex[:16]}.{int(time.time())}.{random.randint(1000,9999)}@{msg_domain}>"
                
                # Add common headers that normal emails have
                msg['MIME-Version'] = '1.0'
                user_agents = [
                    'Mozilla/5.0', 
                    'Microsoft Outlook 16.0', 
                    'Apple Mail (2.3654)',
                    'Thunderbird/102.0',
                    None  # Sometimes no User-Agent
                ]
                ua = random.choice(user_agents)
                if ua:
                    msg['X-Mailer'] = ua
                
                # Attach plain text first, then HTML (standard order)
                part1 = MIMEText(plain_text, 'plain', 'utf-8')
                part2 = MIMEText(final_body, 'html', 'utf-8')
                msg.attach(part1)
                msg.attach(part2)

                node = select_node_for_recipient(pool, rcpt, limit_cfg, source='bulk')
                if not node:
                    # No node available for this domain (all nodes exclude it)
                    logger.warning(f"⚠️ Skipping {rcpt}: No node available for this domain")
                    continue
                node_name = node.get('name', 'Unknown')
                
                # Determine status based on scheduling
                initial_status = 'scheduled' if schedule_time and schedule_time > datetime.now() else 'pending'
                scheduled_at_str = schedule_time.strftime('%Y-%m-%d %H:%M:%S') if schedule_time else None
                
                tasks.append(('', json.dumps([rcpt]), msg.as_bytes(), node_name, initial_status, 'bulk', tracking_id, datetime.utcnow() + timedelta(hours=8), datetime.utcnow() + timedelta(hours=8), scheduled_at_str, final_subject))
                count += 1
                
                # Batch insert every 500 records for better performance
                if len(tasks) >= 500:
                    with get_db() as conn:
                        conn.executemany(
                            "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, tracking_id, created_at, updated_at, scheduled_at, subject) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            tasks
                        )
                    tasks = []
            except Exception as e:
                logger.error(f"准备邮件失败 {rcpt}: {e}")
                continue

        # Insert remaining tasks
        if tasks:
            with get_db() as conn:
                conn.executemany(
                    "INSERT INTO queue (mail_from, rcpt_tos, content, assigned_node, status, source, tracking_id, created_at, updated_at, scheduled_at, subject) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    tasks
                )
        logger.info(f"群发导入完成: 共 {count} 封邮件")
    except Exception as e:
        logger.error(f"群发导入任务失败: {e}")

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

        # Get scheduled_at if provided
        scheduled_at = data.get('scheduled_at', '')

        # Start background task with raw string
        threading.Thread(target=bulk_import_task, args=(raw_recipients, subjects, bodies, pool, scheduled_at)).start()
        
        if scheduled_at:
            return jsonify({"status": "ok", "count": "Processing in background", "scheduled": scheduled_at})
        return jsonify({"status": "ok", "count": "Processing in background"})
    except Exception as e:
        logger.error(f"群发错误: {e}")
        return jsonify({"error": str(e)}), 500

# --- SMTP Users Management API ---
@app.route('/api/smtp-users')
@login_required
def api_smtp_users_list():
    with get_db() as conn:
        rows = conn.execute("SELECT id, username, email_limit, email_sent, hourly_sent, hourly_reset_at, expires_at, enabled, created_at, last_used_at FROM smtp_users ORDER BY id DESC").fetchall()
    return jsonify([dict(r) for r in rows])

@app.route('/api/smtp-users', methods=['POST'])
@login_required
def api_smtp_users_create():
    data = request.json
    username = data.get('username', '').strip()
    password = data.get('password', '').strip()
    email_limit = int(data.get('email_limit', 0))
    expires_at = data.get('expires_at', '').strip() or None
    
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400
    
    try:
        with get_db() as conn:
            conn.execute(
                "INSERT INTO smtp_users (username, password, email_limit, expires_at, enabled) VALUES (?, ?, ?, ?, 1)",
                (username, password, email_limit, expires_at)
            )
        return jsonify({"status": "ok"})
    except sqlite3.IntegrityError:
        return jsonify({"error": "Username already exists"}), 400

@app.route('/api/smtp-users/<int:user_id>', methods=['PUT'])
@login_required
def api_smtp_users_update(user_id):
    data = request.json
    updates = []
    params = []
    
    if 'password' in data and data['password']:
        updates.append("password=?")
        params.append(data['password'])
    if 'email_limit' in data:
        updates.append("email_limit=?")
        params.append(int(data['email_limit']))
    if 'expires_at' in data:
        updates.append("expires_at=?")
        params.append(data['expires_at'] if data['expires_at'] else None)
    if 'enabled' in data:
        updates.append("enabled=?")
        params.append(1 if data['enabled'] else 0)
    if 'reset_count' in data and data['reset_count']:
        updates.append("email_sent=0")
    
    if not updates:
        return jsonify({"error": "No fields to update"}), 400
    
    params.append(user_id)
    with get_db() as conn:
        conn.execute(f"UPDATE smtp_users SET {', '.join(updates)} WHERE id=?", params)
    return jsonify({"status": "ok"})

@app.route('/api/smtp-users/<int:user_id>', methods=['DELETE'])
@login_required
def api_smtp_users_delete(user_id):
    with get_db() as conn:
        conn.execute("DELETE FROM smtp_users WHERE id=?", (user_id,))
    return jsonify({"status": "ok"})

@app.route('/api/smtp-users/batch', methods=['POST'])
@login_required
def api_smtp_users_batch():
    """Batch generate SMTP users"""
    import secrets
    import string
    
    data = request.json
    user_type = data.get('type', 'free')
    count = min(int(data.get('count', 1)), 1000)  # Max 1000
    prefix = data.get('prefix', '').strip() or 'user_'
    
    # Load config for limits
    cfg = load_config()
    user_limits = cfg.get('user_limits', {})
    
    # Determine limit and expiry based on type
    limit_map = {
        'free': (user_limits.get('free', 10), None),
        'monthly': (user_limits.get('monthly', 100), 30),
        'quarterly': (user_limits.get('quarterly', 500), 90),
        'yearly': (user_limits.get('yearly', 1000), 365)
    }
    email_limit, days = limit_map.get(user_type, (100, None))
    
    # Generate users
    generated = []
    with get_db() as conn:
        for i in range(count):
            # Generate unique username and password
            suffix = secrets.token_hex(4)
            username = f"{prefix}{suffix}"
            password = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12))
            
            # Calculate expiry
            expires_at = None
            if days:
                expires_at = (datetime.now() + timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S')
            
            try:
                conn.execute(
                    "INSERT INTO smtp_users (username, password, email_limit, expires_at, enabled) VALUES (?, ?, ?, ?, 1)",
                    (username, password, email_limit, expires_at)
                )
                generated.append({
                    'username': username,
                    'password': password,
                    'email_limit': email_limit,
                    'expires_at': expires_at or '永久有效',
                    'type': user_type
                })
            except sqlite3.IntegrityError:
                continue  # Skip duplicates
    
    return jsonify({"status": "ok", "users": generated, "count": len(generated)})

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

@app.route('/api/contacts/domain_stats')
@login_required
def api_contacts_domain_stats():
    """Get domain statistics for all contacts"""
    with get_db() as conn:
        rows = conn.execute("SELECT email FROM contacts").fetchall()
    
    domain_count = {}
    for row in rows:
        email = row['email']
        if '@' in email:
            domain = email.split('@')[-1].lower().strip()
            if domain:
                domain_count[domain] = domain_count.get(domain, 0) + 1
    
    # Sort by count descending
    sorted_domains = sorted(domain_count.items(), key=lambda x: x[1], reverse=True)
    result = [{'domain': d, 'count': c} for d, c in sorted_domains]
    return jsonify(result)

@app.route('/api/contacts/clear', methods=['POST'])
@login_required
def api_contacts_clear():
    with get_db() as conn:
        conn.execute("DELETE FROM contacts")
    return jsonify({"status": "ok"})

@app.route('/api/contacts/shuffle', methods=['POST'])
@login_required
def api_contacts_shuffle():
    """Shuffle all contacts and re-insert them in random order"""
    with get_db() as conn:
        rows = conn.execute("SELECT email FROM contacts").fetchall()
        if not rows:
            return jsonify({"status": "ok", "count": 0})
        emails = [r['email'] for r in rows]
        random.shuffle(emails)
        conn.execute("DELETE FROM contacts")
        for e in emails:
            conn.execute("INSERT INTO contacts (email, created_at) VALUES (?, datetime('now', '+08:00'))", (e,))
    return jsonify({"status": "ok", "count": len(emails)})

@app.route('/api/contacts/download')
@login_required
def api_contacts_download():
    """Download all contacts as a text file"""
    with get_db() as conn:
        rows = conn.execute("SELECT email FROM contacts ORDER BY id").fetchall()
    content = '\n'.join([r['email'] for r in rows])
    from flask import Response
    return Response(
        content,
        mimetype='text/plain',
        headers={'Content-Disposition': 'attachment; filename=contacts_' + datetime.now().strftime('%Y%m%d_%H%M%S') + '.txt'}
    )

@app.route('/api/contacts/remove', methods=['POST'])
@login_required
def api_contacts_remove():
    """Remove a specific email from contacts"""
    email = request.json.get('email', '').strip().lower()
    if not email:
        return jsonify({"error": "No email provided"}), 400
    with get_db() as conn:
        # SQLite LOWER() for case-insensitive match
        result = conn.execute("DELETE FROM contacts WHERE LOWER(email) = ?", (email,))
        deleted = result.rowcount
    return jsonify({"status": "ok", "deleted": deleted})

@app.route('/api/contacts/remove_domain', methods=['POST'])
@login_required
def api_contacts_remove_domain():
    """Remove all emails with a specific domain from contacts"""
    domain = request.json.get('domain', '').strip().lower()
    if not domain:
        return jsonify({"error": "No domain provided"}), 400
    # Remove @ prefix if user included it
    if domain.startswith('@'):
        domain = domain[1:]
    with get_db() as conn:
        # Match emails ending with @domain (case-insensitive)
        result = conn.execute("DELETE FROM contacts WHERE LOWER(email) LIKE ?", ('%@' + domain,))
        deleted = result.rowcount
    return jsonify({"status": "ok", "deleted": deleted, "domain": domain})

@app.route('/api/contacts/remove_domains', methods=['POST'])
@login_required
def api_contacts_remove_domains():
    """Remove all emails with multiple domains from contacts"""
    domains = request.json.get('domains', [])
    if not domains:
        return jsonify({"error": "No domains provided"}), 400
    total_deleted = 0
    with get_db() as conn:
        for domain in domains:
            domain = domain.strip().lower()
            if domain.startswith('@'):
                domain = domain[1:]
            if domain:
                result = conn.execute("DELETE FROM contacts WHERE LOWER(email) LIKE ?", ('%@' + domain,))
                total_deleted += result.rowcount
    return jsonify({"status": "ok", "deleted": total_deleted, "domains": domains})

@app.route('/api/contacts/remove_small_domains', methods=['POST'])
@login_required
def api_contacts_remove_small_domains():
    """Remove all emails from domains with count less than threshold"""
    threshold = request.json.get('threshold', 10)
    try:
        threshold = int(threshold)
    except:
        return jsonify({"error": "Invalid threshold"}), 400
    
    # Use SQL to efficiently find and delete emails from small domains
    with get_db() as conn:
        # Get count before deletion
        before_count = conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0]
        
        # Create a subquery to find emails from domains with count >= threshold (to keep)
        # Then delete everything else
        # This is more efficient than iterating through thousands of domains
        conn.execute("""
            DELETE FROM contacts WHERE id NOT IN (
                SELECT c.id FROM contacts c
                INNER JOIN (
                    SELECT LOWER(SUBSTR(email, INSTR(email, '@') + 1)) as domain
                    FROM contacts
                    GROUP BY LOWER(SUBSTR(email, INSTR(email, '@') + 1))
                    HAVING COUNT(*) >= ?
                ) keep_domains
                ON LOWER(SUBSTR(c.email, INSTR(c.email, '@') + 1)) = keep_domains.domain
            )
        """, (threshold,))
        
        # Get count after deletion
        after_count = conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0]
        deleted = before_count - after_count
    
    return jsonify({"status": "ok", "deleted": deleted, "threshold": threshold})

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
    cfg = load_config(use_cache=False)  # Force fresh config
    pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
    if not pool: return 0
    
    # Build lookup for quick access
    pool_by_name = {n['name']: n for n in pool}
    bulk_pool = [n for n in pool if n.get('allow_bulk', True)]
    
    # If no bulk-enabled nodes, we can't rebalance bulk mails
    if not bulk_pool:
        bulk_pool = pool  # Fallback to all enabled nodes
    
    limit_cfg = cfg.get('limit_config', {})
    
    # Pre-compute routing exclusion sets for each node (for faster lookup)
    node_exclusions = {}
    for n in pool:
        rules = n.get('routing_rules', '')
        if rules and rules.strip():
            node_exclusions[n['name']] = set(d.strip().lower() for d in rules.split(',') if d.strip())
        else:
            node_exclusions[n['name']] = set()
    
    # Get list of valid node names for quick check
    valid_node_names = set(pool_by_name.keys())
    bulk_disabled_nodes = set(n['name'] for n in pool if not n.get('allow_bulk', True))
    
    with get_db() as conn:
        # Fetch ALL pending items to check routing rules
        rows = conn.execute("SELECT id, rcpt_tos, source, assigned_node FROM queue WHERE status IN ('pending', 'scheduled')").fetchall()
        
        if not rows: return 0
        
        updates = []
        failures = []
        
        for r in rows:
            try:
                rcpts = json.loads(r['rcpt_tos'])
                rcpt = rcpts[0] if rcpts else ''
                domain = rcpt.split('@')[-1].lower().strip() if '@' in rcpt else ''
            except:
                rcpt = ''
                domain = ''
            
            source = r['source']
            current_node_name = r['assigned_node']
            current_node = pool_by_name.get(current_node_name)
            
            # Check if current assignment is valid
            needs_reassign = False
            
            # 1. Node doesn't exist or is disabled
            if current_node_name not in valid_node_names:
                needs_reassign = True
            # 2. Bulk mail on bulk-disabled node
            elif source == 'bulk' and current_node_name in bulk_disabled_nodes:
                needs_reassign = True
            # 3. Domain is excluded by current node's routing rules
            elif domain and domain in node_exclusions.get(current_node_name, set()):
                needs_reassign = True
            
            if needs_reassign:
                target_pool = bulk_pool if source == 'bulk' else pool
                node = select_node_for_recipient(target_pool, rcpt, limit_cfg, source=source)
                if node and node['name'] != current_node_name:
                    updates.append((node['name'], r['id']))
                elif not node:
                    # No valid node found, mark as failed
                    failures.append((r['id'],))
        
        # Batch update for efficiency
        if updates:
            conn.executemany("UPDATE queue SET assigned_node=? WHERE id=?", updates)
        if failures:
            conn.executemany("UPDATE queue SET status='failed', last_error='No node available for this domain' WHERE id=?", failures)
        
        count = len(updates)
        if count > 0:
            logger.info(f"🔄 重分配完成: {count} 个成功, {len(failures)} 个失败")
    return count

@app.route('/api/queue/rebalance', methods=['POST'])
@login_required
def api_queue_rebalance():
    try:
        count = rebalance_queue_internal()
        return jsonify({"status": "ok", "count": count})
    except Exception as e:
        logger.error(f"重分配错误: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/queue/force_rebalance', methods=['POST'])
@login_required
def api_queue_force_rebalance():
    """Force rebalance: redistribute ALL pending items evenly based on weight, respecting routing rules"""
    try:
        result = force_rebalance_internal()
        return jsonify(result)
    except Exception as e:
        logger.error(f"强制均分错误: {e}")
        return jsonify({"error": str(e)}), 500

def force_rebalance_internal():
    """Internal function for force rebalance, returns count and stats"""
    cfg = load_config(use_cache=False)
    pool = [n for n in cfg.get('downstream_pool', []) if n.get('enabled', True)]
    if not pool:
        return {"status": "ok", "count": 0, "failed": 0, "distribution": {}}
    
    bulk_pool = [n for n in pool if n.get('allow_bulk', True)]
    if not bulk_pool:
        bulk_pool = pool
    
    limit_cfg = cfg.get('limit_config', {})
    
    # Pre-compute routing exclusion sets for each node
    node_exclusions = {}
    for n in pool + bulk_pool:
        if n['name'] not in node_exclusions:
            rules = n.get('routing_rules', '')
            if rules and rules.strip():
                node_exclusions[n['name']] = set(d.strip().lower() for d in rules.split(',') if d.strip())
            else:
                node_exclusions[n['name']] = set()
    
    with get_db() as conn:
        rows = conn.execute(
            "SELECT id, source, rcpt_tos FROM queue WHERE status IN ('pending', 'scheduled') ORDER BY id"
        ).fetchall()
        
        if not rows:
            return {"status": "ok", "count": 0, "failed": 0, "distribution": {}}
        
        # Calculate weights for each node based on speed
        def calc_weight(node):
            min_i = float(node.get('min_interval') or limit_cfg.get('min_interval', 1))
            max_i = float(node.get('max_interval') or limit_cfg.get('max_interval', 5))
            avg_i = (min_i + max_i) / 2
            if avg_i <= 0.01: avg_i = 0.01
            speed = 3600 / avg_i
            max_ph = int(node.get('max_per_hour', 0))
            if max_ph > 0: speed = min(speed, max_ph)
            return speed
        
        pool_weights = {n['name']: calc_weight(n) for n in pool}
        bulk_weights = {n['name']: calc_weight(n) for n in bulk_pool}
        
        # Distribute items proportionally based on weights, respecting routing rules
        updates = []
        failures = []
        # Track assignments per node - include all nodes from both pools
        all_node_names = set(n['name'] for n in pool) | set(n['name'] for n in bulk_pool)
        node_counts = {name: 0 for name in all_node_names}
        
        # Calculate "flexibility" for each node (how many domains it can accept)
        # Nodes with fewer exclusions should get more tasks
        node_flexibility = {}
        for n in pool + bulk_pool:
            if n['name'] not in node_flexibility:
                excluded = node_exclusions.get(n['name'], set())
                # Fewer exclusions = higher flexibility score
                node_flexibility[n['name']] = 1.0 / (1 + len(excluded) * 0.5)  # More exclusions = lower score
        
        for r in rows:
            source = r['source']
            
            # Extract domain from recipient
            try:
                rcpts = json.loads(r['rcpt_tos'])
                rcpt = rcpts[0] if rcpts else ''
                domain = rcpt.split('@')[-1].lower().strip() if '@' in rcpt else ''
            except:
                domain = ''
            
            # Get candidate nodes that accept this domain
            target_pool = bulk_pool if source == 'bulk' else pool
            candidates = []
            for n in target_pool:
                excluded = node_exclusions.get(n['name'], set())
                if not domain or domain not in excluded:
                    candidates.append(n)
            
            if not candidates:
                # No node accepts this domain
                failures.append((r['id'],))
                continue
            
            # NEW LOGIC: Prioritize nodes with no exclusions (they can handle any domain)
            # and prefer nodes with lower current load
            weights = (pool_weights if source != 'bulk' else bulk_weights)
            
            # Sort candidates: 
            # 1. First by flexibility (nodes with no exclusions first)
            # 2. Then by current load / weight ratio (lower is better)
            def node_score(n):
                name = n['name']
                current_load = node_counts[name]
                weight = weights.get(name, 1)
                flexibility = node_flexibility.get(name, 1)
                # Lower score = better choice
                # Nodes with high flexibility should have lower base score
                # Nodes with fewer current tasks should be preferred
                return (current_load + 1) / (weight * flexibility + 0.001)
            
            best_node = min(candidates, key=node_score)
            node_counts[best_node['name']] += 1
            updates.append((best_node['name'], r['id']))
        
        if updates:
            conn.executemany("UPDATE queue SET assigned_node=? WHERE id=?", updates)
        if failures:
            conn.executemany("UPDATE queue SET status='failed', last_error='No node accepts this domain' WHERE id=?", failures)
        
        logger.info(f"⚡ 强制均分完成: {len(updates)} 个成功, {len(failures)} 个失败")
        
        # Return distribution stats
        stats = {n['name']: node_counts.get(n['name'], 0) for n in pool}
        
        return {"status": "ok", "count": len(updates), "failed": len(failures), "distribution": stats}

@app.route('/api/bulk/control', methods=['POST'])
@login_required
def api_bulk_control():
    action = request.json.get('action')
    cfg = load_config()
    if 'bulk_control' not in cfg: cfg['bulk_control'] = {'status': 'running'}
    
    if action == 'pause':
        cfg['bulk_control']['status'] = 'paused'
        save_config(cfg)
        logger.info("⏸️ 群发已暂停")
    elif action == 'resume':
        cfg['bulk_control']['status'] = 'running'
        save_config(cfg)
        logger.info("▶️ 群发已恢复")
    elif action == 'stop':
        # Stop means clear pending bulk
        with get_db() as conn:
            deleted = conn.execute("DELETE FROM queue WHERE (status='pending' OR status='processing') AND source='bulk'").rowcount
        logger.info(f"⏹️ 群发已停止，清理了 {deleted} 封待发邮件")
        
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
            # 获取收件人信息
            row = conn.execute("SELECT rcpt_tos FROM queue WHERE tracking_id=?", (tid,)).fetchone()
            rcpt = '未知'
            if row:
                try:
                    rcpt_list = json.loads(row['rcpt_tos'])
                    rcpt = rcpt_list[0] if rcpt_list else '未知'
                except:
                    pass
            conn.execute("UPDATE queue SET opened_at=datetime('now', '+08:00'), open_count=open_count+1 WHERE tracking_id=?", (tid,))
            logger.info(f"📖 邮件被打开 | 收件人: {rcpt} | 追踪ID: {tid[:8]}...")
    except Exception as e:
        logger.error(f"跟踪错误: {e}")
    return TRACKING_GIF, 200, {'Content-Type': 'image/gif', 'Cache-Control': 'no-cache, no-store, must-revalidate'}

# --- Custom SMTP class with authentication ---
class AuthSMTP(SMTPServer):
    def __init__(self, handler, require_auth=True, **kwargs):
        self.authenticator = SMTPAuthenticator()
        self._require_auth = require_auth
        if require_auth:
            super().__init__(
                handler,
                auth_required=True,
                auth_require_tls=False,
                authenticator=self.authenticator,
                **kwargs
            )
        else:
            super().__init__(handler, **kwargs)

class AuthController(Controller):
    def __init__(self, handler, require_auth=True, **kwargs):
        self._require_auth = require_auth
        super().__init__(handler, **kwargs)
    
    def factory(self):
        return AuthSMTP(self.handler, require_auth=self._require_auth)

def start_services():
    init_db()
    cfg = load_config()
    port = int(cfg.get('server_config', {}).get('port', 587))
    # Check if any SMTP users exist - if not, disable auth requirement
    with get_db() as conn:
        user_count = conn.execute("SELECT COUNT(*) FROM smtp_users WHERE enabled=1").fetchone()[0]
    require_auth = user_count > 0
    print(f"SMTP Port: {port}, Auth Required: {require_auth}")
    
    # Start SMTP Server
    controller = AuthController(
        RelayHandler(), 
        hostname='0.0.0.0', 
        port=port,
        require_auth=require_auth
    )
    controller.start()
    
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
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <style>
        /* Hide app until Vue is mounted (Vue 3 adds data-v-app when ready) */
        #app:not([data-v-app]) { display: none !important; }
        
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
        .log-line { white-space: pre-wrap; word-break: break-all; line-height: 1.4; padding: 1px 0; }
        .log-line.log-error { color: #f14c4c; }
        .log-line.log-warning { color: #cca700; }
        .log-line.log-success { color: #23d18b; }
        .log-line.log-info { color: #3794ff; }
    </style>
</head>
<body>
    <div id="app" v-cloak>
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
                <div class="nav-item" :class="{active: tab=='nodes'}" @click="tab='nodes'; mobileMenu=false">
                    <i class="bi bi-diagram-3-fill"></i> <span>节点池</span>
                </div>
                <div class="nav-item" :class="{active: tab=='users'}" @click="tab='users'; fetchSmtpUsers(); mobileMenu=false">
                    <i class="bi bi-people-fill"></i> <span>用户管理</span>
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

                <!-- Live Logs -->
                <div class="card mb-4">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <div class="d-flex align-items-center gap-2">
                            <span>实时日志</span>
                            <span class="badge bg-success" v-if="liveLogsEnabled"><i class="bi bi-broadcast"></i> 实时</span>
                            <span class="badge bg-secondary" v-else><i class="bi bi-pause-circle"></i> 已暂停</span>
                        </div>
                        <div class="d-flex gap-2">
                            <button class="btn btn-sm" :class="liveLogsEnabled ? 'btn-warning' : 'btn-success'" @click="toggleLiveLogs">
                                <i class="bi" :class="liveLogsEnabled ? 'bi-pause-fill' : 'bi-play-fill'"></i>
                                [[ liveLogsEnabled ? '暂停' : '启用' ]]
                            </button>
                            <button class="btn btn-sm btn-outline-secondary" @click="clearLogs">
                                <i class="bi bi-trash"></i> 清空
                            </button>
                            <button class="btn btn-sm btn-outline-primary" @click="refreshLogs">
                                <i class="bi bi-arrow-clockwise"></i> 刷新
                            </button>
                        </div>
                    </div>
                    <div class="card-body p-0">
                        <div ref="logContainer" class="log-container font-monospace small" style="height: 300px; overflow-y: auto; background: #1e1e1e; color: #d4d4d4; padding: 10px;" @scroll="onLogScroll">
                            <div v-for="(log, idx) in liveLogs" :key="idx" class="log-line" :class="getLogClass(log)">
                                [[ log ]]
                            </div>
                            <div v-if="liveLogs.length === 0" class="text-muted text-center py-4">暂无日志</div>
                        </div>
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
                        <div class="btn-group">
                            <button class="btn btn-sm btn-outline-primary" @click="rebalanceQueue" :disabled="rebalancing" title="仅重分配无效节点上的任务">
                                <i class="bi" :class="rebalancing?'bi-hourglass-split':'bi-shuffle'"></i> 
                                [[ rebalancing ? '分配中...' : '智能重分配' ]]
                            </button>
                            <button class="btn btn-sm btn-outline-warning" @click="forceRebalanceQueue" :disabled="rebalancing" title="忽略排除规则，按权重平均分配所有任务">
                                <i class="bi bi-lightning-charge"></i> 强制均分
                            </button>
                        </div>
                    </div>
                    <div class="table-responsive">
                        <table class="table table-custom table-hover mb-0">
                            <thead><tr><th>节点名称</th><th class="text-center">堆积</th><th class="text-center">变化</th><th class="text-center">成功</th><th class="text-center">失败</th><th>预计时长</th><th>预计结束</th></tr></thead>
                            <tbody>
                                <template v-for="(s, name) in qStats.nodes" :key="name">
                                <tr v-if="(s.pending || 0) > 0 || nodeChanges[name]">
                                    <td class="fw-medium">[[ name ]]</td>
                                    <td class="text-center"><span class="badge bg-warning text-dark">[[ s.pending || 0 ]]</span></td>
                                    <td class="text-center">
                                        <span v-if="nodeChanges[name] > 0" class="badge bg-success">+[[ nodeChanges[name] ]]</span>
                                        <span v-else-if="nodeChanges[name] < 0" class="badge bg-danger">[[ nodeChanges[name] ]]</span>
                                        <span v-else class="text-muted">-</span>
                                    </td>
                                    <td class="text-center text-success">[[ s.sent || 0 ]]</td>
                                    <td class="text-center text-danger">[[ s.failed || 0 ]]</td>
                                    <td class="text-muted small">[[ getEstDuration(name, s.pending) ]]</td>
                                    <td class="text-muted small">[[ getEstFinishTime(name, s.pending) ]]</td>
                                </tr>
                                </template>
                                <tr v-if="!hasPendingNodes && Object.keys(nodeChanges).length === 0"><td colspan="7" class="text-center text-muted py-4">暂无待发任务节点</td></tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Recent Logs -->
                <div class="card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <div class="d-flex align-items-center gap-2">
                            <span>最近投递记录</span>
                            <div class="btn-group btn-group-sm">
                                <button class="btn" :class="queueFilter===''?'btn-primary':'btn-outline-secondary'" @click="queueFilter=''">全部</button>
                                <button class="btn" :class="queueFilter==='sent'?'btn-success':'btn-outline-secondary'" @click="queueFilter='sent'">已发送</button>
                                <button class="btn" :class="queueFilter==='pending'?'btn-warning':'btn-outline-secondary'" @click="queueFilter='pending'">待发送</button>
                                <button class="btn" :class="queueFilter==='scheduled'?'btn-info':'btn-outline-secondary'" @click="queueFilter='scheduled'">
                                    <i class="bi bi-clock"></i> 定时
                                </button>
                                <button class="btn" :class="queueFilter==='failed'?'btn-danger':'btn-outline-secondary'" @click="queueFilter='failed'">失败</button>
                            </div>
                            <span class="text-muted small fw-normal" v-if="totalMails > 100">(最新 100 条 / 共 [[ totalMails ]] 条)</span>
                        </div>
                        <button class="btn btn-sm btn-outline-danger" @click="clearQueue">清理历史</button>
                    </div>
                    <div class="table-responsive" style="max-height: 550px; overflow-y: auto;">
                        <table class="table table-custom table-hover mb-0">
                            <thead style="position: sticky; top: 0; background: var(--card-bg); z-index: 1;"><tr><th class="ps-4">ID</th><th>用户/主题</th><th>详情</th><th>节点</th><th>状态</th><th>时间</th></tr></thead>
                            <tbody>
                                <tr v-for="m in filteredQList" :key="m.id">
                                    <td class="ps-4 text-muted">#[[ m.id ]]</td>
                                    <td>
                                        <div v-if="m.smtp_user" class="small"><span class="badge bg-info-subtle text-info">[[ m.smtp_user ]]</span></div>
                                        <div class="text-muted small text-truncate" style="max-width: 150px;" :title="m.subject">[[ m.subject || '-' ]]</div>
                                    </td>
                                    <td>
                                        <div class="fw-bold text-theme-main">[[ m.mail_from ]]</div>
                                        <div class="text-muted small text-truncate" style="max-width: 200px;">[[ m.rcpt_tos ]]</div>
                                    </td>
                                    <td>
                                        <span class="badge" :class="nodeExists(m.assigned_node) ? 'bg-theme-light text-theme-main border border-theme' : 'bg-danger-subtle text-danger border border-danger'" :title="nodeExists(m.assigned_node) ? '' : '节点已删除'">
                                            [[ m.assigned_node ]]
                                            <i v-if="!nodeExists(m.assigned_node)" class="bi bi-exclamation-triangle-fill ms-1"></i>
                                        </span>
                                    </td>
                                    <td>
                                        <span class="badge" :class="statusBadgeClass(m.status)">[[ m.status ]]</span>
                                        <div v-if="m.last_error" class="text-danger small mt-1" style="font-size: 0.7rem;">[[ m.last_error ]]</div>
                                    </td>
                                    <td class="text-muted small">[[ m.created_at ]]</td>
                                </tr>
                                <tr v-if="filteredQList.length===0"><td colspan="6" class="text-center py-5 text-muted">暂无记录</td></tr>
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
                                
                                <!-- 通讯录域名统计 -->
                                <div v-if="contactDomainStats.length > 0" class="mb-2">
                                    <div class="d-flex justify-content-between align-items-center mb-1">
                                        <small class="text-muted">通讯录域名统计:</small>
                                        <div class="d-flex gap-1 align-items-center">
                                            <div class="input-group input-group-sm" style="width: auto;">
                                                <span class="input-group-text py-0 px-1" style="font-size: 0.75rem;">&lt;</span>
                                                <input type="number" v-model.number="smallDomainThreshold" class="form-control py-0 px-1" style="width: 50px; font-size: 0.75rem;" min="1" placeholder="N">
                                                <button class="btn btn-outline-danger btn-sm py-0 px-1" @click="removeSmallDomains" :title="'删除数量小于 ' + smallDomainThreshold + ' 的域名'" style="font-size: 0.75rem;">
                                                    <i class="bi bi-trash"></i>
                                                </button>
                                            </div>
                                            <button v-if="domainSelectMode && selectedDomains.length > 0" class="btn btn-danger btn-sm py-0 px-2" @click="removeSelectedDomains" :title="'删除已选的 ' + selectedDomains.length + ' 个域名'">
                                                <i class="bi bi-trash"></i> 删除([[ selectedDomains.length ]])
                                            </button>
                                            <button v-if="domainSelectMode" class="btn btn-secondary btn-sm py-0 px-2" @click="selectAllDomains" title="全选/取消">
                                                <i class="bi" :class="selectedDomains.length === contactDomainStats.length ? 'bi-check-square' : 'bi-square'"></i>
                                            </button>
                                            <button class="btn btn-sm py-0 px-2" :class="domainSelectMode ? 'btn-primary' : 'btn-outline-secondary'" @click="toggleDomainSelectMode" :title="domainSelectMode ? '退出选择' : '批量选择'">
                                                <i class="bi" :class="domainSelectMode ? 'bi-x-lg' : 'bi-check2-square'"></i>
                                            </button>
                                            <button class="btn btn-link btn-sm p-0 text-muted" @click="fetchContactDomainStats" title="刷新统计">
                                                <i class="bi bi-arrow-clockwise"></i>
                                            </button>
                                        </div>
                                    </div>
                                    <div class="d-flex flex-wrap gap-1" style="max-height: 100px; overflow-y: auto;">
                                        <span v-if="!domainSelectMode" class="badge bg-secondary-subtle text-dark border" v-for="ds in contactDomainStats" :key="ds.domain" style="cursor: pointer;" @click="removeDomainFromContacts(ds.domain)" :title="'点击清除通讯录中所有 @' + ds.domain + ' 邮箱'">
                                            @[[ ds.domain ]] <span class="text-muted">([[ ds.count ]])</span> <i class="bi bi-x-circle text-danger ms-1"></i>
                                        </span>
                                        <span v-else class="badge border" v-for="ds in contactDomainStats" :key="ds.domain" :class="selectedDomains.includes(ds.domain) ? 'bg-danger text-white' : 'bg-light text-dark'" style="cursor: pointer;" @click="toggleSelectDomain(ds.domain)">
                                            <i class="bi me-1" :class="selectedDomains.includes(ds.domain) ? 'bi-check-square' : 'bi-square'"></i>
                                            @[[ ds.domain ]] <span :class="selectedDomains.includes(ds.domain) ? '' : 'text-muted'">([[ ds.count ]])</span>
                                        </span>
                                    </div>
                                </div>

                                <textarea v-model="bulk.recipients" class="form-control flex-grow-1 mb-3" placeholder="每行一个邮箱地址..." style="min-height: 200px;"></textarea>
                                <div class="d-flex justify-content-between align-items-center mb-2">
                                    <span class="fw-bold">当前输入: [[ recipientCount ]] 人</span>
                                    <div class="btn-group btn-group-sm" v-if="contactCount > 0">
                                        <button class="btn btn-outline-secondary" @click="shuffleAllContacts" :disabled="shufflingContacts" :title="'打乱通讯录 (' + contactCount + ' 人)'">
                                            <i class="bi" :class="shufflingContacts ? 'bi-hourglass-split' : 'bi-shuffle'"></i>
                                        </button>
                                        <button class="btn btn-outline-secondary" @click="downloadAllContacts" :title="'下载通讯录 (' + contactCount + ' 人)'">
                                            <i class="bi bi-download"></i>
                                        </button>
                                    </div>
                                </div>
                                <div class="d-flex flex-wrap gap-1 mb-3" v-if="recipientDomainStats.length > 0">
                                    <span class="badge bg-light text-dark border" v-for="ds in recipientDomainStats" :key="ds.domain" style="cursor: pointer;" @click="removeDomainFromRecipients(ds.domain)" :title="'点击清除所有 ' + ds.domain + ' 邮箱'">
                                        [[ ds.domain ]] <span class="text-muted">([[ ds.count ]])</span> <i class="bi bi-x-circle text-danger ms-1"></i>
                                    </span>
                                </div>
                                <div class="input-group input-group-sm mb-2">
                                    <input type="text" v-model="removeEmail" class="form-control" placeholder="输入要清除的邮箱地址..." @keyup.enter="removeSpecificEmail">
                                    <button class="btn btn-outline-danger" @click="removeSpecificEmail" :disabled="!removeEmail"><i class="bi bi-trash"></i> 清除</button>
                                </div>
                                <div class="input-group input-group-sm mb-3">
                                    <span class="input-group-text">@</span>
                                    <input type="text" v-model="removeDomain" class="form-control" placeholder="输入要清除的域名 (如 qq.com)..." @keyup.enter="removeDomainFromContacts">
                                    <button class="btn btn-outline-danger" @click="removeDomainFromContacts" :disabled="!removeDomain"><i class="bi bi-trash"></i> 按域名清除</button>
                                </div>
                                
                                <!-- 定时发送 -->
                                <div class="mb-3">
                                    <div class="form-check form-switch mb-2">
                                        <input class="form-check-input" type="checkbox" v-model="bulk.enableSchedule" id="enableSchedule">
                                        <label class="form-check-label" for="enableSchedule">
                                            <i class="bi bi-clock me-1"></i>定时发送
                                        </label>
                                    </div>
                                    <div v-if="bulk.enableSchedule" class="input-group input-group-sm">
                                        <span class="input-group-text"><i class="bi bi-calendar-event"></i></span>
                                        <input type="datetime-local" v-model="bulk.scheduledAt" class="form-control">
                                        <span class="input-group-text text-muted small" v-if="bulk.scheduledAt">
                                            [[ formatScheduleTime(bulk.scheduledAt) ]]
                                        </span>
                                    </div>
                                    <div v-if="bulk.enableSchedule" class="form-text">设置后邮件将在指定时间开始发送</div>
                                </div>
                                
                                <button class="btn btn-primary w-100 py-3 fw-bold" @click="sendBulk" :disabled="sending || recipientCount === 0">
                                    <span v-if="sending" class="spinner-border spinner-border-sm me-2"></span>
                                    <i v-else class="bi" :class="bulk.enableSchedule && bulk.scheduledAt ? 'bi-clock-fill' : 'bi-send-fill'" class="me-2"></i>
                                    [[ sending ? '正在提交...' : (bulk.enableSchedule && bulk.scheduledAt ? '定时发送' : '确认发送') ]]
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Users Tab -->
            <div v-if="tab=='users'" class="fade-in">
                <div class="d-flex justify-content-between align-items-center mb-4">
                    <h4 class="fw-bold mb-0">SMTP 用户管理</h4>
                    <div class="d-flex gap-2">
                        <button class="btn btn-outline-primary" @click="showBatchUserModal=true">
                            <i class="bi bi-people-fill me-1"></i>批量生成
                        </button>
                        <button class="btn btn-primary" @click="showAddUserModal">
                            <i class="bi bi-plus-lg me-1"></i>添加用户
                        </button>
                    </div>
                </div>

                <div class="card">
                    <div class="table-responsive">
                        <table class="table table-hover mb-0">
                            <thead>
                                <tr>
                                    <th>用户名</th>
                                    <th>限额/小时</th>
                                    <th>本小时</th>
                                    <th>累计</th>
                                    <th>到期时间</th>
                                    <th>状态</th>
                                    <th style="width:180px">操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr v-if="smtpUsers.length==0">
                                    <td colspan="7" class="text-center text-muted py-4">暂无用户数据</td>
                                </tr>
                                <tr v-for="u in smtpUsers" :key="u.id">
                                    <td><strong>[[ u.username ]]</strong></td>
                                    <td>[[ u.email_limit == 0 ? '无限制' : u.email_limit.toLocaleString() + '/h' ]]</td>
                                    <td>
                                        <span :class="{'text-danger': u.email_limit > 0 && (u.hourly_sent||0) >= u.email_limit}">[[ (u.hourly_sent||0).toLocaleString() ]]</span>
                                        <span v-if="u.email_limit > 0" class="text-muted"> / [[ u.email_limit ]]</span>
                                    </td>
                                    <td class="text-muted">[[ (u.email_sent||0).toLocaleString() ]]</td>
                                    <td>
                                        <span v-if="!u.expires_at" class="text-muted">永不过期</span>
                                        <span v-else :class="{'text-danger': new Date(u.expires_at) < new Date()}">[[ u.expires_at ]]</span>
                                    </td>
                                    <td>
                                        <span class="badge" :class="u.enabled ? 'bg-success' : 'bg-secondary'">[[ u.enabled ? '启用' : '禁用' ]]</span>
                                    </td>
                                    <td>
                                        <button class="btn btn-sm btn-outline-secondary me-1" @click="resetUserCount(u)" title="重置计数">
                                            <i class="bi bi-arrow-counterclockwise"></i>
                                        </button>
                                        <button class="btn btn-sm btn-outline-primary me-1" @click="showEditUserModal(u)" title="编辑">
                                            <i class="bi bi-pencil"></i>
                                        </button>
                                        <button class="btn btn-sm btn-outline-danger" @click="deleteSmtpUser(u)" title="删除">
                                            <i class="bi bi-trash"></i>
                                        </button>
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- User Modal -->
                <div class="modal fade" :class="{show: showUserModal}" :style="{display: showUserModal ? 'block' : 'none'}" tabindex="-1">
                    <div class="modal-dialog">
                        <div class="modal-content">
                            <div class="modal-header">
                                <h5 class="modal-title">[[ editingUser ? '编辑用户' : '添加用户' ]]</h5>
                                <button type="button" class="btn-close" @click="showUserModal=false"></button>
                            </div>
                            <div class="modal-body">
                                <div class="mb-3">
                                    <label class="form-label">用户名 <span class="text-danger">*</span></label>
                                    <input type="text" class="form-control" v-model="userForm.username" :disabled="editingUser" placeholder="SMTP登录用户名">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">密码 <span v-if="!editingUser" class="text-danger">*</span></label>
                                    <input type="password" class="form-control" v-model="userForm.password" :placeholder="editingUser ? '留空则不修改密码' : 'SMTP登录密码'">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">发送限额 (每小时)</label>
                                    <input type="number" class="form-control" v-model.number="userForm.email_limit" min="0" placeholder="0表示无限制">
                                    <div class="form-text">每小时允许发送的邮件数量，0为不限制</div>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">到期时间</label>
                                    <input type="datetime-local" class="form-control" v-model="userForm.expires_at">
                                    <div class="form-text">留空表示永不过期</div>
                                </div>
                                <div class="form-check form-switch">
                                    <input class="form-check-input" type="checkbox" v-model="userForm.enabled" id="userEnabled">
                                    <label class="form-check-label" for="userEnabled">启用账户</label>
                                </div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-secondary" @click="showUserModal=false">取消</button>
                                <button type="button" class="btn btn-primary" @click="saveSmtpUser">[[ editingUser ? '保存' : '添加' ]]</button>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="modal-backdrop fade" :class="{show: showUserModal}" :style="{display: showUserModal ? 'block' : 'none'}" @click="showUserModal=false"></div>

                <!-- Batch Generate Modal -->
                <div class="modal fade" :class="{show: showBatchUserModal}" :style="{display: showBatchUserModal ? 'block' : 'none'}" tabindex="-1">
                    <div class="modal-dialog">
                        <div class="modal-content">
                            <div class="modal-header">
                                <h5 class="modal-title">批量生成用户</h5>
                                <button type="button" class="btn-close" @click="showBatchUserModal=false"></button>
                            </div>
                            <div class="modal-body">
                                <div class="mb-3">
                                    <label class="form-label">用户类型 <span class="text-danger">*</span></label>
                                    <select class="form-select" v-model="batchUserForm.type">
                                        <option value="free">免费用户 (限额: [[ config.user_limits?.free || 10 ]] 封/小时)</option>
                                        <option value="monthly">月度用户 (限额: [[ config.user_limits?.monthly || 100 ]] 封/小时)</option>
                                        <option value="quarterly">季度用户 (限额: [[ config.user_limits?.quarterly || 500 ]] 封/小时)</option>
                                        <option value="yearly">年度用户 (限额: [[ config.user_limits?.yearly || 1000 ]] 封/小时)</option>
                                    </select>
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">生成数量 <span class="text-danger">*</span></label>
                                    <input type="number" class="form-control" v-model.number="batchUserForm.count" min="1" max="1000" placeholder="输入生成数量 (1-1000)">
                                </div>
                                <div class="mb-3">
                                    <label class="form-label">用户名前缀</label>
                                    <input type="text" class="form-control" v-model="batchUserForm.prefix" placeholder="留空使用默认前缀 (user_)">
                                </div>
                                <div class="alert alert-info small mb-0">
                                    <i class="bi bi-info-circle me-1"></i>
                                    生成后将自动下载包含用户名和密码的 CSV 文件。
                                    <br>用户有效期: 免费=永久, 月度=30天, 季度=90天, 年度=365天
                                </div>
                            </div>
                            <div class="modal-footer">
                                <button type="button" class="btn btn-secondary" @click="showBatchUserModal=false">取消</button>
                                <button type="button" class="btn btn-primary" @click="batchGenerateUsers" :disabled="batchGenerating">
                                    <span v-if="batchGenerating" class="spinner-border spinner-border-sm me-1"></span>
                                    生成并下载
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="modal-backdrop fade" :class="{show: showBatchUserModal}" :style="{display: showBatchUserModal ? 'block' : 'none'}" @click="showBatchUserModal=false"></div>
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
                            </div>
                        </div>
                    </div>

                    <div class="col-12">
                        <div class="card">
                            <div class="card-header">用户套餐限额配置</div>
                            <div class="card-body">
                                <div class="row g-3">
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">免费用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.free" class="form-control" placeholder="10">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">月度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.monthly" class="form-control" placeholder="100">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">季度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.quarterly" class="form-control" placeholder="500">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">年度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.yearly" class="form-control" placeholder="1000">
                                    </div>
                                </div>
                                <div class="form-text mt-2">批量生成用户时将使用这些每小时发送限额</div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Nodes Tab -->
            <div v-if="tab=='nodes'" class="fade-in" style="padding-bottom: 80px;">
                <div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
                    <div class="d-flex align-items-center gap-3">
                        <h4 class="fw-bold mb-0">下游节点池</h4>
                        <span class="badge bg-secondary">[[ filteredNodes.length ]] / [[ config.downstream_pool.length ]]</span>
                    </div>
                    <div class="d-flex gap-2 flex-wrap">
                        <!-- 搜索框 -->
                        <div class="input-group input-group-sm" style="width: 200px;">
                            <span class="input-group-text"><i class="bi bi-search"></i></span>
                            <input v-model="nodeSearch" class="form-control" placeholder="搜索节点..." @input="nodeGroupFilter = ''">
                            <button v-if="nodeSearch" class="btn btn-outline-secondary" @click="nodeSearch = ''" type="button"><i class="bi bi-x"></i></button>
                        </div>
                        <!-- 视图切换 -->
                        <div class="btn-group btn-group-sm">
                            <button class="btn" :class="nodeViewMode === 'card' ? 'btn-primary' : 'btn-outline-secondary'" @click="nodeViewMode = 'card'" title="卡片视图"><i class="bi bi-grid-3x3-gap"></i></button>
                            <button class="btn" :class="nodeViewMode === 'table' ? 'btn-primary' : 'btn-outline-secondary'" @click="nodeViewMode = 'table'" title="表格视图"><i class="bi bi-table"></i></button>
                        </div>
                        <button class="btn btn-sm btn-outline-secondary" @click="showGroupModal = true" title="管理分组"><i class="bi bi-folder-plus"></i></button>
                        <button class="btn btn-sm btn-outline-secondary" @click="autoRenameNodes" title="自动命名 (分组-域名)"><i class="bi bi-tag"></i> 自动命名</button>
                        <button class="btn btn-sm btn-outline-primary" @click="addNode"><i class="bi bi-plus-lg"></i> 添加</button>
                        <button class="btn btn-sm btn-primary" @click="save" :disabled="saving">
                            <span v-if="saving" class="spinner-border spinner-border-sm me-1"></span>
                            <i v-else class="bi bi-save"></i> 保存
                        </button>
                    </div>
                </div>

                <!-- Group Filter Tabs with colors -->
                <div class="mb-3">
                    <div class="d-flex flex-wrap gap-2 align-items-center">
                        <button class="btn btn-sm" :class="nodeGroupFilter === '' && !nodeSearch ? 'btn-dark' : 'btn-outline-secondary'" @click="nodeGroupFilter = ''; nodeSearch = ''">
                            全部 <span class="badge bg-light text-dark ms-1">[[ config.downstream_pool.length ]]</span>
                        </button>
                        <button class="btn btn-sm" :class="nodeGroupFilter === '__ungrouped__' ? 'btn-secondary' : 'btn-outline-secondary'" @click="nodeGroupFilter = '__ungrouped__'; nodeSearch = ''">
                            <i class="bi bi-folder"></i> 未分组 <span class="badge bg-light text-dark ms-1">[[ ungroupedNodeCount ]]</span>
                        </button>
                        <button v-for="(g, gi) in config.node_groups" :key="g" class="btn btn-sm" 
                            :class="nodeGroupFilter === g ? 'text-white' : ''" 
                            :style="nodeGroupFilter === g ? 'background-color:' + getGroupColor(gi) + ';border-color:' + getGroupColor(gi) : 'border-color:' + getGroupColor(gi) + ';color:' + getGroupColor(gi)" 
                            @click="nodeGroupFilter = g; nodeSearch = ''">
                            <i class="bi bi-folder-fill"></i> [[ g ]] <span class="badge bg-light text-dark ms-1">[[ nodeCountByGroup(g) ]]</span>
                        </button>
                        <button v-if="!config.node_groups || config.node_groups.length === 0" class="btn btn-sm btn-outline-secondary" @click="showGroupModal = true">
                            <i class="bi bi-plus"></i> 添加分组
                        </button>
                    </div>
                </div>

                <!-- Group Management Modal -->
                <div class="modal fade" :class="{show: showGroupModal}" :style="{display: showGroupModal ? 'block' : 'none'}" tabindex="-1" @click.self="showGroupModal = false">
                    <div class="modal-dialog modal-dialog-centered">
                        <div class="modal-content">
                            <div class="modal-header">
                                <h5 class="modal-title"><i class="bi bi-folder"></i> 分组管理</h5>
                                <button type="button" class="btn-close" @click="showGroupModal = false"></button>
                            </div>
                            <div class="modal-body">
                                <div class="mb-3">
                                    <label class="form-label">添加新分组</label>
                                    <div class="input-group">
                                        <input v-model="newGroupName" class="form-control" placeholder="输入分组名称" @keyup.enter="addNodeGroup">
                                        <button class="btn btn-primary" @click="addNodeGroup" :disabled="!newGroupName.trim()">添加</button>
                                    </div>
                                </div>
                                <div v-if="config.node_groups && config.node_groups.length > 0">
                                    <label class="form-label">现有分组</label>
                                    <ul class="list-group">
                                        <li v-for="(g, idx) in config.node_groups" :key="idx" class="list-group-item d-flex justify-content-between align-items-center">
                                            <div class="d-flex align-items-center gap-2 flex-grow-1">
                                                <i class="bi bi-folder-fill text-warning"></i>
                                                <template v-if="editingGroupIndex === idx">
                                                    <input v-model="config.node_groups[idx]" class="form-control form-control-sm" style="max-width: 200px;" @keyup.enter="editingGroupIndex = null" @blur="editingGroupIndex = null">
                                                </template>
                                                <template v-else>
                                                    <span>[[ g ]]</span>
                                                    <span class="badge bg-secondary">[[ nodeCountByGroup(g) ]] 节点</span>
                                                </template>
                                            </div>
                                            <div class="d-flex gap-1">
                                                <button class="btn btn-sm btn-outline-primary py-0 px-2" @click="editingGroupIndex = idx" title="重命名"><i class="bi bi-pencil"></i></button>
                                                <button class="btn btn-sm btn-outline-danger py-0 px-2" @click="deleteNodeGroup(idx)" title="删除分组"><i class="bi bi-trash"></i></button>
                                            </div>
                                        </li>
                                    </ul>
                                </div>
                                <div v-else class="text-muted text-center py-3">暂无分组</div>
                            </div>
                            <div class="modal-footer">
                                <button class="btn btn-secondary" @click="showGroupModal = false">关闭</button>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="modal-backdrop fade" :class="{show: showGroupModal}" :style="{display: showGroupModal ? 'block' : 'none'}" @click="showGroupModal = false"></div>

                <!-- Table View -->
                <div v-if="nodeViewMode === 'table'" class="card">
                    <div class="table-responsive">
                        <table class="table table-hover table-sm mb-0 align-middle">
                            <thead class="table-light">
                                <tr>
                                    <th style="width: 40px;"><input type="checkbox" class="form-check-input" @change="toggleSelectAllNodes($event)" :checked="batchSelectedCount === searchedNodes.length && searchedNodes.length > 0"></th>
                                    <th>节点名称</th>
                                    <th>分组</th>
                                    <th>Host</th>
                                    <th style="width: 80px;">状态</th>
                                    <th style="width: 100px;">速度</th>
                                    <th style="width: 80px;">群发</th>
                                    <th style="width: 100px;">操作</th>
                                </tr>
                            </thead>
                            <tbody>
                                <tr v-if="searchedNodes.length === 0">
                                    <td colspan="8" class="text-center text-muted py-4">暂无节点</td>
                                </tr>
                                <tr v-for="n in searchedNodes" :key="getNodeIndex(n)" :class="{'table-secondary': !n.enabled}">
                                    <td><input type="checkbox" class="form-check-input" v-model="n.batchSelected"></td>
                                    <td>
                                        <span class="fw-bold">[[ n.name ]]</span>
                                        <a href="#" class="ms-2 text-muted small" @click.prevent="n.expanded = true; nodeViewMode = 'card'" title="编辑"><i class="bi bi-pencil"></i></a>
                                    </td>
                                    <td>
                                        <span v-if="n.group" class="badge" :style="'background-color:' + getGroupColor(config.node_groups.indexOf(n.group))">[[ n.group ]]</span>
                                        <span v-else class="text-muted small">-</span>
                                    </td>
                                    <td class="small text-muted">[[ n.host ]]:[[ n.port ]]</td>
                                    <td>
                                        <div class="form-check form-switch mb-0">
                                            <input class="form-check-input" type="checkbox" v-model="n.enabled">
                                        </div>
                                    </td>
                                    <td class="small">[[ n.max_per_hour || '∞' ]]/h</td>
                                    <td>
                                        <div class="form-check form-switch mb-0">
                                            <input class="form-check-input" :class="n.allow_bulk ? 'bg-warning border-warning' : ''" type="checkbox" v-model="n.allow_bulk">
                                        </div>
                                    </td>
                                    <td>
                                        <div class="btn-group btn-group-sm">
                                            <button class="btn btn-outline-secondary py-0 px-1" @click="copyNode(getNodeIndex(n))" title="复制"><i class="bi bi-copy"></i></button>
                                            <button class="btn btn-outline-danger py-0 px-1" @click="delNode(getNodeIndex(n))" title="删除"><i class="bi bi-trash"></i></button>
                                        </div>
                                    </td>
                                </tr>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- Card View -->
                <div v-if="nodeViewMode === 'card'">
                    <div v-if="searchedNodes.length === 0" class="text-center py-5 text-muted">
                        <i class="bi bi-inbox" style="font-size: 3rem;"></i>
                        <p class="mt-2" v-if="nodeSearch">未找到匹配"[[ nodeSearch ]]"的节点</p>
                        <p class="mt-2" v-else-if="nodeGroupFilter">当前分组暂无节点</p>
                        <p class="mt-2" v-else>暂无节点，点击上方"添加"按钮创建</p>
                    </div>
                    <div class="row g-2">
                        <div v-for="(n, i) in searchedNodes" :key="getNodeIndex(n)" class="col-sm-6 col-lg-4 col-xl-3 col-xxl-2"
                             @dragover.prevent="onDragOver($event, getNodeIndex(n))"
                             @drop="onDrop($event, getNodeIndex(n))"
                             :class="{'drag-over': dragOverIndex === getNodeIndex(n) && draggingIndex !== getNodeIndex(n)}">
                            <!-- Card with colored left border for group -->
                            <div class="card h-100 shadow-sm position-relative overflow-hidden" 
                                 :style="(draggingIndex === getNodeIndex(n) ? 'opacity: 0.5;' : '') + (n.group ? 'border-left: 4px solid ' + getGroupColor(config.node_groups.indexOf(n.group)) : 'border-left: 4px solid #dee2e6')">
                                <div class="card-header py-2 px-2 bg-transparent">
                                    <!-- Node name row -->
                                    <div class="d-flex justify-content-between align-items-center" style="cursor:pointer;" @click="n.expanded = !n.expanded">
                                        <div class="d-flex align-items-center gap-1 flex-grow-1" style="min-width: 0;">
                                            <input type="checkbox" v-model="n.batchSelected" class="form-check-input" style="width: 1em; height: 1em;" @click.stop title="选择此节点">
                                            <i class="bi text-muted small" :class="n.expanded ? 'bi-chevron-down' : 'bi-chevron-right'"></i>
                                            <span class="fw-bold small text-truncate" :title="n.name" :class="{'text-muted': !n.enabled}">[[ n.name ]]</span>
                                        </div>
                                        <div class="d-flex align-items-center gap-1" @click.stop>
                                            <span class="badge" :class="n.enabled ? 'bg-success' : 'bg-secondary'" style="font-size: 0.65rem;">[[ n.enabled ? 'ON' : 'OFF' ]]</span>
                                            <div class="dropdown">
                                                <button class="btn btn-sm btn-link text-muted p-0" data-bs-toggle="dropdown"><i class="bi bi-three-dots-vertical"></i></button>
                                                <ul class="dropdown-menu dropdown-menu-end">
                                                    <li><a class="dropdown-item small" href="#" @click.prevent="n.enabled = !n.enabled"><i class="bi" :class="n.enabled ? 'bi-pause' : 'bi-play'"></i> [[ n.enabled ? '禁用' : '启用' ]]</a></li>
                                                    <li><a class="dropdown-item small" href="#" @click.prevent="copyNode(getNodeIndex(n))"><i class="bi bi-copy"></i> 复制</a></li>
                                                    <li><hr class="dropdown-divider"></li>
                                                    <li><a class="dropdown-item small text-danger" href="#" @click.prevent="delNode(getNodeIndex(n))"><i class="bi bi-trash"></i> 删除</a></li>
                                                </ul>
                                            </div>
                                        </div>
                                    </div>
                                    <!-- Quick info row -->
                                    <div class="d-flex align-items-center gap-2 mt-1 small text-muted">
                                        <span title="发送速度"><i class="bi bi-speedometer2"></i> [[ n.max_per_hour || '∞' ]]/h</span>
                                        <span v-if="n.allow_bulk" class="badge bg-warning-subtle text-warning" style="font-size: 0.6rem;">群发</span>
                                        <span v-if="n.routing_rules" class="badge bg-danger-subtle text-danger" style="font-size: 0.6rem;" :title="'排除: ' + n.routing_rules">排除[[ n.routing_rules.split(',').length ]]</span>
                                    </div>
                                </div>
                                    <!-- Collapsed quick edit -->
                                    <div class="card-body py-2 px-3 border-top" v-show="!n.expanded" style="background: var(--hover-bg);">
                                        <div class="row g-2">
                                            <div class="col-12">
                                                <div class="d-flex align-items-center gap-2">
                                                    <span class="text-muted small"><i class="bi bi-speedometer2"></i></span>
                                                    <input v-model.number="n.max_per_hour" type="number" class="form-control form-control-sm" style="width: 70px;" placeholder="0" title="Max/Hr">
                                                    <span class="text-muted small">/h</span>
                                                    <input v-model.number="n.min_interval" type="number" class="form-control form-control-sm" style="width: 50px;" placeholder="1" title="Min(s)">
                                                    <span class="text-muted small">~</span>
                                                    <input v-model.number="n.max_interval" type="number" class="form-control form-control-sm" style="width: 50px;" placeholder="5" title="Max(s)">
                                                    <span class="text-muted small">s</span>
                                                </div>
                                            </div>
                                            <div class="col-12">
                                                <div class="d-flex align-items-center gap-1 flex-wrap">
                                                    <span class="text-muted small me-1" title="选中的域名将不会通过此节点发送"><i class="bi bi-signpost-split"></i>排除:</span>
                                                    <button class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="(!n.routing_rules)?'btn-success':'btn-outline-secondary'" @click="n.routing_rules=''" title="不排除任何域名">全部</button>
                                                    <template v-for="d in topDomains" :key="d.domain">
                                                        <button v-if="d.domain !== '__other__'" class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="hasDomain(n, d.domain)?'btn-danger':'btn-outline-secondary'" @click="toggleDomain(n, d.domain)" :title="hasDomain(n, d.domain)?'点击取消排除 '+d.domain:'点击排除 '+d.domain">[[ formatDomainLabel(d.domain) ]]</button>
                                                        <button v-else class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="hasAllOtherDomains(n, d.domains)?'btn-danger':'btn-outline-secondary'" @click="toggleOtherDomains(n, d.domains)" :title="d.count + '封 (' + (d.domains||[]).length + '个域名)'">其他</button>
                                                    </template>
                                                </div>
                                            </div>
                                        </div>
                                    </div>
                                    <div class="card-body" v-show="n.expanded">
                                        <div class="row g-2">
                                            <div class="col-8">
                                                <label class="small text-muted">备注名称</label>
                                                <input v-model="n.name" class="form-control form-control-sm" placeholder="备注">
                                            </div>
                                            <div class="col-4">
                                                <label class="small text-muted">分组</label>
                                                <select v-model="n.group" class="form-select form-select-sm">
                                                    <option value="">未分组</option>
                                                    <option v-for="g in config.node_groups" :key="g" :value="g">[[ g ]]</option>
                                                </select>
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
                                                <label class="small text-muted">Sender Domain</label>
                                                <input v-model="n.sender_domain" class="form-control form-control-sm" placeholder="域名，如 mail.example.com">
                                            </div>
                                            <div class="col-6">
                                                <label class="small text-muted">Sender Prefix</label>
                                                <div class="input-group input-group-sm">
                                                    <div class="input-group-text">
                                                        <input type="checkbox" v-model="n.sender_random" class="form-check-input mt-0" title="随机生成">
                                                        <span class="ms-1 small">随机</span>
                                                    </div>
                                                    <input v-model="n.sender_prefix" class="form-control" placeholder="如 mail" :disabled="n.sender_random">
                                                </div>
                                                <div class="small text-muted mt-1" v-if="n.sender_domain">
                                                    预览: [[ n.sender_random ? '(6位随机)' : (n.sender_prefix || 'mail') ]]@[[ n.sender_domain ]]
                                                </div>
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
                                                <label class="small text-muted">排除规则 <span class="text-danger">(选中的域名不发送)</span></label>
                                                <div class="d-flex flex-wrap gap-1 mb-1">
                                                    <button class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="(!n.routing_rules)?'btn-success':'btn-outline-secondary'" @click="n.routing_rules=''" title="不排除任何域名">全部</button>
                                                    <template v-for="d in topDomains" :key="d.domain">
                                                        <button v-if="d.domain !== '__other__'" class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="hasDomain(n, d.domain)?'btn-danger':'btn-outline-secondary'" @click="toggleDomain(n, d.domain)" :title="d.count + '封'">[[ formatDomainLabel(d.domain) ]]</button>
                                                        <button v-else class="btn btn-sm py-0 px-1" style="font-size: 0.7rem;" :class="hasAllOtherDomains(n, d.domains)?'btn-danger':'btn-outline-secondary'" @click="toggleOtherDomains(n, d.domains)" :title="d.count + '封 (' + (d.domains||[]).length + '个域名)'">其他</button>
                                                    </template>
                                                    <span v-if="topDomains.length === 0" class="text-muted small">暂无数据</span>
                                                </div>
                                                <input v-model="n.routing_rules" class="form-control form-control-sm" placeholder="排除的域名，逗号分隔...">
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Fixed Bottom Batch Edit Toolbar -->
                <div v-if="batchSelectedCount > 0" class="position-fixed bottom-0 start-0 end-0 bg-dark text-white p-2 shadow-lg" style="z-index: 1050;">
                    <div class="container-fluid">
                        <div class="d-flex align-items-center justify-content-between flex-wrap gap-2">
                            <div class="d-flex align-items-center gap-2">
                                <span class="badge bg-primary">[[ batchSelectedCount ]] 个已选</span>
                                <button class="btn btn-sm btn-outline-light" @click="batchSelectAll">全选</button>
                                <button class="btn btn-sm btn-outline-light" @click="batchSelectNone">取消</button>
                            </div>
                            <div class="d-flex align-items-center gap-3 flex-wrap">
                                <!-- 批量速度 -->
                                <div class="d-flex align-items-center gap-1">
                                    <span class="small"><i class="bi bi-speedometer2"></i></span>
                                    <input v-model.number="batchEdit.max_per_hour" type="number" class="form-control form-control-sm bg-dark text-white border-secondary" style="width: 60px;" placeholder="/h">
                                </div>
                                <!-- 批量间隔 -->
                                <div class="d-flex align-items-center gap-1">
                                    <span class="small"><i class="bi bi-clock"></i></span>
                                    <input v-model.number="batchEdit.min_interval" type="number" class="form-control form-control-sm bg-dark text-white border-secondary" style="width: 50px;" placeholder="最小">
                                    <span class="small">-</span>
                                    <input v-model.number="batchEdit.max_interval" type="number" class="form-control form-control-sm bg-dark text-white border-secondary" style="width: 50px;" placeholder="最大">
                                    <span class="small text-muted">秒</span>
                                </div>
                                <button class="btn btn-sm btn-outline-light" @click="applyBatchSpeed">应用速度/间隔</button>
                                <!-- 批量分组 -->
                                <div class="d-flex align-items-center gap-1" v-if="config.node_groups && config.node_groups.length > 0">
                                    <span class="small"><i class="bi bi-folder"></i></span>
                                    <select v-model="batchEdit.group" class="form-select form-select-sm bg-dark text-white border-secondary" style="width: 100px;">
                                        <option value="">未分组</option>
                                        <option v-for="g in config.node_groups" :key="g" :value="g">[[ g ]]</option>
                                    </select>
                                    <button class="btn btn-sm btn-outline-light" @click="applyBatchGroup">应用</button>
                                </div>
                                <!-- 批量启用/禁用 -->
                                <div class="btn-group btn-group-sm">
                                    <button class="btn btn-outline-success" @click="batchSetEnabled(true)"><i class="bi bi-play"></i> 全部启用</button>
                                    <button class="btn btn-outline-warning" @click="batchSetEnabled(false)"><i class="bi bi-pause"></i> 全部禁用</button>
                                </div>
                                <!-- 批量删除 -->
                                <button class="btn btn-sm btn-danger" @click="batchDeleteNodes"><i class="bi bi-trash"></i> 删除</button>
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
                            </div>
                        </div>
                    </div>

                    <div class="col-12">
                        <div class="card">
                            <div class="card-header">用户套餐限额配置</div>
                            <div class="card-body">
                                <div class="row g-3">
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">免费用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.free" class="form-control" placeholder="10">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">月度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.monthly" class="form-control" placeholder="100">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">季度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.quarterly" class="form-control" placeholder="500">
                                    </div>
                                    <div class="col-md-3 col-6">
                                        <label class="form-label">年度用户 (封/小时)</label>
                                        <input type="number" v-model.number="config.user_limits.yearly" class="form-control" placeholder="1000">
                                    </div>
                                </div>
                                <div class="form-text mt-2">批量生成用户时将使用这些每小时发送限额</div>
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
                    queueFilter: '',
                    bulk: { sender: '', subject: '', recipients: '', body: '', bodyList: [''], enableSchedule: false, scheduledAt: '' },
                    sending: false,
                    contactCount: 0,
                    bulkStatus: 'running',
                    rebalancing: false,
                    nodeChanges: {},  // Track pending count changes per node
                    liveLogs: [],  // Real-time logs
                    liveLogsEnabled: true,  // Auto-refresh logs
                    logAtTop: true,  // Whether log container is scrolled to top
                    logTimer: null,  // Log refresh timer
                    theme: 'auto',
                    draggingIndex: null,
                    dragOverIndex: null,
                    topDomains: [],
                    showBatchEdit: false,
                    batchEdit: { max_per_hour: null, min_interval: null, max_interval: null, routing_rules: '', group: '' },
                    shufflingContacts: false,
                    removeEmail: '',
                    removeDomain: '',
                    contactDomainStats: [],
                    domainSelectMode: false,
                    selectedDomains: [],
                    smallDomainThreshold: 10,
                    smtpUsers: [],
                    showUserModal: false,
                    editingUser: null,
                    userForm: { username: '', password: '', email_limit: 0, expires_at: '', enabled: true },
                    showBatchUserModal: false,
                    batchUserForm: { type: 'monthly', count: 10, prefix: '' },
                    batchGenerating: false,
                    nodeGroupFilter: '',
                    showGroupModal: false,
                    newGroupName: '',
                    editingGroupIndex: null,
                    nodeSearch: '',
                    nodeViewMode: 'card'
                }
            },
            computed: {
                filteredQList() {
                    if (!this.queueFilter) return this.qList;
                    return this.qList.filter(m => m.status === this.queueFilter);
                },
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
                recipientDomainStats() {
                    if (!this.bulk.recipients) return [];
                    const emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                    const domainCounts = {};
                    emails.forEach(e => {
                        const parts = e.trim().split('@');
                        if (parts.length === 2) {
                            const domain = parts[1].toLowerCase();
                            domainCounts[domain] = (domainCounts[domain] || 0) + 1;
                        }
                    });
                    return Object.entries(domainCounts)
                        .map(([domain, count]) => ({ domain, count }))
                        .sort((a, b) => b.count - a.count)
                        .slice(0, 15);
                },
                batchSelectedCount() {
                    return this.config.downstream_pool.filter(n => n.batchSelected).length;
                },
                totalMails() {
                    const t = this.qStats.total;
                    return (t.pending||0) + (t.processing||0) + (t.sent||0) + (t.failed||0) + (t.scheduled||0);
                },
                progressPercent() {
                    if(this.totalMails === 0) return 0;
                    return Math.round(((this.qStats.total.sent||0) / this.totalMails) * 100);
                },
                isFinished() {
                    const t = this.qStats.total;
                    return this.totalMails > 0 && (t.pending||0) === 0 && (t.processing||0) === 0 && (t.scheduled||0) === 0;
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
                },
                filteredNodes() {
                    if (!this.nodeGroupFilter) return this.config.downstream_pool;
                    if (this.nodeGroupFilter === '__ungrouped__') {
                        return this.config.downstream_pool.filter(n => !n.group);
                    }
                    return this.config.downstream_pool.filter(n => n.group === this.nodeGroupFilter);
                },
                ungroupedNodeCount() {
                    return this.config.downstream_pool.filter(n => !n.group).length;
                },
                searchedNodes() {
                    let nodes = this.filteredNodes;
                    if (this.nodeSearch) {
                        const s = this.nodeSearch.toLowerCase();
                        nodes = this.config.downstream_pool.filter(n => 
                            n.name.toLowerCase().includes(s) || 
                            n.host.toLowerCase().includes(s) ||
                            (n.group && n.group.toLowerCase().includes(s))
                        );
                    }
                    return nodes;
                }
            },
            mounted() {
                if(!this.config.limit_config) this.config.limit_config = { max_per_hour: 0, min_interval: 1, max_interval: 5 };
                if(!this.config.log_config) this.config.log_config = { max_mb: 50, backups: 3, retention_days: 7 };
                if(!this.config.user_limits) this.config.user_limits = { free: 10, monthly: 100, quarterly: 500, yearly: 1000 };
                if(!this.config.node_groups) this.config.node_groups = [];
                this.config.downstream_pool.forEach(n => { 
                    if(n.enabled === undefined) n.enabled = true; 
                    if(n.allow_bulk === undefined) n.allow_bulk = true;
                    if(n.group === undefined) n.group = '';
                    n.expanded = false; // Always start collapsed on page load
                });
                
                // Auto-load draft
                this.loadDraft();
                
                // Load theme
                const savedTheme = localStorage.getItem('theme') || 'auto';
                this.setTheme(savedTheme);

                this.fetchQueue();
                this.fetchContactCount();
                this.fetchContactDomainStats();
                this.fetchBulkStatus();
                this.fetchTopDomains();
                this.startLogTimer();  // 启动实时日志
                setInterval(() => {
                    this.fetchQueue();
                    this.fetchBulkStatus();
                }, 5000);
                // Refresh domain stats less frequently (every 30 seconds)
                setInterval(() => {
                    this.fetchTopDomains();
                }, 30000);
            },
            watch: {
                bulk: {
                    handler(v) { this.debouncedSaveDraft(); },
                    deep: true
                }
            },
            methods: {
                getGroupColor(index) {
                    const colors = ['#6366f1', '#f59e0b', '#10b981', '#ef4444', '#8b5cf6', '#06b6d4', '#ec4899', '#84cc16'];
                    if (index < 0) return '#6c757d';
                    return colors[index % colors.length];
                },
                toggleSelectAllNodes(e) {
                    const checked = e.target.checked;
                    this.searchedNodes.forEach(n => n.batchSelected = checked);
                },
                batchSetEnabled(enabled) {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    if (selected.length === 0) return;
                    selected.forEach(n => n.enabled = enabled);
                },
                batchDeleteNodes() {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    if (selected.length === 0) return;
                    if (!confirm(`确定删除选中的 ${selected.length} 个节点？`)) return;
                    selected.forEach(n => {
                        const idx = this.config.downstream_pool.indexOf(n);
                        if (idx !== -1) this.config.downstream_pool.splice(idx, 1);
                    });
                },
                getNodeIndex(node) {
                    return this.config.downstream_pool.indexOf(node);
                },
                nodeCountByGroup(groupName) {
                    return this.config.downstream_pool.filter(n => n.group === groupName).length;
                },
                addNodeGroup() {
                    const name = this.newGroupName.trim();
                    if (!name) return;
                    if (!this.config.node_groups) this.config.node_groups = [];
                    if (this.config.node_groups.includes(name)) {
                        alert('分组名称已存在');
                        return;
                    }
                    this.config.node_groups.push(name);
                    this.newGroupName = '';
                },
                deleteNodeGroup(idx) {
                    const groupName = this.config.node_groups[idx];
                    const count = this.nodeCountByGroup(groupName);
                    if (count > 0) {
                        if (!confirm(`该分组下有 ${count} 个节点，删除分组后这些节点将变为"未分组"，确定继续？`)) return;
                        this.config.downstream_pool.forEach(n => {
                            if (n.group === groupName) n.group = '';
                        });
                    }
                    this.config.node_groups.splice(idx, 1);
                    if (this.nodeGroupFilter === groupName) this.nodeGroupFilter = '';
                },
                nodeExists(name) {
                    const nodeNames = new Set(this.config.downstream_pool.map(n => n.name));
                    return nodeNames.has(name);
                },
                async fetchSmtpUsers() {
                    try {
                        const res = await fetch('/api/smtp-users');
                        this.smtpUsers = await res.json();
                    } catch(e) { console.error("Failed to fetch users", e); }
                },
                showAddUserModal() {
                    this.editingUser = null;
                    this.userForm = { username: '', password: '', email_limit: 0, expires_at: '', enabled: true };
                    this.showUserModal = true;
                },
                showEditUserModal(u) {
                    this.editingUser = u;
                    this.userForm = { 
                        username: u.username, 
                        password: '', 
                        email_limit: u.email_limit, 
                        expires_at: u.expires_at ? u.expires_at.replace(' ', 'T') : '',
                        enabled: u.enabled 
                    };
                    this.showUserModal = true;
                },
                async saveSmtpUser() {
                    if (!this.userForm.username) { alert('请输入用户名'); return; }
                    if (!this.editingUser && !this.userForm.password) { alert('请输入密码'); return; }
                    try {
                        const payload = { ...this.userForm };
                        if (payload.expires_at) payload.expires_at = payload.expires_at.replace('T', ' ');
                        if (this.editingUser) {
                            await fetch('/api/smtp-users/' + this.editingUser.id, {
                                method: 'PUT',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify(payload)
                            });
                        } else {
                            await fetch('/api/smtp-users', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify(payload)
                            });
                        }
                        this.showUserModal = false;
                        this.fetchSmtpUsers();
                    } catch(e) { alert('保存失败: ' + e.message); }
                },
                async deleteSmtpUser(u) {
                    if (!confirm('确定删除用户 ' + u.username + '?')) return;
                    try {
                        await fetch('/api/smtp-users/' + u.id, { method: 'DELETE' });
                        this.fetchSmtpUsers();
                    } catch(e) { alert('删除失败: ' + e.message); }
                },
                async resetUserCount(u) {
                    if (!confirm('确定重置用户 ' + u.username + ' 的发送计数?')) return;
                    try {
                        await fetch('/api/smtp-users/' + u.id, {
                            method: 'PUT',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ reset_count: true })
                        });
                        this.fetchSmtpUsers();
                    } catch(e) { alert('重置失败: ' + e.message); }
                },
                async batchGenerateUsers() {
                    if (!this.batchUserForm.count || this.batchUserForm.count < 1) {
                        alert('请输入有效的生成数量'); return;
                    }
                    this.batchGenerating = true;
                    try {
                        const res = await fetch('/api/smtp-users/batch', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(this.batchUserForm)
                        });
                        const data = await res.json();
                        if (data.users && data.users.length > 0) {
                            // Generate CSV content
                            const typeNames = { free: '免费用户', monthly: '月度用户', quarterly: '季度用户', yearly: '年度用户' };
                            let csv = 'Username,Password,Type,EmailLimit,ExpiresAt\n';
                            data.users.forEach(u => {
                                csv += `${u.username},${u.password},${typeNames[u.type] || u.type},${u.email_limit},${u.expires_at}\n`;
                            });
                            // Download CSV
                            const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
                            const link = document.createElement('a');
                            link.href = URL.createObjectURL(blob);
                            link.download = `smtp_users_${this.batchUserForm.type}_${new Date().toISOString().slice(0,10)}.csv`;
                            link.click();
                            URL.revokeObjectURL(link.href);
                            
                            alert(`成功生成 ${data.count} 个用户，CSV 文件已下载`);
                            this.showBatchUserModal = false;
                            this.fetchSmtpUsers();
                        } else {
                            alert('生成失败，请重试');
                        }
                    } catch(e) { alert('生成失败: ' + e.message); }
                    this.batchGenerating = false;
                },
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
                async fetchContactDomainStats() {
                    try {
                        const res = await fetch('/api/contacts/domain_stats');
                        this.contactDomainStats = await res.json();
                    } catch(e) { this.contactDomainStats = []; }
                },
                async fetchTopDomains() {
                    try {
                        const res = await fetch('/api/domain/stats');
                        this.topDomains = await res.json();
                    } catch(e) { this.topDomains = []; }
                },
                statusBadgeClass(status) {
                    const map = {
                        'pending': 'bg-warning-subtle text-warning',
                        'processing': 'bg-info-subtle text-info',
                        'sent': 'bg-success-subtle text-success',
                        'failed': 'bg-danger-subtle text-danger',
                        'scheduled': 'bg-primary-subtle text-primary'
                    };
                    return map[status] || 'bg-secondary-subtle text-secondary';
                },
                formatScheduleTime(dateStr) {
                    if (!dateStr) return '';
                    const d = new Date(dateStr);
                    const now = new Date();
                    const diff = d - now;
                    if (diff < 0) return '已过期';
                    const hours = Math.floor(diff / 3600000);
                    const mins = Math.floor((diff % 3600000) / 60000);
                    if (hours > 24) {
                        const days = Math.floor(hours / 24);
                        return `${days}天${hours % 24}小时后`;
                    }
                    if (hours > 0) return `${hours}小时${mins}分钟后`;
                    return `${mins}分钟后`;
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
                async shuffleAllContacts() {
                    if(!confirm(`确定打乱通讯录中的 ${this.contactCount} 个邮箱？\n打乱后分组顺序会重新排列。`)) return;
                    this.shufflingContacts = true;
                    try {
                        const res = await fetch('/api/contacts/shuffle', { method: 'POST' });
                        const data = await res.json();
                        alert(`已打乱 ${data.count} 个邮箱`);
                    } catch(e) { alert('失败: ' + e); }
                    this.shufflingContacts = false;
                },
                downloadAllContacts() {
                    if(this.contactCount === 0) { alert('通讯录为空'); return; }
                    window.location.href = '/api/contacts/download';
                },
                shuffleRecipients() {
                    if (!this.bulk.recipients) return;
                    let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                    // Fisher-Yates shuffle
                    for (let i = emails.length - 1; i > 0; i--) {
                        const j = Math.floor(Math.random() * (i + 1));
                        [emails[i], emails[j]] = [emails[j], emails[i]];
                    }
                    this.bulk.recipients = emails.join('\n');
                },
                removeDomainFromRecipients(domain) {
                    if (!confirm(`确定清除所有 @${domain} 的邮箱吗？`)) return;
                    if (!this.bulk.recipients) return;
                    let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                    const before = emails.length;
                    emails = emails.filter(e => !e.trim().toLowerCase().endsWith('@' + domain.toLowerCase()));
                    this.bulk.recipients = emails.join('\n');
                    alert(`已清除 ${before - emails.length} 个 @${domain} 邮箱`);
                },
                async removeSpecificEmail() {
                    if (!this.removeEmail || !this.removeEmail.trim()) return;
                    const target = this.removeEmail.trim();
                    if (!confirm(`确定从通讯录中删除 ${target} 吗？`)) return;
                    try {
                        const res = await fetch('/api/contacts/remove', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ email: target })
                        });
                        const data = await res.json();
                        if (data.deleted > 0) {
                            alert(`已从通讯录中删除 ${target}`);
                            this.removeEmail = '';
                            this.fetchContactCount();
                            // Also remove from current input if present
                            if (this.bulk.recipients) {
                                let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                                emails = emails.filter(e => e.trim().toLowerCase() !== target.toLowerCase());
                                this.bulk.recipients = emails.join('\n');
                            }
                        } else {
                            alert(`通讯录中未找到 ${target}`);
                        }
                    } catch(e) { alert('失败: ' + e); }
                },
                async removeDomainFromContacts(domainParam) {
                    let domain = domainParam || this.removeDomain;
                    if (!domain || !domain.trim()) return;
                    domain = domain.trim().toLowerCase();
                    if (domain.startsWith('@')) domain = domain.substring(1);
                    if (!confirm(`确定从通讯录中删除所有 @${domain} 的邮箱吗？`)) return;
                    try {
                        const res = await fetch('/api/contacts/remove_domain', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ domain: domain })
                        });
                        // Check for session expiry
                        const ct = res.headers.get("content-type");
                        if (ct && ct.indexOf("application/json") === -1) {
                            alert('会话已过期，请刷新页面重新登录');
                            window.location.reload();
                            return;
                        }
                        const data = await res.json();
                        if (data.deleted > 0) {
                            this.removeDomain = '';
                            this.fetchContactCount();
                            this.fetchContactDomainStats();
                            // Also remove from current input if present
                            if (this.bulk.recipients) {
                                let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                                emails = emails.filter(e => !e.trim().toLowerCase().endsWith('@' + domain));
                                this.bulk.recipients = emails.join('\n');
                            }
                        } else {
                            alert(`通讯录中未找到 @${domain} 的邮箱`);
                        }
                    } catch(e) { alert('失败: ' + e); }
                },
                toggleDomainSelectMode() {
                    this.domainSelectMode = !this.domainSelectMode;
                    if (!this.domainSelectMode) {
                        this.selectedDomains = [];
                    }
                },
                toggleSelectDomain(domain) {
                    const idx = this.selectedDomains.indexOf(domain);
                    if (idx === -1) {
                        this.selectedDomains.push(domain);
                    } else {
                        this.selectedDomains.splice(idx, 1);
                    }
                },
                selectAllDomains() {
                    if (this.selectedDomains.length === this.contactDomainStats.length) {
                        this.selectedDomains = [];
                    } else {
                        this.selectedDomains = this.contactDomainStats.map(ds => ds.domain);
                    }
                },
                async removeSelectedDomains() {
                    if (this.selectedDomains.length === 0) return;
                    const count = this.selectedDomains.length;
                    const totalEmails = this.contactDomainStats
                        .filter(ds => this.selectedDomains.includes(ds.domain))
                        .reduce((sum, ds) => sum + ds.count, 0);
                    if (!confirm(`确定删除 ${count} 个域名的 ${totalEmails} 个邮箱吗？\n\n域名: ${this.selectedDomains.join(', ')}`)) return;
                    try {
                        const res = await fetch('/api/contacts/remove_domains', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ domains: this.selectedDomains })
                        });
                        // Check for session expiry
                        const ct = res.headers.get("content-type");
                        if (ct && ct.indexOf("application/json") === -1) {
                            alert('会话已过期，请刷新页面重新登录');
                            window.location.reload();
                            return;
                        }
                        const data = await res.json();
                        if (data.deleted > 0) {
                            // Also remove from current input if present
                            if (this.bulk.recipients) {
                                let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                                this.selectedDomains.forEach(domain => {
                                    emails = emails.filter(e => !e.trim().toLowerCase().endsWith('@' + domain.toLowerCase()));
                                });
                                this.bulk.recipients = emails.join('\n');
                            }
                            this.selectedDomains = [];
                            this.domainSelectMode = false;
                            this.fetchContactCount();
                            this.fetchContactDomainStats();
                        } else {
                            alert('未删除任何邮箱');
                        }
                    } catch(e) { alert('失败: ' + e); }
                },
                async removeSmallDomains() {
                    const threshold = this.smallDomainThreshold || 10;
                    const smallDomains = this.contactDomainStats.filter(ds => ds.count < threshold);
                    if (smallDomains.length === 0) {
                        alert(`没有数量小于 ${threshold} 的域名`);
                        return;
                    }
                    const totalEmails = smallDomains.reduce((sum, ds) => sum + ds.count, 0);
                    if (!confirm(`确定删除数量小于 ${threshold} 的 ${smallDomains.length} 个域名（共 ${totalEmails} 个邮箱）吗？`)) return;
                    try {
                        const res = await fetch('/api/contacts/remove_small_domains', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ threshold: threshold })
                        });
                        // Check for session expiry
                        const ct = res.headers.get("content-type");
                        if (ct && ct.indexOf("application/json") === -1) {
                            alert('会话已过期，请刷新页面重新登录');
                            window.location.reload();
                            return;
                        }
                        const data = await res.json();
                        if (data.deleted > 0) {
                            // Also remove from current input if present
                            if (this.bulk.recipients) {
                                let emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                                smallDomains.forEach(ds => {
                                    emails = emails.filter(e => !e.trim().toLowerCase().endsWith('@' + ds.domain.toLowerCase()));
                                });
                                this.bulk.recipients = emails.join('\n');
                            }
                            this.fetchContactCount();
                            this.fetchContactDomainStats();
                        } else {
                            alert('未删除任何邮箱');
                        }
                    } catch(e) { alert('失败: ' + e); }
                },
                downloadRecipients() {
                    if (!this.bulk.recipients) { alert('没有收件人可下载'); return; }
                    const emails = this.bulk.recipients.split('\n').filter(r => r.trim());
                    const blob = new Blob([emails.join('\n')], { type: 'text/plain' });
                    const url = URL.createObjectURL(blob);
                    const a = document.createElement('a');
                    a.href = url;
                    a.download = 'recipients_' + new Date().toISOString().slice(0, 10) + '.txt';
                    document.body.appendChild(a);
                    a.click();
                    document.body.removeChild(a);
                    URL.revokeObjectURL(url);
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
                toggleOtherDomains(n, domains) {
                    if(!domains || domains.length === 0) return;
                    let rules = n.routing_rules ? n.routing_rules.split(',').map(x=>x.trim()).filter(x=>x) : [];
                    // Check if all other domains are already selected
                    const allSelected = domains.every(d => rules.includes(d));
                    if(allSelected) {
                        // Remove all other domains
                        rules = rules.filter(x => !domains.includes(x));
                    } else {
                        // Add all other domains
                        domains.forEach(d => {
                            if(!rules.includes(d)) rules.push(d);
                        });
                    }
                    n.routing_rules = rules.join(',');
                },
                hasAllOtherDomains(n, domains) {
                    if(!domains || domains.length === 0 || !n.routing_rules) return false;
                    const rules = n.routing_rules.split(',').map(x=>x.trim());
                    return domains.every(d => rules.includes(d));
                },
                // Batch edit methods
                batchSelectAll() {
                    this.config.downstream_pool.forEach(n => n.batchSelected = true);
                },
                batchSelectNone() {
                    this.config.downstream_pool.forEach(n => n.batchSelected = false);
                },
                batchSelectEnabled() {
                    this.config.downstream_pool.forEach(n => n.batchSelected = n.enabled);
                },
                batchHasDomain(d) {
                    if(!this.batchEdit.routing_rules) return false;
                    return this.batchEdit.routing_rules.split(',').map(x=>x.trim()).includes(d);
                },
                batchToggleDomain(d) {
                    let rules = this.batchEdit.routing_rules ? this.batchEdit.routing_rules.split(',').map(x=>x.trim()).filter(x=>x) : [];
                    if(rules.includes(d)) {
                        rules = rules.filter(x=>x!==d);
                    } else {
                        rules.push(d);
                    }
                    this.batchEdit.routing_rules = rules.join(',');
                },
                batchHasAllOther(domains) {
                    if(!domains || domains.length === 0 || !this.batchEdit.routing_rules) return false;
                    const rules = this.batchEdit.routing_rules.split(',').map(x=>x.trim());
                    return domains.every(d => rules.includes(d));
                },
                batchToggleOther(domains) {
                    if(!domains || domains.length === 0) return;
                    let rules = this.batchEdit.routing_rules ? this.batchEdit.routing_rules.split(',').map(x=>x.trim()).filter(x=>x) : [];
                    const allSelected = domains.every(d => rules.includes(d));
                    if(allSelected) {
                        rules = rules.filter(x => !domains.includes(x));
                    } else {
                        domains.forEach(d => { if(!rules.includes(d)) rules.push(d); });
                    }
                    this.batchEdit.routing_rules = rules.join(',');
                },
                applyBatchSpeed() {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    if(selected.length === 0) { alert('请先选择要编辑的节点'); return; }
                    selected.forEach(n => {
                        if(this.batchEdit.max_per_hour !== null && this.batchEdit.max_per_hour !== '') n.max_per_hour = this.batchEdit.max_per_hour;
                        if(this.batchEdit.min_interval !== null && this.batchEdit.min_interval !== '') n.min_interval = this.batchEdit.min_interval;
                        if(this.batchEdit.max_interval !== null && this.batchEdit.max_interval !== '') n.max_interval = this.batchEdit.max_interval;
                    });
                    alert(`已应用到 ${selected.length} 个节点`);
                },
                applyBatchRouting() {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    if(selected.length === 0) { alert('请先选择要编辑的节点'); return; }
                    selected.forEach(n => {
                        n.routing_rules = this.batchEdit.routing_rules;
                    });
                    alert(`已应用到 ${selected.length} 个节点`);
                },
                applyBatchGroup() {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    if(selected.length === 0) { alert('请先选择要编辑的节点'); return; }
                    selected.forEach(n => {
                        n.group = this.batchEdit.group;
                    });
                    alert(`已将 ${selected.length} 个节点分配到"${this.batchEdit.group || '未分组'}"`);
                },
                addNode() { 
                    this.config.downstream_pool.push({ name: 'Node-'+Math.floor(Math.random()*1000), host: '', port: 587, encryption: 'none', username: '', password: '', sender_email: '', sender_domain: '', sender_prefix: '', sender_random: false, enabled: true, allow_bulk: true, routing_rules: '', group: '', expanded: true }); 
                },
                delNode(i) { if(confirm('删除此节点?')) this.config.downstream_pool.splice(i, 1); },
                copyNode(i) {
                    const original = this.config.downstream_pool[i];
                    const copy = JSON.parse(JSON.stringify(original));
                    // 自动生成名称：分组-域名 格式
                    copy.name = this.generateNodeName(copy);
                    copy.expanded = true;
                    this.config.downstream_pool.splice(i + 1, 0, copy);
                },
                generateNodeName(node) {
                    const group = node.group || '未分组';
                    const domain = node.sender_domain || node.host || 'unknown';
                    return `${group}-${domain}`;
                },
                autoRenameNodes() {
                    const selected = this.config.downstream_pool.filter(n => n.batchSelected);
                    const targets = selected.length > 0 ? selected : this.config.downstream_pool;
                    if (selected.length === 0 && !confirm(`确定为所有 ${targets.length} 个节点自动命名吗？\n格式: 分组名-发送域名`)) return;
                    if (selected.length > 0 && !confirm(`确定为选中的 ${selected.length} 个节点自动命名吗？\n格式: 分组名-发送域名`)) return;
                    targets.forEach(n => {
                        n.name = this.generateNodeName(n);
                    });
                    alert(`已重命名 ${targets.length} 个节点`);
                },
                moveNode(i, direction) {
                    const newIndex = i + direction;
                    if (newIndex < 0 || newIndex >= this.config.downstream_pool.length) return;
                    const pool = this.config.downstream_pool;
                    // Swap elements using splice (Vue 3 compatible)
                    const item = pool.splice(i, 1)[0];
                    pool.splice(newIndex, 0, item);
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
                    
                    // Validate schedule time if enabled
                    if (this.bulk.enableSchedule && this.bulk.scheduledAt) {
                        const scheduleDate = new Date(this.bulk.scheduledAt);
                        if (scheduleDate <= new Date()) {
                            return alert('定时发送时间必须是未来时间');
                        }
                    }
                    
                    const confirmMsg = this.bulk.enableSchedule && this.bulk.scheduledAt 
                        ? `确认定时发送给 ${this.recipientCount} 人?\n发送时间: ${this.bulk.scheduledAt.replace('T', ' ')}`
                        : `确认发送给 ${this.recipientCount} 人?`;
                    if(!confirm(confirmMsg)) return;
                    
                    this.sending = true;
                    try {
                        const payload = {
                            ...this.bulk,
                            bodies: validBodies,
                            scheduled_at: this.bulk.enableSchedule ? this.bulk.scheduledAt : ''
                        };
                        const res = await fetch('/api/send/bulk', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify(payload)
                        });
                        const data = await res.json();
                        if(res.ok) {
                            const msg = data.scheduled 
                                ? `已加入定时队列: ${data.count} 封\n发送时间: ${data.scheduled.replace('T', ' ')}`
                                : `已加入队列: ${data.count} 封`;
                            alert(msg);
                            this.bulk.recipients = '';
                            this.bulk.enableSchedule = false;
                            this.bulk.scheduledAt = '';
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
                    if(!confirm('智能重分配：仅处理分配到已禁用节点或不满足路由规则的任务\n\n继续吗？')) return;
                    
                    // Record current pending counts before rebalance
                    const beforeCounts = {};
                    for(const [name, stats] of Object.entries(this.qStats.nodes || {})) {
                        beforeCounts[name] = stats.pending || 0;
                    }
                    
                    this.rebalancing = true;
                    this.nodeChanges = {};
                    
                    try {
                        const res = await fetch('/api/queue/rebalance', { method: 'POST' });
                        const data = await res.json();
                        if(res.ok) {
                            await this.fetchQueue();
                            
                            // Calculate changes
                            const changes = {};
                            const allNodes = new Set([...Object.keys(beforeCounts), ...Object.keys(this.qStats.nodes || {})]);
                            for(const name of allNodes) {
                                const before = beforeCounts[name] || 0;
                                const after = (this.qStats.nodes[name]?.pending) || 0;
                                const diff = after - before;
                                if(diff !== 0) changes[name] = diff;
                            }
                            this.nodeChanges = changes;
                            
                            let msg = `成功重分配 ${data.count} 个任务`;
                            if(Object.keys(changes).length > 0) {
                                msg += '\n\n变化详情：\n';
                                for(const [node, diff] of Object.entries(changes)) {
                                    msg += `  ${node}: ${diff > 0 ? '+' : ''}${diff}\n`;
                                }
                            }
                            alert(msg);
                            
                            setTimeout(() => { this.nodeChanges = {}; }, 30000);
                        } else {
                            alert('错误: ' + data.error);
                        }
                    } catch(e) { alert('失败: ' + e); }
                    this.rebalancing = false;
                },
                async forceRebalanceQueue() {
                    if(!confirm('⚡ 强制均分：按各节点发送速率权重平均分配所有待发任务\n\n• 遵守分流规则（排除域名）\n• 负载轻的节点获得更多任务\n• 最终分配比例接近节点发送能力比\n\n确定继续吗？')) return;
                    
                    // Record current pending counts before rebalance
                    const beforeCounts = {};
                    for(const [name, stats] of Object.entries(this.qStats.nodes || {})) {
                        beforeCounts[name] = stats.pending || 0;
                    }
                    
                    this.rebalancing = true;
                    this.nodeChanges = {};  // Clear previous changes
                    
                    try {
                        const res = await fetch('/api/queue/force_rebalance', { method: 'POST' });
                        const data = await res.json();
                        if(res.ok) {
                            // Fetch updated queue data
                            await this.fetchQueue();
                            
                            // Calculate changes for each node
                            const changes = {};
                            const allNodes = new Set([...Object.keys(beforeCounts), ...Object.keys(this.qStats.nodes || {})]);
                            for(const name of allNodes) {
                                const before = beforeCounts[name] || 0;
                                const after = (this.qStats.nodes[name]?.pending) || 0;
                                const diff = after - before;
                                if(diff !== 0) {
                                    changes[name] = diff;
                                }
                            }
                            this.nodeChanges = changes;
                            
                            // Build summary message
                            let msg = `✅ 强制均分完成！\n分配成功: ${data.count} 个\n分配失败: ${data.failed || 0} 个\n\n变化详情：\n`;
                            for(const [node, diff] of Object.entries(changes)) {
                                const sign = diff > 0 ? '+' : '';
                                msg += `  ${node}: ${sign}${diff}\n`;
                            }
                            alert(msg);
                            
                            // Clear changes display after 30 seconds
                            setTimeout(() => { this.nodeChanges = {}; }, 30000);
                        } else {
                            alert('错误: ' + data.error);
                        }
                    } catch(e) { alert('失败: ' + e); }
                    this.rebalancing = false;
                },
                // 实时日志相关方法
                async fetchLogs() {
                    // 只有在顶部时才刷新
                    if(!this.logAtTop) return;
                    try {
                        const res = await fetch('/api/logs?lines=50');
                        const data = await res.json();
                        if(data.logs) {
                            // 限制最多显示100条防止卡顿
                            this.liveLogs = data.logs.slice(0, 100);
                        }
                    } catch(e) { console.error('获取日志失败:', e); }
                },
                onLogScroll(e) {
                    // 检查是否滚动到顶部（允许 5px 的容差）
                    this.logAtTop = e.target.scrollTop <= 5;
                },
                toggleLiveLogs() {
                    this.liveLogsEnabled = !this.liveLogsEnabled;
                    if(this.liveLogsEnabled) {
                        this.startLogTimer();
                    } else {
                        this.stopLogTimer();
                    }
                },
                startLogTimer() {
                    this.stopLogTimer();
                    this.fetchLogs();
                    this.logTimer = setInterval(() => {
                        if(this.liveLogsEnabled) {
                            this.fetchLogs();
                        }
                    }, 1000);  // 每1秒刷新
                },
                stopLogTimer() {
                    if(this.logTimer) {
                        clearInterval(this.logTimer);
                        this.logTimer = null;
                    }
                },
                clearLogs() {
                    this.liveLogs = [];
                },
                refreshLogs() {
                    this.fetchLogs();
                },
                getLogClass(log) {
                    if(!log) return '';
                    const lower = log.toLowerCase();
                    if(lower.includes('error') || lower.includes('失败') || lower.includes('错误') || lower.includes('❌')) return 'log-error';
                    if(lower.includes('warning') || lower.includes('警告') || lower.includes('⚠')) return 'log-warning';
                    if(lower.includes('success') || lower.includes('成功') || lower.includes('✅') || lower.includes('sent to')) return 'log-success';
                    if(lower.includes('info') || lower.includes('🆕') || lower.includes('🔄') || lower.includes('⚡')) return 'log-info';
                    return '';
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
