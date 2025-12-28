#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 捕获命令行参数
CLI_SUB_URL="$1"

MONITOR_SCRIPT="/etc/sing-box/monitor.sh"
CONFIG_FILE="/etc/sing-box/config.json"
LOG_FILE="/var/log/singbox_monitor.log"
TPROXY_PORT=12345

# ==========================================
# 辅助函数
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# 清理 iptables 规则的函数
flush_iptables() {
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    iptables -t mangle -D PREROUTING -j SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -D OUTPUT -j SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -F SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -X SINGBOX_DIVERT 2>/dev/null
}

uninstall_singbox() {
    echo -e "${YELLOW}正在清理网络规则...${PLAIN}"
    flush_iptables
    
    echo -e "${YELLOW}停止服务...${PLAIN}"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$LOG_FILE"
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ 卸载完成，TProxy 规则已清除。${PLAIN}"
}

install_singbox() {
    # 1. 检查内核模块 (关键步骤)
    echo -e "${GREEN}步骤 1/6: 检查 TProxy 依赖...${PLAIN}"
    if ! modprobe xt_TPROXY >/dev/null 2>&1; then
        echo -e "${RED}警告: 无法加载 xt_TPROXY 模块！${PLAIN}"
        echo -e "${YELLOW}如果这一步失败，说明你的 VPS 内核不支持 TProxy，建议换回 ProxyChains 方案。${PLAIN}"
        read -p "是否强制继续? (y/n): " force_c
        if [[ "$force_c" != "y" ]]; then return; fi
    else
        echo -e "${GREEN}内核模块检查通过。${PLAIN}"
    fi

    # 2. 安装基础软件
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq python3 cron iptables >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar unzip jq python3 crontabs iptables-services >/dev/null 2>&1
    fi

    # 3. 订阅处理
    if [[ -n "$CLI_SUB_URL" ]]; then
        SUB_URL="$CLI_SUB_URL"
        echo -e "${YELLOW}使用参数订阅: ${SUB_URL}${PLAIN}"
    else
        echo -e "${YELLOW}请输入节点订阅链接:${PLAIN}"
        read -p "链接: " SUB_URL
    fi
    if [[ -z "$SUB_URL" ]]; then echo -e "${RED}链接为空！${PLAIN}"; return; fi

    echo -e "${GREEN}下载订阅...${PLAIN}"
    wget --no-check-certificate -q -O /tmp/singbox_raw.json "$SUB_URL"
    if [[ -s /tmp/singbox_raw.json ]] && jq -e '.outbounds' /tmp/singbox_raw.json >/dev/null 2>&1; then
        cp /tmp/singbox_raw.json /tmp/singbox_pre.json
        USE_CONVERSION=false
    else
        echo -e "${YELLOW}转换订阅格式...${PLAIN}"
        ENCODED_URL=$(urlencode "$SUB_URL")
        PRE_API="https://api.v1.mk/sub?target=sing-box&url=${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget --no-check-certificate -q -O /tmp/singbox_pre.json "$PRE_API"
        USE_CONVERSION=true
    fi

    # 4. 安装 Sing-box
    echo -e "${GREEN}步骤 2/6: 部署 Sing-box...${PLAIN}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) singbox_arch="amd64" ;;
        aarch64) singbox_arch="arm64" ;;
        *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; return ;;
    esac
    LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".assets[] | select(.name | contains(\"linux-$singbox_arch\") and contains(\".tar.gz\")) | .browser_download_url")
    wget -q -O sing-box.tar.gz "$LATEST_URL"
    tar -zxvf sing-box.tar.gz > /dev/null
    mv sing-box*linux*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*
    mkdir -p /etc/sing-box
    
    # WebUI
    WEBUI_DIR="/etc/sing-box/ui"
    mkdir -p "$WEBUI_DIR"
    wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
    unzip -q webui.zip
    mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
    rm -rf Yacd-meta-gh-pages webui.zip

    # 5. 生成 Monitor 脚本 (含 iptables 逻辑)
    echo -e "${GREEN}步骤 3/6: 配置 TProxy 规则脚本...${PLAIN}"
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
SUB_URL="$SUB_URL"
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
USE_CONVERSION=$USE_CONVERSION
TPROXY_PORT=$TPROXY_PORT

# 设置 iptables 规则 (核心逻辑)
set_iptables() {
    # 1. 清理旧规则
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -F SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -X SINGBOX_DIVERT 2>/dev/null

    # 2. 策略路由
    ip rule add fwmark 1 lookup 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # 3. 创建 DIVERT 链 (防止环路)
    iptables -t mangle -N SINGBOX_DIVERT
    iptables -t mangle -A SINGBOX_DIVERT -j MARK --set-mark 1
    iptables -t mangle -A SINGBOX_DIVERT -j ACCEPT

    # 4. 创建 TPROXY 链 (入站劫持)
    iptables -t mangle -N SINGBOX_TPROXY
    # 绕过保留地址
    iptables -t mangle -A SINGBOX_TPROXY -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 240.0.0.0/4 -j RETURN
    # 劫持 TCP/UDP 到 TProxy 端口
    iptables -t mangle -A SINGBOX_TPROXY -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark 1
    iptables -t mangle -A SINGBOX_TPROXY -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark 1

    # 5. 应用规则
    # PREROUTING: 处理进入本机的流量 (如果本机当网关用)
    iptables -t mangle -A PREROUTING -j SINGBOX_TPROXY
    # OUTPUT: 处理本机发出的流量
    iptables -t mangle -A OUTPUT -j SINGBOX_DIVERT
}

check_proxy() {
    # 检测国内网是否通 (用百度) 
    if curl -s --max-time 3 https://www.baidu.com >/dev/null; then
        # 如果百度通，再测谷歌 (看代理通不通)
        if curl -s --max-time 5 https://www.google.com/generate_204 >/dev/null; then return 0; fi
    fi
    # 如果都不通，或者只有百度通谷歌不通，返回失败
    return 1
}

update_subscription() {
    # 暂时清空规则以防无法下载
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -F SINGBOX_DIVERT 2>/dev/null
    
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
    else
        ENCODED_URL=\$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$SUB_URL")
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
    # TProxy 专用配置
    TPROXY_CONFIG='{
      "log": { "level": "info", "timestamp": true },
      "inbounds": [
        {
          "type": "tproxy",
          "tag": "tproxy-in",
          "listen": "::",
          "listen_port": $TPROXY_PORT,
          "sniff": true,
          "sniff_override_destination": true
        }
      ],
      "route": {
        "rules": [
          { "protocol": "dns", "outbound": "dns-out" },
          { "clash_mode": "Direct", "outbound": "direct" },
          { "clash_mode": "Global", "outbound": "Proxy" }
        ]
      },
      "experimental": {
        "cache_file": { "enabled": true, "path": "cache.db" },
        "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "/etc/sing-box/ui" }
      }
    }'
    
    if [[ -s /tmp/singbox_new.json ]] && jq . /tmp/singbox_new.json >/dev/null 2>&1; then
        jq 'del(.inbounds, .experimental, .log, .route)' /tmp/singbox_new.json > /tmp/singbox_clean.json
        jq -s '.[0] * .[1]' /tmp/singbox_clean.json <(echo "\$TPROXY_CONFIG") > /tmp/singbox_merged.json
        
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then 
             jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' /tmp/singbox_merged.json > "\$CONFIG_FILE"
        else 
             mv /tmp/singbox_merged.json "\$CONFIG_FILE"
        fi
        
        systemctl restart sing-box
        sleep 2
        set_iptables
    fi
}

if [[ "\$1" == "force" ]]; then update_subscription; exit 0; fi
if ! systemctl is-active --quiet sing-box; then update_subscription; fi
EOF
    chmod +x "$MONITOR_SCRIPT"
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
    echo "*/5 * * * * $MONITOR_SCRIPT" >> /tmp/cron_bk
    crontab /tmp/cron_bk
    rm /tmp/cron_bk

    # 6. 服务文件
    echo -e "${GREEN}步骤 4/6: 注册服务...${PLAIN}"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    echo -e "${GREEN}步骤 5/6: 启动 TProxy 服务...${PLAIN}"
    bash "$MONITOR_SCRIPT" force
    
    echo -e ""
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ Sing-box TProxy 模式运行中！${PLAIN}"
        echo -e "WebUI: http://$(curl -s4m5 ip.sb):9090/ui/"
        echo -e "${YELLOW}正在测试连通性...${PLAIN}"
        curl -I https://www.google.com/generate_204
    else
        echo -e "${RED}❌ 启动失败。请检查系统是否支持 xt_TPROXY 模块。${PLAIN}"
    fi
}

# 菜单
clear
echo -e "${BLUE}Sing-box TProxy 透明代理安装脚本${PLAIN}"
echo -e "1. ${GREEN}安装 (TProxy 全局代理)${PLAIN}"
echo -e "2. ${RED}卸载${PLAIN}"
echo -e "0. 退出"
read -p "选择: " choice
case $choice in
    1) install_singbox ;;
    2) uninstall_singbox ;;
    0) exit 0 ;;
    *) exit 1 ;;
esac
