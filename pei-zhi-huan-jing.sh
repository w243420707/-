#!/bin/bash

# 更新 apt 软件包列表
echo "正在更新 apt 软件包列表..."
apt update

# 安装 curl
echo "正在安装 curl..."
apt install -y curl

# 安装 sudo
echo "正在安装 sudo..."
apt-get install -y sudo

echo "环境设置完成。"
