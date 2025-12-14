#!/bin/bash

# =========================================================
# VPS 资源守护脚本 (专业版 - 中文优化)
# 功能：平滑控制 CPU/内存 占用，智能避让，拒绝尖刺
# 特性：大内存优化、多核优化、中文显示、彩色输出
# =========================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

SERVICE_NAME="vps-resource-keeper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH=$(readlink -f "$0")

# =========================================================
# 1. 核心 Python 引擎 (嵌入式)
# =========================================================
run_worker() {
    # 再次检查依赖
    if ! command -v python3 &> /dev/null; then exit 1; fi

    PYTHON_WORKER="/tmp/vps_keeper_pro.py"
    
    cat << 'EOF' > $PYTHON_WORKER
import time
import sys
import os
import threading

# --- 配置区域 ---
TARGET_MIN = 20.0  # 目标最小百分比
TARGET_MAX = 25.0  # 目标最大百分比
CHECK_INTERVAL = 3 # 检测周期(秒)

# --- 全局变量 ---
memory_blocks = [] # 用于存储内存块的列表
cpu_duty_cycle = 0.0 # CPU 占空比 (0.0 - 1.0)
running = True

# --- 基础工具函数 ---

def get_cpu_usage():
    try:
        with open('/proc/stat', 'r') as f:
            line = f.readline()
        parts = line.split()
        active = sum(int(parts[i]) for i in [1, 2, 3, 6, 7, 8])
        idle = int(parts[4]) + int(parts[5])
        return active, active + idle
    except:
        return 0, 0

def get_mem_usage_percent():
    try:
        with open('/proc/meminfo', 'r') as f:
            mem_total = 0
            mem_available = 0
            for line in f:
                if 'MemTotal' in line:
                    mem_total = int(line.split()[1])
                elif 'MemAvailable' in line:
                    mem_available = int(line.split()[1])
                if mem_total and mem_available:
                    break
        used = mem_total - mem_available
        return (used / mem_total) * 100.0
    except:
        return 0

# --- CPU 消耗线程 (PWM 模拟) ---
def cpu_burner_thread(core_id):
    global cpu_duty_cycle, running
    while running:
        current_duty = cpu_duty_cycle
        if current_duty <= 0:
            time.sleep(0.5)
            continue
        
        # 0.1秒为一个周期
        start_time = time.time()
        # 忙碌阶段
        while (time.time() - start_time) < (0.1 * current_duty):
            _ = 3.14159 * 2.71828 # 浮点运算
            
        # 休息阶段
        sleep_time = 0.1 * (1 - current_duty)
        if sleep_time > 0:
            time.sleep(sleep_time)

# --- 主控制循环 ---
def main():
    global memory_blocks, cpu_duty_cycle, running
    
    num_cores = os.cpu_count() or 1
    print(f"日志: 检测到 {num_cores} 个 CPU 核心")
    
    # 启动对应核心数的线程
    for i in range(num_cores):
        t = threading.Thread(target=cpu_burner_thread, args=(i,))
        t.daemon = True
        t.start()

    print(f"日志: 守护进程启动成功。目标占用范围: {TARGET_MIN}% - {TARGET_MAX}%")
    
    last_active, last_total = get_cpu_usage()
    
    while True:
        time.sleep(CHECK_INTERVAL)
        
        # 1. 计算 CPU 使用率
        curr_active, curr_total = get_cpu_usage()
        delta_total = curr_total - last_total
        delta_active = curr_active - last_active
        
        current_cpu_percent = 0
        if delta_total > 0:
            current_cpu_percent = (delta_active / delta_total) * 100.0
        
        last_active, last_total = curr_active, curr_total
        current_mem_percent = get_mem_usage_percent()
        
        # --- 2. 内存 动态调整 (堆叠法) ---
        # 每次调整 100MB
        CHUNK_SIZE = 100 * 1024 * 1024 
        
        if current_mem_percent < TARGET_MIN:
            try:
                block = bytearray(CHUNK_SIZE) # 申请物理内存
                memory_blocks.append(block) 
            except:
                pass 
        elif current_mem_percent > TARGET_MAX:
            # 如果内存超标且是我们占用的，则释放
            if len(memory_blocks) > 0:
                memory_blocks.pop()

        # --- 3. CPU 动态调整 (PID 简化版) ---
        step = 0.05
        if current_cpu_percent < TARGET_MIN:
            cpu_duty_cycle = min(1.0, cpu_duty_cycle + step)
        elif current_cpu_percent > TARGET_MAX:
            cpu_duty_cycle = max(0.0, cpu_duty_cycle - step * 2) # 快速避让

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        running = False
EOF
    # 启动 Python 脚本
    python3 -u $PYTHON_WORKER
}

# =========================================================
# 2. 自动安装与服务管理
# =========================================================

# 后台入口
if [ "$1" == "daemon" ]; then
    run_worker
    exit 0
fi

# 前台安装界面
clear
echo -e "${CYAN}=====================================================${PLAIN}"
echo -e "${CYAN}       VPS 资源守护脚本 (自动识别/智能调控)          ${PLAIN}"
echo -e "${CYAN}       目标: CPU/内存 20%-25% | 大内存优化版         ${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[错误] 请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}[1/3] 正在检测并安装系统依赖...${PLAIN}"
# 安装 python3
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y python3 >/dev/null 2>&1 || dnf install -y python3 >/dev/null 2>&1
elif [ -f /etc/alpine-release ]; then
    apk add python3 >/dev/null 2>&1
fi
echo -e "${GREEN}      依赖检查完成。${PLAIN}"

echo -e "${YELLOW}[2/3] 正在配置开机自启服务...${PLAIN}"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=VPS Resource Keeper Pro
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo -e "${YELLOW}[3/3] 正在启动后台守护进程...${PLAIN}"
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 获取硬件信息用于展示
CORES=$(nproc)
MEM=$(free -m | awk '/^Mem:/{print $2}')

echo -e "${CYAN}=====================================================${PLAIN}"
echo -e "${GREEN} INSTALLATION SUCCESSFUL (安装成功) ${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"
echo -e " 检测硬件配置 : ${YELLOW}${CORES} 核 CPU / ${MEM} MB 内存${PLAIN}"
echo -e " 运行状态     : ${GREEN}已在后台运行 (支持开机自启)${PLAIN}"
echo -e " 目标占用率   : ${GREEN}20% - 25% (智能动态调整)${PLAIN}"
echo -e "${CYAN}-----------------------------------------------------${PLAIN}"
echo -e " 温馨提示:"
echo -e " 1. 内存占用会像搭积木一样每3秒增加一点，直到达标。"
echo -e "    (对于 ${MEM}MB 内存，可能需要 1-2 分钟才能爬升到位)"
echo -e " 2. 如需停止脚本，请运行命令:"
echo -e "    ${YELLOW}systemctl stop $SERVICE_NAME && systemctl disable $SERVICE_NAME${PLAIN}"
echo -e " 3. 查看实时日志:"
echo -e "    ${YELLOW}journalctl -u $SERVICE_NAME -f${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"
