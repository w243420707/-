#!/bin/bash

# 检查是否以root用户运行脚本
if [[ $EUID -ne 0 ]]; then
   echo "本脚本需要以root用户权限运行" 
   exit 1
fi

# 创建交换文件
fallocate -l 5G /swapfile

# 设置文件权限
chmod 600 /swapfile

# 将文件转换为交换文件
mkswap /swapfile

# 启用交换文件
swapon /swapfile

# 将交换文件添加到 /etc/fstab 中
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

echo "5GB 虚拟内存已成功添加！"
