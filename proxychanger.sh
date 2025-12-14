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
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    else
        echo -e "${RED}系统不支持${PLAIN}" && exit 1
    fi
    
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
# 3. 工具函数 (修复了IP获取逻辑)
# ==========================================
get_public_ip() {
    # 尝试多个接口，增加稳定性
    local ip=$(curl -s4m5 https://api.ipify.org)
    
    # 如果第一个失败或者返回的不是纯IP，尝试第二个
    if [[ -z "$ip" ]] || [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=$(curl -s4m5 https://icanhazip.com)
    fi
    
    if [[ -z "$ip" ]] || [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=$(curl -s4m5 https://ifconfig.me)
    fi

    # 清理一下可能的换行符
    echo "$ip" | tr -d '\n'
}

process_address() {
    local addr=$1
    addr=$(echo "$addr" | sed 's/^[ \t]*//;s/[ \t]*$//')
    
    # 更严格的IP判断
    local regex_ip="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $addr =~ $regex_ip ]]; then echo "${addr}:80"; else echo "${addr}"; fi
}

# ==========================================
# 4. 生成监控脚本 (同步更新了IP获取逻辑)
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

# 增强的获取IP逻辑
get_ip() {
    local ip=\$(curl -s4m5 https://api.ipify.org)
    if [[ ! "\$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=\$(curl -s4m5 https://icanhazip.com)
    fi
    if [[ ! "\$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=\$(curl -s4m5 https://ifconfig.me)
    fi
    echo "\$ip" | tr -d '\n'
}

CURRENT_IP=\$(get_ip)
# 如果三次都失败，直接退出
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
# 6. 配置逻辑
# ==========================================
configure_proxy() {
    local current_ip=$(get_public_ip)
    local enable_monitor=false
    
    local dec_token=$(echo "$TG_BOT_TOKEN_B64" | base64 -d)
    local dec_chat_id=$(echo "$TG_CHAT_ID_B64" | base64 -d)
    
    # 增加一层检查，如果获取到的IP不对，必须强制手动输入
    local regex_check="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    
    echo -e "${SKYBLUE}步骤 1: 设置接入IP/域名${PLAIN}"
    
    if [[ "$current_ip" =~ $regex_check ]]; then
        echo -e "本机IP: ${GREEN}[ ${current_ip} ]${PLAIN}"
    else
        echo -e "${RED}警告: 自动获取IP失败，请手动输入！${PLAIN}"
        current_ip=""
    fi

    read -e -p "请输入 (留空回车使用本机IP): " input_domain
    input_domain=$(echo "$input_domain" | sed 's/^[ \t]*//;s/[ \t]*$//')

    if [[ -z "${input_domain}" ]]; then
        if [[ -z "${current_ip}" ]]; then
             echo -e "${RED}无法获取本机IP，且输入为空，退出！${PLAIN}"
             exit 1
        fi
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

    if [ ! -f /etc/caddy/Caddyfile ]; then touch /etc/caddy/Caddyfile; fi
    
    cat >> /etc/caddy/Caddyfile <<EOF

${domain} {
    reverse_proxy ${target}
    encode gzip
}
EOF

    if [[ "$enable_monitor" == "true" ]]; then
        echo "${current_ip}" > /root/.last_known_ip
        manage_cron "on"
        TG_MSG="✅ 反代部署成功(监控开启)%0AIP: ${current_ip}"
    else
        manage_cron "off"
        TG_MSG="✅ 反代部署成功(静态配置)%0A域名: ${input_domain}"
    fi

    if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile &> /dev/null; then
        systemctl reload caddy
        echo -e "${GREEN}配置成功！${PLAIN}"
        curl -s -X POST "https://api.telegram.org/bot${dec_token}/sendMessage" \
            -d chat_id="${dec_chat_id}" -d text="${TG_MSG}" >/dev/null
    else
        echo -e "${RED}验证失败，请检查配置！${PLAIN}"
        echo -e "写入的配置可能包含无效字符，正在回滚..."
        # 简单回滚：删除最后4行
        head -n -4 /etc/caddy/Caddyfile > /tmp/caddyfile_tmp && mv /tmp/caddyfile_tmp /etc/caddy/Caddyfile
    fi
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
