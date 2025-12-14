#!/bin/bash

# =========================================================
# VPS Resource Keeper (Hardware Aware Edition)
# 功能：自动识别 CPU/内存配置，动态维持 20%-25% 占用
# 特性：自动硬件识别、自动安装依赖、开机自启、静默运行
# =========================================================

SERVICE_NAME="vps-resource-keeper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH=$(readlink -f "$0")

# 目标占用范围 (%)
TARGET_MIN=20
TARGET_MAX=25
INTERVAL=5

# =========================================================
# 1. 核心 Worker (后台服务运行逻辑)
# =========================================================
run_worker() {
    # --- 硬件识别 ---
    NUM_CORES=$(nproc)
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    
    echo "LOG: Detected Hardware -> CPU Cores: ${NUM_CORES}, Total RAM: ${TOTAL_MEM}MB"
    echo "LOG: Target Usage -> ${TARGET_MIN}% - ${TARGET_MAX}%"

    # --- 依赖工具检查 ---
    if ! command -v bc &> /dev/null || ! command -v python3 &> /dev/null; then
        echo "Error: Dependencies missing in worker thread."
        exit 1
    fi

    # --- 内存控制脚本 (Python) ---
    MEM_SCRIPT="/tmp/vps_keeper_mem_worker.py"
    cat << 'EOF' > $MEM_SCRIPT
import time, sys, os
def allocate_memory(target_mb):
    try:
        # 申请内存并写入数据确保物理内存被占用
        return bytearray(int(target_mb * 1024 * 1024))
    except:
        return None
if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(1)
    target_mb = float(sys.argv[1])
    ppid = os.getppid()
    if allocate_memory(target_mb):
        while True:
            try:
                os.kill(ppid, 0) # 监听父进程，父进程死则自杀
                time.sleep(2)
            except: break
EOF

    # --- 辅助函数 ---
    # 获取 CPU 总体使用率
    get_cpu() { top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'; }
    # 获取 内存 使用率
    get_mem() { free | grep Mem | awk '{print $3/$2 * 100.0}'; }
    
    # CPU 消耗函数 (根据核心数调整压力)
    burn_cpu() { 
        # 运行 sha256sum 计算，持续 0.3s
        timeout 0.3s sha256sum /dev/zero > /dev/null 2>&1
    }

    # 内存调整函数
    current_mem_pid=""
    adjust_mem() {
        local target=$1
        # 先清理旧进程
        if [ ! -z "$current_mem_pid" ]; then 
            kill $current_mem_pid 2>/dev/null 
            wait $current_mem_pid 2>/dev/null
        fi
        
        # 启动新进程
        if (( $(echo "$target > 0" | bc -l) )); then
            python3 $MEM_SCRIPT $target > /dev/null 2>&1 &
            current_mem_pid=$!
        else
            current_mem_pid=""
        fi
    }

    # 退出清理
    trap "if [ ! -z '$current_mem_pid' ]; then kill $current_mem_pid 2>/dev/null; fi; rm -f $MEM_SCRIPT; exit 0" SIGINT SIGTERM

    TARGET_AVG=$(echo "($TARGET_MAX + $TARGET_MIN) / 2" | bc)

    # --- 主循环 ---
    while true; do
        cpu=$(get_cpu)
        mem=$(get_mem)
        
        # 1. 计算内存需求
        # 获取当前脚本占用的内存(MB)
        script_mem_mb=0
        if [ ! -z "$current_mem_pid" ] && ps -p $current_mem_pid > /dev/null; then
             rss=$(ps -o rss= -p $current_mem_pid 2>/dev/null | awk '{print $1}')
             if [ ! -z "$rss" ]; then script_mem_mb=$(echo "$rss / 1024" | bc); fi
        else 
             current_mem_pid=""
        fi

        # 计算"非脚本"的系统真实负载
        # 真实负载% = (当前总内存% * 总内存MB - 脚本占用MB) / 总内存MB * 100
        real_sys_usage=$(echo "($mem * $TOTAL_MEM / 100 - $script_mem_mb) / $TOTAL_MEM * 100" | bc -l)
        if (( $(echo "$real_sys_usage < 0" | bc -l) )); then real_sys_usage=0; fi

        # 内存策略：
        if (( $(echo "$real_sys_usage > $TARGET_MAX" | bc -l) )); then
            # 其他程序占用超过 MAX -> 脚本全部释放
            if [ ! -z "$current_mem_pid" ]; then adjust_mem 0; fi
        elif (( $(echo "$mem < $TARGET_MIN" | bc -l) )); then
            # 总占用低于 MIN -> 补齐到 AVG
            needed_mb=$(echo "$TOTAL_MEM * ($TARGET_AVG - $real_sys_usage) / 100" | bc)
            adjust_mem $needed_mb
        fi

        # 2. 计算 CPU 需求
        if (( $(echo "$cpu < $TARGET_MIN" | bc -l) )); then
            # 计算差距
            gap=$(echo "$TARGET_AVG - $cpu" | bc -l)
            
            # 根据核心数决定并发量
            # 逻辑：如果 gap 很大，且核心数多，则多开几个线程
            # 基础并发 = 核心数 * (Gap / 10)
            threads=$(echo "$NUM_CORES * $gap / 10" | bc)
            
            # 限制线程数范围 [1, 核心数*2]
            if [ "$threads" -lt "1" ]; then threads=1; fi
            max_threads=$(echo "$NUM_CORES * 2" | bc)
            if [ "$threads" -gt "$max_threads" ]; then threads=$max_threads; fi
            
            for ((i=1; i<=threads; i++)); do
                burn_cpu &
            done
            wait
        fi

        sleep $INTERVAL
    done
}

# =========================================================
# 2. 自动安装逻辑 (Systemd 入口)
# =========================================================

if [ "$1" == "daemon" ]; then
    run_worker
    exit 0
fi

echo ">>> VPS Resource Keeper: Auto-Installer"
echo ">>> Step 1: Detecting System..."

# 检查 Root
if [ "$(id -u)" != "0" ]; then echo "Error: Must run as root"; exit 1; fi

# 自动安装依赖
if [ -f /etc/debian_version ]; then
    echo "    - OS: Debian/Ubuntu detected."
    apt-get update -y >/dev/null 2>&1 && apt-get install -y bc python3 procps >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    echo "    - OS: CentOS/RHEL detected."
    if command -v dnf &> /dev/null; then dnf install -y bc python3 procps >/dev/null 2>&1; else yum install -y bc python3 procps >/dev/null 2>&1; fi
elif [ -f /etc/alpine-release ]; then
    echo "    - OS: Alpine Linux detected."
    apk update >/dev/null 2>&1 && apk add bc python3 procps >/dev/null 2>&1
elif command -v pacman &> /dev/null; then
    echo "    - OS: Arch Linux detected."
    pacman -Sy --noconfirm bc python procps >/dev/null 2>&1
else
    echo "    - Unknown OS. Attempting to run anyway (dependencies might fail)."
fi

echo ">>> Step 2: Configuring Auto-Start Service..."

# 写入 Systemd 服务文件
cat > $SERVICE_FILE <<EOF
[Unit]
Description=VPS Resource Keeper (Auto Hardware Detect)
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 获取硬件信息用于显示安装结果
CORES=$(nproc)
MEM=$(free -m | awk '/^Mem:/{print $2}')

echo ">>> Installation Complete!"
echo "-----------------------------------------------------"
echo " Detected CPU Cores : $CORES"
echo " Detected Total RAM : ${MEM} MB"
echo " Service Status     : Active (Running in background)"
echo "-----------------------------------------------------"
echo "To check logs: journalctl -u $SERVICE_NAME -f"
echo "To stop:       systemctl stop $SERVICE_NAME; systemctl disable $SERVICE_NAME"
