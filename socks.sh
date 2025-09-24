#!/bin/sh
# Alpine(OpenRC) & Debian/Ubuntu(systemd) 一键 SOCKS5 安装（Dante 优先，Microsocks 回退）
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

detect_os() {
  OS_FAMILY=""
  INIT_SYSTEM=""
  if [ -f /etc/os-release ]; then . /etc/os-release; fi

  case "${ID:-}" in
    alpine) OS_FAMILY="alpine" ;;
    debian|ubuntu) OS_FAMILY="debian" ;;
    *) : ;;
  esac

  if [ -z "$OS_FAMILY" ] && [ -n "${ID_LIKE:-}" ]; then
    case "$ID_LIKE" in
      *alpine*) OS_FAMILY="alpine" ;;
      *debian*|*ubuntu*) OS_FAMILY="debian" ;;
    esac
  fi

  if [ "$OS_FAMILY" = "alpine" ]; then
    INIT_SYSTEM="openrc"
  else
    # 默认假定 debian 系都为 systemd
    if exists systemctl; then
      INIT_SYSTEM="systemd"
      [ -z "$OS_FAMILY" ] && OS_FAMILY="debian"
    else
      # 兜底：无 systemd 则按 alpine 流程（OpenRC）尽力处理
      INIT_SYSTEM="openrc"
      [ -z "$OS_FAMILY" ] && OS_FAMILY="alpine"
      warn "未检测到 systemd，将按 OpenRC 方式处理。"
    fi
  fi

  export OS_FAMILY INIT_SYSTEM
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
  if [ "$OS_FAMILY" = "alpine" ]; then
    log "安装基础工具（curl, ca-certificates, iproute2, bind-tools, openrc）..."
    apk update
    apk add --no-cache curl ca-certificates iproute2 bind-tools openrc
  else
    log "安装基础工具（curl, ca-certificates, iproute2, dnsutils）..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # dnsutils 提供 dig；某些极简系统可能没有 iproute2 包名（已内置），失败不致命
    apt-get install -y curl ca-certificates iproute2 dnsutils || true
  fi
}

get_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# ========================= Alpine/OpenRC: Dante =========================
install_dante_alpine() {
  log "尝试安装 Dante（dante-server）[Alpine]..."
  if apk add --no-cache dante-server; then
    [ -x /usr/sbin/sockd ] || { err "dante-server 安装后未发现 /usr/sbin/sockd"; return 1; }
    return 0
  fi
  return 1
}

configure_dante_openrc() {
  log "写入 Dante 配置（OpenRC）..."
  IFACE="$(get_default_iface)"
  if [ -n "$IFACE" ]; then EXTERNAL_LINE="external: $IFACE"; else EXTERNAL_LINE="external: default"; fi

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
  cp -f /etc/sockd.conf /etc/danted.conf 2>/dev/null || true

  if [ ! -x /etc/init.d/sockd ]; then
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

  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=dante
SERVICE_NAME=sockd
EOF

  log "Dante 已安装并启动（OpenRC 服务名：sockd）。"
}

# ========================= Debian/systemd: Dante =========================
install_dante_debian() {
  log "尝试安装 Dante（dante-server）[Debian/Ubuntu]..."
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y dante-server; then
    [ -x /usr/sbin/sockd ] || { err "dante-server 安装后未发现 /usr/sbin/sockd"; return 1; }
    return 0
  fi
  return 1
}

configure_dante_systemd() {
  log "写入 Dante 配置（systemd）..."
  IFACE="$(get_default_iface)"
  if [ -n "$IFACE" ]; then EXTERNAL_LINE="external: $IFACE"; else EXTERNAL_LINE="external: 0.0.0.0"; fi

  # Debian/Ubuntu 通常使用 /etc/danted.conf
  cat >/etc/danted.conf <<EOF
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

  # 优先使用已存在的 danted.service；若无则创建
  if ! systemctl list-unit-files | grep -q '^danted\.service'; then
    log "未检测到 danted.service，创建 systemd 单元..."
    cat >/etc/systemd/system/danted.service <<'EOF'
[Unit]
Description=Dante SOCKS5 proxy daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/sockd -f /etc/danted.conf
Restart=on-failure
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable --now danted || {
    warn "启动 danted 失败，尝试以 sockd.service 名称启动..."
    systemctl enable --now sockd || true
  }

  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=dante
SERVICE_NAME=danted
EOF

  log "Dante 已安装并启动（systemd 单元：danted）。"
}

# ========================= Alpine/OpenRC: Microsocks =========================
install_microsocks_alpine() {
  log "回退安装 Microsocks [Alpine]..."
  if apk add --no-cache microsocks; then
    return 0
  fi
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

configure_microsocks_openrc() {
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

  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=microsocks
SERVICE_NAME=microsocks
EOF

  rc-update add microsocks default
  rc-service microsocks restart || rc-service microsocks start
  log "Microsocks 已安装并启动（OpenRC 服务名：microsocks）。"
}

# ========================= Debian/systemd: Microsocks =========================
install_microsocks_debian() {
  log "回退安装 Microsocks [Debian/Ubuntu]..."
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y microsocks; then
    return 0
  fi
  warn "仓库安装 microsocks 失败，尝试源码编译（安装 build 依赖）..."
  apt-get install -y git build-essential
  workdir="/tmp/microsocks.$"
  rm -rf "$workdir"; mkdir -p "$workdir"
  git clone --depth=1 https://github.com/rofl0r/microsocks.git "$workdir"
  make -C "$workdir"
  install -m 0755 "$workdir/microsocks" /usr/local/bin/microsocks
  return 0
}

configure_microsocks_systemd() {
  log "配置 Microsocks systemd 服务..."
  BIN="/usr/bin/microsocks"
  [ -x "$BIN" ] || BIN="/usr/local/bin/microsocks"

  cat >/etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=Microsocks SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=$BIN -i 0.0.0.0 -p $PORT
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now microsocks

  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=microsocks
SERVICE_NAME=microsocks
EOF

  log "Microsocks 已安装并启动（systemd 单元：microsocks）。"
}

# ========================= Watchdog（每小时自检） =========================
setup_watchdog_openrc() {
  log "创建每小时自检脚本 + 启用 crond（OpenRC）..."
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
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  if ! rc-service "$SERVICE" status >/dev/null 2>&1; then
    rc-service "$SERVICE" restart >/dev/null 2>&1 || rc-service "$SERVICE" start >/dev/null 2>&1 || true
  fi
fi
EOF
  chmod +x /usr/local/bin/socks5-watchdog.sh

  apk add --no-cache openrc >/dev/null 2>&1 || true
  rc-update add crond default 2>/dev/null || true
  rc-service crond start 2>/dev/null || true

  CRON_FILE="/etc/crontabs/root"
  MARK="# SOCKS5_WATCHDOG"
  mkdir -p /etc/crontabs
  touch "$CRON_FILE"
  grep -v "$MARK" "$CRON_FILE" > "${CRON_FILE}.new" || true
  mv "${CRON_FILE}.new" "$CRON_FILE"
  echo "0 * * * * /usr/local/bin/socks5-watchdog.sh >/dev/null 2>&1 $MARK" >> "$CRON_FILE"
  chown root:root "$CRON_FILE"
  chmod 600 "$CRON_FILE"
  rc-service crond restart 2>/dev/null || true
  log "已启用每小时自检（crond + root crontab）。"
}

setup_watchdog_systemd() {
  log "创建每小时自检脚本 + systemd timer..."
  cat >/usr/local/bin/socks5-watchdog.sh <<'EOF'
#!/bin/sh
set -e
SERVICE=""
[ -f /etc/socks5-proxy.env ] && . /etc/socks5-proxy.env

# 推断服务名
if [ -n "$SERVICE_NAME" ]; then
  SERVICE="$SERVICE_NAME"
else
  for s in danted sockd microsocks; do
    if systemctl list-unit-files | grep -q "^${s}\.service"; then SERVICE="$s"; break; fi
  done
fi

if [ -n "$SERVICE" ]; then
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl is-active --quiet "$SERVICE" || systemctl restart "$SERVICE" || systemctl start "$SERVICE" || true
fi
EOF
  chmod +x /usr/local/bin/socks5-watchdog.sh

  cat >/etc/systemd/system/socks5-watchdog.service <<'EOF'
[Unit]
Description=SOCKS5 watchdog (ensure proxy is running)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/socks5-watchdog.sh
EOF

  cat >/etc/systemd/system/socks5-watchdog.timer <<'EOF'
[Unit]
Description=Run SOCKS5 watchdog hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now socks5-watchdog.timer
  log "已启用每小时自检（systemd timer）。"
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

# ========================= 主流程 =========================
need_root
detect_os
[ "$OS_FAMILY" = "alpine" ] || warn "检测到非 Alpine 系统，将使用 ${OS_FAMILY}/${INIT_SYSTEM} 流程。"

prompt_port
install_base_tools

DANTE_OK=0
if [ "$OS_FAMILY" = "alpine" ]; then
  if install_dante_alpine; then
    configure_dante_openrc || true
    DANTE_OK=1
  fi
else
  if install_dante_debian; then
    configure_dante_systemd || true
    DANTE_OK=1
  fi
fi

if [ "$DANTE_OK" -ne 1 ]; then
  warn "Dante 安装或配置失败，回退到 Microsocks..."
  if [ "$OS_FAMILY" = "alpine" ]; then
    install_microsocks_alpine
    configure_microsocks_openrc
  else
    install_microsocks_debian
    configure_microsocks_systemd
  fi
fi

if [ "$INIT_SYSTEM" = "openrc" ]; then
  setup_watchdog_openrc
else
  setup_watchdog_systemd
fi

PUB_IP="$(get_public_ip)"
print_result "$PUB_IP"
