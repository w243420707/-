#!/bin/bash

# =========================================================
# Sing-box + WebUI (Metacubexd) 一键全自动安装脚本
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
WEBUI_DIR="/etc/sing-box/ui"
UI_PORT="9090"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

echo -e "${BLUE}正在初始化环境...${PLAIN}"

# 1. 安装基础依赖 (curl, wget, tar, unzip, jq)
# jq 用于处理 JSON 配置文件
if [ -f /etc/debian_version ]; then
    apt-get update -y
    apt-get install -y curl wget tar unzip jq
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip jq
else
    echo -e "${RED}无法识别的操作系统，脚本仅支持 Debian/Ubuntu 或 CentOS/RHEL${PLAIN}"
    exit 1
fi

# 2. 安装 Sing-box
echo -e "${YELLOW}[1/4] 检查 Sing-box 安装状态...${PLAIN}"
if ! command -v sing-box &> /dev/null; then
    echo -e "未检测到 sing-box，正在安装最新正式版..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Sing-box 安装失败！${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}Sing-box 安装成功。${PLAIN}"
else
    echo -e "${GREEN}Sing-box 已安装，跳过。${PLAIN}"
fi

# 3. 下载并部署 WebUI (Metacubexd)
echo -e "${YELLOW}[2/4] 部署 WebUI 面板 (Metacubexd)...${PLAIN}"
mkdir -p "$WEBUI_DIR"

# 清理旧文件
rm -rf "$WEBUI_DIR"/*

echo -e "正在从 GitHub 下载 WebUI 资源..."
# 使用 gh-pages 分支的 zip 包
wget -O "$WEBUI_DIR/ui.zip" "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"

if [ $? -ne 0 ]; then
    echo -e "${RED}WebUI 下载失败，请检查服务器网络 (GitHub 连接)。${PLAIN}"
    exit 1
fi

echo -e "正在解压..."
unzip -o "$WEBUI_DIR/ui.zip" -d "$WEBUI_DIR" > /dev/null 2>&1
# 移动子文件夹内容到 ui 根目录
mv "$WEBUI_DIR/metacubexd-gh-pages"/* "$WEBUI_DIR/"
rm -rf "$WEBUI_DIR/metacubexd-gh-pages" "$WEBUI_DIR/ui.zip"
echo -e "${GREEN}WebUI 部署完成，路径: $WEBUI_DIR${PLAIN}"

# 4. 智能配置 Config.json
echo -e "${YELLOW}[3/4] 配置 Sing-box API 设置...${PLAIN}"

# 如果配置文件不存在，创建一个基础模板
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "未找到配置文件，创建默认配置..."
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
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
fi

# 使用 jq 工具合并配置，强制开启 Clash API 和 external_ui
# 下面的命令会读取现有的 config.json，并插入/覆盖 experimental 字段
echo -e "正在更新配置文件..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" # 备份原配置

# 定义要注入的 JSON 片段
API_CONFIG=$(cat <<EOF
{
  "clash_api": {
    "external_controller": "0.0.0.0:$UI_PORT",
    "external_ui": "$WEBUI_DIR",
    "secret": "",
    "default_mode": "rule"
  }
}
EOF
)

# 使用 jq 将配置合并 (如果 experimental 不存在则创建，如果存在则合并 clash_api)
# 逻辑：读取文件 -> 如果没有 experimental 键，添加它 -> 在 experimental 中合并 clash_api -> 写回文件
jq --argjson api "$API_CONFIG" '.experimental += $api | .experimental.clash_api = $api.clash_api' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}配置文件更新成功！(已备份原文件为 config.json.bak)${PLAIN}"
else
    echo -e "${RED}配置文件更新失败，请检查 json 格式。恢复原文件...${PLAIN}"
    mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    exit 1
fi

# 5. 重启服务
echo -e "${YELLOW}[4/4] 重启 Sing-box 服务...${PLAIN}"
systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

# 检查服务状态
if systemctl is-active --quiet sing-box; then
    IP=$(curl -s4 ifconfig.me)
    echo -e "\n${GREEN}=============================================${PLAIN}"
    echo -e "${GREEN}          安装与配置全部完成！               ${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "WebUI 访问地址: ${BLUE}http://$IP:$UI_PORT/ui/${PLAIN}"
    echo -e "API 地址:       ${BLUE}http://$IP:$UI_PORT${PLAIN}"
    echo -e "配置文件路径:   ${YELLOW}$CONFIG_FILE${PLAIN}"
    echo -e "UI文件路径:     ${YELLOW}$WEBUI_DIR${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "注意：请确保你的云服务器防火墙已放行 TCP ${RED}$UI_PORT${PLAIN} 端口"
else
    echo -e "${RED}服务启动失败！请使用 'journalctl -u sing-box -e' 查看日志。${PLAIN}"
fi
