#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

MONITOR_SCRIPT="/etc/sing-box/monitor.sh"
CONFIG_FILE="/etc/sing-box/config.json"
LOG_FILE="/var/log/singbox_monitor.log"

# URL编码函数
urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# ==========================================
# 1. Root 检查
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

# 停止旧服务并清理旧的环境变量（防止冲突）
systemctl stop sing-box >/dev/null 2>&1
unset http_proxy https_proxy all_proxy
sed -i '/singbox_proxy.sh/d' ~/.bashrc
rm -f /etc/profile.d/singbox_proxy.sh

clear
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e "${BLUE}#                                                           #${PLAIN}"
echo -e "${BLUE}#   Sing-box TUN 全局接管版 (强制所有流量走代理)            #${PLAIN}"
echo -e "${BLUE}#                                                           #${PLAIN}"
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e ""

echo -e "${GREEN}步骤 1/5: 初始化环境...${PLAIN}"

# 开启 IP 转发（TUN 模式必须）
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-singbox.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-singbox.conf
sysctl -p /etc/sysctl.d/99-singbox.conf >/dev/null 2>&1

if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget tar unzip jq python3 cron ntpdate >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip jq python3 crontabs ntpdate >/dev/null 2>&1
fi
ntpdate pool.ntp.org >/dev/null 2>&1

# 检查 TUN 设备
if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

if [[ ! -c /dev/net/tun ]]; then
    echo -e "${RED}严重警告：系统未检测到 TUN 设备！TUN 模式可能无法启动。${PLAIN}"
    echo -e "${YELLOW}如果你是 LXC/OpenVZ VPS，请在控制面板开启 TUN/TAP 功能。${PLAIN}"
    read -p "按回车继续尝试，或 Ctrl+C 退出..."
fi

echo -e ""

# ==========================================
# 2. 用户交互
# ==========================================
if [[ -n "$1" ]]; then
    SUB_URL="$1"
    echo -e "${YELLOW}已检测到命令行参数，自动使用订阅: ${SUB_URL}${PLAIN}"
else
    echo -e "${YELLOW}请输入你的节点订阅链接:${PLAIN}"
    read -p "链接: " SUB_URL
fi

FINAL_REGEX=""
USE_CONVERSION=true 

if [[ -z "$SUB_URL" ]]; then
    echo -e "${RED}未输入链接，脚本无法继续。${PLAIN}"
    exit 1
else
    echo -e "${GREEN}正在下载订阅...${PLAIN}"
    wget --no-check-certificate -q -O /tmp/singbox_raw.json "$SUB_URL"
    
    if [[ -s /tmp/singbox_raw.json ]] && jq -e '.outbounds' /tmp/singbox_raw.json >/dev/null 2>&1; then
        echo -e "${GREEN}格式正确，准备配置。${PLAIN}"
        cp /tmp/singbox_raw.json /tmp/singbox_pre.json
        USE_CONVERSION=false
    else
        echo -e "${YELLOW}正在通过 API 转换格式...${PLAIN}"
        ENCODED_URL=$(urlencode "$SUB_URL")
        PRE_API="https://api.v1.mk/sub?target=sing-box&url=${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget --no-check-certificate -q -O /tmp/singbox_pre.json "$PRE_API"
    fi
    
    # 简单的节点筛选逻辑 (简化版，直接问是否全选)
    NODE_TAGS=$(jq -r '.outbounds[] | select(.type | test("Selector|URLTest|Direct|Block") | not) | .tag' /tmp/singbox_pre.json)
    echo -e "----------------------------------------"
    echo -e "${YELLOW}是否要过滤特定国家节点？(y/n)${PLAIN}"
    read -p "默认保留所有 (n): " FILTER_YN
    if [[ "$FILTER_YN" == "y" ]]; then
        read -p "请输入要保留的国家关键词 (如 UK, US, HK): " KEYWORD
        if [[ -n "$KEYWORD" ]]; then
            FINAL_REGEX="$KEYWORD"
            echo -e "${GREEN}已设置过滤关键词: $FINAL_REGEX${PLAIN}"
        fi
    fi
fi

# ==========================================
# 3. 安装 Sing-box
# ==========================================
echo -e "${GREEN}步骤 2/5: 安装 Sing-box...${PLAIN}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) singbox_arch="amd64" ;;
    aarch64) singbox_arch="arm64" ;;
    armv7l) singbox_arch="armv7" ;;
    *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1 ;;
esac

LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".assets[] | select(.name | contains(\"linux-$singbox_arch\") and contains(\".tar.gz\")) | .browser_download_url")
wget -q -O sing-box.tar.gz "$LATEST_URL"
tar -zxvf sing-box.tar.gz > /dev/null
cd sing-box*linux* || exit
mv sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
cd ..
rm -rf sing-box*
mkdir -p /etc/sing-box

# ==========================================
# 4. 安装 WebUI
# ==========================================
echo -e "${GREEN}步骤 3/5: 部署 WebUI...${PLAIN}"
WEBUI_DIR="/etc/sing-box/ui"
rm -rf "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR"
wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
unzip -q webui.zip
mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
rm -rf Yacd-meta-gh-pages webui.zip

# ==========================================
# 5. 生成 TUN 模式 Monitor 脚本
# ==========================================
echo -e "${GREEN}步骤 4/5: 生成 TUN 自动化脚本...${PLAIN}"

cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
# Sing-box Watchdog - 全局 TUN 模式

SUB_URL="$SUB_URL"
FILTER_REGEX="$FINAL_REGEX"
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
MAX_RETRIES=3
USE_CONVERSION=$USE_CONVERSION

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
urlencode() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$1"; }

check_proxy() {
    # 在 TUN 模式下，直接 curl Google 应该就是通的
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://www.google.com/generate_204)
    if [[ "\$http_code" == "204" ]]; then return 0; else return 1; fi
}

update_subscription() {
    echo "\$(timestamp) - 停止服务，准备更新..." >> "\$LOG_FILE"
    systemctl stop sing-box
    
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
        if [[ -n "\$FILTER_REGEX" ]] && [[ -s /tmp/singbox_new.json ]]; then
             echo "\$(timestamp) - 执行本地过滤..." >> "\$LOG_FILE"
             jq --arg re "\$FILTER_REGEX" '.outbounds |= map(select((.type | test("Selector|URLTest|Direct|Block"; "i")) or (.tag | test(\$re; "i"))))' /tmp/singbox_new.json > /tmp/singbox_filtered.json
             mv /tmp/singbox_filtered.json /tmp/singbox_new.json
        fi
    else
        ENCODED_URL=\$(urlencode "\$SUB_URL")
        INCLUDE_PARAM=""
        if [[ -n "\$FILTER_REGEX" ]]; then
            ENCODED_REGEX=\$(urlencode "\$FILTER_REGEX")
            INCLUDE_PARAM="&include=\${ENCODED_REGEX}"
        fi
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json\${INCLUDE_PARAM}"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
    # === 关键：TUN 全局配置 ===
    # 包含 DNS劫持、Auto Route 和 TUN Inbound
    TUN_CONFIG='{
      "log": {
        "level": "info",
        "timestamp": true
      },
      "dns": {
        "servers": [
          {
            "tag": "remote-dns",
            "address": "8.8.8.8",
            "detour": "Proxy"
          },
          {
            "tag": "local-dns",
            "address": "223.5.5.5",
            "detour": "direct"
          }
        ],
        "rules": [
          { "outbound": "any", "server": "local-dns" },
          { "clash_mode": "Global", "server": "remote-dns" },
          { "clash_mode": "Direct", "server": "local-dns" },
          { "rule_set": "geosite-cn", "server": "local-dns" }
        ],
        "strategy": "ipv4_only"
      },
      "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "tun0",
            "inet4_address": "172.19.0.1/30",
            "auto_route": true,
            "strict_route": true, 
            "stack": "system",
            "sniff": true
        },
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "::",
            "listen_port": 2080
        }
      ],
      "route": {
        "auto_detect_interface": true,
        "rules": [
           { "protocol": "dns", "outbound": "dns-out" },
           { "clash_mode": "Direct", "outbound": "direct" },
           { "clash_mode": "Global", "outbound": "Proxy" }
        ]
      },
      "experimental": {
        "cache_file": { "enabled": true, "path": "cache.db" },
        "clash_api": {
          "external_controller": "0.0.0.0:9090",
          "external_ui": "/etc/sing-box/ui",
          "secret": "",
          "default_mode": "Rule",
          "access_control_allow_origin": ["*"],
          "access_control_allow_private_network": true
        }
      }
    }'
    
    if [[ -s /tmp/singbox_new.json ]] && jq . /tmp/singbox_new.json >/dev/null 2>&1; then
        # 清理旧的 dns, inbounds, route, experimental 字段，使用 TUN 模板覆盖
        jq 'del(.dns, .inbounds, .route, .experimental, .log)' /tmp/singbox_new.json > /tmp/singbox_clean.json
        jq -s '.[0] * .[1]' /tmp/singbox_clean.json <(echo "\$TUN_CONFIG") > /tmp/singbox_merged.json
        
        # 强制锁定 Auto 组
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then
             jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' /tmp/singbox_merged.json > "\$CONFIG_FILE"
        else
             mv /tmp/singbox_merged.json "\$CONFIG_FILE"
        fi
        
        echo "\$(timestamp) - 启动服务 (TUN模式)..." >> "\$LOG_FILE"
        systemctl start sing-box
        sleep 15
        
        if check_proxy; then
            echo "\$(timestamp) - [成功] 全局代理已生效。" >> "\$LOG_FILE"
        else
            echo "\$(timestamp) - [失败] TUN 启动后无法联网，停止服务以防断网。" >> "\$LOG_FILE"
            systemctl stop sing-box
        fi
    else
        echo "\$(timestamp) - [错误] 订阅下载失败。" >> "\$LOG_FILE"
    fi
}

if [[ "\$1" == "force" ]]; then update_subscription; exit 0; fi

if systemctl is-active --quiet sing-box; then
    FAIL_COUNT=0
    for ((i=1; i<=MAX_RETRIES; i++)); do
        if check_proxy; then exit 0; else FAIL_COUNT=\$((FAIL_COUNT+1)); sleep 3; fi
    done
    if [[ \$FAIL_COUNT -eq \$MAX_RETRIES ]]; then
        update_subscription
    fi
else
    update_subscription
fi
EOF

chmod +x "$MONITOR_SCRIPT"
crontab -l | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
echo "*/5 * * * * $MONITOR_SCRIPT" >> /tmp/cron_bk
crontab /tmp/cron_bk
rm /tmp/cron_bk

echo -e "${GREEN}TUN 监控脚本已部署。${PLAIN}"

# ==========================================
# 6. 启动与检查
# ==========================================
echo -e "${GREEN}步骤 5/5: 初次启动 TUN 模式...${PLAIN}"
bash "$MONITOR_SCRIPT" force

# Systemd 服务文件 (增加 Capability 权限)
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo -e ""
echo -e "${GREEN}=========================================${PLAIN}"
# 检查运行状态
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}状态:           Sing-box (TUN模式) 正在运行 ${PLAIN}"
    # 测试
    echo -e "正在测试全局流量接管情况..."
    # 此时无需 proxy 参数，直接 curl 应该变 IP
    IP_INFO=$(curl -s --max-time 5 ip.sb) 
    if [[ -n "$IP_INFO" ]]; then
         echo -e "${GREEN}当前公网IP:     $IP_INFO (如果不是本机IP，说明全局成功！)${PLAIN}"
         echo -e "${YELLOW}所有流量(Ping/UDP/System)均已自动走代理。${PLAIN}"
    else
         echo -e "${RED}连接测试:       无法联网！(TUN可能配置冲突)${PLAIN}"
         echo -e "请尝试重启 VPS 或检查 tun 模块。"
    fi
else
    echo -e "${RED}状态:           Sing-box 未启动${PLAIN}"
fi
echo -e "WebUI:          http://$(curl -s4m5 ip.sb):9090/ui/"
echo -e "${GREEN}=========================================${PLAIN}"
