#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

MONITOR_SCRIPT="/etc/sing-box/monitor.sh"
CONFIG_FILE="/etc/sing-box/config.json"
LOG_FILE="/var/log/singbox_monitor.log"
PROXY_PROFILE="/etc/profile.d/singbox_proxy.sh"
PROXY_PORT=2080

urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

uninstall_singbox() {
    echo -e "${YELLOW}停止服务...${PLAIN}"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$LOG_FILE" "$PROXY_PROFILE"
    sed -i '/singbox_proxy.sh/d' ~/.bashrc
    unset http_proxy https_proxy all_proxy
    systemctl daemon-reload
    echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
}

install_singbox() {
    # 1. 环境准备
    echo -e "${GREEN}步骤 1/5: 初始化环境...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq python3 cron >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar unzip jq python3 crontabs >/dev/null 2>&1
    fi

    # 2. 获取订阅
    echo -e "${YELLOW}请输入你的节点订阅链接:${PLAIN}"
    read -p "链接: " SUB_URL
    if [[ -z "$SUB_URL" ]]; then echo -e "${RED}链接为空！${PLAIN}"; return; fi
    
    # 简单下载逻辑
    echo -e "${GREEN}下载订阅...${PLAIN}"
    wget --no-check-certificate -q -O /tmp/singbox_raw.json "$SUB_URL"
    if [[ -s /tmp/singbox_raw.json ]] && jq -e '.outbounds' /tmp/singbox_raw.json >/dev/null 2>&1; then
        cp /tmp/singbox_raw.json /tmp/singbox_pre.json
        USE_CONVERSION=false
    else
        echo -e "${YELLOW}API 转换中...${PLAIN}"
        ENCODED_URL=$(urlencode "$SUB_URL")
        PRE_API="https://api.v1.mk/sub?target=sing-box&url=${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget --no-check-certificate -q -O /tmp/singbox_pre.json "$PRE_API"
        USE_CONVERSION=true
    fi

    # 3. 安装程序
    echo -e "${GREEN}步骤 2/5: 安装程序...${PLAIN}"
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

    # 4. WebUI
    WEBUI_DIR="/etc/sing-box/ui"
    mkdir -p "$WEBUI_DIR"
    wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
    unzip -q webui.zip
    mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
    rm -rf Yacd-meta-gh-pages webui.zip

    # 5. 注册服务 (无 Capability 限制，兼容性最高)
    echo -e "${GREEN}步骤 3/5: 注册服务...${PLAIN}"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    # 6. 生成监控脚本 (只用 Mixed 口)
    echo -e "${GREEN}步骤 4/5: 配置代理脚本...${PLAIN}"
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
SUB_URL="$SUB_URL"
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
PROXY_PROFILE="$PROXY_PROFILE"
USE_CONVERSION=$USE_CONVERSION

enable_env() {
    echo "export http_proxy=\"http://127.0.0.1:$PROXY_PORT\"" > "\$PROXY_PROFILE"
    echo "export https_proxy=\"http://127.0.0.1:$PROXY_PORT\"" >> "\$PROXY_PROFILE"
    echo "export all_proxy=\"socks5://127.0.0.1:$PROXY_PORT\"" >> "\$PROXY_PROFILE"
    echo "export NO_PROXY=\"localhost,127.0.0.1,::1\"" >> "\$PROXY_PROFILE"
    if ! grep -q "singbox_proxy.sh" ~/.bashrc; then echo "[ -f \$PROXY_PROFILE ] && source \$PROXY_PROFILE" >> ~/.bashrc; fi
}

check_proxy() {
    # 检测代理端口是否通
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --proxy http://127.0.0.1:$PROXY_PORT https://www.google.com/generate_204)
    if [[ "\$http_code" == "204" ]]; then return 0; else return 1; fi
}

update_subscription() {
    systemctl stop sing-box
    # 暂时移除环境变量以使用直连
    rm -f "\$PROXY_PROFILE"
    unset http_proxy https_proxy all_proxy
    
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
    else
        ENCODED_URL=\$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$SUB_URL")
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
    # 纯 Mixed 配置 (无需 TUN)
    MIXED_CONFIG='{
      "log": { "level": "info", "timestamp": true },
      "inbounds": [ { "type": "mixed", "tag": "mixed-in", "listen": "::", "listen_port": $PROXY_PORT } ],
      "experimental": {
        "cache_file": { "enabled": true, "path": "cache.db" },
        "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "/etc/sing-box/ui" }
      }
    }'
    
    if [[ -s /tmp/singbox_new.json ]] && jq . /tmp/singbox_new.json >/dev/null 2>&1; then
        jq 'del(.inbounds, .experimental, .log)' /tmp/singbox_new.json > /tmp/singbox_clean.json
        jq -s '.[0] * .[1]' /tmp/singbox_clean.json <(echo "\$MIXED_CONFIG") > /tmp/singbox_merged.json
        
        # 自动选节点
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then 
            jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' /tmp/singbox_merged.json > "\$CONFIG_FILE"
        else 
            mv /tmp/singbox_merged.json "\$CONFIG_FILE"
        fi
        
        systemctl start sing-box
        sleep 5
        if check_proxy; then enable_env; fi
    fi
}
if [[ "\$1" == "force" ]]; then update_subscription; exit 0; fi
if ! systemctl is-active --quiet sing-box || ! check_proxy; then update_subscription; fi
EOF
    chmod +x "$MONITOR_SCRIPT"
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
    echo "*/5 * * * * $MONITOR_SCRIPT" >> /tmp/cron_bk
    crontab /tmp/cron_bk
    rm /tmp/cron_bk

    echo -e "${GREEN}步骤 5/5: 启动并应用环境...${PLAIN}"
    bash "$MONITOR_SCRIPT" force
    
    echo -e ""
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ 服务已启动 (非 TUN 模式)${PLAIN}"
        echo -e "${YELLOW}警告：此模式不支持 Ping，也无法代理不支持 HTTP/SOCKS5 协议的软件。${PLAIN}"
        echo -e "${YELLOW}>>> 正在刷新 Shell 环境... <<<${PLAIN}"
        sleep 2
        # 强制替换当前 Shell 以立即加载环境变量
        exec bash -l
    else
        echo -e "${RED}❌ 启动失败。${PLAIN}"
    fi
}

# 菜单
clear
echo -e "1. ${GREEN}安装 (兼容模式 - 无需 TUN)${PLAIN}"
echo -e "2. ${RED}卸载${PLAIN}"
echo -e "0. 退出"
read -p "选择: " choice
case $choice in
    1) install_singbox ;;
    2) uninstall_singbox ;;
    0) exit 0 ;;
    *) exit 1 ;;
esac
