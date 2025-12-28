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

# URL编码函数
urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# Root 检查
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

# ==========================================
# 核心功能函数
# ==========================================

uninstall_singbox() {
    echo -e "${YELLOW}正在停止 Sing-box 服务...${PLAIN}"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    echo -e "${YELLOW}正在清理定时任务...${PLAIN}"
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -

    echo -e "${YELLOW}正在删除文件和配置...${PLAIN}"
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$LOG_FILE"
    
    # 清理环境变量残留
    rm -f /etc/profile.d/singbox_proxy.sh
    sed -i '/singbox_proxy.sh/d' ~/.bashrc
    
    # 清理 sysctl 配置
    rm -f /etc/sysctl.d/99-singbox.conf
    
    systemctl daemon-reload
    
    echo -e "${GREEN}✅ 卸载完成！系统已恢复原状。${PLAIN}"
}

install_singbox() {
    # 1. 环境准备
    echo -e "${GREEN}步骤 1/6: 初始化环境...${PLAIN}"
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-singbox.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-singbox.conf
    sysctl -p /etc/sysctl.d/99-singbox.conf >/dev/null 2>&1

    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq python3 cron ntpdate >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar unzip jq python3 crontabs ntpdate >/dev/null 2>&1
    fi
    ntpdate pool.ntp.org >/dev/null 2>&1

    # 检查 TUN
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi

    # 2. 获取订阅
    echo -e "${YELLOW}请输入你的节点订阅链接:${PLAIN}"
    read -p "链接: " SUB_URL
    
    if [[ -z "$SUB_URL" ]]; then echo -e "${RED}链接为空！${PLAIN}"; return; fi

    FINAL_REGEX=""
    USE_CONVERSION=true 

    echo -e "${GREEN}正在下载订阅...${PLAIN}"
    wget --no-check-certificate -q -O /tmp/singbox_raw.json "$SUB_URL"
    
    if [[ -s /tmp/singbox_raw.json ]] && jq -e '.outbounds' /tmp/singbox_raw.json >/dev/null 2>&1; then
        echo -e "${GREEN}格式正确。${PLAIN}"
        cp /tmp/singbox_raw.json /tmp/singbox_pre.json
        USE_CONVERSION=false
    else
        echo -e "${YELLOW}正在转换格式...${PLAIN}"
        ENCODED_URL=$(urlencode "$SUB_URL")
        PRE_API="https://api.v1.mk/sub?target=sing-box&url=${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget --no-check-certificate -q -O /tmp/singbox_pre.json "$PRE_API"
    fi

    # 3. 菜单选择逻辑
    NODE_TAGS=$(jq -r '.outbounds[] | select(.type | test("Selector|URLTest|Direct|Block") | not) | .tag' /tmp/singbox_pre.json)
    REGION_DATA=(
"阿富汗 (AF)|🇦🇫|AF|Afghanistan|阿富汗" "阿尔巴尼亚 (AL)|🇦🇱|AL|Albania|阿尔巴尼亚" "阿尔及利亚 (AG)|🇩🇿|AG|Algeria|阿尔及利亚" "安道尔 (AN)|🇦🇩|AN|Andorra|安道尔" "安哥拉 (AO)|🇦🇴|AO|Angola|安哥拉" "阿根廷 (AR)|🇦🇷|AR|Argentina|阿根廷" "澳大利亚 (AS)|🇦🇺|AS|Australia|澳大利亚" "奥地利 (AU)|🇦🇹|AU|Austria|奥地利" "阿塞拜疆 (AJ)|🇦🇿|AJ|Azerbaijan|阿塞拜疆" "巴哈马 (BF)|🇧🇸|BF|Bahamas|巴哈马" "巴林 (BA)|🇧🇭|BA|Bahrain|巴林" "孟加拉国 (BG)|🇧🇩|BG|Bangladesh|孟加拉" "白俄罗斯 (BO)|🇧🇾|BO|Belarus|白俄罗斯" "比利时 (BE)|🇧🇪|BE|Belgium|比利时" "伯利兹 (BH)|🇧🇿|BH|Belize|伯利兹" "玻利维亚 (BL)|🇧🇴|BL|Bolivia|玻利维亚" "波黑 (BK)|🇧🇦|BK|Bosnia|波黑" "巴西 (BR)|🇧🇷|BR|Brazil|巴西" "文莱 (BX)|🇧🇳|BX|Brunei|文莱" "保加利亚 (BU)|🇧🇬|BU|Bulgaria|保加利亚" "柬埔寨 (CB)|🇰🇭|CB|Cambodia|柬埔寨" "加拿大 (CA)|🇨🇦|CA|Canada|加拿大" "智利 (CI)|🇨🇱|CI|Chile|智利" "中国 (CN)|🇨🇳|CN|China|中国|回国" "哥伦比亚 (CO)|🇨🇴|CO|Colombia|哥伦比亚" "刚果 (CG)|🇨🇬|CG|Congo|刚果" "哥斯达黎加 (CS)|🇨🇷|CS|Costa Rica|哥斯达黎加" "克罗地亚 (HR)|🇭🇷|HR|Croatia|克罗地亚" "古巴 (CU)|🇨🇺|CU|Cuba|古巴" "塞浦路斯 (CY)|🇨🇾|CY|Cyprus|塞浦路斯" "捷克 (EZ)|🇨🇿|EZ|Czech|捷克" "丹麦 (DA)|🇩🇰|DA|Denmark|丹麦" "厄瓜多尔 (EC)|🇪🇨|EC|Ecuador|厄瓜多尔" "埃及 (EG)|🇪🇬|EG|Egypt|埃及" "爱沙尼亚 (EN)|🇪🇪|EN|Estonia|爱沙尼亚" "芬兰 (FI)|🇫🇮|FI|Finland|芬兰" "法国 (FR)|🇫🇷|FR|France|法国" "格鲁吉亚 (GG)|🇬🇪|GG|Georgia|格鲁吉亚" "德国 (DE)|🇩🇪|DE|Germany|德国" "加纳 (GH)|🇬🇭|GH|Ghana|加纳" "希腊 (GR)|🇬🇷|GR|Greece|希腊" "危地马拉 (GT)|🇬🇹|GT|Guatemala|危地马拉" "海地 (HA)|🇭🇹|HA|Haiti|海地" "洪都拉斯 (HO)|🇭🇳|HO|Honduras|洪都拉斯" "香港 (HK)|🇭🇰|HK|Hong Kong|HongKong|香港" "匈牙利 (HU)|🇭🇺|HU|Hungary|匈牙利" "冰岛 (IC)|🇮🇸|IC|Iceland|冰岛" "印度 (IN)|🇮🇳|IN|India|印度" "印度尼西亚 (ID)|🇮🇩|ID|Indonesia|印尼|印度尼西亚" "伊朗 (IR)|🇮🇷|IR|Iran|伊朗" "伊拉克 (IZ)|🇮🇶|IZ|Iraq|伊拉克" "爱尔兰 (EI)|🇮🇪|EI|Ireland|爱尔兰" "以色列 (IS)|🇮🇱|IS|Israel|以色列" "意大利 (IT)|🇮🇹|IT|Italy|意大利" "牙买加 (JM)|🇯🇲|JM|Jamaica|牙买加" "日本 (JP)|🇯🇵|JP|Japan|日本" "约旦 (JO)|🇯🇴|JO|Jordan|约旦" "哈萨克斯坦 (KZ)|🇰🇿|KZ|Kazakhstan|哈萨克斯坦" "肯尼亚 (KE)|🇰🇪|KE|Kenya|肯尼亚" "韩国 (KR)|🇰🇷|KR|South Korea|Korea|韩国" "科威特 (KU)|🇰🇼|KU|Kuwait|科威特" "吉尔吉斯斯坦 (KG)|🇰🇬|KG|Kyrgyzstan|吉尔吉斯" "老挝 (LA)|🇱🇦|LA|Laos|老挝" "拉脱维亚 (LG)|🇱🇻|LG|Latvia|拉脱维亚" "黎巴嫩 (LE)|🇱🇧|LE|Lebanon|黎巴嫩" "立陶宛 (LH)|🇱🇹|LH|Lithuania|立陶宛" "卢森堡 (LU)|🇱🇺|LU|Luxembourg|卢森堡" "澳门 (MC)|🇲🇴|MC|Macao|Macau|澳门" "北马其顿 (MK)|🇲🇰|MK|Macedonia|北马其顿" "马来西亚 (MY)|🇲🇾|MY|Malaysia|马来西亚" "马耳他 (MT)|🇲🇹|MT|Malta|马耳他" "墨西哥 (MX)|🇲🇽|MX|Mexico|墨西哥" "摩尔多瓦 (MD)|🇲🇩|MD|Moldova|摩尔多瓦" "摩纳哥 (MN)|🇲🇨|MN|Monaco|摩纳哥" "蒙古 (MG)|🇲🇳|MG|Mongolia|蒙古" "黑山 (MJ)|🇲🇪|MJ|Montenegro|黑山" "摩洛哥 (MO)|🇲🇦|MO|Morocco|摩洛哥" "尼泊尔 (NP)|🇳🇵|NP|Nepal|尼泊尔" "荷兰 (NL)|🇳🇱|NL|Netherlands|Holland|荷兰" "新西兰 (NZ)|🇳🇿|NZ|New Zealand|新西兰" "尼日利亚 (NI)|🇳🇬|NI|Nigeria|尼日利亚" "挪威 (NO)|🇳🇴|NO|Norway|挪威" "阿曼 (MU)|🇴🇲|MU|Oman|阿曼" "巴基斯坦 (PK)|🇵🇰|PK|Pakistan|巴基斯坦" "巴拿马 (PM)|🇵🇦|PM|Panama|巴拿马" "巴拉圭 (PA)|🇵🇾|PA|Paraguay|巴拉圭" "秘鲁 (PE)|🇵🇪|PE|Peru|秘鲁" "菲律宾 (RP)|🇵🇭|RP|Philippines|菲律宾" "波兰 (PL)|🇵🇱|PL|Poland|波兰" "葡萄牙 (PO)|🇵🇹|PO|Portugal|葡萄牙" "卡塔尔 (QA)|🇶🇦|QA|Qatar|卡塔尔" "罗马尼亚 (RO)|🇷🇴|RO|Romania|罗马尼亚" "台湾 (TW)|🇹🇼|TW|Taiwan|TaiWan|台湾" "俄罗斯 (RS)|🇷🇺|RS|Russia|俄罗斯" "沙特阿拉伯 (SA)|🇸🇦|SA|Saudi Arabia|沙特" "塞尔维亚 (RI)|🇷🇸|RI|Serbia|塞尔维亚" "新加坡 (SG)|🇸🇬|SG|Singapore|新加坡" "斯洛伐克 (LO)|🇸🇰|LO|Slovakia|斯洛伐克" "斯洛文尼亚 (SI)|🇸🇮|SI|Slovenia|斯洛文尼亚" "南非 (SF)|🇿🇦|SF|South Africa|南非" "西班牙 (SP)|🇪🇸|SP|Spain|西班牙" "斯里兰卡 (CE)|🇱🇰|CE|Sri Lanka|斯里兰卡" "瑞典 (SW)|🇸🇪|SW|Sweden|瑞典" "瑞士 (SZ)|🇨🇭|SZ|Switzerland|瑞士" "叙利亚 (SY)|🇸🇾|SY|Syria|叙利亚" "塔吉克斯坦 (TI)|🇹🇯|TI|Tajikistan|塔吉克斯坦" "泰国 (TH)|🇹🇭|TH|Thailand|泰国" "突尼斯 (TS)|🇹🇳|TS|Tunisia|突尼斯" "土耳其 (TU)|🇹🇷|TU|Turkey|土耳其" "土库曼斯坦 (TX)|🇹🇲|TX|Turkmenistan|土库曼斯坦" "乌克兰 (UP)|🇺🇦|UP|Ukraine|乌克兰" "阿联酋 (AE)|🇦🇪|AE|United Arab Emirates|UAE|阿联酋" "英国 (UK)|🇬🇧|UK|United Kingdom|Britain|英国" "美国 (US)|🇺🇸|US|United States|USA|America|美国" "乌拉圭 (UY)|🇺🇾|UY|Uruguay|乌拉圭" "乌兹别克斯坦 (UZ)|🇺🇿|UZ|Uzbekistan|乌兹别克斯坦" "委内瑞拉 (VE)|🇻🇪|VE|Venezuela|委内瑞拉" "越南 (VM)|🇻🇳|VM|Vietnam|越南"
    )
    FOUND_REGEXS=()
    FOUND_NAMES=()
    echo -e "----------------------------------------"
    echo -e "${GREEN}检测到以下地区的节点：${PLAIN}"
    idx=1
    for item in "${REGION_DATA[@]}"; do
        NAME="${item%%|*}"
        KEYWORDS="${item#*|}"
        COUNT=$(echo "$NODE_TAGS" | grep -Ei "$KEYWORDS" | wc -l)
        if [[ $COUNT -gt 0 ]]; then
            echo -e "${GREEN}[$idx]${PLAIN} $NAME - ${YELLOW}$COUNT${PLAIN} 个节点"
            FOUND_REGEXS+=("$KEYWORDS")
            FOUND_NAMES+=("$NAME")
            ((idx++))
        fi
    done
    echo -e "----------------------------------------"
    echo -e "${GREEN}[0]${PLAIN} 保留所有节点 (默认)"
    echo -e ""
    echo -e "${YELLOW}请输入要保留的地区编号 (例如 1 3)，或输入 0 全选:${PLAIN}"
    read -p "选择: " USER_CHOICE
    if [[ -n "$USER_CHOICE" && "$USER_CHOICE" != "0" ]]; then
        REGEX_PARTS=()
        for i in $USER_CHOICE; do
            REAL_IDX=$((i-1))
            if [[ -n "${FOUND_REGEXS[$REAL_IDX]}" ]]; then REGEX_PARTS+=("(${FOUND_REGEXS[$REAL_IDX]})"); fi
        done
        FINAL_REGEX=$(IFS="|"; echo "${REGEX_PARTS[*]}")
    fi

    # 4. 安装 Sing-box
    echo -e "${GREEN}步骤 2/6: 安装程序...${PLAIN}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) singbox_arch="amd64" ;;
        aarch64) singbox_arch="arm64" ;;
        armv7l) singbox_arch="armv7" ;;
        *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; return ;;
    esac
    LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".assets[] | select(.name | contains(\"linux-$singbox_arch\") and contains(\".tar.gz\")) | .browser_download_url")
    wget -q -O sing-box.tar.gz "$LATEST_URL"
    tar -zxvf sing-box.tar.gz > /dev/null
    cd sing-box*linux* || exit
    mv sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    cd ..
    rm -rf sing-box*
    mkdir -p /etc/sing-box

    # 5. 安装 WebUI
    echo -e "${GREEN}步骤 3/6: 部署 WebUI...${PLAIN}"
    WEBUI_DIR="/etc/sing-box/ui"
    rm -rf "$WEBUI_DIR"
    mkdir -p "$WEBUI_DIR"
    wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
    unzip -q webui.zip
    mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
    rm -rf Yacd-meta-gh-pages webui.zip

    # 6. (修正顺序) 先创建 Systemd 服务
    echo -e "${GREEN}步骤 4/6: 注册系统服务...${PLAIN}"
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target nss-lookup.target
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

    # 7. 生成 Monitor 脚本
    echo -e "${GREEN}步骤 5/6: 配置 TUN 全局监控...${PLAIN}"
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
SUB_URL="$SUB_URL"
FILTER_REGEX="$FINAL_REGEX"
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
USE_CONVERSION=$USE_CONVERSION

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
urlencode() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$1"; }
check_proxy() {
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://www.google.com/generate_204)
    if [[ "\$http_code" == "204" ]]; then return 0; else return 1; fi
}
update_subscription() {
    echo "\$(timestamp) - 更新配置..." >> "\$LOG_FILE"
    systemctl stop sing-box
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
        if [[ -n "\$FILTER_REGEX" ]] && [[ -s /tmp/singbox_new.json ]]; then
             jq --arg re "\$FILTER_REGEX" '.outbounds |= map(select((.type | test("Selector|URLTest|Direct|Block"; "i")) or (.tag | test(\$re; "i"))))' /tmp/singbox_new.json > /tmp/singbox_filtered.json
             mv /tmp/singbox_filtered.json /tmp/singbox_new.json
        fi
    else
        ENCODED_URL=\$(urlencode "\$SUB_URL")
        INCLUDE_PARAM=""
        if [[ -n "\$FILTER_REGEX" ]]; then
            ENCODED_REGEX=\$(urlencode "\$FILTER_REGEX")
            INCLUDE_PARAM="&include=\${ENCODED_REGEX}"
        fi
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json\${INCLUDE_PARAM}"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
    TUN_CONFIG='{
      "log": { "level": "info", "timestamp": true },
      "dns": {
        "servers": [ { "tag": "remote-dns", "address": "8.8.8.8", "detour": "Proxy" }, { "tag": "local-dns", "address": "223.5.5.5", "detour": "direct" } ],
        "rules": [ { "outbound": "any", "server": "local-dns" }, { "clash_mode": "Global", "server": "remote-dns" }, { "clash_mode": "Direct", "server": "local-dns" }, { "rule_set": "geosite-cn", "server": "local-dns" } ],
        "strategy": "ipv4_only"
      },
      "inbounds": [
        { "type": "tun", "tag": "tun-in", "interface_name": "tun0", "inet4_address": "172.19.0.1/30", "auto_route": true, "strict_route": true, "stack": "system", "sniff": true },
        { "type": "mixed", "tag": "mixed-in", "listen": "::", "listen_port": 2080 }
      ],
      "route": { "auto_detect_interface": true, "rules": [ { "protocol": "dns", "outbound": "dns-out" }, { "clash_mode": "Direct", "outbound": "direct" }, { "clash_mode": "Global", "outbound": "Proxy" } ] },
      "experimental": {
        "cache_file": { "enabled": true, "path": "cache.db" },
        "clash_api": { "external_controller": "0.0.0.0:9090", "external_ui": "/etc/sing-box/ui", "secret": "", "default_mode": "Rule", "access_control_allow_origin": ["*"], "access_control_allow_private_network": true }
      }
    }'
    if [[ -s /tmp/singbox_new.json ]] && jq . /tmp/singbox_new.json >/dev/null 2>&1; then
        jq 'del(.dns, .inbounds, .route, .experimental, .log)' /tmp/singbox_new.json > /tmp/singbox_clean.json
        jq -s '.[0] * .[1]' /tmp/singbox_clean.json <(echo "\$TUN_CONFIG") > /tmp/singbox_merged.json
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' /tmp/singbox_merged.json > "\$CONFIG_FILE"; else mv /tmp/singbox_merged.json "\$CONFIG_FILE"; fi
        systemctl start sing-box
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

    # 8. 启动
    echo -e "${GREEN}步骤 6/6: 启动服务...${PLAIN}"
    bash "$MONITOR_SCRIPT" force
    
    echo -e ""
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ Sing-box 运行成功 (TUN 模式)${PLAIN}"
        echo -e "WebUI: http://$(curl -s4m5 ip.sb):9090/ui/"
        echo -e "测试 IP: $(curl -s --max-time 5 ip.sb)"
    else
        echo -e "${RED}❌ 启动失败，请检查配置。${PLAIN}"
    fi
}

# ==========================================
# 主菜单
# ==========================================
clear
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e "${BLUE}#                 Sing-box 全能管理脚本                     #${PLAIN}"
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e "1. ${GREEN}安装 / 更新${PLAIN} (TUN 全局代理模式)"
echo -e "2. ${RED}卸载${PLAIN} (彻底清理)"
echo -e "0. 退出"
echo -e ""
read -p "请输入选项 [0-2]: " choice

case $choice in
    1)
        install_singbox
        ;;
    2)
        uninstall_singbox
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}无效选项，脚本退出。${PLAIN}"
        exit 1
        ;;
esac
