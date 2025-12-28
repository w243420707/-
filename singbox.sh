#!/bin/bash

# =================================================================
# Sing-box 最终修复版 v3 (解决 Duplicate Tag 重复标签问题)
# 核心逻辑：只保留选中的节点，彻底杜绝重复。
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 命令行参数解析
SUB_URL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sub) SUB_URL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 权限运行${NC}"; exit 1; fi

# 2. 依赖检查
echo -e "${BLUE}>>> [1/7] 检查依赖...${NC}"
for pkg in curl jq tar; do
    if ! command -v $pkg >/dev/null; then
        echo -e "${YELLOW}正在安装 $pkg...${NC}"
        if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q $pkg
        elif command -v yum >/dev/null; then yum install -y -q $pkg
        elif command -v apk >/dev/null; then apk add -q $pkg
        else echo -e "${RED}无法自动安装，请手动安装: curl jq tar${NC}"; exit 1; fi
    fi
done

# 3. 安装 Sing-box
echo -e "${BLUE}>>> [2/7] 安装 Sing-box...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    *) echo -e "${RED}不支持: $ARCH${NC}"; exit 1 ;;
esac

API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r ".assets[] | select(.name | contains(\"linux-$SING_ARCH\")) | select(.name | contains(\".tar.gz\")) | .browser_download_url" | head -n 1)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-$SING_ARCH.tar.gz"
fi
curl -L -s -o sing-box.tar.gz "$DOWNLOAD_URL"
tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
systemctl stop sing-box 2>/dev/null
cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

# 4. 下载订阅
echo -e "${BLUE}>>> [3/7] 下载配置...${NC}"
mkdir -p /etc/sing-box
CONFIG_FILE="/etc/sing-box/config.json"

if [ -z "$SUB_URL" ]; then read -p "请输入订阅链接: " SUB_URL; fi
if [ -z "$SUB_URL" ]; then echo -e "${RED}链接为空${NC}"; exit 1; fi

curl -L -s -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}无效的 JSON 订阅${NC}"; exit 1; fi

# 5. 扫描节点 (使用文件缓存避免参数过长)
echo -e "${BLUE}>>> [4/7] 扫描节点...${NC}"
jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE" > /tmp/singbox_tags.txt
TOTAL_COUNT=$(wc -l < /tmp/singbox_tags.txt)

if [ "$TOTAL_COUNT" -eq 0 ]; then echo -e "${RED}未找到可用节点${NC}"; exit 1; fi

# 国家库
REGIONS_DB=(
"全选 (Global Auto)|.*"
"香港 (HK)|HK|Hong Kong|🇭🇰" "台湾 (TW)|TW|Taiwan|🇹🇼" "日本 (JP)|JP|Japan|🇯🇵"
"韩国 (KR)|KR|Korea|🇰🇷" "新加坡 (SG)|SG|Singapore|🇸🇬" "美国 (US)|US|United States|🇺🇸"
"英国 (UK)|UK|United Kingdom|🇬🇧" "德国 (DE)|DE|Germany|🇩🇪" "法国 (FR)|FR|France|🇫🇷"
"俄罗斯 (RU)|RU|Russia|🇷🇺" "加拿大 (CA)|CA|Canada|🇨🇦"
)

AVAILABLE_REGIONS=()
declare -A REGION_COUNTS
declare -A REGION_REGEX

for item in "${REGIONS_DB[@]}"; do
    IFS='|' read -r NAME KEY EXTRA EMOJI <<< "$item"
    MATCH_STR="($KEY|$EXTRA|$EMOJI)"
    # 修复：排除 Global Auto 的 .* 以避免 grep 报错，直接赋值
    if [[ "$NAME" == *"Global Auto"* ]]; then MATCH_STR=".*"; fi
    
    COUNT=$(grep -E -i "$MATCH_STR" /tmp/singbox_tags.txt | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        AVAILABLE_REGIONS+=("$NAME")
        REGION_COUNTS["$NAME"]=$COUNT
        REGION_REGEX["$NAME"]="$MATCH_STR"
    fi
done

# 6. 选择菜单
echo -e "${GREEN}=====================================${NC}"
i=0
for region in "${AVAILABLE_REGIONS[@]}"; do
    printf " [%d] %-20s (%d 节点)\n" $i "$region" "${REGION_COUNTS[$region]}"
    ((i++))
done
echo -e "${YELLOW}-------------------------------------${NC}"
read -p "请选择: " IDX

if [[ ! "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -ge "${#AVAILABLE_REGIONS[@]}" ]; then
    echo -e "${RED}无效选择${NC}"; exit 1
fi

SELECTED_NAME="${AVAILABLE_REGIONS[$IDX]}"
MATCH_KEY="${REGION_REGEX[$SELECTED_NAME]}"
echo -e "${GREEN}已选: $SELECTED_NAME${NC}"

# 7. 重构配置 (修复重复 Tag 问题)
echo -e "${BLUE}>>> [5/7] 生成配置 (Fix Duplicate Tag)...${NC}"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# 关键逻辑说明：
# 1. 仅提取原始 config 中所有 outbounds (包含所有节点)
# 2. 在 jq 内部使用 map + select 过滤出符合条件的 selected_nodes
# 3. 重新组装 outbounds 数组：
#    - [URLTest组]
#    - [direct]
#    - [block]
#    - [selected_nodes] (只放选中的！不放原来的全部！这就解决了重复问题)

jq -n \
    --slurpfile original "$CONFIG_FILE.bak" \
    --arg match_key "$MATCH_KEY" \
    '{
    "log": { "level": "info", "timestamp": true },
    "dns": {
        "servers": [
            { "tag": "cf-doh", "address": "https://1.1.1.1/dns-query", "detour": "direct" },
            { "tag": "local", "address": "local", "detour": "direct" }
        ],
        "rules": [
            { "outbound": "any", "server": "cf-doh" }
        ]
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "0.0.0.0",
            "listen_port": 2080,
            "sniff": true
        }
    ],
    "outbounds": (
        # 1. 从原始文件提取所有的实际节点对象
        ($original[0].outbounds | map(select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest"))) as $all_nodes |
        
        # 2. 根据正则过滤出我们想要的节点对象
        ($all_nodes | map(select(.tag | test($match_key; "i")))) as $selected_nodes |
        
        # 3. 构造新的列表：组 + 直连 + 阻断 + 选中的节点
        [
            {
                "type": "urltest",
                "tag": "AUTO-SELECT-GROUP",
                "outbounds": ($selected_nodes | map(.tag)),
                "url": "https://www.gstatic.com/generate_204",
                "interval": "30s",
                "tolerance": 50
            },
            { "type": "direct", "tag": "direct" },
            { "type": "block", "tag": "block" }
        ] + $selected_nodes
    ),
    "route": {
        "rules": [
            { "protocol": "dns", "outbound": "dns-out" },
            { "inbound": "mixed-in", "action": "route", "outbound": "AUTO-SELECT-GROUP" }
        ],
        "auto_detect_interface": true
    }
}' > "$CONFIG_FILE"

# 8. 启动服务
echo -e "${BLUE}>>> [6/7] 启动服务...${NC}"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

sleep 2
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}✅ 启动成功！${NC}"
    echo -e "端口: 2080"
    echo -e "export http_proxy=\"http://127.0.0.1:2080\""
    echo -e "export https_proxy=\"http://127.0.0.1:2080\""
    echo -e "curl -m 10 ipinfo.io"
else
    echo -e "${RED}启动失败，最后日志：${NC}"
    journalctl -u sing-box -n 10 --no-pager
fi
