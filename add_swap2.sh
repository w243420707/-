#!/bin/bash

# 检查是否以 root 用户运行脚本
if [[ $EUID -ne 0 ]]; then
   echo "本脚本需要以root用户权限运行"
   exit 1
fi

# 提示用户输入交换文件大小（以 MB 为单位）
read -p "请输入交换文件大小（MB）: " swap_size

# 检查输入是否为有效数字
if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
   echo "无效的输入，请输入一个正整数的大小（MB）"
   exit 1
fi

# 创建交换文件，大小为用户输入的值（MB）
fallocate -l ${swap_size}M /swapfile

# 设置文件权限
chmod 600 /swapfile

# 将文件转换为交换文件
mkswap /swapfile

# 启用交换文件
swapon /swapfile

# 将交换文件添加到 /etc/fstab 中
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

echo "${swap_size}MB 虚拟内存已成功添加！"
