#!/bin/bash

# 下载脚本到指定位置
download_url="https://raw.githubusercontent.com/w243420707/-/main/liuliang.sh"
destination="/usr/local/bin/liuliang.sh"

# 检查并安装 dos2unix
function install_dos2unix() {
    if ! command -v dos2unix &> /dev/null; then
        echo "dos2unix 未安装，正在安装..."
        if [ -x "$(command -v apt-get)" ]; then
            sudo apt-get update
            sudo apt-get install -y dos2unix
        elif [ -x "$(command -v yum)" ]; then
            sudo yum install -y dos2unix
        elif [ -x "$(command -v pacman)" ]; then
            sudo pacman -S --noconfirm dos2unix
        else
            echo "无法自动安装 dos2unix，请手动安装。"
            exit 1
        fi
    else
        echo "dos2unix 已安装。"
    fi
}

# 下载脚本
echo "正在下载脚本..."
curl -s -o $destination $download_url

# 检查并安装 dos2unix
install_dos2unix

# 转换文件格式为 Linux
echo "正在转换文件格式..."
dos2unix $destination

# 赋予执行权限
echo "正在赋予执行权限..."
chmod +x $destination

# 设置 cron 任务
echo "正在设置 cron 任务..."
cron_job="0 0,12 * * * $destination"
(crontab -l ; echo "$cron_job") | sort - | uniq - | crontab -

echo "脚本安装和 cron 设置完成。"
