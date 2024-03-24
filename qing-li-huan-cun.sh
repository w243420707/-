#!/bin/bash

# 清理 apt 软件包缓存
echo "正在清理 apt 软件包缓存..."
apt clean

# 清理旧的软件包
echo "正在清理旧的软件包..."
apt autoclean

# 清理系统日志
echo "正在清理系统日志..."
journalctl --vacuum-time=1d

# 清理临时文件
echo "正在清理临时文件..."
rm -rf /tmp/*

echo "缓存清理完成。"
