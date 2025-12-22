#!/bin/bash
echo "=== 一键安全清理系统日志、缓存并添加定时任务 ==="

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行此脚本: sudo bash $0"
    exit 1
fi

# 1️⃣ 安全清理系统日志（使用 truncate 保持文件存在）
echo "清理系统日志..."
truncate -s 0 /var/log/syslog
truncate -s 0 /var/log/kern.log
[ -f /var/log/messages ] && truncate -s 0 /var/log/messages

# 2️⃣ 安全清理旧日志和 journal
echo "清理旧日志文件和 journal..."
# 只删除压缩的旧日志文件，保留当前日志
find /var/log -name "syslog.*" -name "kern.log.*" -type f -mtime +7 -delete 2>/dev/null
# 安全清理 journal，保留3天日志
journalctl --vacuum-time=3d

# 3️⃣ 配置 systemd journal 限制
echo "配置 systemd journal 限制..."
if ! grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
    echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
else
    sed -i 's/^SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
fi

# 重启 journal 服务（仅在配置变更时）
if systemctl is-active systemd-journald >/dev/null 2>&1; then
    systemctl restart systemd-journald
    echo "journald 服务已重启"
fi

# 4️⃣ 清理 apt 缓存
echo "清理 apt 缓存..."
apt clean 2>/dev/null  echo "apt clean 失败（可能未安装）"

# 5️⃣ 安全清理临时文件（只清理7天前的文件）
echo "清理临时文件..."
find /var/tmp -type f -atime +7 -delete 2>/dev/null
find /tmp -type f -atime +7 -delete 2>/dev/null

# 6️⃣ 输出清理结果
echo "=== 清理完成 ==="
echo "当前磁盘占用："
df -h | grep -E '(/dev/vda1|/dev/sda1|/$)' | head -1
echo ""
echo "相关目录大小："
du -sh /var/log /var/cache /var/tmp /tmp 2>/dev/null

# 7️⃣ 创建安全的清理脚本
CLEAN_SCRIPT="/usr/local/bin/safe-system-cleanup.sh"
cat > $CLEAN_SCRIPT << 'EOF'
#!/bin/bash
# 安全系统清理脚本
[ "$EUID" -ne 0 ] && exit 1

# 清理日志
truncate -s 0 /var/log/syslog
truncate -s 0 /var/log/kern.log
[ -f /var/log/messages ] && truncate -s 0 /var/log/messages

# 清理旧日志文件（7天前）
find /var/log -name "syslog.*" -name "kern.log.*" -type f -mtime +7 -delete 2>/dev/null

# 清理 journal（保留3天）
journalctl --vacuum-time=3d 2>/dev/null

# 清理包缓存
command -v apt >/dev/null && apt clean
command -v yum >/dev/null && yum clean all

# 清理临时文件（7天前）
find /var/tmp -type f -atime +7 -delete 2>/dev/null
find /tmp -type f -atime +7 -delete 2>/dev/null
EOF

chmod +x $CLEAN_SCRIPT

# 8️⃣ 添加安全的定时任务
CRON_JOB="0 3 * * * root $CLEAN_SCRIPT"
if ! grep -q "$CLEAN_SCRIPT" /etc/crontab 2>/dev/null; then
    echo "$CRON_JOB" >> /etc/crontab
    echo "定时任务已添加到 /etc/crontab"
else
    echo "定时任务已存在"
fi

# 重启 cron 服务
systemctl restart cron 2>/dev/null  systemctl restart crond 2>/dev/null

echo "=== 部署完成 ==="
echo "安全清理脚本: $CLEAN_SCRIPT"
echo "定时任务: 每天凌晨3点自动运行"
echo "手动运行: sudo $CLEAN_SCRIPT"

