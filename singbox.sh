#!/bin/bash

# =========================================================
# Sing-box + WebUI 全能一键安装/重装脚本 (Final Version)
# 支持系统：Ubuntu / Debian / CentOS / Alpine
# 功能：环境检查、内核安装、UI部署、配置重置、兼容性修复
# =========================================================

# --- 变量定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
WEBUI_DIR="$CONFIG_DIR/ui"
UI_PORT="9090"
MIXED_PORT="2080"

# --- 1. 权限检查 ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

clear
echo -e "${BLUE}#################################################${PLAIN}"
echo -e "${BLUE}#      Sing-box + WebUI 一键安装/修复脚本       #${PLAIN}"
echo -e "${BLUE}#################################################${PLAIN}"
echo -e "${YELLOW}正在初始化安装环境...${PLAIN}"

# --- 2. 安装基础依赖 ---
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y curl wget tar unzip
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip
elif [ -f /etc/alpine-release ]; then
    apk add curl wget tar unzip
else
    echo -e "${RED}不支持的操作系统。${PLAIN}"
    exit 1
fi

# --- 3. 安装/更新 Sing-box 内核 ---
echo -e "${YELLOW}[1/5] 安装最新版 Sing-box 内核...${PLAIN}"
bash <(curl -fsSL https://sing-box.app/deb-install.sh)
if [ $? -ne 0 ]; then
    echo -e "${RED}内核安装失败，请检查网络连接。${PLAIN}"
    exit 1
fi

# --- 4. 部署 WebUI ---
echo -e "${YELLOW}[2/5] 部署 Metacubexd 面板...${PLAIN}"
# 清理旧文件
rm -rf "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR"

# 下载最新构建
wget -O "$WEBUI_DIR/ui.zip" "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
if [ $? -ne 0 ]; then
    echo -e "${RED}面板下载失败 (GitHub 连接超时)，请重试。${PLAIN}"
    exit 1
fi

# 解压并归位
unzip -o "$WEBUI_DIR/ui.zip" -d "$WEBUI_DIR" > /dev/null 2>&1
mv "$WEBUI_DIR/metacubexd-gh-pages"/* "$WEBUI_DIR/"
rm -rf "$WEBUI_DIR/metacubexd-gh-pages" "$WEBUI_DIR/ui.zip"

# --- 5. 注入兼容性补丁 (修复 FATAL 报错) ---
echo -e "${YELLOW}[3/5] 注入 Systemd 兼容性补丁...${PLAIN}"
# 这是为了防止新版内核运行旧版订阅配置时报错
mkdir -p /etc/systemd/system/sing-box.service.d/
cat > /etc/systemd/system/sing-box.service.d/override.conf <<EOF
[Service]
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"
EOF
systemctl daemon-reload

# --- 6. 生成标准配置文件 ---
echo -e "${YELLOW}[4/5] 重置 config.json 配置文件...${PLAIN}"
# 备份旧配置(如果有)
if [ -f "$CONFIG_FILE" ]; then
    mv "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    echo -e "(已备份旧配置为 .bak 文件)"
fi

# 写入绝对正确的纯净配置
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": $MIXED_PORT
    }
  ],
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:$UI_PORT",
      "external_ui": "$WEBUI_DIR",
      "secret": "",
      "default_mode": "rule"
    }
  },
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ]
  }
}
EOF

# --- 7. 启动服务 ---
echo -e "${YELLOW}[5/5] 重启服务并验证...${PLAIN}"
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

# 等待2秒让服务完全启动
sleep 2

# 获取 IP
IP=$(curl -s4 ifconfig.me)
if [ -z "$IP" ]; then
    IP="你的服务器IP"
fi

# 检查状态
if systemctl is-active --quiet sing-box; then
    echo -e "\n${GREEN}=============================================${PLAIN}"
    echo -e "${GREEN}             安装成功！(Success)             ${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "WebUI 面板地址: ${BLUE}http://$IP:$UI_PORT/ui/${PLAIN}"
    echo -e "HTTP/Socks端口: ${YELLOW}$MIXED_PORT${PLAIN}"
    echo -e ""
    echo -e "${YELLOW}下一步操作指南：${PLAIN}"
    echo -e "1. 浏览器打开上面的 WebUI 链接。"
    echo -e "2. 如果打不开，请去云服务商后台【安全组/防火墙】放行 ${RED}$UI_PORT${PLAIN} 端口。"
    echo -e "3. 这是一个纯净版，请在面板左侧 [Proxies] -> [Provider] 添加你的机场订阅。"
    echo -e "${GREEN}=============================================${PLAIN}"
else
    echo -e "${RED}服务启动失败！${PLAIN}"
    echo -e "请运行以下命令查看详细错误日志："
    echo -e "journalctl -u sing-box --no-pager -n 20"
fi
