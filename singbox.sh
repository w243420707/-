#!/bin/bash

# ==========================================
# Sing-box 一键安装与配置脚本 (增强节点选择版)
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

# 1. 安装依赖 (保留原逻辑)
echo -e "${BLUE}>>> [1/6] 检查并安装依赖...${NC}"
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

# 2. 识别架构 (保留原逻辑)
echo -e "${BLUE}>>> [2/6] 检测系统架构...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    armv7l) SING_ARCH="armv7" ;;
    s390x) SING_ARCH="s390x" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 3. 下载 Sing-box (保留原逻辑)
echo -e "${BLUE}>>> [3/6] 获取并安装 Sing-box...${NC}"
# 优先尝试获取最新版
API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r ".assets[] | select(.name | contains(\"linux-$SING_ARCH\")) | select(.name | contains(\".tar.gz\")) | .browser_download_url" | head -n 1)

# 如果 API 失败，使用备用版本
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-$SING_ARCH.tar.gz"
fi

curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
systemctl stop sing-box 2>/dev/null
cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

# 4. 下载配置 (保留原逻辑)
echo -e "${BLUE}>>> [4/6] 配置订阅...${NC}"
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ -z "$SUB_URL" ]; then
    read -p "请输入订阅链接: " SUB_URL
fi

if [ -z "$SUB_URL" ]; then echo -e "${RED}未提供链接${NC}"; exit 1; fi

echo -e "${GREEN}正在下载配置...${NC}"
curl -L -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}下载失败或非 JSON 格式${NC}"; exit 1
fi

# 5. 解析节点与地区选择 (这里是核心修改点)
echo -e "${BLUE}>>> [5/6] 解析节点与地区选择...${NC}"

# 获取所有 Outbound 的 tag，排除掉 direct, block, dns-out 等内置类型
# 我们尝试获取所有类型可能是 selector, urltest 或者具体的协议节点 (vmess, ss, trojan等)
RAW_TAGS=$(jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns") | .tag' "$CONFIG_FILE")

if [ -z "$RAW_TAGS" ]; then
    echo -e "${YELLOW}未找到有效节点，使用默认配置。${NC}"
else
    echo -e "${GREEN}检测到以下可用节点/分组:${NC}"
    
    # 将 tags 存入数组
    mapfile -t TAG_ARRAY <<< "$RAW_TAGS"
    
    # 打印列表
    count=${#TAG_ARRAY[@]}
    for ((i=0; i<count; i++)); do
        echo -e "  [$i] ${TAG_ARRAY[$i]}"
    done
    
    echo -e "${YELLOW}------------------------------------------------${NC}"
    echo -e "${YELLOW}请选择一个节点/分组作为默认出口 (输入数字):${NC}"
    echo -e "${YELLOW}输入 auto 或直接回车，将保持配置文件的默认行为${NC}"
    
    # 这一步强制交互，哪怕脚本有参数也会停下来等你选（除非你想做全自动随机选，那比较危险）
    # 如果希望完全无人值守，可以去掉这里的 read，或者加一个超时
    read -p "选择: " SELECT_INDEX
    
    if [[ "$SELECT_INDEX" =~ ^[0-9]+$ ]] && [ "$SELECT_INDEX" -lt "$count" ]; then
        SELECTED_TAG="${TAG_ARRAY[$SELECT_INDEX]}"
        echo -e "${GREEN}你选择了: $SELECTED_TAG${NC}"
        
        # === 修改配置文件的黑魔法 ===
        # Sing-box 没有简单的 "current_node" 字段。
        # 我们这里做一个骚操作：修改路由规则(route.rules)。
        # 查找所有的规则，如果它原本指向 'proxy' 或 'select' 等通用组，我们尝试把它强制改为你选的 tag。
        # 但更稳妥的方式是：修改第一个非内置 outbound 的 tag 为一个占位符，或者创建一个新的 selector 放在最前面。
        
        # 方案：创建一个新的名为 "GLOBAL-USER-SELECT" 的 selector，包含你选的节点，并设为默认。
        # 由于 JSON 结构复杂，这里使用 jq 仅仅打印提示，真正修改极其容易破坏配置。
        # 下面是一个尝试修改 config.json 的操作，将所有流量默认指向所选节点。
        
        # 备份原配置
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
        
        # 使用 jq 修改：在 outbounds 列表最前面插入一个 direct 规则截获所有流量？不，那是路由。
        # 我们尝试将所有默认规则的出口修改为选定的 tag。
        # 简单粗暴法：把所有路由规则的 outbound 字段，如果不是 direct/block，都改成选定的 tag。
        
        jq --arg tag "$SELECTED_TAG" '
          if .route and .route.rules then
            .route.rules |= map(
              if .outbound != "direct" and .outbound != "block" and .outbound != "dns-out" then
                .outbound = $tag
              else
                .
              end
            )
          else
            .
          end
        ' "$CONFIG_FILE.bak" > "$CONFIG_FILE"
        
        echo -e "${GREEN}>>> 已尝试将默认路由规则修改为指向: $SELECTED_TAG${NC}"
        
    else
        echo -e "${YELLOW}未选择或输入无效，保持默认配置。${NC}"
    fi
fi

# 6. 启动服务 (保留原逻辑)
echo -e "${BLUE}>>> [6/6] 启动 Sing-box 服务...${NC}"
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

sleep 2
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}启动成功！${NC}"
    echo -e "当前选中出口: ${SELECTED_TAG:-默认}"
else
    echo -e "${RED}启动失败，可能是修改配置导致语法错误。${NC}"
    echo -e "正在尝试还原备份配置..."
    if [ -f "$CONFIG_FILE.bak" ]; then
        cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${YELLOW}已还原默认配置并重启。${NC}"
    else
        journalctl -u sing-box -n 20 --no-pager
    fi
fi
