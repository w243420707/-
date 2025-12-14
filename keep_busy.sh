#!/bin/bash

# =========================================================
# VPS Resource Keeper (Pro Edition)
# 专治大内存(10GB+)和多核环境，平滑曲线，拒绝尖刺
# =========================================================

SERVICE_NAME="vps-resource-keeper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH=$(readlink -f "$0")

# =========================================================
# 1. 核心 Python 引擎 (嵌入式)
# =========================================================
# 我们将生成一个功能强大的 Python 脚本来接管控制
# 它使用多线程同时处理 CPU 和 内存，比 Shell 更精准
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
import math

# 配置
TARGET_MIN = 20.0
TARGET_MAX = 25.0
CHECK_INTERVAL = 3  # 检查周期

# 全局变量
memory_blocks = []
cpu_duty_cycle = 0.0 # CPU 占空比 (0.0 - 1.0)
cpu_threads = []
running = True

# --- 基础工具函数 ---

def get_cpu_usage():
    try:
        # 读取 /proc/stat 计算 CPU
        with open('/proc/stat', 'r') as f:
            line = f.readline()
        parts = line.split()
        # user+nice+system+irq+softirq+steal
        active = sum(int(parts[i]) for i in [1, 2, 3, 6, 7, 8])
        idle = int(parts[4]) + int(parts[5]) # idle + iowait
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
        return (used / mem_total) * 100.0, mem_total # 返回百分比和总内存(KB)
    except:
        return 0, 0

# --- CPU 消耗线程 ---
# 模拟 PWM：在 0.1s 的周期内，忙碌 duty_cycle 的时间
def cpu_burner_thread(core_id):
    global cpu_duty_cycle, running
    
    # 获取本机核心数
    try:
        num_cores = os.cpu_count()
    except:
        num_cores = 1
        
    while running:
        # 我们的目标是让 系统总CPU 达到 20%
        # 如果是双核，总占用 20% 意味着我们需要消耗 0.4 个核心的算力 (2 * 0.2)
        # 所以这里的 sleep 逻辑需要根据 duty_cycle 动态调整
        
        current_duty = cpu_duty_cycle
        
        if current_duty <= 0:
            time.sleep(0.5)
            continue
            
        start_time = time.time()
        # 忙碌阶段 (做数学运算)
        while (time.time() - start_time) < (0.1 * current_duty):
            _ = 3.14159 * 2.71828 # 简单的浮点运算
            
        # 休息阶段
        sleep_time = 0.1 * (1 - current_duty)
        if sleep_time > 0:
            time.sleep(sleep_time)

# --- 主控制循环 ---
def main():
    global memory_blocks, cpu_duty_cycle, running
    
    # 启动与 CPU 核心数相同数量的线程，以便能占满所有核心
    num_cores = os.cpu_count() or 1
    print(f"LOG: Detected {num_cores} CPU Cores")
    
    for i in range(num_cores):
        t = threading.Thread(target=cpu_burner_thread, args=(i,))
        t.daemon = True
        t.start()
        cpu_threads.append(t)

    print(f"LOG: Worker started. Target range: {TARGET_MIN}% - {TARGET_MAX}%")
    
    last_active, last_total = get_cpu_usage()
    
    while True:
        time.sleep(CHECK_INTERVAL)
        
        # 1. 获取当前状态
        curr_active, curr_total = get_cpu_usage()
        delta_total = curr_total - last_total
        delta_active = curr_active - last_active
        
        current_cpu_percent = 0
        if delta_total > 0:
            current_cpu_percent = (delta_active / delta_total) * 100.0
            
        last_active, last_total = curr_active, curr_total
        
        current_mem_percent, total_mem_kb = get_mem_usage_percent()
        
        # --- 2. 内存 动态调整 (堆叠法) ---
        # 每次只调整一小块 (100MB)，避免大起大落
        CHUNK_SIZE_MB = 100
        CHUNK_SIZE_BYTES = CHUNK_SIZE_MB * 1024 * 1024
        
        if current_mem_percent < TARGET_MIN:
            # 内存不够，分配一块
            try:
                # 使用 bytearray 并填充数据，防止被系统压缩或忽略
                block = bytearray(CHUNK_SIZE_BYTES)
                # 简单填充，确保产生实际物理内存占用
                memory_blocks.append(block) 
                # print(f"Added 100MB. Blocks: {len(memory_blocks)}")
            except:
                pass # 内存满了分配失败，忽略
                
        elif current_mem_percent > TARGET_MAX:
            # 内存超了，如果是因为我们占用的，就释放一块
            # 智能避让：如果 current_mem 很高但 blocks 为空，说明是其他程序占的，我们不管
            if len(memory_blocks) > 0:
                memory_blocks.pop()
                # print(f"Removed 100MB. Blocks: {len(memory_blocks)}")
            # 如果 memory_blocks 已经空了还是高，说明是业务占用，我们保持 0 占用即可

        # --- 3. CPU 动态调整 (PID 简化版) ---
        # 如果当前 CPU < 20%，增加占空比
        # 如果当前 CPU > 25%，减少占空比
        
        step = 0.05 # 每次调整 5% 的力度
        
        if current_cpu_percent < TARGET_MIN:
            cpu_duty_cycle = min(1.0, cpu_duty_cycle + step)
        elif current_cpu_percent > TARGET_MAX:
            cpu_duty_cycle = max(0.0, cpu_duty_cycle - step * 2) # 下降快一点
            
        # 调试日志 (可选)
        # print(f"CPU: {current_cpu_percent:.1f}% (Duty: {cpu_duty_cycle:.2f}), RAM: {current_mem_percent:.1f}% (Blocks: {len(memory_blocks)})")

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

if [ "$1" == "daemon" ]; then
    run_worker
    exit 0
fi

echo ">>> VPS Resource Keeper: Pro Edition"
echo ">>> Step 1: Installing Dependencies..."

if [ "$(id -u)" != "0" ]; then echo "Error: Must run as root"; exit 1; fi

# 安装 python3 (基本所有 VPS 都有，防止万一)
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y python3 >/dev/null 2>&1 || dnf install -y python3 >/dev/null 2>&1
elif [ -f /etc/alpine-release ]; then
    apk add python3 >/dev/null 2>&1
fi

echo ">>> Step 2: Configuring Systemd Service..."

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

systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

echo ">>> Success! Running in background."
echo ">>> The script will now smoothly ramp up usage to 20-25%."
echo ">>> It may take 1-2 minutes to stabilize the Memory curve."
echo ">>> Check status: systemctl status $SERVICE_NAME"
