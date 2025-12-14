#!/bin/bash

# ==========================================
# 用户配置
# ==========================================
TG_BOT_TOKEN="8489262619:AAEAcKVSKghuBld2AX2ATKDuTlLmnqMWGP0"
TG_CHAT_ID="6378456739"

# ==========================================
# 颜色配置
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# ==========================================
# 1. 环境检测
# ==========================================
check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    else
        echo -e "${RED}系统不支持${PLAIN}" && exit 1
    fi
    
    # 安装 crontab
    if [[ ${release} == "centos" ]]; then
        yum install -y crontabs
        systemctl start crond && systemctl enable crond
    else
        apt-get update && apt-get install -y cron
        systemctl start cron && systemctl enable cron
    fi
}

# ==========================================
# 2. 安装 Caddy
# ==========================================
install_caddy() {
    if command -v caddy &> /dev/null; then
        echo -e "${GREEN}Caddy 已安装${PLAIN}"
        return
    fi
    echo -e "${YELLOW}安装 Caddy...${PLAIN}"
    if [[ ${release} == "centos" ]]; then
        yum install -y curl tar yum-plugin-copr
        yum copr enable @caddy/caddy -y
        yum install caddy -y
    else
        apt-get install -y curl tar debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update && apt-get install caddy -y
    fi
    systemctl enable caddy
}

# ==========================================
# 3. 工具函数
# ==========================================
get_public_ip() {
    local ip=$(curl -s4m8 https://ip.sb)
    [[ -z "$ip" ]] && ip=$(curl -s4m8 https://api.ipify.org)
    echo "$ip"
}

process_address() {
    local addr=$1
    local regex_ip="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $addr =~ $regex_ip ]]; then echo "${addr}:80"; else echo "${addr}"; fi
}

# ==========================================
# 4. 生成监控脚本
# ==========================================
create_monitor_script() {
    cat > /usr/local/bin/ip_monitor.sh <<EOF
#!/bin/bash
IP_CACHE="/root/.last_known_ip"
CADDY_FILE="/etc/caddy/Caddyfile"
BOT_TOKEN="${TG_BOT_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"

CURRENT_IP=\$(curl -s4m10 https://ip.sb)
[[ -z "\$CURRENT_IP" ]] && CURRENT_IP=\$(curl -s4m10 https://api.ipify.org)
[[ -z "\$CURRENT_IP" ]] && exit 0

if [[ -f "\$IP_CACHE" ]]; then
    LAST_IP=\$(cat "\$IP_CACHE")
else
    echo "\$CURRENT_IP" > "\$IP_CACHE"
    exit 0
fi

if [[ "\$CURRENT_IP" != "\$LAST_IP" ]]; then
    if grep -q "\$LAST_IP" "\$CADDY_FILE"; then
        sed -i "s/\$LAST_IP/\$CURRENT_IP/g" "\$CADDY_FILE"
        systemctl reload caddy
        echo "\$CURRENT_IP" > "\$IP_CACHE"
        
        MSG="🚨 *IP 变更通知* 🚨%0A%0A旧: \`\$LAST_IP\`%0A新: \`\$CURRENT_IP\`%0A%0A✅ Caddy 配置已更新。"
        curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
            -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" -d text="\${MSG}"
    fi
fi
EOF
    chmod +x /usr/local/bin/ip_monitor.sh
}

# ==========================================
# 5. 定时任务管理 (开启/关闭)
# ==========================================
manage_cron() {
    local action=$1 # "on" or "off"
    
    # 先清理旧任务
    crontab -l 2>/dev/null | grep -v "ip_monitor.sh" > /tmp/cron.tmp
    
    if [[ "$action" == "on" ]]; then
        create_monitor_script
        echo "*/3 * * * * /bin/bash /usr/local/bin/ip_monitor.sh >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp
        echo -e "${GREEN}已开启: 自动IP监控 (每3分钟)${PLAIN}"
    else
        crontab /tmp/cron.tmp
        rm -f /usr/local/bin/ip_monitor.sh
        echo -e "${YELLOW}已关闭: 自动IP监控 (无需监控)${PLAIN}"
    fi
    rm -f /tmp/cron.tmp
}

# ==========================================
# 6. 配置逻辑 (带判断)
# ==========================================
configure_proxy() {
    local current_ip=$(get_public_ip)
    local enable_monitor=false

    echo -e "${SKYBLUE}步骤 1: 设置接入IP/域名${PLAIN}"
    echo -e "本机IP: ${GREEN}[ ${current_ip} ]${PLAIN}"
    echo -e "提示: 只有直接回车使用默认IP，才会开启自动监控功能。"
    read -p "请输入 (留空回车使用本机IP): " input_domain
    
    if [[ -z "${input_domain}" ]]; then
        input_domain="${current_ip}"
        enable_monitor=true
        echo -e "已选择本机IP，${GREEN}将开启自动监控${PLAIN}。"
    elif [[ "${input_domain}" == "${current_ip}" ]]; then
        enable_monitor=true
        echo -e "手动输入了本机IP，${GREEN}将开启自动监控${PLAIN}。"
    else
        echo -e "检测到自定义域名/IP，${YELLOW}不开启监控${PLAIN}。"
    fi
    
    domain=$(process_address "$input_domain")

    echo -e "\n${SKYBLUE}步骤 2: 设置源站地址${PLAIN}"
    read -p "请输入源站 (如 8.8.8.8): " input_target
    [[ -z "${input_target}" ]] && echo -e "${RED}错误：不能为空${PLAIN}" && exit 1
    target=$(process_address "$input_target")

    # 写入配置
    if [ ! -f /etc/caddy/Caddyfile ]; then touch /etc/caddy/Caddyfile; fi
    
    # 简单的配置追加
    cat >> /etc/caddy/Caddyfile <<EOF

${domain} {
    reverse_proxy ${target}
    encode gzip
}
EOF

    # 处理监控逻辑
    if [[ "$enable_monitor" == "true" ]]; then
        echo "${current_ip}" > /root/.last_known_ip
        manage_cron "on"
        TG_MSG="✅ 反代已部署 (IP监控开启)。%0AIP: ${current_ip}"
    else
        manage_cron "off"
        TG_MSG="✅ 反代已部署 (静态配置)。%0A域名: ${input_domain}"
    fi

    if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile &> /dev/null; then
        systemctl reload caddy
        echo -e "${GREEN}配置成功！${PLAIN}"
        # 发送 TG 通知
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" -d text="${TG_MSG}" >/dev/null
    else
        echo -e "${RED}配置验证失败，请检查配置文件！${PLAIN}"
    fi
}

# ==========================================
# 主程序
# ==========================================
main() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请用 root 运行${PLAIN}" && exit 1
    check_sys
    
    echo -e "1. 配置反代 (自动判断是否开启监控)"
    echo -e "2. 卸载 Caddy"
    read -p "选择: " choice

    case $choice in
        1)
            install_caddy
            configure_proxy
            ;;
        2)
            systemctl stop caddy
            yum remove caddy -y 2>/dev/null || apt-get remove caddy -y 2>/dev/null
            manage_cron "off"
            rm -rf /etc/caddy
            echo -e "${GREEN}已卸载${PLAIN}"
            ;;
        *) exit 1 ;;
    esac
}

main
