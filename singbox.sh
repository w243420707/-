#!/bin/bash

# =========================================================
# Sing-box 智能分组安装脚本 (Python 增强版)
# 功能：安装内核 + 部署UI + 自动转换订阅 + 智能国家分组
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

# --- 1. 检查 Root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}" 
   exit 1
fi

# --- 2. 安装依赖 (包含 Python3 用于处理 JSON) ---
echo -e "${YELLOW}[1/6] 安装依赖环境...${PLAIN}"
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y curl wget tar unzip python3
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip python3
elif [ -f /etc/alpine-release ]; then
    apk add curl wget tar unzip python3
fi

# --- 3. 安装 Sing-box ---
echo -e "${YELLOW}[2/6] 安装/更新 Sing-box...${PLAIN}"
bash <(curl -fsSL https://sing-box.app/deb-install.sh)

# --- 4. 部署 WebUI ---
echo -e "${YELLOW}[3/6] 部署 Metacubexd 面板...${PLAIN}"
rm -rf "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR"
wget -q -O "$WEBUI_DIR/ui.zip" "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
unzip -o "$WEBUI_DIR/ui.zip" -d "$WEBUI_DIR" > /dev/null 2>&1
mv "$WEBUI_DIR/metacubexd-gh-pages"/* "$WEBUI_DIR/"
rm -rf "$WEBUI_DIR/metacubexd-gh-pages" "$WEBUI_DIR/ui.zip"

# --- 5. 注入兼容补丁 ---
echo -e "${YELLOW}[4/6] 注入 Systemd 补丁...${PLAIN}"
mkdir -p /etc/systemd/system/sing-box.service.d/
echo -e "[Service]\nEnvironment=\"ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true\"" > /etc/systemd/system/sing-box.service.d/override.conf
systemctl daemon-reload

# --- 6. 处理订阅与智能分组 (核心逻辑) ---
echo -e "${YELLOW}[5/6] 正在处理订阅并进行智能分组...${PLAIN}"

if [ -z "$SUB_URL" ]; then
    echo -e "${RED}警告：未提供订阅链接 (--sub)，将生成空配置。${PLAIN}"
    # 生成默认空配置
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [{"type": "mixed","tag": "mixed-in","listen": "::","listen_port": $MIXED_PORT}],
  "experimental": {"clash_api": {"external_controller": "0.0.0.0:$UI_PORT","external_ui": "$WEBUI_DIR","secret": "","default_mode": "rule"}},
  "outbounds": [{"type": "direct","tag": "direct"},{"type": "dns","tag": "dns-out"},{"type": "block","tag": "block"}],
  "route": {"rules": [{"protocol": "dns","outbound": "dns-out"}]}
}
EOF
else
    # 下载订阅内容
    TEMP_JSON="/tmp/singbox_sub.json"
    wget -O "$TEMP_JSON" "$SUB_URL"
    
    # 使用 Python 脚本进行智能分组处理
    # 这是一个内嵌的 Python 脚本，负责解析下载的 JSON，识别 Emoji，重组 Outbounds
    cat > /tmp/process_config.py <<EOF
import json
import sys
import re

# 配置文件路径
sub_file = "$TEMP_JSON"
target_file = "$CONFIG_FILE"
ui_dir = "$WEBUI_DIR"
ui_port = $UI_PORT
mixed_port = $MIXED_PORT

def get_group_name(tag):
    # 简单的正则匹配 Emoji 或常见国家代码
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
    
    # 提取原来的 outbounds 中的节点 (排除 direct, block, dns 等)
    proxies = []
    for out in data.get('outbounds', []):
        if out.get('type') not in ['direct', 'dns', 'block', 'selector', 'urltest']:
            proxies.append(out)
    
    if not proxies:
        print("Error: No proxies found in subscription.")
        sys.exit(1)

    # 分组逻辑
    groups = {}
    all_proxy_tags = []
    
    for proxy in proxies:
        tag = proxy.get('tag', 'unknown')
        all_proxy_tags.append(tag)
        g_name = get_group_name(tag)
        if g_name not in groups:
            groups[g_name] = []
        groups[g_name].append(tag)

    # 构建新的 Outbounds
    new_outbounds = []
    
    # 1. 代理选择 (主策略)
    selector_groups = ["♻️ 自动选择", "🚀 节点选择"] + list(groups.keys()) + ["DIRECT"]
    new_outbounds.append({
        "type": "selector",
        "tag": "PROXY",
        "outbounds": selector_groups
    })

    # 2. 自动选择 (UrlTest)
    new_outbounds.append({
        "type": "urltest",
        "tag": "♻️ 自动选择",
        "outbounds": all_proxy_tags,
        "url": "http://www.gstatic.com/generate_204",
        "interval": "3m",
        "tolerance": 50
    })
    
    # 3. 手动选择 (包含所有节点)
    new_outbounds.append({
        "type": "selector",
        "tag": "🚀 节点选择",
        "outbounds": all_proxy_tags
    })

    # 4. 地区分组 Selector
    for g_name, tags in groups.items():
        # 如果分组内节点多，加个自动测速
        if len(tags) > 1:
             # 创建该地区的自动测速
            auto_tag = f"⚡ {g_name} 自动"
            new_outbounds.append({
                "type": "urltest",
                "tag": auto_tag,
                "outbounds": tags,
                "url": "http://www.gstatic.com/generate_204",
                "interval": "3m",
                "tolerance": 50
            })
            # 地区分组包含：自动测速 + 具体节点
            final_tags = [auto_tag] + tags
        else:
            final_tags = tags
            
        new_outbounds.append({
            "type": "selector",
            "tag": g_name,
            "outbounds": final_tags
        })

    # 5. 添加具体节点数据
    new_outbounds.extend(proxies)

    # 6. 添加基础 Outbounds
    new_outbounds.append({"type": "direct", "tag": "DIRECT"})
    new_outbounds.append({"type": "dns", "tag": "dns-out"})
    new_outbounds.append({"type": "block", "tag": "block"})

    # 构建最终 Config
    final_config = {
        "log": {"level": "info", "timestamp": True},
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "::",
                "listen_port": mixed_port
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
                {"clash_mode": "direct", "outbound": "DIRECT"},
                {"clash_mode": "global", "outbound": "PROXY"}
            ],
            "auto_detect_interface": True,
            "final": "PROXY"
        }
    }

    with open(target_file, 'w', encoding='utf-8') as f:
        json.dump(final_config, f, indent=2, ensure_ascii=False)
    
    print("Config generation successful.")

except Exception as e:
    print(f"Error processing json: {e}")
    sys.exit(1)
EOF

    # 执行 Python 脚本
    python3 /tmp/process_config.py
    if [ $? -ne 0 ]; then
        echo -e "${RED}配置文件处理失败！请检查订阅链接是否返回了正确的 Sing-box JSON 格式。${PLAIN}"
        echo -e "注意：此脚本只支持已经是 JSON 格式的订阅，如果是 Base64 需先转换。"
        exit 1
    fi
fi

# --- 7. 启动服务 ---
echo -e "${YELLOW}[6/6] 重启服务...${PLAIN}"
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

IP=$(curl -s4 ifconfig.me)
echo -e "\n${GREEN}=============================================${PLAIN}"
echo -e "${GREEN}      安装完成 & 智能分组已生效！      ${PLAIN}"
echo -e "${GREEN}=============================================${PLAIN}"
echo -e "WebUI: http://$IP:$UI_PORT/ui/"
echo -e "分组策略: 自动根据 Emoji/关键词 生成了 [香港][日本][美国] 等组。"
echo -e "${GREEN}=============================================${PLAIN}"
