#!/bin/bash

# 检查是否安装了 sudo
if ! command -v sudo &> /dev/null
then
    echo "sudo 未安装，正在安装..."
    apt update
    apt install -y sudo
fi

# 检查是否安装了 vnstat
if ! command -v vnstat &> /dev/null
then
    echo "vnstat 未安装，正在安装..."
    sudo apt update
    sudo apt install -y vnstat
fi

# 设置监视网络接口
sudo vnstat -u -i eth0

# 查看当日流量使用情况
vnstat -d
