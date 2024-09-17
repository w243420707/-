#!/bin/bash

# 检查并安装 bc
function install_bc() {
    if ! command -v bc &> /dev/null; then
        echo "bc 未安装，正在安装..."
        if [ -x "$(command -v apt-get)" ]; then
            sudo apt-get update
            sudo apt-get install -y bc
        elif [ -x "$(command -v yum)" ]; then
            sudo yum install -y bc
        elif [ -x "$(command -v pacman)" ]; then
            sudo pacman -S --noconfirm bc
        else
            echo "无法自动安装 bc，请手动安装。"
            exit 1
        fi
    else
        echo "bc 已安装。"
    fi
}

# 获取 IP 地址
function get_ip() {
    ip_addr=$(hostname -I | awk '{print $1}')
    echo "IP 地址: $ip_addr"
}

# 获取 IP 厂商信息
function get_ip_vendor() {
    ip_addr=$(hostname -I | awk '{print $1}')
    vendor=$(curl -s "https://ipinfo.io/$ip_addr/org?token=e8b55ad2275583")
    echo "IP 厂商: $vendor"
}

# 获取当前系统的流量统计
function get_traffic() {
    rx_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes) # 入站流量
    tx_bytes=$(cat /sys/class/net/eth0/statistics/tx_bytes) # 出站流量

    # 将字节转换为 GB 和 TB
    rx_gb=$(echo "scale=2; $rx_bytes / 1024 / 1024 / 1024" | bc)
    tx_gb=$(echo "scale=2; $tx_bytes / 1024 / 1024 / 1024" | bc)
    rx_tb=$(echo "scale=2; $rx_bytes / 1024 / 1024 / 1024 / 1024" | bc)
    tx_tb=$(echo "scale=2; $tx_bytes / 1024 / 1024 / 1024 / 1024" | bc)

    echo "入站流量: $rx_gb GB / $rx_tb TB"
    echo "出站流量: $tx_gb GB / $tx_tb TB"
}

# 发送消息到Telegram
function send_to_telegram() {
    local message="$1"
    local bot_token="6269706467:AAETOZmgL7GtsN_UCnOVGtaTFpOhPrQ9Zs8"
    local chat_id="6653302268"
    local url="https://api.telegram.org/bot$bot_token/sendMessage"
    
    curl -s -X POST $url -d chat_id=$chat_id -d text="$message"
}

# 检查并安装 bc
install_bc

# 获取 IP 地址和 IP 厂商信息
ip_info=$(get_ip)
ip_vendor=$(get_ip_vendor)

# 获取流量数据
traffic_data=$(get_traffic)

# 生成消息内容
message="$ip_info\n$ip_vendor\n$traffic_data"

# 将结果发送到Telegram
send_to_telegram "$message"
