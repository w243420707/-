#!/bin/bash

# =========================================================
# Sing-box 全局代理(Tun) + 智能分组 终极安装脚本
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

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}" 
   exit 1
fi

# --- 1. 开启 IP 转发 (Tun 模式核心) ---
echo -e "${YELLOW}[1/6] 开启系统 IP 转发...${PLAIN}"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-singbox.conf
sysctl --system > /dev/null 2>&1

# --- 2. 安装依赖 ---
echo -e "${YELLOW}[2/6] 安装依赖环境...${PLAIN}"
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y curl wget tar unzip python3
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip python3
elif [ -f /etc/alpine-release ]; then
    apk add curl wget tar unzip python3
fi

# --- 3. 安装 Sing-box ---
echo -e "${YELLOW}[3/6] 安装/更新 Sing-box...${PLAIN}"
bash <(curl -fsSL https://sing-box.app/deb-install.sh)

# --- 4. 部署 WebUI ---
echo -e "${YELLOW}[4/6] 部署 Metacubexd 面板...${PLAIN}"
rm -rf "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR"
wget -q -O "$WEBUI_DIR/ui.zip" "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
unzip -o "$WEBUI_DIR/ui.zip" -d "$WEBUI_DIR" > /dev/null 2>&1
mv "$WEBUI_DIR/metacubexd-gh-pages"/* "$WEBUI_DIR/"
rm -rf "$WEBUI_DIR/metacubexd-gh-pages" "$WEBUI_DIR/ui.zip"

# --- 5. 注入 Systemd 补丁 ---
echo -e "${YELLOW}[5/6] 注入 Systemd 权限补丁...${PLAIN}"
mkdir -p /etc/systemd/system/sing-box.service.d/
cat > /etc/systemd/system/sing-box.service.d/override.conf <<EOF
[Service]
Environment="ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true"
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF
systemctl daemon-reload

# --- 6. Python 生成 Tun 配置文件 ---
echo -e "${YELLOW}[6/6] 下载订阅并生成全局 Tun 配置...${PLAIN}"

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
    if re.search(r'🇰🇷|KR|KOREA|韩国', tag): return "🇰🇷 韩国节点"
    return "🏳️ 其他节点"

try:
    with open(sub_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    proxies = []
    for out in data.get('outbounds', []):
        if out.get('type') not in ['direct', 'dns', 'block', 'selector', 'urltest']:
            proxies.append(out)
    
    if not proxies:
        print("Error: No proxies found.")
        sys.exit(1)

    # --- 分组逻辑 ---
    groups = {}
    all_proxy_tags = []
    for proxy in proxies:
        tag = proxy.get('tag', 'unknown')
        all_proxy_tags.append(tag)
        g_name = get_group_name(tag)
        if g_name not in groups: groups[g_name] = []
        groups[g_name].append(tag)

    # --- Outbounds 构建 ---
    new_outbounds = []
    
    # 1. 主选择器
    selector_groups = ["♻️ 自动选择", "🚀 节点选择"] + list(groups.keys()) + ["DIRECT"]
    new_outbounds.append({"type": "selector", "tag": "PROXY", "outbounds": selector_groups})
    
    # 2. 自动选择
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

    # --- 最终配置结构 (Tun 模式) ---
    final_config = {
        "log": {"level": "info", "timestamp": True},
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
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "inet4_address": "172.19.0.1/30",
                "auto_route": True,
                "strict_route": False,
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
                {"port": 22, "outbound": "DIRECT"},  # SSH 保护 (最关键)
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
    print("Config generated successfully.")

except Exception as e:
    print(f"Python script error: {e}")
    sys.exit(1)
EOF

python3 /tmp/gen_tun_config.py
if [ $? -ne 0 ]; then
    echo -e "${RED}配置生成失败！请检查订阅链接是否正确。${PLAIN}"
    exit 1
fi

# 重启服务
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

IP=$(curl -s4 --max-time 5 ifconfig.me)
if [ -z "$IP" ]; then
    IP="检测超时(可能已走代理)"
fi

echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}      全局代理(Tun) + 智能分组 安装成功！      ${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "面板地址: http://你的IP:$UI_PORT/ui/"
echo -e "当前模式: 所有流量自动走代理 (包括 curl/apt/docker)"
echo -e "SSH 保护: 已强制 22 端口直连，防止断连。"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "测试一下: curl ip.sb (如果显示机场IP则成功)"
