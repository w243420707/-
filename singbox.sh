#!/bin/bash

# ==========================================
# Sing-box 一键安装与配置脚本
# 支持参数: --sub "订阅链接"
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 解析命令行参数
SUB_URL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sub)
            SUB_URL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本 (sudo su)${NC}"
  exit 1
fi

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}      Sing-box 自动安装脚本 (Linux)           ${NC}"
echo -e "${BLUE}==============================================${NC}"

# 1. 安装依赖
echo -e "${BLUE}>>> [1/6] 检查并安装依赖 (curl, jq, tar)...${NC}"
if command -v apt-get >/dev/null; then
    apt-get update -q && apt-get install -y -q curl jq tar
elif command -v yum >/dev/null; then
    yum install -y -q curl jq tar
elif command -v apk >/dev/null; then
    apk add -q curl jq tar
else
    echo -e "${RED}未知的包管理器，请手动安装 curl, jq, tar${NC}"
    exit 1
fi

# 2. 识别架构
echo -e "${BLUE}>>> [2/6] 检测系统架构...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    armv7l) SING_ARCH="armv7" ;;
    s390x) SING_ARCH="s390x" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac
echo -e "${GREEN}    架构: linux-$SING_ARCH${NC}"

# 3. 下载 Sing-box
echo -e "${BLUE}>>> [3/6] 获取并安装 Sing-box 最新版...${NC}"
API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r ".assets[] | select(.name | contains(\"linux-$SING_ARCH\")) | select(.name | contains(\".tar.gz\")) | .browser_download_url" | head -n 1)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}获取下载链接失败。尝试使用备用硬编码版本 (1.8.0)...${NC}"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.8.0/sing-box-1.8.0-linux-$SING_ARCH.tar.gz"
fi

echo -e "${GREEN}    下载地址: $DOWNLOAD_URL${NC}"
curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

# 解压安装
tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")

# 停止旧服务（如果存在）
systemctl stop sing-box 2>/dev/null

cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

INSTALLED_VER=$(sing-box version | head -n 1 | awk '{print $3}')
echo -e "${GREEN}    安装成功，当前版本: $INSTALLED_VER${NC}"

# 4. 处理订阅配置
echo -e "${BLUE}>>> [4/6] 配置订阅...${NC}"
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"

# 如果命令行没传 --sub，则询问
if [ -z "$SUB_URL" ]; then
    echo -e "${YELLOW}请输入 Sing-box 格式的订阅链接:${NC}"
    read -p "链接: " SUB_URL
fi

if [ -z "$SUB_URL" ]; then
    echo -e "${RED}错误: 未提供订阅链接，脚本退出。${NC}"
    exit 1
fi

echo -e "${GREEN}    正在下载配置: $SUB_URL${NC}"
# 使用 User-Agent 防止被某些防火墙拦截
curl -L -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"

# 验证 JSON
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}错误: 下载的内容不是合法的 JSON。请检查链接是否需要鉴权或已过期。${NC}"
    echo -e "文件内容前10行预览:"
    head -n 10 "$CONFIG_FILE"
    exit 1
fi

# 5. 解析节点与地区选择
echo -e "${BLUE}>>> [5/6] 解析节点组/地区...${NC}"

# 提取 selector 或 urltest 类型的 tag
TAGS_JSON=$(jq -r '[.outbounds[] | select(.type=="selector" or .type=="urltest") | .tag] | .[]' "$CONFIG_FILE")

if [ -z "$TAGS_JSON" ]; then
    echo -e "${YELLOW}配置文件中未发现明显的选择器组(Selector)，将使用默认配置启动。${NC}"
else
    echo -e "${GREEN}检测到以下节点分组/地区:${NC}"
    declare -a TAG_ARRAY
    i=0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            TAG_ARRAY[$i]="$line"
            echo -e "  [$i] ${TAG_ARRAY[$i]}"
            ((i++))
        fi
    done <<< "$TAGS_JSON"
    
    echo -e "${YELLOW}------------------------------------------------${NC}"
    echo -e "${YELLOW}注意: 此步骤仅供确认。通常订阅转换后的配置已包含 'Auto' 或 'Select' 组。${NC}"
    echo -e "${YELLOW}直接回车将使用默认配置启动。${NC}"
    echo -e "${YELLOW}------------------------------------------------${NC}"
    
    # 这里我们不做复杂的 JSON 修改，因为 sing-box 路由非常灵活，
    # 强制修改 default outbound 可能会破坏 dns 规则或 block 规则。
    # 真正的地区选择建议在客户端（面板）进行，或者在订阅转换时指定“默认选中”。
fi

# 6. 启动服务
echo -e "${BLUE}>>> [6/6] 启动 Sing-box 服务...${NC}"

# 创建 systemd 文件
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

# 检查状态
sleep 3
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}      Sing-box 安装并启动成功！               ${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "状态: 运行中 (Active)"
    echo -e "配置文件: $CONFIG_FILE"
    echo -e "常用命令:"
    echo -e "  - 重启: systemctl restart sing-box"
    echo -e "  - 停止: systemctl stop sing-box"
    echo -e "  - 日志: journalctl -u sing-box -f"
    echo -e "${BLUE}提示: 如果需要开启面板，请确保订阅配置中包含 experimental.clash_api 字段${NC}"
else
    echo -e "${RED}启动失败！请查看日志排查问题：${NC}"
    journalctl -u sing-box -n 20 --no-pager
    exit 1
fi
