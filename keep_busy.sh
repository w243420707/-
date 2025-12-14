#!/bin/bash

# =========================================================
# VPS Resource Keeper (Auto-Install & Silent Run)
# 功能：自动占用 CPU/内存 20%-25%，智能避让
# 特性：一键运行，自动安装依赖，自动注册开机自启，后台静默
# =========================================================

SERVICE_NAME="vps-resource-keeper"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH=$(readlink -f "$0")

# 资源占用配置
TARGET_MIN=20
TARGET_MAX=25
INTERVAL=5

# =========================================================
# 1. 核心 Worker (Systemd 调用时运行此部分)
# =========================================================
run_worker() {
    # 再次检查依赖，确保万无一失
    if ! command -v bc &> /dev/null || ! command -v python3 &> /dev/null; then
        exit 1
    fi

    MEM_SCRIPT="/tmp/vps_keeper_mem.py"
    cat << 'EOF' > $MEM_SCRIPT
import time, sys, os
def allocate_memory(target_mb):
    try:
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
                os.kill(ppid, 0)
                time.sleep(2)
            except: break
EOF

    get_cpu() { top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'; }
    get_mem() { free | grep Mem | awk '{print $3/$2 * 100.0}'; }
    get_total_mem() { free -m | awk '/^Mem:/{print $2}'; }
    burn_cpu() { timeout 0.3s sha256sum /dev/zero > /dev/null 2>&1; }

    current_mem_pid=""
    adjust_mem() {
        if [ ! -z "$current_mem_pid" ]; then kill $current_mem_pid 2>/dev/null; wait $current_mem_pid 2>/dev/null; fi
        if (( $(echo "$1 > 0" | bc -l) )); then
            python3 $MEM_SCRIPT $1 > /dev/null 2>&1 &
            current_mem_pid=$!
        else
            current_mem_pid=""
        fi
    }

    trap "if [ ! -z '$current_mem_pid' ]; then kill $current_mem_pid 2>/dev/null; fi; rm -f $MEM_SCRIPT; exit 0" SIGINT SIGTERM

    TOTAL_MEM=$(get_total_mem)
    TARGET_AVG=$(echo "($TARGET_MAX + $TARGET_MIN) / 2" | bc)

    while true; do
        cpu=$(get_cpu); mem=$(get_mem)
        
        # 内存计算
        script_mem_mb=0
        if [ ! -z "$current_mem_pid" ] && ps -p $current_mem_pid > /dev/null; then
             rss=$(ps -o rss= -p $current_mem_pid 2>/dev/null | awk '{print $1}')
             if [ ! -z "$rss" ]; then script_mem_mb=$(echo "$rss / 1024" | bc); fi
        else current_mem_pid=""; fi

        real_sys_usage=$(echo "($mem * $TOTAL_MEM / 100 - $script_mem_mb) / $TOTAL_MEM * 100" | bc -l)
        if (( $(echo "$real_sys_usage < 0" | bc -l) )); then real_sys_usage=0; fi

        if (( $(echo "$real_sys_usage > $TARGET_MAX" | bc -l) )); then
            if [ ! -z "$current_mem_pid" ]; then adjust_mem 0; fi
        elif (( $(echo "$mem < $TARGET_MIN" | bc -l) )); then
            adjust_mem $(echo "$TOTAL_MEM * ($TARGET_AVG - $real_sys_usage) / 100" | bc)
        fi

        if (( $(echo "$cpu < $TARGET_MIN" | bc -l) )); then
            loops=$(echo "($TARGET_AVG - $cpu) / 4" | bc)
            if [ "$loops" -lt "1" ]; then loops=1; fi
            if [ "$loops" -gt "8" ]; then loops=8; fi
            for ((i=1; i<=loops; i++)); do burn_cpu & done
            wait
        fi
        sleep $INTERVAL
    done
}

# =========================================================
# 2. 自动安装逻辑 (脚本直接运行走这里)
# =========================================================

# 判断是否为 Systemd 后台调用
if [ "$1" == "daemon" ]; then
    run_worker
    exit 0
fi

# 下面是安装逻辑
echo ">>> Start Installing VPS Resource Keeper..."

# 1. 检查 Root
if [ "$(id -u)" != "0" ]; then echo "Error: Must run as root"; exit 1; fi

# 2. 安装依赖
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y bc python3 >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    if command -v dnf &> /dev/null; then dnf install -y bc python3 >/dev/null 2>&1; else yum install -y bc python3 >/dev/null 2>&1; fi
elif [ -f /etc/alpine-release ]; then
    apk update >/dev/null 2>&1 && apk add bc python3 >/dev/null 2>&1
elif command -v pacman &> /dev/null; then
    pacman -Sy --noconfirm bc python >/dev/null 2>&1
fi

# 3. 写入 Systemd 服务
echo ">>> Configuring Systemd Service..."
cat > $SERVICE_FILE <<EOF
[Unit]
Description=VPS Resource Keeper
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 4. 启动服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

echo ">>> Installation Complete!"
echo ">>> Status: Running in background (Auto-start enabled)"
echo ">>> Check status command: systemctl status $SERVICE_NAME"
