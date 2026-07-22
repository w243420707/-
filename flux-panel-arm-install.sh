#!/usr/bin/env bash
set -Eeuo pipefail

# flux-panel ARM 一键交互安装脚本
# 用途：在 ARM64/aarch64 机器上安装 BrunuhVille/flux-panel 的定制版 gost。
# 原项目只提供 linux amd64 二进制，本脚本会在 ARM 机器上安装 qemu-user-static/binfmt 兼容层，
# 然后运行原安装脚本，使面板上报功能正常工作。

INSTALL_SH_URL="https://raw.githubusercontent.com/BrunuhVille/flux-panel/refs/heads/main/install.sh"
INSTALL_DIR="/etc/gost"
ORIGIN_BIN_URL="https://github.com/BrunuhVille/flux-panel/releases/download/gost-latest/gost"
TMP_INSTALL="/tmp/flux-panel-install.sh"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "请使用 root 运行，或用 sudo 执行此脚本。"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_base_tools() {
  blue "==> 检查基础工具 curl/file..."
  local missing=()
  need_cmd curl || missing+=(curl)
  need_cmd file || missing+=(file)

  if ((${#missing[@]} == 0)); then
    green "基础工具已存在。"
    return 0
  fi

  yellow "缺少工具：${missing[*]}，正在尝试安装..."
  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  elif need_cmd dnf; then
    dnf install -y "${missing[@]}"
  elif need_cmd yum; then
    yum install -y "${missing[@]}"
  elif need_cmd apk; then
    apk add --no-cache "${missing[@]}"
  else
    red "无法自动安装基础工具，请先手动安装：${missing[*]}"
    exit 1
  fi
}

install_amd64_compat_on_arm() {
  local arch
  arch="$(uname -m)"
  blue "==> 当前系统架构：${arch}"

  case "${arch}" in
    x86_64|amd64)
      green "当前是 amd64/x86_64，直接运行原版安装脚本即可。"
      return 0
      ;;
    aarch64|arm64|armv7l|armv6l)
      yellow "检测到 ARM 架构，正在安装 amd64 兼容运行环境 qemu-user-static/binfmt..."
      ;;
    *)
      yellow "未知架构：${arch}，仍尝试安装兼容环境。"
      ;;
  esac

  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-user-static binfmt-support
    systemctl enable --now binfmt-support >/dev/null 2>&1 || true
    systemctl restart binfmt-support >/dev/null 2>&1 || true
  elif need_cmd dnf; then
    dnf install -y qemu-user-static systemd-binfmt || dnf install -y qemu-user-static
    systemctl enable --now systemd-binfmt >/dev/null 2>&1 || true
    systemctl restart systemd-binfmt >/dev/null 2>&1 || true
  elif need_cmd yum; then
    yum install -y qemu-user-static || true
    systemctl enable --now systemd-binfmt >/dev/null 2>&1 || true
    systemctl restart systemd-binfmt >/dev/null 2>&1 || true
  elif need_cmd apk; then
    apk add --no-cache qemu-x86_64 qemu-openrc qemu-binfmt || apk add --no-cache qemu-x86_64
    rc-service qemu-binfmt start >/dev/null 2>&1 || true
    rc-update add qemu-binfmt default >/dev/null 2>&1 || true
  else
    red "没有识别到支持的包管理器，请手动安装 qemu-user-static/binfmt 后重试。"
    exit 1
  fi

  green "兼容环境安装步骤完成。"
}

parse_from_text() {
  local text="$1"
  ADDR="$(printf '%s\n' "$text" | grep -oE -- '-a[[:space:]]+[^[:space:]]+' | awk '{print $2}' | tail -n1 || true)"
  SECRET="$(printf '%s\n' "$text" | grep -oE -- '-s[[:space:]]+[^[:space:]]+' | awk '{print $2}' | tail -n1 || true)"
}

ask_config() {
  ADDR=""
  SECRET=""

  echo
  blue "请粘贴原来的安装命令，例如："
  echo "curl -L ${INSTALL_SH_URL} -o ./install.sh && chmod +x ./install.sh && ./install.sh -a 107.175.77.38:6365 -s xxxxxxxxxxxxxxxxxxxxx"
  echo
  read -r -p "粘贴后回车；如果想手动输入 addr/secret，直接回车跳过：" PASTED_CMD || true

  if [[ -n "${PASTED_CMD:-}" ]]; then
    parse_from_text "${PASTED_CMD}"
  fi

  while [[ -z "${ADDR}" ]]; do
    read -r -p "请输入面板地址 addr，例如 107.175.77.38:6365：" ADDR
  done

  while [[ -z "${SECRET}" ]]; do
    read -r -p "请输入 secret：" SECRET
  done

  echo
  blue "即将使用以下配置安装："
  echo "addr   = ${ADDR}"
  echo "secret = ${SECRET}"
  read -r -p "确认继续？[Y/n] " CONFIRM || true
  CONFIRM="${CONFIRM:-Y}"
  case "${CONFIRM}" in
    y|Y|yes|YES) ;;
    *) red "已取消。"; exit 1 ;;
  esac
}

run_origin_installer() {
  blue "==> 下载原 flux-panel 安装脚本..."
  curl -fsSL "${INSTALL_SH_URL}" -o "${TMP_INSTALL}"
  chmod +x "${TMP_INSTALL}"

  blue "==> 运行原安装脚本..."
  bash "${TMP_INSTALL}" -a "${ADDR}" -s "${SECRET}" || true
}

ensure_custom_binary() {
  blue "==> 确保使用 flux-panel 定制版 gost 二进制..."
  mkdir -p "${INSTALL_DIR}"
  systemctl stop gost >/dev/null 2>&1 || true
  curl -fL "${ORIGIN_BIN_URL}" -o "${INSTALL_DIR}/gost"
  chmod +x "${INSTALL_DIR}/gost"
  file "${INSTALL_DIR}/gost" || true
}

ensure_service() {
  blue "==> 确保 systemd 服务存在并启动..."
  cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=Gost Proxy Service
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/gost
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl reset-failed gost >/dev/null 2>&1 || true
  systemctl enable gost
  systemctl restart gost
}

check_result() {
  blue "==> 等待服务连接面板..."
  sleep 5

  if systemctl is-active --quiet gost; then
    green "gost 服务状态：运行中"
  else
    red "gost 服务没有正常运行。最近日志如下："
    journalctl -u gost -n 80 --no-pager || true
    exit 1
  fi

  echo
  blue "最近日志："
  journalctl -u gost -n 40 --no-pager || true

  echo
  if journalctl -u gost -n 80 --no-pager 2>/dev/null | grep -qE 'WebSocket连接建立成功|连接建立成功|配置加载成功'; then
    green "安装完成：已看到连接/配置成功日志。请刷新面板查看在线状态。"
  else
    yellow "安装完成，但暂未在最近日志里看到连接成功字样。请稍等几十秒刷新面板，或执行：journalctl -u gost -f"
  fi
}

main() {
  need_root
  install_base_tools
  ask_config
  install_amd64_compat_on_arm
  run_origin_installer
  ensure_custom_binary
  ensure_service
  check_result
}

main "$@"
