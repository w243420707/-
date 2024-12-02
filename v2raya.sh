#!/bin/bash

# 检查是否以root权限运行
if [[ $EUID -ne 0 ]]; then
    echo "请以root权限运行此脚本。"
    exit 1
fi

echo "开始执行自动化脚本..."

# 第一步：下载installer_debian_x64_2.2.6.3.deb
echo "正在下载installer_debian_x64_2.2.6.3.deb..."
wget -O /root/installer_debian_x64_2.2.6.3.deb "https://github.com/w243420707/-/raw/refs/heads/main/installer_debian_x64_2.2.6.3.deb"

# 第二步：下载v2ray_5.22.0_amd64.deb
echo "正在下载v2ray_5.22.0_amd64.deb..."
wget -O /root/v2ray_5.22.0_amd64.deb "https://github.com/w243420707/-/raw/refs/heads/main/v2ray_5.22.0_amd64.deb"

# 第三步：给两个文件赋予777权限
echo "赋予两个文件777权限..."
chmod 777 /root/installer_debian_x64_2.2.6.3.deb
chmod 777 /root/v2ray_5.22.0_amd64.deb

# 第四步：安装v2ray_5.22.0_amd64.deb
echo "安装v2ray_5.22.0_amd64.deb..."
sudo apt install -y /root/v2ray_5.22.0_amd64.deb

# 第五步：安装installer_debian_x64_2.2.6.3.deb
echo "安装installer_debian_x64_2.2.6.3.deb..."
sudo apt install -y /root/installer_debian_x64_2.2.6.3.deb

# 第六步：重启v2raya.service
echo "重启v2raya服务..."
sudo systemctl restart v2raya.service

# 第七步：设置v2raya服务开机自启
echo "设置v2raya服务开机自启..."
sudo systemctl enable v2raya.service

# 第八步：获取网卡的IPv4地址并以链接形式输出
echo "获取网卡的IPv4地址..."
IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n 1)

if [[ -z "$IP" ]]; then
    echo "无法获取IPv4地址，请检查网卡配置。"
    exit 1
fi

echo "IPv4地址获取成功：$IP"
echo "访问链接：http://$IP:2017"

echo "脚本执行完成！"
