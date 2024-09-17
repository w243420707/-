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

# 获取当前系统所有网络接口的流量统计
function get_max_traffic_interface() {
    local max_rx_bytes=0
    local max_tx_bytes=0
    local max_interface=""

    for interface in $(ls /sys/class/net/); do
        if [ -e /sys/class/net/$interface/statistics/rx_bytes ] && [ -e /sys/class/net/$interface/statistics/tx_bytes ]; then
            rx_bytes=$(cat /sys/class/net/$interface/statistics/rx_bytes)
            tx_bytes=$(cat /sys/class/net/$interface/statistics/tx_bytes)

            if [ "$rx_bytes" -gt "$max_rx_bytes" ] || [ "$tx_bytes" -gt "$max_tx_bytes" ]; then
                max_rx_bytes=$rx_bytes
                max_tx_bytes=$tx_bytes
                max_interface=$interface
            fi
        fi
    done

    echo "$max_interface"
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

    echo -e "入站流量: $rx_gb GB / $rx_tb TB\n出站流量: $tx_gb GB / $tx_tb TB"
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
max_interface=$(get_max_traffic_interface)

# 获取流量数据
traffic_data=$(get_traffic "$max_interface")

# 获取 IP 地址和运营商信息
ip_info=$(get_ip_info)

# 获取当前时间戳
timestamp=$(date "+%Y-%m-%d %H:%M:%S")

# 添加时间戳和 IP 信息到消息中
message="$ip_info%0A$traffic_data%0A时间: $timestamp"

# 将结果发送到 Telegram
send_to_telegram "$message"

# 设置 cron 任务
setup_cron

# 重启 cron 服务
restart_cron
