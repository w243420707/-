#!/usr/bin/env bash
# 一键安装 SOCKS5 代理 + 开机自启 + 每小时自检守护
# Dante 优先，失败回退 microsocks。完成后输出 socks5://IP:PORT

set -u

#===== 基础工具函数 =====
log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERR ] $*" >&2; }
exists() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 权限运行。"
    exit 1
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"; OS_VER=""; OS_LIKE=""
  fi

  if exists apt-get; then
    PKG_MGR="apt"
  elif exists dnf; then
    PKG_MGR="dnf"
  elif exists yum; then
    PKG_MGR="yum"
  else
    PKG_MGR=""
  fi

  ARCH="$(uname -m)"
}

prompt_port() {
  local default_port=1080
  read -rp "请输入监听端口 [默认 ${default_port}]: " PORT
  PORT="${PORT:-$default_port}"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    err "端口无效：$PORT"
    exit 1
  fi
}

install_base_tools() {
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates lsb-release iproute2 dig || true
      ;;
    dnf)
      dnf -y install curl ca-certificates iproute bind-utils || true
      ;;
    yum)
      yum -y install curl ca-certificates iproute bind-utils || true
      ;;
    *)
      warn "无法识别包管理器，跳过基础工具安装。"
      ;;
  esac
}

install_dante() {
  log "尝试安装 Dante（dante-server）..."
  local ok=0
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      if apt-get install -y dante-server; then ok=1; fi
      ;;
    dnf)
      dnf -y install epel-release || true
      if dnf -y install dante-server; then ok=1; fi
      ;;
    yum)
      yum -y install epel-release || true
      if yum -y install dante-server; then ok=1; fi
      ;;
    *)
      warn "未识别的包管理器，跳过 Dante 安装。"
      ;;
  esac

  if [ $ok -eq 1 ]; then
    if ! exists danted && ! exists sockd; then ok=0; fi
  fi
  return $ok
}

configure_dante() {
  log "生成 Dante 配置..."
  local DEFAULT_IFACE IFACE EXTERNAL_LINE
  DEFAULT_IFACE="$(ip -4 route ls default 2>/dev/null | awk '{print $5; exit}')"
  if [ -n "$DEFAULT_IFACE" ]; then
    IFACE="$DEFAULT_IFACE"
    EXTERNAL_LINE="external: $IFACE"
  else
    EXTERNAL_LINE="external: default"
  fi

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

  # 兼容可能的 sockd.conf
  cp -f /etc/danted.conf /etc/sockd.conf 2>/dev/null || true

  # 确定服务名
  local SERVICE_NAME=""
  if systemctl cat danted >/dev/null 2>&1; then
    SERVICE_NAME="danted"
  elif systemctl cat sockd >/dev/null 2>&1; then
    SERVICE_NAME="sockd"
  else
    # 自建服务
    local BIN=""
    if exists danted; then BIN="$(command -v danted)"; fi
    if [ -z "$BIN" ] && exists sockd; then BIN="$(command -v sockd)"; fi
    if [ -z "$BIN" ]; then
      if [ -x /usr/sbin/danted ]; then BIN="/usr/sbin/danted"; fi
      if [ -z "$BIN" ] && [ -x /usr/sbin/sockd ]; then BIN="/usr/sbin/sockd"; fi
    fi
    if [ -z "$BIN" ]; then
      err "未找到 danted/sockd 可执行文件。"
      return 1
    fi
    SERVICE_NAME="danted"
    cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Dante SOCKS5 proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -f /etc/danted.conf
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  # 尽量把发行版自带的 danted/sockd 服务也改为更稳的策略
  if systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat >"/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf" <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF
    systemctl daemon-reload
  fi

  systemctl enable --now "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    warn "Dante 服务启动失败：journalctl -u ${SERVICE_NAME} -e"
    return 1
  fi

  # 写入环境记录
  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=dante
SERVICE_NAME=${SERVICE_NAME}
EOF

  log "Dante 已启动（服务名：${SERVICE_NAME}）。"
  return 0
}

install_microsocks() {
  log "回退安装 microsocks ..."
  case "$PKG_MGR" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y gcc make git curl
      ;;
    dnf)
      dnf -y install gcc make git curl
      ;;
    yum)
      yum -y install gcc make git curl
      ;;
    *)
      warn "未识别的包管理器，将尝试继续。"
      ;;
  esac

  local workdir="/tmp/microsocks.$"
  rm -rf "$workdir"; mkdir -p "$workdir"
  if ! git clone --depth=1 https://github.com/rofl0r/microsocks.git "$workdir"; then
    err "拉取 microsocks 源码失败。"; return 1
  fi
  if ! make -C "$workdir"; then err "编译 microsocks 失败。"; return 1; fi
  install -m 0755 "$workdir/microsocks" /usr/local/bin/microsocks

  cat >/etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=Microsocks SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
ExecStart=/usr/local/bin/microsocks -i 0.0.0.0 -p ${PORT}
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now microsocks
  sleep 1
  if ! systemctl is-active --quiet microsocks; then
    err "microsocks 服务启动失败：journalctl -u microsocks -e"
    return 1
  fi

  mkdir -p /etc
  cat >/etc/socks5-proxy.env <<EOF
PORT=${PORT}
PROVIDER=microsocks
SERVICE_NAME=microsocks
EOF

  log "microsocks 已安装并启动。"
  return 0
}

open_firewall() {
  log "尝试开放防火墙端口 ${PORT} ..."
  if exists ufw && ufw status >/dev/null 2>&1; then
    if ufw status | grep -qi "Status: active"; then
      ufw allow "${PORT}/tcp" || true
      ufw allow "${PORT}/udp" || true
      log "已通过 ufw 放行端口。"
    fi
  fi
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${PORT}/udp" || true
    firewall-cmd --reload || true
    log "已通过 firewalld 放行端口。"
  fi
}

get_public_ip() {
  local ip=""
  ip="$(curl -fsSL https://api.ipify.org || true)"
  if [ -z "$ip" ]; then ip="$(curl -fsSL https://ifconfig.me || true)"; fi
  if [ -z "$ip" ] && exists dig; then
    ip="$(dig -4 +short myip.opendns.com @resolver1.opendns.com || true)"
  fi
  if [ -z "$ip" ]; then
    local IFACE
    IFACE="$(ip -4 route ls default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$IFACE" ]; then
      ip="$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fi
  fi
  echo "${ip}"
}

setup_watchdog_systemd() {
  log "创建每小时自检守护（systemd timer）..."
  install -m 0755 /dev/stdin /usr/local/bin/socks5-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVICE=""
PORT="1080"

if [ -f /etc/socks5-proxy.env ]; then
  # shellcheck disable=SC1091
  . /etc/socks5-proxy.env || true
fi

if command -v systemctl >/dev/null 2>&1; then
  if [ -n "${SERVICE_NAME:-}" ] && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    SERVICE="$SERVICE_NAME"
  else
    for s in danted sockd microsocks; do
      if systemctl list-unit-files | grep -q "^${s}.service"; then SERVICE="$s"; break; fi
    done
  fi

  if [ -z "$SERVICE" ]; then
    exit 0
  fi

  # 自动拉起不活跃的服务
  if ! systemctl is-active --quiet "$SERVICE"; then
    systemctl restart "$SERVICE" || true
    sleep 2
  fi

  # 确保开机自启
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true

else
  # 无 systemd 的极少数环境，尝试直接确保进程在
  if pgrep -x microsocks >/dev/null 2>&1; then exit 0; fi
  if command -v microsocks >/dev/null 2>&1; then
    nohup microsocks -i 0.0.0.0 -p "${PORT}" >/var/log/microsocks.log 2>&1 &
  fi
fi
EOF

  cat >/etc/systemd/system/socks5-watchdog.service <<'EOF'
[Unit]
Description=SOCKS5 proxy watchdog (hourly check)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/socks5-watchdog.sh
EOF

  cat >/etc/systemd/system/socks5-watchdog.timer <<'EOF'
[Unit]
Description=Run SOCKS5 watchdog hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now socks5-watchdog.timer
  log "已启用守护定时器：socks5-watchdog.timer（每小时自检）。"
}

setup_watchdog_cron_fallback() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "未检测到 systemd，使用 cron 作为小时守护回退..."
    exists crontab || { warn "系统无 crontab，无法设置小时守护。"; return; }
    # 去重后写入
    local marker="# SOCKS5_WATCHDOG_CRON"
    local line="0 * * * * /usr/local/bin/socks5-watchdog.sh >/dev/null 2>&1 ${marker}"
    (crontab -l 2>/dev/null | grep -v "${marker}"; echo "$line") | crontab -
    log "已写入 cron 每小时自检。"
  fi
}

print_result() {
  local ip="$1"
  if [ -z "$ip" ]; then
    warn "未能自动获取公网 IP，请手动替换以下结果中的 IP。"
    ip="YOUR_SERVER_IP"
  fi
  echo
  echo "==============================================="
  echo "安装完成！你的 SOCKS5 代理地址："
  echo "socks5://${ip}:${PORT}"
  echo "==============================================="
}

#===== 主流程 =====
need_root
detect_os
log "检测到系统：ID=${OS_ID} ${OS_VER} (LIKE=${OS_LIKE}), 架构=${ARCH}"
prompt_port
install_base_tools

if install_dante && configure_dante; then
  log "Dante 安装与配置成功。"
else
  warn "Dante 安装/配置未成功，切换到 microsocks。"
  if ! install_microsocks; then
    err "无法完成 SOCKS5 安装，请手动检查环境与日志。"
    exit 1
  fi
fi

open_firewall
setup_watchdog_systemd
setup_watchdog_cron_fallback

PUB_IP="$(get_public_ip)"
print_result "$PUB_IP"
