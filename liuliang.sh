#!/bin/bash

# 检查并安装 bc 工具
function install_bc() {
    if ! command -v bc &> /dev/null; then
        echo "bc 未安装，正在安装..."
        if [ -f /etc/debian_version ]; then
            sudo apt update
            sudo apt install -y bc
        elif [ -f /etc/redhat-release ]; then
            sudo yum install -y bc
        elif [ -f /etc/arch-release ]; then
            sudo pacman -S --noconfirm bc
        else
            echo "未知的Linux发行版，请手动安装 bc。"
            exit 1
        fi
    fi
}

# 运行安装函数
install_bc

# 获取当前月份的第一天
function get_month_start_date() {
    date -d "$(date +%Y-%m-01)" "+%s"
}

# 获取当前日期的秒数
function get_current_date_seconds() {
    date "+%s"
}

# 获取系统首次通电时间
function get_boot_time() {
    local boot_time_file="/var/log/first_boot_time.log"
    
    if [ -f "$boot_time_file" ]; then
        # 如果标记文件存在，则读取第一次通电的时间
        local boot_time=$(cat "$boot_time_file")
    else
        # 如果标记文件不存在，则创建并记录当前时间
        local boot_time=$(date "+%Y-%m-%d %H:%M:%S")
        echo "$boot_time" > "$boot_time_file"
    fi

    echo "$boot_time"
}

# 计算设备运行天数
function calculate_uptime_days() {
    local boot_time=$(get_boot_time)
    local boot_seconds=$(date -d "$boot_time" "+%s")
    local current_seconds=$(get_current_date_seconds)
    local uptime_seconds=$((current_seconds - boot_seconds))
    local uptime_days=$(echo "scale=0; $uptime_seconds / 86400" | bc)
    
    echo "$uptime_days"
}

# 计算当月已用流量
function calculate_current_month_traffic() {
    local total_rx_bytes=$1
    local total_tx_bytes=$2
    local month_start_seconds=$(get_month_start_date)
    local current_seconds=$(get_current_date_seconds)
    
    # 计算当月的流量
    local days_this_month=$(echo "scale=2; ($current_seconds - $month_start_seconds) / 86400" | bc)
    
    rx_current_month=$(echo "scale=2; $total_rx_bytes / 1024 / 1024 / 1024" | bc)
    tx_current_month=$(echo "scale=2; $total_tx_bytes / 1024 / 1024 / 1024" | bc)
    rx_current_month_tb=$(echo "scale=2; $total_rx_bytes / 1024 / 1024 / 1024 / 1024" | bc)
    tx_current_month_tb=$(echo "scale=2; $total_tx_bytes / 1024 / 1024 / 1024 / 1024" | bc)

    echo -e "从 $(date -d @$month_start_seconds +'%Y-%m-%d') 到 $(date +'%Y-%m-%d')\n本月已用入站流量 : $rx_current_month GB   换算： $rx_current_month_tb TB\n本月已用出站流量 : $tx_current_month GB   换算： $tx_current_month_tb TB\n"
}

# 获取指定接口的流量统计
function get_traffic() {
    local interface="$1"

    if [ ! -e /sys/class/net/$interface/statistics/rx_bytes ]; then
        echo "接口 $interface 不存在"
        exit 1
    fi

    rx_bytes=$(cat /sys/class/net/$interface/statistics/rx_bytes) # 入站流量
    tx_bytes=$(cat /sys/class/net/$interface/statistics/tx_bytes) # 出站流量

    # 将字节转换为 GB 和 TB
    rx_gb=$(echo "scale=2; $rx_bytes / 1024 / 1024 / 1024" | bc)
    tx_gb=$(echo "scale=2; $tx_bytes / 1024 / 1024 / 1024" | bc)
    rx_tb=$(echo "scale=2; $rx_bytes / 1024 / 1024 / 1024 / 1024" | bc)
    tx_tb=$(echo "scale=2; $tx_bytes / 1024 / 1024 / 1024 / 1024" | bc)

    # 获取系统首次通电时间
    boot_time=$(get_boot_time)

    # 计算设备运行天数
    uptime_days=$(calculate_uptime_days)

    echo -e "开机时间: $boot_time\n设备运行 $uptime_days 天\n开机起总入站流量: $rx_gb GB   换算： $rx_tb TB\n开机起总出站流量: $tx_gb GB   换算： $tx_tb TB\n------------------------------------"
    
    # 计算当月已用流量
    calculate_current_month_traffic "$rx_bytes" "$tx_bytes"
}

# 获取当前 IP 地址和运营商信息
function get_ip_info() {
    curl -s https://myip.ipip.net
}

# URL 编码函数
function urlencode() {
    local string="$1"
    local encoded

    # 使用 awk 进行 URL 编码
    encoded=$(printf '%s' "$string" | awk '
        {
            gsub(/ /, "%20");
            gsub(/\n/, "%0A");
            gsub(/\r/, "%0D");
            gsub(/"/, "%22");
            gsub(/#/, "%23");
            gsub(/\$/, "%24");
            gsub(/&/, "%26");
            gsub(/'\''/, "%27");
            gsub(/\(/, "%28");
            gsub(/\)/, "%29");
            gsub(/\*/, "%2A");
            gsub(/\+/, "%2B");
            gsub(/,/, "%2C");
            gsub(/-/, "%2D");
            gsub(/\./, "%2E");
            gsub(/:/, "%3A");
            gsub(/;/, "%3B");
            gsub(/</, "%3C");
            gsub(/=/, "%3D");
            gsub(/>/, "%3E");
            gsub(/\?/, "%3F");
            gsub(/@/, "%40");
            gsub(/\[/, "%5B");
            gsub(/\\/, "%5C");
            gsub(/\]/, "%5D");
            gsub(/\^/, "%5E");
            gsub(/_/, "%5F");
            gsub(/`/, "%60");
            gsub(/{/, "%7B");
            gsub(/\|/, "%7C");
            gsub(/}/, "%7D");
            gsub(/~/, "%7E");
            print;
        }
    ')
    echo "$encoded"
}

# 发送消息到 Telegram
function send_to_telegram() {
    local message="$1"
    local bot_token="6269706467:AAETOZmgL7GtsN_UCnOVGtaTFpOhPrQ9Zs8"
    local chat_id="6653302268"
    local url="https://api.telegram.org/bot$bot_token/sendMessage"

    # URL 编码消息
    local encoded_message=$(urlencode "$message")

    curl -s -X POST "$url" -d "chat_id=$chat_id" -d "text=$encoded_message"
}

# 设置 cron 任务
function setup_cron() {
    local cron_file="/tmp/crontab_tmp"
    local new_cron="0 0,12 * * * /root/liuliang.sh"

    # 清除现有的 cron 任务中与该脚本相关的任务
    crontab -l | grep -v "/root/liuliang.sh" > "$cron_file"

    # 添加新的 cron 任务
    echo "$new_cron" >> "$cron_file"

    # 更新 crontab
    crontab "$cron_file"
    rm "$cron_file"
}

# 重启 cron 服务
function restart_cron() {
    if systemctl list-units --type=service --state=running | grep -q 'cron.service'; then
        sudo systemctl restart cron
    elif systemctl list-units --type=service --state=running | grep -q 'crond.service'; then
        sudo systemctl restart crond
    else
        sudo service cron restart
    fi
}

# 找到流量用量最大的网络接口
max_interface=$(ls /sys/class/net | grep -E 'eth0|enp' | head -n 1)

# 获取流量数据
traffic_data=$(get_traffic "$max_interface")

# 获取 IP 地址和运营商信息
ip_info=$(get_ip_info)

# 获取当前时间戳
timestamp=$(date "+%Y-%m-%d %H:%M:%S")

# 组合消息，将 IP 信息放在第一行，时间信息放在最后一行
message="$ip_info%0A------------------------------------%0A$traffic_data%0A------------------------------------%0A时间: $timestamp"

# 将结果发送到 Telegram
send_to_telegram "$message"
