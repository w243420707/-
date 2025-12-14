#!/bin/bash

# ==========================================
# 用户配置 (Base64 加密存储)
# ==========================================
TG_BOT_TOKEN_B64="ODQ4OTI2MjYxOTpBQUVBY0tWU0tnaHVCbGQyQVgyQVRLRHVUbExtbnFNV0dQMA=="
TG_CHAT_ID_B64="NjM3ODQ1NjczOQ=="

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
    else
        release="unknown"
    fi
    
    if [[ ${release} == "centos" ]]; then
        yum install -y crontabs curl
        systemctl start crond && systemctl enable crond
    else
        apt-get update && apt-get install -y cron curl
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
        yum install -y yum-plugin-copr
        yum copr enable @caddy/caddy -y
        yum install caddy -y
    else
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
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
    local urls=("ip.sb" "ifconfig.co" "api.ipify.org" "icanhazip.com")
    for url in "${urls[@]}"; do
        local ip=$(curl -s -4 -L -A "Mozilla/5.0" "$url")
        ip=$(echo "$ip" | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
}

process_address() {
    local addr=$1
    addr=$(echo "$addr" | sed 's/^[ \t]*//;s/[ \t]*$//')
    # 强制加 :80 避免 SSL 申请失败
    local regex_ip="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $addr =~ $regex_ip ]]; then 
        if [[ $addr != *":"* ]]; then
            echo "${addr}:80"
        else
            echo "${addr}"
        fi
    else 
        echo "${addr}"
    fi
}

# ==========================================
# 4. 生成监控脚本 (使用 HTML 模式生成复制代码块)
# ==========================================
create_monitor_script() {
    cat > /usr/local/bin/ip_monitor.sh <<EOF
#!/bin/bash
IP_CACHE="/root/.last_known_ip"
CADDY_FILE="/etc/caddy/Caddyfile"
TOKEN_B64="${TG_BOT_TOKEN_B64}"
CHAT_ID_B64="${TG_CHAT_ID_B64}"

BOT_TOKEN=\$(echo "\$TOKEN_B64" | base64 -d)
CHAT_ID=\$(echo "\$CHAT_ID_B64" | base64 -d)

get_ip() {
    local urls=("ip.sb" "ifconfig.co" "api.ipify.org")
    for url in "\${urls[@]}"; do
        local ip=\$(curl -s -4 -L -A "Mozilla/5.0" "\$url")
        ip=\$(echo "\$ip" | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [[ "\$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "\$ip"
            return 0
        fi
    done
}

CURRENT_IP=\$(get_ip)
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
        if caddy validate --config "\$CADDY_FILE" --adapter caddyfile >/dev/null 2>&1; then
            systemctl reload caddy
            echo "\$CURRENT_IP" > "\$IP_CACHE"
            # 这里的 <pre> 标签就是关键，它会生成你想要的那个复制框
            MSG="🚨 <b>IP 变更通知</b> 🚨%0A%0A旧 IP:%0A<pre>\$LAST_IP</pre>%0A%0A新 IP:%0A<pre>\$CURRENT_IP</pre>%0A%0A✅ Caddy 配置已自动更新。"
        else
            MSG="⚠️ <b>IP 变更失败</b> ⚠️%0A新 IP: <pre>\$CURRENT_IP</pre>%0A原因: Caddy 校验未通过。"
        fi
        # 注意这里改成了 parse_mode="HTML"
        curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
            -d chat_id="\${CHAT_ID}" -d parse_mode="HTML" -d text="\${MSG}"
    fi
fi
EOF
    chmod +x /usr/local/bin/ip_monitor.sh
}

# ==========================================
# 5. 定时任务管理
# ==========================================
manage_cron() {
    local action=$1 
    crontab -l 2>/dev/null | grep -v "ip_monitor.sh" > /tmp/cron.tmp
    if [[ "$action" == "on" ]]; then
        create_monitor_script
        echo "*/3 * * * * /bin/bash /usr/local/bin/ip_monitor.sh >/dev/null 2>&1" >> /tmp/cron.tmp
        crontab /tmp/cron.tmp
        echo -e "${GREEN}已开启: 自动IP监控 (每3分钟)${PLAIN}"
    else
        crontab /tmp/cron.tmp
        rm -f /usr/local/bin/ip_monitor.sh
        echo -e "${YELLOW}已关闭: 自动IP监控${PLAIN}"
    fi
    rm -f /tmp/cron.tmp
}

# ==========================================
# 6. 配置逻辑 (暴力重置 + HTML通知)
# ==========================================
reset_caddyfile() {
    local file="/etc/caddy/Caddyfile"
    echo -e "${YELLOW}正在完全重置 Caddyfile...${PLAIN}"
    if [ -f "$file" ]; then
        mv "$file" "${file}.bak_failed_$(date +%s)"
    fi
    touch "$file"
}

configure_proxy() {
    reset_caddyfile

    local current_ip=$(get_public_ip)
    local enable_monitor=false
    local dec_token=$(echo "$TG_BOT_TOKEN_B64" | base64 -d)
    local dec_chat_id=$(echo "$TG_CHAT_ID_B64" | base64 -d)
    
    echo -e "${SKYBLUE}步骤 1: 设置接入IP/域名${PLAIN}"
    echo -e "本机IP: ${GREEN}[ ${current_ip} ]${PLAIN}"
    read -e -p "请输入 (留空回车使用本机IP): " input_domain
    input_domain=$(echo "$input_domain" | sed 's/^[ \t]*//;s/[ \t]*$//')

    if [[ -z "${input_domain}" ]]; then
        input_domain="${current_ip}"
        enable_monitor=true
        echo -e "已选择本机IP，${GREEN}开启监控${PLAIN}。"
    elif [[ "${input_domain}" == "${current_ip}" ]]; then
        enable_monitor=true
        echo -e "手动输入本机IP，${GREEN}开启监控${PLAIN}。"
    else
        echo -e "自定义域名/IP，${YELLOW}不开启监控${PLAIN}。"
    fi
    
    domain=$(process_address "$input_domain")

    echo -e "\n${SKYBLUE}步骤 2: 设置源站地址${PLAIN}"
    read -e -p "请输入源站 (如 8.8.8.8): " input_target
    input_target=$(echo "$input_target" | sed 's/^[ \t]*//;s/[ \t]*$//')
    [[ -z "${input_target}" ]] && echo -e "${RED}错误：不能为空${PLAIN}" && exit 1
    target=$(process_address "$input_target")

    cat >> /etc/caddy/Caddyfile <<EOF
${domain} {
    reverse_proxy ${target}
    encode gzip
}
EOF

    echo -e "${YELLOW}正在验证 Caddy 配置...${PLAIN}"
    if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /tmp/caddy_error.log 2>&1; then
        
        if systemctl reload caddy 2>/dev/null; then
            echo -e "${GREEN}Caddy 配置已重载。${PLAIN}"
        else
            echo -e "${YELLOW}服务未启动，正在启动 Caddy...${PLAIN}"
            systemctl enable --now caddy
            echo -e "${GREEN}Caddy 已启动。${PLAIN}"
        fi
        
        if [[ "$enable_monitor" == "true" ]]; then
            echo "${current_ip}" > /root/.last_known_ip
            manage_cron "on"
            # 使用 HTML 模式的 <pre> 标签包裹 IP
            TG_MSG="✅ <b>反代部署成功(监控开启)</b>%0A%0A当前 IP:%0A<pre>${current_ip}</pre>"
        else
            manage_cron "off"
            TG_MSG="✅ <b>反代部署成功(静态配置)</b>%0A%0A域名:%0A<pre>${input_domain}</pre>"
        fi
        
        echo -e "${GREEN}配置成功！${PLAIN}"
        # 这里务必使用 parse_mode="HTML"
        curl -s -X POST "https://api.telegram.org/bot${dec_token}/sendMessage" \
            -d chat_id="${dec_chat_id}" -d parse_mode="HTML" -d text="${TG_MSG}" >/dev/null
    else
        echo -e "${RED}验证失败！${PLAIN}"
        echo -e "${RED}============= Caddy 报错详情 =============${PLAIN}"
        cat /tmp/caddy_error.log
        echo -e "${RED}=========================================${PLAIN}"
    fi
    rm -f /tmp/caddy_error.log
}

# ==========================================
# 主程序
# ==========================================
main() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请用 root 运行${PLAIN}" && exit 1
    check_sys
    
    echo -e "1. 配置反代 (默认)"
    echo -e "2. 卸载 Caddy"
    read -e -p "选择 [默认1]: " choice
    [[ -z "${choice}" ]] && choice="1"

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
        *) 
            install_caddy
            configure_proxy
            ;;
    esac
}

main
