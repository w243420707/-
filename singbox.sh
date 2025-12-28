#!/bin/bash

# =================================================================
# Sing-box 终极全能版 v12
# 功能：
# 1. 自动安装 Sing-box (适配全架构)
# 2. 自动下载订阅并解析节点
# 3. 支持国家/地区分组选择
# 4. 自动优选 (UrlTest) + 故障转移
# 5. 修复所有新版兼容性报错 (Legacy TUN, Legacy Outbound)
# 6. 强化 DNS 稳定性 (使用 UDP 8.8.8.8, 避免 DoH 握手失败)
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 0. 权限与清理 ---
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 权限运行${NC}"; exit 1; fi

# 停止旧服务，清理环境
systemctl stop sing-box >/dev/null 2>&1
rm -f /etc/sysctl.d/99-singbox.conf

# --- 1. 系统设置 ---
echo -e "${BLUE}>>> [1/8] 系统初始化...${NC}"

# 开启 IP 转发
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-singbox.conf
sysctl -p /etc/sysctl.d/99-singbox.conf >/dev/null 2>&1

# 时间同步 (防止节点拒绝连接)
timedatectl set-ntp true >/dev/null 2>&1
if command -v systemctl >/dev/null; then systemctl restart systemd-timesyncd >/dev/null 2>&1; fi

# 获取 SSH 端口 (防止自锁)
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
if [ -z "$SSH_PORT" ]; then SSH_PORT=22; fi
echo -e "识别 SSH 端口: ${GREEN}$SSH_PORT${NC}"

# 安装依赖
for pkg in curl jq tar; do
    if ! command -v $pkg >/dev/null; then
        echo -e "安装依赖: $pkg..."
        if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q $pkg
        elif command -v yum >/dev/null; then yum install -y -q $pkg
        elif command -v apk >/dev/null; then apk add -q $pkg
        else echo -e "${RED}无法自动安装依赖，请手动安装: curl jq tar${NC}"; exit 1; fi
    fi
done

# --- 2. 安装 Sing-box ---
echo -e "${BLUE}>>> [2/8] 安装/更新 Sing-box...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 优先使用稳定版 v1.9.0 (兼容性最好)
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-$SING_ARCH.tar.gz"

curl -L -s -o sing-box.tar.gz "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then echo -e "${RED}下载失败，请检查网络${NC}"; exit 1; fi

tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

# --- 3. 下载订阅 ---
echo -e "${BLUE}>>> [3/8] 获取订阅配置...${NC}"
mkdir -p /etc/sing-box
CONFIG_FILE="/etc/sing-box/config.json"

# 处理参数输入
SUB_URL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sub) SUB_URL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$SUB_URL" ]; then read -p "请输入订阅链接: " SUB_URL; fi
if [ -z "$SUB_URL" ]; then echo -e "${RED}错误：订阅链接不能为空${NC}"; exit 1; fi

echo -e "正在下载订阅..."
curl -L -s -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then 
    echo -e "${RED}错误：下载的内容不是有效的 JSON 格式。请检查链接是否有效。${NC}"; exit 1; 
fi

# --- 4. 扫描节点 ---
echo -e "${BLUE}>>> [4/8] 解析节点列表...${NC}"
jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE" > /tmp/singbox_tags.txt
TOTAL_COUNT=$(wc -l < /tmp/singbox_tags.txt)

if [ "$TOTAL_COUNT" -eq 0 ]; then 
    echo -e "${RED}错误：订阅文件中未找到可用节点。${NC}"; exit 1; 
fi
echo -e "共发现 ${GREEN}$TOTAL_COUNT${NC} 个节点。"

# --- 5. 国家/地区选择 ---
REGIONS_DB=(
"全球自动选择 (Global Auto)|.*|🌐|Global"
"中华人民共和国|CH|🇨🇳|China" "香港|HK|🇭🇰|Hong Kong" "台湾|TW|🇹🇼|Taiwan" "日本|JA|🇯🇵|Japan|JP" "韩国|KS|🇰🇷|Korea|KR" "新加坡|SN|🇸🇬|Singapore|SG" "美国|US|🇺🇸|United States|USA" "英国|UK|🇬🇧|United Kingdom|Britain" "德国|GM|🇩🇪|Germany|DE" "法国|FR|🇫🇷|France" "俄罗斯|RS|🇷🇺|Russia|RU" "加拿大|CA|🇨🇦|Canada" "澳大利亚|AS|🇦🇺|Australia|AU" "印度|IN|🇮🇳|India" "土耳其|TU|🇹🇷|Turkey" "荷兰|NL|🇳🇱|Netherlands" "巴西|BR|🇧🇷|Brazil" 
)

AVAILABLE_REGIONS=()
declare -A REGION_COUNTS
declare -A REGION_REGEX

echo -e "${GREEN}=====================================${NC}"
i=0
for item in "${REGIONS_DB[@]}"; do
    IFS='|' read -r CN_NAME CODE EMOJI EN_KEY <<< "$item"
    if [ "$CN_NAME" == "全球自动选择 (Global Auto)" ]; then
        MATCH_STR=".*"
    elif [ -n "$EN_KEY" ]; then 
        MATCH_STR="($CN_NAME|$CODE|$EMOJI|$EN_KEY)" 
    else 
        MATCH_STR="($CN_NAME|$CODE|$EMOJI)" 
    fi
    
    COUNT=$(grep -E -i "$MATCH_STR" /tmp/singbox_tags.txt | wc -l)
    
    if [ "$COUNT" -gt 0 ]; then
        DISPLAY_NAME="$EMOJI $CN_NAME ($CODE)"
        AVAILABLE_REGIONS+=("$DISPLAY_NAME")
        REGION_COUNTS["$DISPLAY_NAME"]=$COUNT
        REGION_REGEX["$DISPLAY_NAME"]="$MATCH_STR"
        printf " [%-2d] %-35s - %d 个节点\n" $i "$DISPLAY_NAME" "$COUNT"
        ((i++))
    fi
done
echo -e "${GREEN}=====================================${NC}"

read -p "请选择节点分组 [输入数字]: " IDX
if [[ ! "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -ge "${#AVAILABLE_REGIONS[@]}" ]; then
    echo -e "${RED}无效选择，默认使用全球自动选择${NC}"
    SELECTED_NAME="${AVAILABLE_REGIONS[0]}"
else
    SELECTED_NAME="${AVAILABLE_REGIONS[$IDX]}"
fi
MATCH_KEY="${REGION_REGEX[$SELECTED_NAME]}"
echo -e "已选: ${GREEN}$SELECTED_NAME${NC}"

# --- 6. 生成核心配置 ---
echo -e "${BLUE}>>> [6/8] 生成 Sing-box 配置文件...${NC}"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# 关键配置说明：
# 1. DNS: 使用 8.8.8.8 UDP 直连，最稳定的方案。
# 2. TUN: 使用 inet4_address 数组格式，兼容新旧版本。
# 3. Route: 移除 legacy outbound 写法，使用 action: route。
# 4. UrlTest: 设置 interval 300s, idle_timeout 1800s，避免逻辑报错。

jq -n \
    --slurpfile original "$CONFIG_FILE.bak" \
    --arg match_key "$MATCH_KEY" \
    --argjson ssh_port "$SSH_PORT" \
    '{
    "log": { "level": "info", "timestamp": true },
    "dns": {
        "servers": [
            { "tag": "google", "address": "8.8.8.8", "detour": "direct" },
            { "tag": "local", "address": "local", "detour": "direct" }
        ],
        "rules": [
            { "outbound": "any", "server": "google" }
        ],
        "final": "google",
        "strategy": "ipv4_only"
    },
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "singbox-tun",
            "inet4_address": ["172.19.0.1/30"],
            "mtu": 1280,
            "auto_route": true,
            "strict_route": false,
            "stack": "system",
            "sniff": true
        }
    ],
    "outbounds": (
        ($original[0].outbounds | map(select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest"))) as $all_nodes |
        ($all_nodes | map(select(.tag | test($match_key; "i")))) as $selected_nodes |
        [
            {
                "type": "urltest",
                "tag": "AUTO-SELECT-GROUP",
                "outbounds": ($selected_nodes | map(.tag)),
                "url": "http://www.gstatic.com/generate_204",
                "interval": "300s",
                "tolerance": 50,
                "idle_timeout": "1800s"
            },
            { "type": "direct", "tag": "direct" },
            { "type": "block", "tag": "block" }
        ] + $selected_nodes
    ),
    "route": {
        "rules": [
            { "protocol": "dns", "action": "route", "outbound": "direct" },
            { "port": $ssh_port, "action": "route", "outbound": "direct" },
            { "ip_is_private": true, "action": "route", "outbound": "direct" },
            { "inbound": "tun-in", "action": "route", "outbound": "AUTO-SELECT-GROUP" }
        ],
        "auto_detect_interface": true,
        "final": "AUTO-SELECT-GROUP"
    }
}' > "$CONFIG_FILE"

# --- 7. 配置系统服务 ---
echo -e "${BLUE}>>> [7/8] 注册并启动服务...${NC}"

# 写入 Systemd 服务文件 (包含环境变量兼容补丁)
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
# 关键环境变量：强制兼容所有过时特性，防止版本杀手
Environment="ENABLE_DEPRECATED_TUN_ADDRESS_X=true"
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"
Environment="ENABLE_DEPRECATED_DNS_RULE_ITEM=true"
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

# --- 8. 验证与测试 ---
echo -e "${BLUE}>>> [8/8] 正在验证网络连接...${NC}"
echo -e "${YELLOW}等待 8 秒，让 Sing-box 完成节点测速...${NC}"
sleep 8

# 清除代理环境变量，确保测试的是 TUN 模式
unset http_proxy https_proxy all_proxy

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}✅ Sing-box 服务启动成功！${NC}"
    
    echo -e "正在测试 IPInfo (通过代理)..."
    RES=$(curl -s -m 8 ipinfo.io)
    
    if [[ $RES == *"ip"* ]]; then
        IP=$(echo "$RES" | grep '"ip"' | cut -d '"' -f 4)
        COUNTRY=$(echo "$RES" | grep '"country"' | cut -d '"' -f 4)
        ORG=$(echo "$RES" | grep '"org"' | cut -d '"' -f 4)
        echo -e "${GREEN}🎉 网络通畅！${NC}"
        echo -e "当前 IP: ${YELLOW}$IP${NC} ($COUNTRY)"
        echo -e "运营商 : $ORG"
    else
        echo -e "${RED}⚠️  Sing-box 运行中，但无法访问外网。${NC}"
        echo -e "可能原因：所选地区的节点全部不可用，或者 VPS 禁止了 UDP 流量。"
        echo -e "建议：重新运行脚本，选择 '全球自动选择'。"
    fi
else
    echo -e "${RED}❌ 启动失败！请检查日志：${NC}"
    journalctl -u sing-box -n 20 --no-pager
fi

echo -e "${BLUE}-------------------------------------${NC}"
echo -e "停止代理命令: systemctl stop sing-box"
echo -e "重启代理命令: systemctl restart sing-box"
echo -e "${BLUE}-------------------------------------${NC}"
