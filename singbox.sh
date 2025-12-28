#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 工作目录
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
    # 使用 v1.9.0 稳定版，避开 v1.10+ 的配置兼容性大坑
    wget -q -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-${singbox_arch}.tar.gz"
    tar -zxvf sing-box.tar.gz > /dev/null
    mv sing-box*linux*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*
}

# ==========================================
# 3. 用户交互：订阅与地区
# ==========================================
configure_user() {
    echo -e "${YELLOW}请输入订阅链接:${PLAIN}"
    read -p "链接: " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo -e "${RED}链接为空${PLAIN}"; exit 1; fi
    
    echo -e "${GREEN}正在分析订阅中的节点地区...${PLAIN}"
    # 预下载分析
    wget --no-check-certificate -q -O /tmp/raw_sub.json "https://api.v1.mk/sub?target=sing-box&url=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$SUB_URL")&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
    
    if [ ! -s /tmp/raw_sub.json ]; then echo -e "${RED}订阅下载失败${PLAIN}"; exit 1; fi

    # 提取标签
    NODE_TAGS=$(jq -r '.outbounds[] | select(.type | test("Selector|URLTest|Direct|Block") | not) | .tag' /tmp/raw_sub.json)
    
    # 地区列表
    REGION_DATA=(
    "香港 (HK)|HK|Hong Kong|HongKong" "台湾 (TW)|TW|Taiwan|TaiWan" 
    "日本 (JP)|JP|Japan" "新加坡 (SG)|SG|Singapore" 
    "美国 (US)|US|United States|USA|America" "韩国 (KR)|KR|Korea" 
    "英国 (UK)|UK|United Kingdom|Britain" "德国 (DE)|DE|Germany" 
    "法国 (FR)|FR|France" "俄罗斯 (RU)|RU|Russia" 
    "印度 (IN)|IN|India" "加拿大 (CA)|CA|Canada"
    )

    echo -e "----------------------------------------"
    idx=1
    FOUND_REGEXS=()
    for item in "${REGION_DATA[@]}"; do
        NAME="${item%%|*}"
        KEYWORDS="${item#*|}"
        # 简单匹配计数
        COUNT=$(echo "$NODE_TAGS" | grep -Ei "$KEYWORDS" | wc -l)
        if [[ $COUNT -gt 0 ]]; then
            echo -e "${GREEN}[$idx]${PLAIN} $NAME - ${YELLOW}$COUNT${PLAIN} 个节点"
            FOUND_REGEXS+=("$KEYWORDS")
            ((idx++))
        fi
    done
    echo -e "----------------------------------------"
    echo -e "${GREEN}[0]${PLAIN} 全都要 (默认)"
    
    read -p "选择地区 (例如输入 1 3 选香港和日本): " USER_CHOICE
    
    FINAL_REGEX=""
    if [[ -n "$USER_CHOICE" && "$USER_CHOICE" != "0" ]]; then
        REGEX_PARTS=()
        for i in $USER_CHOICE; do
            REAL_IDX=$((i-1))
            if [[ -n "${FOUND_REGEXS[$REAL_IDX]}" ]]; then REGEX_PARTS+=("(${FOUND_REGEXS[$REAL_IDX]})"); fi
        done
        FINAL_REGEX=$(IFS="|"; echo "${REGEX_PARTS[*]}")
    fi
    
    # 保存用户配置供 Monitor 使用
    echo "SUB_URL=\"$SUB_URL\"" > "$USER_CONF"
    echo "FILTER_REGEX=\"$FINAL_REGEX\"" >> "$USER_CONF"
}

# ==========================================
# 4. 生成核心监控脚本 (自动运行的核心)
# ==========================================
create_monitor() {
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
source $USER_CONF

# --- 1. 下载订阅 ---
# 使用 Python URL Encode
ENCODED_URL=\$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "\$SUB_URL")
API="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"

wget -q -O /tmp/new_config.json "\$API"
if [ ! -s /tmp/new_config.json ]; then exit 1; fi

# --- 2. 地区筛选 (jq) ---
if [[ -n "\$FILTER_REGEX" ]]; then
    jq --arg re "\$FILTER_REGEX" '.outbounds |= map(select( (.type | test("Selector|URLTest|Direct|Block"; "i")) or (.tag | test(\$re; "i")) ))' /tmp/new_config.json > /tmp/filtered_config.json
    mv /tmp/filtered_config.json /tmp/new_config.json
fi

# --- 3. 注入 TProxy 和 DNS 配置 (修复 DNS 问题核心) ---
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

# 强力合并配置
jq -s '.[0] * .[1] | del(.experimental)' /tmp/new_config.json /tmp/injection.json > "$CONFIG_FILE"

# --- 4. 确保自动选择策略 ---
# 找到自动测速组的名字，把默认路由指向它
AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' "$CONFIG_FILE" | head -n 1)
if [[ -n "\$AUTO_TAG" ]]; then 
     jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' "$CONFIG_FILE" > /tmp/final_config.json
     mv /tmp/final_config.json "$CONFIG_FILE"
fi

# --- 5. 重启服务 ---
systemctl restart sing-box

# --- 6. 刷新防火墙规则 (SSH 保护) ---
ip rule del fwmark 1 lookup 100 2>/dev/null
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
iptables -t mangle -D OUTPUT -j SINGBOX_OUTPUT 2>/dev/null
iptables -t mangle -F SINGBOX_OUTPUT 2>/dev/null
iptables -t mangle -X SINGBOX_OUTPUT 2>/dev/null

ip rule add fwmark 1 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
iptables -t mangle -N SINGBOX_OUTPUT
# 放行 SSH
iptables -t mangle -A SINGBOX_OUTPUT -p tcp --sport 22 -j RETURN
# 放行私有 IP
iptables -t mangle -A SINGBOX_OUTPUT -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A SINGBOX_OUTPUT -d 240.0.0.0/4 -j RETURN
# 劫持
iptables -t mangle -A SINGBOX_OUTPUT -p tcp -j MARK --set-mark 1
iptables -t mangle -A SINGBOX_OUTPUT -p udp -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -j SINGBOX_OUTPUT

EOF
    chmod +x "$MONITOR_SCRIPT"
}

# ==========================================
# 5. 系统服务与定时任务
# ==========================================
finalize() {
    echo -e "${GREEN}注册服务...${PLAIN}"
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
    
    echo -e "${GREEN}首次运行更新脚本...${PLAIN}"
    bash "$MONITOR_SCRIPT"
    
    echo -e "${GREEN}添加定时保活任务 (每10分钟检查一次)...${PLAIN}"
    # 简单的保活逻辑：每10分钟跑一次 monitor.sh，它会重拉配置并重启
    # 如果你想做得更细致（只有网断了才重拉），可以在 monitor.sh 里加 curl 判断
    # 这里为了确保“节点失效后重新拉取”，直接简单粗暴定时重拉
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
    echo "*/10 * * * * $MONITOR_SCRIPT >/dev/null 2>&1" >> /tmp/cron_bk
    crontab /tmp/cron_bk
    rm /tmp/cron_bk
    
    sleep 3
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ 安装成功！${PLAIN}"
        echo -e "功能状态："
        echo -e "1. [SSH保护] 端口 22 流量直连，不掉线。"
        echo -e "2. [DNS修复] 8.8.8.8 已配置，解决无法解析问题。"
        echo -e "3. [地区筛选] 已根据你的选择过滤节点。"
        echo -e "4. [自动更新] 每 10 分钟自动更新订阅并筛选节点。"
        echo -e ""
        echo -e "${YELLOW}测试连接 (Google)...${PLAIN}"
        curl -I -m 5 https://www.google.com/generate_204
    else
        echo -e "${RED}❌ 启动失败。${PLAIN}"
        echo -e "请运行: journalctl -u sing-box -n 20 查看日志"
    fi
}

# ==========================================
# 主流程
# ==========================================
prepare_env
install_binary
configure_user
create_monitor
finalize
