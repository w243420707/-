#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 捕获命令行参数 (这是你要的核心功能)
CLI_SUB_URL="$1"

# 检查是否传入了链接
if [[ -z "$CLI_SUB_URL" ]]; then
    echo -e "${RED}错误: 请在命令后附带订阅链接！${PLAIN}"
    echo -e "用法: bash $0 \"https://你的订阅链接...\""
    exit 1
fi

# 工作目录配置
WORK_DIR="/etc/sing-box"
CONFIG_FILE="$WORK_DIR/config.json"
MONITOR_SCRIPT="$WORK_DIR/monitor.sh"
USER_CONF="$WORK_DIR/user_conf.env"
TPROXY_PORT=12345

if [[ $EUID -ne 0 ]]; then echo -e "${RED}必须 root 运行${PLAIN}"; exit 1; fi

# ==========================================
# 1. 基础清理与依赖
# ==========================================
prepare_env() {
    # 停止服务
    systemctl stop sing-box 2>/dev/null
    
    # 清理防火墙 (只清理 mangle 表相关链)
    iptables -t mangle -D OUTPUT -j SINGBOX_OUTPUT 2>/dev/null
    iptables -t mangle -F SINGBOX_OUTPUT 2>/dev/null
    iptables -t mangle -X SINGBOX_OUTPUT 2>/dev/null
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    # 安装依赖
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq python3 cron iptables >/dev/null 2>&1
    else
        yum install -y curl wget tar unzip jq python3 crontabs iptables-services >/dev/null 2>&1
    fi
    
    mkdir -p "$WORK_DIR"
}

# ==========================================
# 2. 安装 Sing-box
# ==========================================
install_binary() {
    echo -e "${GREEN}安装 Sing-box 核心...${PLAIN}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) singbox_arch="amd64" ;;
        aarch64) singbox_arch="arm64" ;;
        *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
    # 使用 v1.9.0 稳定版
    wget -q -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-${singbox_arch}.tar.gz"
    tar -zxvf sing-box.tar.gz > /dev/null
    mv sing-box*linux*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*
}

# ==========================================
# 3. 保存配置
# ==========================================
configure_user() {
    # 这里默认 FILTER_REGEX 为空，表示保留所有节点。
    # 如果你想在脚本里写死地区（比如只保留香港），把下面空字符串改为: "HK|Hong Kong|HongKong"
    FINAL_REGEX=""
    
    echo -e "${GREEN}使用订阅链接: ${YELLOW}$CLI_SUB_URL${PLAIN}"
    
    # 保存参数供 Monitor 使用
    echo "SUB_URL=\"$CLI_SUB_URL\"" > "$USER_CONF"
    echo "FILTER_REGEX=\"$FINAL_REGEX\"" >> "$USER_CONF"
}

# ==========================================
# 4. 生成自动管理脚本
# ==========================================
create_monitor() {
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
source $USER_CONF

# --- 1. 下载订阅 ---
ENCODED_URL=\$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "\$SUB_URL")
API="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"

wget -q -O /tmp/new_config.json "\$API"
if [ ! -s /tmp/new_config.json ]; then exit 1; fi

# --- 2. 地区筛选 (如果有) ---
if [[ -n "\$FILTER_REGEX" ]]; then
    jq --arg re "\$FILTER_REGEX" '.outbounds |= map(select( (.type | test("Selector|URLTest|Direct|Block"; "i")) or (.tag | test(\$re; "i")) ))' /tmp/new_config.json > /tmp/filtered_config.json
    mv /tmp/filtered_config.json /tmp/new_config.json
fi

# --- 3. 注入 TProxy 和 DNS 配置 ---
cat > /tmp/injection.json <<INNER_EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "google", "address": "8.8.8.8", "detour": "Proxy" },
      { "tag": "local", "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [
      { "outbound": "any", "server": "local" }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": $TPROXY_PORT,
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "Proxy" }
    ],
    "auto_detect_interface": true
  }
}
INNER_EOF

# 合并配置
jq -s '.[0] * .[1] | del(.experimental)' /tmp/new_config.json /tmp/injection.json > "$CONFIG_FILE"

# --- 4. 自动选择最优节点 ---
AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' "$CONFIG_FILE" | head -n 1)
if [[ -n "\$AUTO_TAG" ]]; then 
     jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' "$CONFIG_FILE" > /tmp/final_config.json
     mv /tmp/final_config.json "$CONFIG_FILE"
fi

# --- 5. 重启 Sing-box ---
systemctl restart sing-box

# --- 6. 刷新 iptables (SSH 保护) ---
ip rule del fwmark 1 lookup 100 2>/dev/null
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
iptables -t mangle -D OUTPUT -j SINGBOX_OUTPUT 2>/dev/null
iptables -t mangle -F SINGBOX_OUTPUT 2>/dev/null
iptables -t mangle -X SINGBOX_OUTPUT 2>/dev/null

ip rule add fwmark 1 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
iptables -t mangle -N SINGBOX_OUTPUT

# SSH 保护
iptables -t mangle -A SINGBOX_OUTPUT -p tcp --sport 22 -j RETURN

# 私有 IP 放行
iptables -t mangle -A SINGBOX_OUTPUT -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 240.0.0.0/4 -j RETURN

# 劫持 TCP/UDP
iptables -t mangle -A SINGBOX_OUTPUT -p tcp -j MARK --set-mark 1
iptables -t mangle -A SINGBOX_OUTPUT -p udp -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -j SINGBOX_OUTPUT

EOF
    chmod +x "$MONITOR_SCRIPT"
}

# ==========================================
# 5. 注册服务与定时任务
# ==========================================
finalize() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
    
    echo -e "${GREEN}正在拉取订阅并配置...${PLAIN}"
    bash "$MONITOR_SCRIPT"
    
    # 添加每10分钟自动更新任务
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
    echo "*/10 * * * * $MONITOR_SCRIPT >/dev/null 2>&1" >> /tmp/cron_bk
    crontab /tmp/cron_bk
    rm /tmp/cron_bk
    
    sleep 3
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ 安装成功！TProxy 已启动，SSH 安全。${PLAIN}"
        curl -I -m 5 https://www.google.com/generate_204
    else
        echo -e "${RED}❌ 启动失败。${PLAIN}"
        journalctl -u sing-box -n 20 --no-pager
    fi
}

# 执行主流程
prepare_env
install_binary
configure_user
create_monitor
finalize
