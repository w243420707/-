#!/bin/sh

# 检查是否已安装 crontab
if ! command -v crontab &> /dev/null; then
    echo "crontab 未安装，正在安装..."
    apk add --no-cache dcron
fi

# 设置每十分钟执行一次 "rc-service V2bX start"
(crontab -l 2>/dev/null | grep -v "rc-service V2bX start"; echo "*/10 * * * * rc-service V2bX start") | crontab -

# 启动cron服务
service crond start

echo "定时任务已设置，每十分钟执行一次 'rc-service V2bX start'"
