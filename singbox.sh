#!/bin/bash

# =========================================================
# Sing-box 全局接管流量 (TUN模式)
# 特性：智能分组 + 强制SSH直连(防失联)
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
WEBUI_DIR="$CONFIG_DIR/ui"
UI_PORT="9090"
MIXED_PORT="2080"
SUB_URL=""

# 解析参数
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

if [ -z "$SUB_URL" ]; then
    echo -e "${RED}错误：请务必提供订阅链接！${PLAIN}"
    echo -e "用法: ./singbox.sh --sub \"http://你的订阅链接\""
    exit 1
fi

# --- 1. 核心：开启 IP 转发 (全局代理必须) ---
echo -e "${YELLOW}[1/5] 开启内核流量转发...${PLAIN}"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-singbox.conf
sysctl --system > /dev/null 2>&1

# --- 2. 核心：处理配置文件 (Python 生成 TUN 配置) ---
echo -e "${YELLOW}[2/5] 下载订阅并生成全局配置...${PLAIN}"
# 确保安装 python3
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y python3 curl wget
elif [ -f /etc/redhat-release ]; then
    yum install -y python3 curl wget
elif [ -f /etc/alpine-release ]; then
    apk add python3 curl wget
fi

TEMP_JSON="/tmp/singbox_sub.json"
wget -O "$TEMP_JSON" "$SUB_URL"

cat > /tmp/gen_tun_config.py <<EOF
import json
import sys
import re

sub_file = "$TEMP_JSON"
target_file = "$CONFIG_FILE"
ui_dir = "$WEBUI_DIR"
ui_port = $UI_PORT

def get_group_name(tag):
    tag = tag.upper()
    if re.search(r'🇭🇰|HK|HONG KONG|香港', tag): return "🇭🇰 香港节点"
    if re.search(r'🇯🇵|JP|JAPAN|日本', tag): return "🇯🇵 日本节点"
    if re.search(r'🇺🇸|US|USA|AMERICA|美国', tag): return "🇺🇸 美国节点"
    if re.search(r'🇸🇬|SG|SINGAPORE|新加坡', tag): return "🇸🇬 新加坡节点"
    if re.search(r'🇹🇼|TW|TAIWAN|台湾', tag): return "🇹🇼 台湾节点"
    return "🏳️ 其他节点"

try:
    with open(sub_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    proxies = []
    # 提取节点
    for out in data.get('outbounds', []):
        if out.get('type') not in ['direct', 'dns', 'block', 'selector', 'urltest']:
            proxies.append(out)
    
    if not proxies:
        print("Error: No proxies found.")
        sys.exit(1)

    # 智能分组
    groups = {}
    all_proxy_tags = []
    for proxy in proxies:
        tag = proxy.get('tag', 'unknown')
        all_proxy_tags.append(tag)
        g_name = get_group_name(tag)
        if g_name not in groups: groups[g_name] = []
        groups[g_name].append(tag)

    # 构建 Outbounds
    new_outbounds = []
    
    # 1. 主选择器
    selector_groups = ["♻️ 自动选择", "🚀 节点选择"] + list(groups.keys()) + ["DIRECT"]
    new_outbounds.append({"type": "selector", "tag": "PROXY", "outbounds": selector_groups})
    
    # 2. 自动测速
    new_outbounds.append({
        "type": "urltest", "tag": "♻️ 自动选择", 
        "outbounds": all_proxy_tags, 
        "url": "http://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
    })
    
    # 3. 手动选择
    new_outbounds.append({"type": "selector", "tag": "🚀 节点选择", "outbounds": all_proxy_tags})

    # 4. 地区分组
    for g_name, tags in groups.items():
        if len(tags) > 1:
            auto_tag = f"⚡ {g_name} 自动"
            new_outbounds.append({
                "type": "urltest", "tag": auto_tag, 
                "outbounds": tags, 
                "url": "http://www.gstatic.com/generate_204", "interval": "3m"
            })
            final_tags = [auto_tag] + tags
        else:
            final_tags = tags
        new_outbounds.append({"type": "selector", "tag": g_name, "outbounds": final_tags})

    new_outbounds.extend(proxies)
    new_outbounds.append({"type": "direct", "tag": "DIRECT"})
    new_outbounds.append({"type": "dns", "tag": "dns-out"})
    new_outbounds.append({"type": "block", "tag": "block"})

    # --- 最终配置 (全局流量接管关键部分) ---
    final_config = {
        "log": {"level": "info", "timestamp": True},
        # 1. DNS 劫持 (必须，否则无法解析)
        "dns": {
            "servers": [
                {"tag": "remote_dns", "address": "8.8.8.8", "detour": "PROXY"},
                {"tag": "local_dns", "address": "223.5.5.5", "detour": "DIRECT"}
            ],
            "rules": [
                {"outbound": "any", "server": "local_dns"}
            ],
            "final": "remote_dns",
            "strategy": "ipv4_only"
        },
        # 2. TUN 网卡 (劫持所有流量)
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "inet4_address": "172.19.0.1/30",
                "auto_route": True,
                "strict_route": False, # 关闭严格路由以避免回环问题
                "stack": "system",
                "sniff": True
            },
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "::",
                "listen_port": $MIXED_PORT
            }
        ],
        "experimental": {
            "clash_api": {
                "external_controller": f"0.0.0.0:{ui_port}",
                "external_ui": ui_dir,
                "secret": "",
                "default_mode": "rule"
            }
        },
        "outbounds": new_outbounds,
        "route": {
            "rules": [
                {"protocol": "dns", "outbound": "dns-out"},
                # --- 核心保护：SSH 流量强制直连，不走代理 ---
                {"port": 22, "outbound": "DIRECT"},
                {"protocol": "ssh", "outbound": "DIRECT"},
                
                {"clash_mode": "direct", "outbound": "DIRECT"},
                {"clash_mode": "global", "outbound": "PROXY"}
            ],
            "auto_detect_interface": True,
            "final": "PROXY"
        }
    }

    with open(target_file, 'w', encoding='utf-8') as f:
        json.dump(final_config, f, indent=2, ensure_ascii=False)
EOF

python3 /tmp/gen_tun_config.py
if [ $? -ne 0 ]; then
    echo -e "${RED}配置生成失败！请检查订阅。${PLAIN}"
    exit 1
fi

# --- 3. 授权 ---
# 给 sing-box 开通网络权限，防止 permission denied
mkdir -p /etc/systemd/system/sing-box.service.d/
cat > /etc/systemd/system/sing-box.service.d/override.conf <<EOF
[Service]
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF
systemctl daemon-reload

# --- 4. 重启 ---
echo -e "${YELLOW}[4/5] 重启 Sing-box...${PLAIN}"
systemctl restart sing-box

# --- 5. 验证 ---
echo -e "${YELLOW}[5/5] 验证连接...${PLAIN}"
sleep 2
IP=$(curl -s4 --max-time 3 ifconfig.me)

echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}      全局代理 (TUN) 已激活！      ${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "WebUI: http://$(curl -s4 ifconfig.me):$UI_PORT/ui/"
echo -e "当前 IP: $IP (如果是机场IP则成功)"
echo -e "SSH 保护: 已排除 22 端口，SSH 连接不受影响。"
echo -e "${GREEN}=============================================${PLAIN}"
