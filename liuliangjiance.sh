#!/bin/bash

# 下载脚本到指定位置
download_url="https://raw.githubusercontent.com/w243420707/-/main/liuliang.sh"
destination="/usr/local/bin/liuliang.sh"

# 下载脚本
echo "正在下载脚本..."
curl -s -o $destination $download_url

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
