#!/bin/bash

# 创建交换文件
sudo fallocate -l 5G /swapfile

# 设置文件权限
sudo chmod 600 /swapfile

# 将文件转换为交换文件
sudo mkswap /swapfile

# 启用交换文件
sudo swapon /swapfile

# 将交换文件添加到 /etc/fstab 中
echo '/swapfile   none    swap    sw    0   0' | sudo tee -a /etc/fstab

echo "5GB 虚拟内存已成功添加！"
