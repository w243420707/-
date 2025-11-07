#!/usr/bin/env bash
set -euo pipefail
# 一体化 VPS 内存监控与安装脚本
# 功能：
#  - 作为守护进程运行，监控物理内存 + swap 的合并使用率，达到阈值触发重启
#  - 支持 DRY_RUN（仅记录不重启）、自定义阈值/间隔/日志路径
#  - 支持子命令 install/uninstall/run/status/help，能在 systemd 系统上安装并启用为服务

DEFAULT_THRESHOLD=70
DEFAULT_INTERVAL=1
DEFAULT_LOGFILE=/var/log/vps-memory-monitor.log
INSTALL_PATH=/usr/local/bin/vps-memory-monitor.sh
SERVICE_PATH=/etc/systemd/system/vps-memory-monitor.service

print_help(){
  cat <<EOF
Usage: $0 [command] [options]

Commands:
  run                直接运行监控（默认，如果未提供命令也为 run）
  install            把脚本安装到 ${INSTALL_PATH} 并在 systemd 上启用服务（需 root）
  uninstall          停用并移除 systemd 服务与已安装脚本（需 root）
  status             查看 systemd 服务状态（若可用）
  help               显示此帮助

Options for run:
  --threshold=N      触发阈值（百分比），默认 ${DEFAULT_THRESHOLD}
  --interval=S       检查间隔（秒），默认 ${DEFAULT_INTERVAL}
  --logfile=PATH     日志文件路径，默认 ${DEFAULT_LOGFILE}
  --dry-run          不执行重启，仅记录和显示触发信息

Examples:
  sudo $0 install                # 安装并启用 systemd 服务
  sudo $0 run --threshold=80     # 以阈值 80% 直接运行监控
  sudo THRESHOLD=80 $0 run       # 也可以用环境变量
EOF
}

log(){
  local msg="$*"
  local time
  time=$(date '+%F %T')
  if [ -n "${LOGFILE:-}" ]; then
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    echo "$time $msg" | tee -a "$LOGFILE"
  else
    echo "$time $msg"
  fi
}

detect_system(){
  ARCH=$(uname -m 2>/dev/null || echo unknown)
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION="unknown"
  fi
  log "Detected OS=${OS_ID} VERSION=${OS_VERSION} ARCH=${ARCH}"
}

# 读取 /proc/meminfo 并返回：total_kb used_kb percent
get_mem_usage(){
  awk '
    BEGIN{memTotal=0;memAvailable=-1;memFree=0;buffers=0;cached=0;swapTotal=0;swapFree=0}
    /^MemTotal:/ {memTotal=$2}
    /^MemAvailable:/ {memAvailable=$2}
    /^MemFree:/ {memFree=$2}
    /^Buffers:/ {buffers=$2}
    /^Cached:/ {cached=$2}
    /^SwapTotal:/ {swapTotal=$2}
    /^SwapFree:/ {swapFree=$2}
    END{
      if (memTotal==0) {print "0 0 0"; exit}
      if (memAvailable>0) usedPhy = memTotal - memAvailable; else usedPhy = memTotal - (memFree + buffers + cached)
      usedSwap = swapTotal - swapFree; if (usedSwap<0) usedSwap=0
      total = memTotal + swapTotal
      used = usedPhy + usedSwap
      percent = (total>0) ? (used/total*100.0) : 0
      if (used<0) used=0
      if (percent<0) percent=0
      printf("%d %d %.2f", total, used, percent)
    }' /proc/meminfo
}

safe_reboot(){
  log "Attempting reboot..."
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 -> skip actual reboot"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    log "Calling systemctl reboot"
    systemctl reboot || true
  else
    if command -v reboot >/dev/null 2>&1; then
      log "Calling reboot"
      reboot || true
    elif command -v shutdown >/dev/null 2>&1; then
      log "Calling shutdown -r now"
      shutdown -r now || true
    else
      log "No reboot command found"
      return 1
    fi
  fi
}

run_monitor(){
  THRESHOLD=${THRESHOLD:-$DEFAULT_THRESHOLD}
  INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}
  LOGFILE=${LOGFILE:-$DEFAULT_LOGFILE}
  DRY_RUN=${DRY_RUN:-0}

  detect_system
  log "Start monitor: threshold=${THRESHOLD}% interval=${INTERVAL}s logfile=${LOGFILE} dry_run=${DRY_RUN}"

  trap 'log "Signal received, exiting"; exit 0' INT TERM

  while true; do
    read total used percent <<< "$(get_mem_usage)"
    exceed=$(awk -v p="$percent" -v t="$THRESHOLD" 'BEGIN{print (p>=t)?1:0}')
    if [ "$exceed" -eq 1 ]; then
      log "Trigger: memory ${percent}% >= threshold ${THRESHOLD}% (total_kb=${total} used_kb=${used})"
      echo "$(date '+%F %T') Trigger: percent=${percent} threshold=${THRESHOLD} total_kb=${total} used_kb=${used}" >> "${LOGFILE}" 2>/dev/null || true
      safe_reboot
      # 如果重启命令返回，则退出以避免死循环
      exit 0
    fi
    sleep "$INTERVAL"
  done
}

install_service(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "install 需要 root 权限，请使用 sudo。"
    exit 1
  fi
  echo "安装脚本到 ${INSTALL_PATH}..."
  mkdir -p "$(dirname "$INSTALL_PATH")" 2>/dev/null || true
  cp "$0" "${INSTALL_PATH}"
  chmod +x "${INSTALL_PATH}"

  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    echo "创建 systemd 单元 ${SERVICE_PATH}..."
    cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=VPS Memory Monitor
After=network.target

[Service]
Type=simple
Environment=THRESHOLD=${DEFAULT_THRESHOLD}
Environment=INTERVAL=${DEFAULT_INTERVAL}
Environment=LOGFILE=${DEFAULT_LOGFILE}
ExecStart=${INSTALL_PATH} run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now vps-memory-monitor.service
    echo "service enabled and started"
  else
    echo "systemd 未检测到；已复制脚本到 ${INSTALL_PATH}，请手动安排开机自启（例如 crontab @reboot）"
  fi
  echo "安装完成。编辑 ${SERVICE_PATH} 或通过 Environment 覆盖 THRESHOLD/INTERVAL。"
}

uninstall_service(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall 需要 root 权限，请使用 sudo。"
    exit 1
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    systemctl stop vps-memory-monitor.service || true
    systemctl disable vps-memory-monitor.service || true
    rm -f "${SERVICE_PATH}" || true
    systemctl daemon-reload || true
    echo "service removed"
  fi
  rm -f "${INSTALL_PATH}" || true
  echo "script removed: ${INSTALL_PATH}"
}

status_service(){
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    systemctl status vps-memory-monitor.service --no-pager || true
  else
    echo "systemd 未检测到。"
  fi
}

# 解析主要子命令
cmd="run"
if [ "$#" -ge 1 ]; then
  case "$1" in
    install|uninstall|status|run|help)
      cmd="$1"; shift || true
      ;;
    --*|-*)
      cmd="run"
      ;;
    *)
      cmd="run"
      ;;
  esac
fi

case "$cmd" in
  help)
    print_help; exit 0
    ;;
  install)
    install_service; exit 0
    ;;
  uninstall)
    uninstall_service; exit 0
    ;;
  status)
    status_service; exit 0
    ;;
  run)
    # 解析 run 的选项
    for arg in "$@"; do
      case "$arg" in
        --threshold=*) THRESHOLD="${arg#*=}" ;;
        --interval=*) INTERVAL="${arg#*=}" ;;
        --logfile=*) LOGFILE="${arg#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        --help) print_help; exit 0 ;;
        *) echo "Unknown option: $arg"; print_help; exit 1 ;;
      esac
    done
    run_monitor
    ;;
  *)
    echo "Unknown command: $cmd"; print_help; exit 1
    ;;
esac
