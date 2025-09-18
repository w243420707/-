#!/bin/sh
# Alpine/OpenRC 一键 SOCKS5 安装（Dante 优先，Microsocks 回退）
# 开机自启 + 每小时自检；结束输出 socks5://IP:PORT

set -e

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERR ] %s\n' "$*" >&2; }
exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 权限运行。"
    exit 1
  fi
}

prompt_port() {
  default_port=1080
  printf "请输入监听端口 [默认 %s]: " "$default_port"
  read -r PORT
  PORT="${PORT:-$default_port}"
  case "$PORT" in
    ''|*[!0-9]*) err "端口无效：$PORT"; exit 1;;
    *) if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then err "端口无效：$PORT"; exit 1; fi;;
  esac
}

install_base_tools() {
  log "安装基础工具（curl, ca-certificates, iproute2, bind-tools）..."
  apk update
  apk add --no-cache curl ca-certificates iproute2 bind-tools
}

get_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

install_dante() {
  log "尝试安装 Dante（dante-server）..."
  if apk add --no-cache dante-server; then
    if [ ! -x /usr/sbin/sockd ]; then
      err "dante-server 安装后未发现 /usr/sbin/sockd"
      return 1
    fi
    return 0
  fi
  return 1
}

configure_dante() {
  log "写入 Dante 配置..."
  IFACE="$(get_default_iface)"
  if [ -n "$IFACE" ]; then
    EXTERNAL_LINE="external: $IFACE"
  else
    EXTERNAL_LINE="external: default"
  fi

  cat >/etc/sockd.conf <<EOF
logoutput: syslog
user.privileged: root
user.notprivileged: nobody

internal: 0.0.0.0 port = $PORT
$EXTERNAL_LINE

socksmethod: none
clientmethod: none

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect disconnect error
}
EOF
  # 兼容路径
  cp -f /etc/sockd.conf /etc/danted.conf 2>/dev/null || true

  # 优先使用包自带的 OpenRC 服务（若存在）
  SERVICE="sockd"
  if [ -x /etc/init.d/sockd ]; then
    :
  else
    log "未检测到 sockd 的 OpenRC 服务，创建之..."
    cat >/etc/init.d/sockd <<'EOF'
#!/sbin/openrc-run
description="Dante SOCKS5 proxy daemon"
command="/usr/sbin/sockd"
command_args="-f /etc/sockd.conf"
pidfile="/run/sockd.pid"
command_background="yes"

depend() {
  need net
}
EOF
    chmod +x /etc/init.d/sockd
  fi

  rc-update add sockd default
  rc-service sockd restart || rc-service sockd start

  # 记录环境
  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=dante
SERVICE_NAME=sockd
EOF

  log "Dante 已安装并启动（服务名：sockd）。"
  return 0
}

install_microsocks() {
  log "回退安装 Microsocks..."
  if apk add --no-cache microsocks; then
    return 0
  fi

  # 极端情况下仓库没有 microsocks，再尝试源码编译（需要 git/gcc/make）
  warn "仓库安装 microsocks 失败，尝试源码编译（安装 build 依赖）..."
  apk add --no-cache git build-base
  workdir="/tmp/microsocks.$"
  rm -rf "$workdir"; mkdir -p "$workdir"
  git clone --depth=1 https://github.com/rofl0r/microsocks.git "$workdir"
  make -C "$workdir"
  install -m 0755 "$workdir/microsocks" /usr/local/bin/microsocks
  echo "/usr/local/bin" >> /etc/profile.d/local_path.sh 2>/dev/null || true
  return 0
}

configure_microsocks() {
  log "配置 Microsocks OpenRC 服务..."
  BIN="/usr/bin/microsocks"
  [ -x "$BIN" ] || BIN="/usr/local/bin/microsocks"

  cat >/etc/init.d/microsocks <<'EOF'
#!/sbin/openrc-run
description="Microsocks SOCKS5 proxy"
command=""
pidfile="/run/microsocks.pid"
command_background="yes"
command_user="nobody:nobody"

depend() {
  need net
}

start() {
  if [ -f /etc/socks5-proxy.env ]; then . /etc/socks5-proxy.env; fi
  : "${PORT:=1080}"

  if [ -x /usr/bin/microsocks ]; then
    command="/usr/bin/microsocks"
  elif [ -x /usr/local/bin/microsocks ]; then
    command="/usr/local/bin/microsocks"
  else
    eerror "未找到 microsocks 可执行文件"
    return 1
  fi

  ebegin "Starting microsocks on port ${PORT}"
  start-stop-daemon --start --background --make-pidfile --pidfile "${pidfile}" \
    --exec "${command}" -- -i 0.0.0.0 -p "${PORT}"
  eend $?
}

stop() {
  ebegin "Stopping microsocks"
  start-stop-daemon --stop --pidfile "${pidfile}"
  eend $?
}
EOF
  chmod +x /etc/init.d/microsocks

  # 记录环境
  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=microsocks
SERVICE_NAME=microsocks
EOF

  rc-update add microsocks default
  rc-service microsocks restart || rc-service microsocks start
  log "Microsocks 已安装并启动（服务名：microsocks）。"
}

setup_watchdog_cron() {
  log "创建每小时自检脚本 + 启用 crond..."
  cat >/usr/local/bin/socks5-watchdog.sh <<'EOF'
#!/bin/sh
set -e
SERVICE=""
[ -f /etc/socks5-proxy.env ] && . /etc/socks5-proxy.env

# 推断服务名
if [ -n "$SERVICE_NAME" ]; then
  SERVICE="$SERVICE_NAME"
else
  for s in sockd danted microsocks; do
    if [ -x "/etc/init.d/$s" ]; then SERVICE="$s"; break; fi
  done
fi

if [ -n "$SERVICE" ]; then
  # 确保加入开机自启
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  # 不在运行则拉起
  if ! rc-service "$SERVICE" status >/dev/null 2>&1; then
    rc-service "$SERVICE" restart >/dev/null 2>&1 || rc-service "$SERVICE" start >/dev/null 2>&1 || true
  fi
fi
EOF
  chmod +x /usr/local/bin/socks5-watchdog.sh

  # 确保 crond 运行
  apk add --no-cache openrc >/dev/null 2>&1 || true
  rc-update add crond default 2>/dev/null || true
  rc-service crond start 2>/dev/null || true

  # 写入 root 的 crontab（Alpine: /etc/crontabs/root）
  CRON_FILE="/etc/crontabs/root"
  MARK="# SOCKS5_WATCHDOG"
  mkdir -p /etc/crontabs
  touch "$CRON_FILE"
  # 去重
  grep -v "$MARK" "$CRON_FILE" > "${CRON_FILE}.new" || true
  mv "${CRON_FILE}.new" "$CRON_FILE"
  echo "0 * * * * /usr/local/bin/socks5-watchdog.sh >/dev/null 2>&1 $MARK" >> "$CRON_FILE"
  chown root:root "$CRON_FILE"
  chmod 600 "$CRON_FILE"
  rc-service crond restart 2>/dev/null || true
  log "已启用每小时自检（crond + root crontab）。"
}

get_public_ip() {
  ip="$(curl -fsSL https://api.ipify.org || true)"
  [ -n "$ip" ] || ip="$(curl -fsSL https://ifconfig.me || true)"
  if [ -z "$ip" ] && exists dig; then
    ip="$(dig -4 +short myip.opendns.com @resolver1.opendns.com || true)"
  fi
  if [ -z "$ip" ]; then
    IFACE="$(get_default_iface)"
    if [ -n "$IFACE" ]; then
      ip="$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fi
  fi
  printf '%s' "$ip"
}

print_result() {
  ip="$1"
  [ -n "$ip" ] || { warn "未能自动获取公网 IP，请手动替换以下结果中的 IP。"; ip="YOUR_SERVER_IP"; }
  echo
  echo "==============================================="
  echo "安装完成！你的 SOCKS5 代理地址："
  echo "socks5://${ip}:${PORT}"
  echo "==============================================="
}

# 主流程
need_root
if [ -f /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" != "alpine" ]; then
  warn "检测到非 Alpine 系统，此脚本专为 Alpine/OpenRC 设计。"
fi

prompt_port
install_base_tools

if install_dante; then
  if ! configure_dante; then
    warn "Dante 配置失败，回退到 Microsocks..."
    install_microsocks
    configure_microsocks
  fi
else
  warn "Dante 安装失败，回退到 Microsocks..."
  install_microsocks
  configure_microsocks
fi

setup_watchdog_cron
PUB_IP="$(get_public_ip)"
print_result "$PUB_IP"
