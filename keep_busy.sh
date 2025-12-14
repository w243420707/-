#!/bin/bash

# =========================================================
# VPS 资源守护脚本 (终极通用版 - 全系适配)
# 适用：1核1G 到 128核512G 全覆盖
# 特性：自适应内存步长、多核并发控制、中文彩色交互
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
memory_blocks = [] 
cpu_duty_cycle = 0.0 
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

def get_mem_info():
    # 返回: (使用率百分比, 总内存KB)
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
        return (used / mem_total) * 100.0, mem_total
    except:
        return 0, 0

# --- CPU 消耗线程 (PWM 模拟) ---
def cpu_burner_thread(core_id):
    global cpu_duty_cycle, running
    while running:
        current_duty = cpu_duty_cycle
        if current_duty <= 0:
            time.sleep(0.5)
            continue
        
        start_time = time.time()
        # 0.1秒为一个PWM周期
        while (time.time() - start_time) < (0.1 * current_duty):
            _ = 3.14159 * 2.71828 
            
        sleep_time = 0.1 * (1 - current_duty)
        if sleep_time > 0:
            time.sleep(sleep_time)

# --- 主控制循环 ---
def main():
    global memory_blocks, cpu_duty_cycle, running
    
    num_cores = os.cpu_count() or 1
    print(f"日志: CPU核心数: {num_cores}")
    
    # 启动对应核心数的线程
    for i in range(num_cores):
        t = threading.Thread(target=cpu_burner_thread, args=(i,))
        t.daemon = True
        t.start()

    print(f"日志: 守护进程启动。目标范围: {TARGET_MIN}% - {TARGET_MAX}%")
    
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
        
        # 2. 获取内存信息
        current_mem_percent, total_mem_kb = get_mem_info()
        
        # --- 内存动态调整 (自适应步长) ---
        # 核心算法：每次调整总内存的 1%
        # 1GB内存 -> 每次调10MB, 24GB内存 -> 每次调240MB
        # 无论机器多大，都在1分钟左右完成爬坡
        chunk_kb = int(total_mem_kb * 0.01)
        if chunk_kb < 1024: chunk_kb = 1024 # 最小1MB防止报错
        
        CHUNK_SIZE_BYTES = chunk_kb * 1024
        
        if current_mem_percent < TARGET_MIN:
            try:
                block = bytearray(CHUNK_SIZE_BYTES) 
                memory_blocks.append(block) 
            except:
                pass 
        elif current_mem_percent > TARGET_MAX:
            if len(memory_blocks) > 0:
                memory_blocks.pop()

        # --- CPU 动态调整 ---
        step = 0.05
        if current_cpu_percent < TARGET_MIN:
            cpu_duty_cycle = min(1.0, cpu_duty_cycle + step)
        elif current_cpu_percent > TARGET_MAX:
            cpu_duty_cycle = max(0.0, cpu_duty_cycle - step * 2) 

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        running = False
EOF
    python3 -u $PYTHON_WORKER
}

# =========================================================
# 2. 自动安装与服务管理
# =========================================================

if [ "$1" == "daemon" ]; then
    run_worker
    exit 0
fi

clear
echo -e "${CYAN}=====================================================${PLAIN}"
echo -e "${CYAN}     VPS 资源守护脚本 (终极通用版 | 1G-128G通用)     ${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[错误] 请使用 root 用户运行！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}[1/3] 检测并安装依赖...${PLAIN}"
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y python3 >/dev/null 2>&1 || dnf install -y python3 >/dev/null 2>&1
elif [ -f /etc/alpine-release ]; then
    apk add python3 >/dev/null 2>&1
fi

echo -e "${YELLOW}[2/3] 配置开机自启服务...${PLAIN}"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=VPS Resource Keeper Universal
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo -e "${YELLOW}[3/3] 启动后台守护进程...${PLAIN}"
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

CORES=$(nproc)
MEM=$(free -m | awk '/^Mem:/{print $2}')

echo -e "${CYAN}=====================================================${PLAIN}"
echo -e "${GREEN} 安装成功！(SUCCESS) ${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"
echo -e " 硬件检测     : ${YELLOW}${CORES} 核 CPU / ${MEM} MB 内存${PLAIN}"
echo -e " 适配模式     : ${GREEN}自适应步长 (1% 动态调节)${PLAIN}"
echo -e " 运行状态     : ${GREEN}后台运行中 (已开机自启)${PLAIN}"
echo -e "${CYAN}-----------------------------------------------------${PLAIN}"
echo -e " 1. 脚本会根据内存大小，自动计算最佳填充速度。"
echo -e " 2. 无论 1G 还是 24G 机器，均在 60秒 左右达到平衡。"
echo -e " 3. 卸载命令: ${YELLOW}systemctl stop $SERVICE_NAME && systemctl disable $SERVICE_NAME${PLAIN}"
echo -e "${CYAN}=====================================================${PLAIN}"
