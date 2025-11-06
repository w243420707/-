#!/bin/bash

################################################################################
# v2node 进程监控一体化脚本
# 功能：安装、配置、监控、卸载全部集成在一个脚本中
# 使用方法：
#   ./v2node_monitor_all.sh install    # 安装并配置监控
#   ./v2node_monitor_all.sh monitor    # 执行一次监控检查
#   ./v2node_monitor_all.sh uninstall  # 卸载监控
#   ./v2node_monitor_all.sh status     # 查看监控状态
################################################################################

# ==================== 配置区域 ====================
# 可以直接在这里修改配置参数

# 进程路径
PROCESS_PATH="/usr/local/v2node/v2node"

# 进程参数（用于识别进程）
PROCESS_ARGS="server"

# 内存阈值（单位：MB）
MEMORY_THRESHOLD=20

# 重启命令
RESTART_COMMAND="rc-service v2node restart"

# 日志文件路径
LOG_FILE="/var/log/v2node_monitor.log"

# 检查间隔（分钟）- 用于定时任务
CHECK_INTERVAL=1

# ==================== 系统检测函数 ====================

# 识别操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        OS="unknown"
        OS_VERSION="unknown"
    fi
}

# ==================== 依赖检查和安装函数 ====================

# 检查必要的命令是否存在
check_dependencies() {
    local missing_deps=()
    
    if ! command -v pgrep &> /dev/null; then
        missing_deps+=("pgrep")
    fi
    
    if ! command -v ps &> /dev/null; then
        missing_deps+=("ps")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# 安装依赖
install_dependencies() {
    echo "正在检查系统依赖..."
    
    if check_dependencies; then
        echo "✓ 所有依赖已满足"
        return 0
    fi
    
    echo "⚠ 缺少必要工具: pgrep 和/或 ps"
    echo "正在自动安装..."
    
    detect_os
    
    case $OS in
        alpine)
            echo "使用 apk 包管理器..."
            apk update && apk add procps
            ;;
            
        ubuntu|debian)
            echo "使用 apt 包管理器..."
            apt-get update && apt-get install -y procps
            ;;
            
        centos|rhel|fedora|rocky|almalinux)
            echo "使用 yum/dnf 包管理器..."
            if command -v dnf &> /dev/null; then
                dnf install -y procps-ng
            else
                yum install -y procps-ng
            fi
            ;;
            
        arch|manjaro)
            echo "使用 pacman 包管理器..."
            pacman -Sy --noconfirm procps-ng
            ;;
            
        opensuse*|sles)
            echo "使用 zypper 包管理器..."
            zypper install -y procps
            ;;
            
        *)
            echo "✗ 未识别的操作系统: $OS"
            echo "请手动安装 procps 或 procps-ng 包"
            return 1
            ;;
    esac
    
    # 验证安装
    if check_dependencies; then
        echo "✓ 依赖安装完成"
        return 0
    else
        echo "✗ 依赖安装失败"
        return 1
    fi
}

# 安装 cron（如果需要且未安装）
install_cron_if_needed() {
    if command -v crontab &> /dev/null; then
        return 0
    fi
    
    echo "正在安装 cron..."
    detect_os
    
    case $OS in
        alpine)
            apk add busybox-openrc
            rc-update add crond
            rc-service crond start
            ;;
        ubuntu|debian)
            apt-get install -y cron
            systemctl enable cron 2>/dev/null
            systemctl start cron 2>/dev/null
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y cronie
            else
                yum install -y cronie
            fi
            systemctl enable crond 2>/dev/null
            systemctl start crond 2>/dev/null
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm cronie
            systemctl enable cronie 2>/dev/null
            systemctl start cronie 2>/dev/null
            ;;
        opensuse*|sles)
            zypper install -y cron
            systemctl enable cron 2>/dev/null
            systemctl start cron 2>/dev/null
            ;;
        *)
            echo "⚠ 无法自动安装 cron"
            return 1
            ;;
    esac
    
    if command -v crontab &> /dev/null; then
        echo "✓ cron 安装完成"
        return 0
    else
        echo "✗ cron 安装失败"
        return 1
    fi
}

# ==================== 监控核心函数 ====================

# 日志函数
log_message() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a "$LOG_FILE"
}

# 获取进程内存使用情况（单位：MB）
get_process_memory() {
    local pid=$(pgrep -f "${PROCESS_PATH}.*${PROCESS_ARGS}")
    
    if [ -z "$pid" ]; then
        echo "0"
        return 1
    fi
    
    local mem_kb=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print $1}')
    
    if [ -z "$mem_kb" ]; then
        echo "0"
        return 1
    fi
    
    local mem_mb=$((mem_kb / 1024))
    echo "$mem_mb"
    return 0
}

# 重启服务
restart_service() {
    log_message "执行重启命令: $RESTART_COMMAND"
    
    if eval "$RESTART_COMMAND" >> "$LOG_FILE" 2>&1; then
        log_message "服务重启成功"
        return 0
    else
        log_message "错误：服务重启失败！"
        return 1
    fi
}

# 主监控逻辑
do_monitor() {
    # 检查依赖
    if ! check_dependencies; then
        echo "错误：缺少必要的依赖工具！"
        echo "请先运行: $0 install"
        exit 1
    fi
    
    log_message "========== 开始监控 =========="
    
    # 获取当前内存使用
    memory_mb=$(get_process_memory)
    local pid_status=$?
    
    if [ $pid_status -ne 0 ] || [ "$memory_mb" -eq 0 ]; then
        log_message "警告：进程 ${PROCESS_PATH} ${PROCESS_ARGS} 未运行或无法获取内存信息"
        log_message "尝试重启服务..."
        restart_service
        log_message "========== 监控结束 =========="
        return 0
    fi
    
    log_message "当前进程内存使用: ${memory_mb}MB (阈值: ${MEMORY_THRESHOLD}MB)"
    
    # 检查内存是否低于阈值
    if [ "$memory_mb" -lt "$MEMORY_THRESHOLD" ]; then
        log_message "警告：内存使用低于阈值！当前: ${memory_mb}MB < ${MEMORY_THRESHOLD}MB"
        restart_service
    else
        log_message "内存使用正常，无需重启"
    fi
    
    log_message "========== 监控结束 =========="
}

# ==================== 安装函数 ====================

install_monitor() {
    echo "========================================="
    echo "v2node 进程监控安装"
    echo "========================================="
    
    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请使用root用户或sudo运行安装"
        exit 1
    fi
    
    # 检测系统
    detect_os
    echo "检测到操作系统: $OS $OS_VERSION"
    echo ""
    
    # 安装依赖
    install_dependencies
    if [ $? -ne 0 ]; then
        echo "✗ 依赖安装失败，请手动安装后重试"
        exit 1
    fi
    
    # 创建日志文件
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # 获取脚本的绝对路径
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    
    echo ""
    echo "请选择定时任务类型："
    echo "1) cron (适用于大多数系统)"
    echo "2) systemd timer (适用于使用systemd的系统)"
    read -p "请输入选择 [1/2]: " choice
    
    case $choice in
        1)
            echo ""
            echo "正在配置 cron 定时任务..."
            
            # 安装 cron
            install_cron_if_needed
            if [ $? -ne 0 ]; then
                echo "✗ 无法配置 cron"
                exit 1
            fi
            
            # 设置 cron 时间表
            if [ "$CHECK_INTERVAL" -eq 1 ]; then
                CRON_SCHEDULE="* * * * *"
            else
                CRON_SCHEDULE="*/$CHECK_INTERVAL * * * *"
            fi
            
            read -p "请输入cron执行时间表达式 (默认: $CRON_SCHEDULE): " user_schedule
            if [ ! -z "$user_schedule" ]; then
                CRON_SCHEDULE="$user_schedule"
            fi
            
            # 添加cron任务
            CRON_JOB="$CRON_SCHEDULE $SCRIPT_PATH monitor"
            
            # 检查是否已存在
            if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH monitor"; then
                echo "警告：cron任务已存在，正在更新..."
                crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH monitor" | crontab -
            fi
            
            # 添加新任务
            (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
            
            echo "✓ cron任务已添加"
            echo "  执行时间表: $CRON_SCHEDULE"
            echo "  监控命令: $SCRIPT_PATH monitor"
            echo ""
            echo "常用命令："
            echo "  查看cron任务: crontab -l"
            echo "  手动执行: $SCRIPT_PATH monitor"
            echo "  查看日志: tail -f $LOG_FILE"
            ;;
            
        2)
            echo ""
            echo "正在配置 systemd timer..."
            
            # 创建systemd service文件
            SERVICE_FILE="/etc/systemd/system/v2node-monitor.service"
            cat > "$SERVICE_FILE" << EOF
[Unit]
Description=v2node Process Memory Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH monitor
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            
            # 创建systemd timer文件
            TIMER_FILE="/etc/systemd/system/v2node-monitor.timer"
            cat > "$TIMER_FILE" << EOF
[Unit]
Description=v2node Process Memory Monitor Timer
Requires=v2node-monitor.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=${CHECK_INTERVAL}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
            
            # 重载systemd
            systemctl daemon-reload
            
            # 启用并启动timer
            systemctl enable v2node-monitor.timer
            systemctl start v2node-monitor.timer
            
            echo "✓ systemd timer 已配置并启动"
            echo ""
            echo "常用命令："
            echo "  查看timer状态: systemctl status v2node-monitor.timer"
            echo "  查看service状态: systemctl status v2node-monitor.service"
            echo "  查看日志: journalctl -u v2node-monitor.service -f"
            echo "  手动执行: $SCRIPT_PATH monitor"
            echo "  或: systemctl start v2node-monitor.service"
            ;;
            
        *)
            echo "无效的选择"
            exit 1
            ;;
    esac
    
    echo ""
    echo "========================================="
    echo "安装完成！"
    echo "========================================="
    echo "配置参数（可在脚本开头修改）："
    echo "  进程路径: $PROCESS_PATH"
    echo "  进程参数: $PROCESS_ARGS"
    echo "  内存阈值: ${MEMORY_THRESHOLD}MB"
    echo "  重启命令: $RESTART_COMMAND"
    echo "  日志文件: $LOG_FILE"
    echo "  检查间隔: ${CHECK_INTERVAL}分钟"
    echo ""
    echo "卸载命令: $SCRIPT_PATH uninstall"
}

# ==================== 卸载函数 ====================

uninstall_monitor() {
    echo "========================================="
    echo "v2node 进程监控卸载"
    echo "========================================="
    
    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请使用root用户或sudo运行卸载"
        exit 1
    fi
    
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    
    echo ""
    echo "正在检测已安装的定时任务..."
    
    # 检查并删除cron任务
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH monitor"; then
        echo "检测到 cron 任务，正在删除..."
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH monitor" | crontab -
        echo "✓ cron 任务已删除"
    fi
    
    # 检查并删除systemd timer
    if systemctl list-unit-files 2>/dev/null | grep -q "v2node-monitor.timer"; then
        echo "检测到 systemd timer，正在删除..."
        
        systemctl stop v2node-monitor.timer 2>/dev/null
        systemctl disable v2node-monitor.timer 2>/dev/null
        
        rm -f /etc/systemd/system/v2node-monitor.service
        rm -f /etc/systemd/system/v2node-monitor.timer
        
        systemctl daemon-reload
        
        echo "✓ systemd timer 已删除"
    fi
    
    echo ""
    read -p "是否删除日志文件? [y/N]: " delete_log
    if [[ "$delete_log" =~ ^[Yy]$ ]]; then
        if [ -f "$LOG_FILE" ]; then
            rm -f "$LOG_FILE"
            echo "✓ 日志文件已删除"
        fi
    fi
    
    echo ""
    echo "========================================="
    echo "卸载完成！"
    echo "========================================="
}

# ==================== 状态查看函数 ====================

show_status() {
    echo "========================================="
    echo "v2node 监控状态"
    echo "========================================="
    echo ""
    
    # 显示配置
    echo "【配置信息】"
    echo "  进程路径: $PROCESS_PATH"
    echo "  进程参数: $PROCESS_ARGS"
    echo "  内存阈值: ${MEMORY_THRESHOLD}MB"
    echo "  重启命令: $RESTART_COMMAND"
    echo "  日志文件: $LOG_FILE"
    echo "  检查间隔: ${CHECK_INTERVAL}分钟"
    echo ""
    
    # 检查依赖
    echo "【依赖检查】"
    if check_dependencies; then
        echo "  ✓ pgrep: 已安装"
        echo "  ✓ ps: 已安装"
    else
        echo "  ✗ 缺少必要依赖，请运行 install"
    fi
    echo ""
    
    # 检查进程状态
    echo "【进程状态】"
    local pid=$(pgrep -f "${PROCESS_PATH}.*${PROCESS_ARGS}" 2>/dev/null)
    if [ ! -z "$pid" ]; then
        local mem_mb=$(get_process_memory)
        echo "  ✓ 进程运行中"
        echo "  PID: $pid"
        echo "  内存使用: ${mem_mb}MB"
    else
        echo "  ✗ 进程未运行"
    fi
    echo ""
    
    # 检查定时任务
    echo "【定时任务】"
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH monitor"; then
        echo "  ✓ cron 已配置"
        echo "  任务: $(crontab -l 2>/dev/null | grep "$SCRIPT_PATH monitor")"
    elif systemctl list-unit-files 2>/dev/null | grep -q "v2node-monitor.timer"; then
        echo "  ✓ systemd timer 已配置"
        systemctl status v2node-monitor.timer 2>/dev/null | grep -E "Active:|Trigger:"
    else
        echo "  ✗ 未配置定时任务"
    fi
    echo ""
    
    # 显示最近日志
    if [ -f "$LOG_FILE" ]; then
        echo "【最近日志】"
        tail -n 10 "$LOG_FILE"
    else
        echo "【日志】"
        echo "  日志文件不存在"
    fi
    
    echo ""
    echo "========================================="
}

# ==================== 帮助信息 ====================

show_help() {
    cat << EOF
v2node 进程监控一体化脚本

用法:
    $0 <命令>

命令:
    install      安装并配置监控（需要root权限）
    monitor      执行一次监控检查
    uninstall    卸载监控（需要root权限）
    status       查看监控状态和配置信息
    help         显示此帮助信息

配置说明:
    所有配置参数都在脚本开头的"配置区域"中，可以直接编辑修改：
    - PROCESS_PATH: 进程路径
    - PROCESS_ARGS: 进程参数
    - MEMORY_THRESHOLD: 内存阈值（MB）
    - RESTART_COMMAND: 重启命令
    - LOG_FILE: 日志文件路径
    - CHECK_INTERVAL: 检查间隔（分钟）

示例:
    # 安装监控
    sudo $0 install
    
    # 手动执行一次检查
    $0 monitor
    
    # 查看状态
    $0 status
    
    # 卸载监控
    sudo $0 uninstall

EOF
}

# ==================== 主程序入口 ====================

# 检查参数
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# 执行对应命令
case "$1" in
    install)
        install_monitor
        ;;
    monitor)
        do_monitor
        ;;
    uninstall)
        uninstall_monitor
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "错误：未知命令 '$1'"
        echo ""
        show_help
        exit 1
        ;;
esac
