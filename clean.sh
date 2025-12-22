#!/bin/bash
# =========================================================
# 脚本名称: Pro System Cleaner (Silent Edition)
# 版本: v4.0 (No Logs)
# =========================================================

# --- 🎨 样式定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
BOLD='\033[1m'

CLEAN_SCRIPT_PATH="/usr/local/bin/safe-system-cleanup.sh"

# --- 📝 辅助打印函数 ---
function print_banner() {
    clear
    echo -e "${BLUE}============================================================${PLAIN}"
    echo -e "${SKYBLUE}      🤫 Linux 系统静默清理工具 (Silent Mode)      ${PLAIN}"
    echo -e "${BLUE}============================================================${PLAIN}"
}
function msg_process() { echo -e "${YELLOW} [....] ${PLAIN} $1..."; }
function msg_success() { echo -e "${GREEN} [DONE] ${PLAIN} $1"; }
function msg_error() { echo -e "${RED} [ERR!] ${PLAIN} $1"; }

if [ "$EUID" -ne 0 ]; then
    msg_error "请使用 sudo 运行此脚本"
    exit 1
fi

# ====================
# 🔴 卸载功能
# ====================
function uninstall_all() {
    print_banner
    echo -e "${RED}${BOLD}🚨 正在执行卸载...${PLAIN}\n"

    # 从 crontab 移除
    crontab -l 2>/dev/null | grep -v "safe-system-cleanup.sh" | crontab -
    msg_success "定时任务已移除"

    # 删除脚本
    rm -f "$CLEAN_SCRIPT_PATH"
    msg_success "脚本文件已删除"

    # 恢复配置
    if grep -q "^SystemMaxUse=200M" /etc/systemd/journald.conf; then
        sed -i '/^SystemMaxUse=200M/d' /etc/systemd/journald.conf
        systemctl restart systemd-journald
        msg_success "已移除 journald 限制"
    fi

    echo -e "\n${GREEN}✅ 卸载完成。${PLAIN}\n"
}

# ====================
# 🟢 安装与清理功能
# ====================
function install_and_clean() {
    print_banner
    echo -e "${BOLD}🛠️  开始部署...${PLAIN}\n"

    # 1️⃣ 立即执行一次清理
    msg_process "执行首次清理"
    truncate -s 0 /var/log/syslog 2>/dev/null
    truncate -s 0 /var/log/kern.log 2>/dev/null
    [ -f /var/log/messages ] && truncate -s 0 /var/log/messages
    find /var/log -name "syslog.*" -name "kern.log.*" -type f -mtime +7 -delete 2>/dev/null
    journalctl --vacuum-time=3d >/dev/null 2>&1
    command -v apt >/dev/null && apt clean 2>/dev/null
    command -v yum >/dev/null && yum clean all 2>/dev/null
    find /var/tmp -type f -atime +7 -delete 2>/dev/null
    find /tmp -type f -atime +7 -delete 2>/dev/null
    msg_success "清理完成"

    # 2️⃣ Systemd 优化
    msg_process "优化日志配置"
    if ! grep -q "SystemMaxUse=" /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
        systemctl restart systemd-journald
        msg_success "Journal 限制已添加"
    else
        echo -e "${BLUE} [INFO] ${PLAIN} 配置已存在，跳过"
    fi

    # 3️⃣ 生成自动化脚本 (脚本内部也添加静默处理)
    msg_process "生成静默执行脚本"
    cat > $CLEAN_SCRIPT_PATH << 'EOF'
#!/bin/bash
# Auto-generated Silent Cleaner
[ "$EUID" -ne 0 ] && exit 1
# 所有命令重定向错误输出到 /dev/null
truncate -s 0 /var/log/syslog 2>/dev/null
truncate -s 0 /var/log/kern.log 2>/dev/null
[ -f /var/log/messages ] && truncate -s 0 /var/log/messages 2>/dev/null
find /var/log -name "syslog.*" -name "kern.log.*" -type f -mtime +7 -delete 2>/dev/null
journalctl --vacuum-time=3d >/dev/null 2>&1
command -v apt >/dev/null && apt clean >/dev/null 2>&1
command -v yum >/dev/null && yum clean all >/dev/null 2>&1
find /var/tmp -type f -atime +7 -delete 2>/dev/null
find /tmp -type f -atime +7 -delete 2>/dev/null
EOF
    chmod +x $CLEAN_SCRIPT_PATH
    msg_success "脚本生成完毕"

    # 4️⃣ 配置 Crontab (关键修改点)
    msg_process "添加静默定时任务"
    
    # 重点： >/dev/null 2>&1  这里确保了 Crontab 运行时不会发邮件，不会写日志
    JOB_CMD="0 * * * * $CLEAN_SCRIPT_PATH >/dev/null 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "safe-system-cleanup.sh"; echo "$JOB_CMD") | crontab -
    
    msg_success "任务已添加 (静默模式)"

    echo -e "\n${GREEN}✅ 部署完成！${PLAIN}"
    echo -e " 验证命令: ${YELLOW}sudo crontab -l${PLAIN}"
}

# ====================
# 🚀 主入口
# ====================
case "$1" in
    uninstall|remove)
        uninstall_all
        ;;
    *)
        install_and_clean
        ;;
esac
