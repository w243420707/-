#!/bin/bash

# ==========================================
# 变量定义
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# === 关键修复：在脚本最开始捕获命令行参数 ===
CLI_SUB_URL="$1"

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

# ==========================================
# 卸载函数
# ==========================================
uninstall_singbox() {
    echo -e "${YELLOW}停止服务...${PLAIN}"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    
    # 清理定时任务
    crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
    
    # 删除文件
    rm -f /usr/local/bin/sing-box
    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$LOG_FILE" "$PROXY_PROFILE"
    
    # 清理 Shell 环境
    sed -i '/singbox_proxy.sh/d' ~/.bashrc
    unset http_proxy https_proxy all_proxy
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ 卸载完成。${PLAIN}"
}

# ==========================================
# 安装函数
# ==========================================
install_singbox() {
    # 1. 环境准备
    echo -e "${GREEN}步骤 1/6: 初始化环境...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar unzip jq python3 cron >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar unzip jq python3 crontabs >/dev/null 2>&1
    fi

    # 2. 处理订阅链接 (优先使用命令行参数)
    if [[ -n "$CLI_SUB_URL" ]]; then
        SUB_URL="$CLI_SUB_URL"
        echo -e "${YELLOW}已检测到参数，自动使用订阅: ${SUB_URL}${PLAIN}"
    else
        echo -e "${YELLOW}请输入你的节点订阅链接:${PLAIN}"
        read -p "链接: " SUB_URL
    fi

    if [[ -z "$SUB_URL" ]]; then echo -e "${RED}链接为空！${PLAIN}"; return; fi
    
    FINAL_REGEX=""
    USE_CONVERSION=true 

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
    fi

    # 3. 国家筛选逻辑 (加回)
    NODE_TAGS=$(jq -r '.outbounds[] | select(.type | test("Selector|URLTest|Direct|Block") | not) | .tag' /tmp/singbox_pre.json)
    REGION_DATA=(
"阿富汗 (AF)|🇦🇫|AF|Afghanistan|阿富汗" "阿尔巴尼亚 (AL)|🇦🇱|AL|Albania|阿尔巴尼亚" "阿尔及利亚 (AG)|🇩🇿|AG|Algeria|阿尔及利亚" "安道尔 (AN)|🇦🇩|AN|Andorra|安道尔" "安哥拉 (AO)|🇦🇴|AO|Angola|安哥拉" "阿根廷 (AR)|🇦🇷|AR|Argentina|阿根廷" "澳大利亚 (AS)|🇦🇺|AS|Australia|澳大利亚" "奥地利 (AU)|🇦🇹|AU|Austria|奥地利" "阿塞拜疆 (AJ)|🇦🇿|AJ|Azerbaijan|阿塞拜疆" "巴哈马 (BF)|🇧🇸|BF|Bahamas|巴哈马" "巴林 (BA)|🇧🇭|BA|Bahrain|巴林" "孟加拉国 (BG)|🇧🇩|BG|Bangladesh|孟加拉" "白俄罗斯 (BO)|🇧🇾|BO|Belarus|白俄罗斯" "比利时 (BE)|🇧🇪|BE|Belgium|比利时" "伯利兹 (BH)|🇧🇿|BH|Belize|伯利兹" "玻利维亚 (BL)|🇧🇴|BL|Bolivia|玻利维亚" "波黑 (BK)|🇧🇦|BK|Bosnia|波黑" "巴西 (BR)|🇧🇷|BR|Brazil|巴西" "文莱 (BX)|🇧🇳|BX|Brunei|文莱" "保加利亚 (BU)|🇧🇬|BU|Bulgaria|保加利亚" "柬埔寨 (CB)|🇰🇭|CB|Cambodia|柬埔寨" "加拿大 (CA)|🇨🇦|CA|Canada|加拿大" "智利 (CI)|🇨🇱|CI|Chile|智利" "中国 (CN)|🇨🇳|CN|China|中国|回国" "哥伦比亚 (CO)|🇨🇴|CO|Colombia|哥伦比亚" "刚果 (CG)|🇨🇬|CG|Congo|刚果" "哥斯达黎加 (CS)|🇨🇷|CS|Costa Rica|哥斯达黎加" "克罗地亚 (HR)|🇭🇷|HR|Croatia|克罗地亚" "古巴 (CU)|🇨🇺|CU|Cuba|古巴" "塞浦路斯 (CY)|🇨🇾|CY|Cyprus|塞浦路斯" "捷克 (EZ)|🇨🇿|EZ|Czech|捷克" "丹麦 (DA)|🇩🇰|DA|Denmark|丹麦" "厄瓜多尔 (EC)|🇪🇨|EC|Ecuador|厄瓜多尔" "埃及 (EG)|🇪🇬|EG|Egypt|埃及" "爱沙尼亚 (EN)|🇪🇪|EN|Estonia|爱沙尼亚" "芬兰 (FI)|🇫🇮|FI|Finland|芬兰" "法国 (FR)|🇫🇷|FR|France|法国" "格鲁吉亚 (GG)|🇬🇪|GG|Georgia|格鲁吉亚" "德国 (DE)|🇩🇪|DE|Germany|德国" "加纳 (GH)|🇬🇭|GH|Ghana|加纳" "希腊 (GR)|🇬🇷|GR|Greece|希腊" "危地马拉 (GT)|🇬🇹|GT|Guatemala|危地马拉" "海地 (HA)|🇭🇹|HA|Haiti|海地" "洪都拉斯 (HO)|🇭🇳|HO|Honduras|洪都拉斯" "香港 (HK)|🇭🇰|HK|Hong Kong|HongKong|香港" "匈牙利 (HU)|🇭🇺|HU|Hungary|匈牙利" "冰岛 (IC)|🇮🇸|IC|Iceland|冰岛" "印度 (IN)|🇮🇳|IN|India|印度" "印度尼西亚 (ID)|🇮🇩|ID|Indonesia|印尼|印度尼西亚" "伊朗 (IR)|🇮🇷|IR|Iran|伊朗" "伊拉克 (IZ)|🇮🇶|IZ|Iraq|伊拉克" "爱尔兰 (EI)|🇮🇪|EI|Ireland|爱尔兰" "以色列 (IS)|🇮🇱|IS|Israel|以色列" "意大利 (IT)|🇮🇹|IT|Italy|意大利" "牙买加 (JM)|🇯🇲|JM|Jamaica|牙买加" "日本 (JP)|🇯🇵|JP|Japan|日本" "约旦 (JO)|🇯🇴|JO|Jordan|约旦" "哈萨克斯坦 (KZ)|🇰🇿|KZ|Kazakhstan|哈萨克斯坦" "肯尼亚 (KE)|🇰🇪|KE|Kenya|肯尼亚" "韩国 (KR)|🇰🇷|KR|South Korea|Korea|韩国" "科威特 (KU)|🇰🇼|KU|Kuwait|科威特" "吉尔吉斯斯坦 (KG)|🇰🇬|KG|Kyrgyzstan|吉尔吉斯" "老挝 (LA)|🇱🇦|LA|Laos|老挝" "拉脱维亚 (LG)|🇱🇻|LG|Latvia|拉脱维亚" "黎巴嫩 (LE)|🇱🇧|LE|Lebanon|黎巴嫩" "立陶宛 (LH)|🇱🇹|LH|Lithuania|立陶宛" "卢森堡 (LU)|🇱🇺|LU|Luxembourg|卢森堡" "澳门 (MC)|🇲🇴|MC|Macao|Macau|澳门" "北马其顿 (MK)|🇲🇰|MK|Macedonia|北马其顿" "马来西亚 (MY)|🇲🇾|MY|Malaysia|马来西亚" "马耳他 (MT)|🇲🇹|MT|Malta|马耳他" "墨西哥 (MX)|🇲🇽|MX|Mexico|墨西哥" "摩尔多瓦 (MD)|🇲🇩|MD|Moldova|摩尔多瓦" "摩纳哥 (MN)|🇲🇨|MN|Monaco|摩纳哥" "蒙古 (MG)|🇲🇳|MG|Mongolia|蒙古" "黑山 (MJ)|🇲🇪|MJ|Montenegro|黑山" "摩洛哥 (MO)|🇲🇦|MO|Morocco|摩洛哥" "尼泊尔 (NP)|🇳🇵|NP|Nepal|尼泊尔" "荷兰 (NL)|🇳🇱|NL|Netherlands|Holland|荷兰" "新西兰 (NZ)|🇳🇿|NZ|New Zealand|新西兰" "尼日利亚 (NI)|🇳🇬|NI|Nigeria|尼日利亚" "挪威 (NO)|🇳🇴|NO|Norway|挪威" "阿曼 (MU)|🇴🇲|MU|Oman|阿曼" "巴基斯坦 (PK)|🇵🇰|PK|Pakistan|巴基斯坦" "巴拿马 (PM)|🇵🇦|PM|Panama|巴拿马" "巴拉圭 (PA)|🇵🇾|PA|Paraguay|巴拉圭" "秘鲁 (PE)|🇵🇪|PE|Peru|秘鲁" "菲律宾 (RP)|🇵🇭|RP|Philippines|菲律宾" "波兰 (PL)|🇵🇱|PL|Poland|波兰" "葡萄牙 (PO)|🇵🇹|PO|Portugal|葡萄牙" "卡塔尔 (QA)|🇶🇦|QA|Qatar|卡塔尔" "罗马尼亚 (RO)|🇷🇴|RO|Romania|罗马尼亚" "台湾 (TW)|🇹🇼|TW|Taiwan|TaiWan|台湾" "俄罗斯 (RS)|🇷🇺|RS|Russia|俄罗斯" "沙特阿拉伯 (SA)|🇸🇦|SA|Saudi Arabia|沙特" "塞尔维亚 (RI)|🇷🇸|RI|Serbia|塞尔维亚" "新加坡 (SG)|🇸🇬|SG|Singapore|新加坡" "斯洛伐克 (LO)|🇸🇰|LO|Slovakia|斯洛伐克" "斯洛文尼亚 (SI)|🇸🇮|SI|Slovenia|斯洛文尼亚" "南非 (SF)|🇿🇦|SF|South Africa|南非" "西班牙 (SP)|🇪🇸|SP|Spain|西班牙" "斯里兰卡 (CE)|🇱🇰|CE|Sri Lanka|斯里兰卡" "瑞典 (SW)|🇸🇪|SW|Sweden|瑞典" "瑞士 (SZ)|🇨🇭|SZ|Switzerland|瑞士" "叙利亚 (SY)|🇸🇾|SY|Syria|叙利亚" "塔吉克斯坦 (TI)|🇹🇯|TI|Tajikistan|塔吉克斯坦" "泰国 (TH)|🇹🇭|TH|Thailand|泰国" "突尼斯 (TS)|🇹🇳|TS|Tunisia|突尼斯" "土耳其 (TU)|🇹🇷|TU|Turkey|土耳其" "土库曼斯坦 (TX)|🇹🇲|TX|Turkmenistan|土库曼斯坦" "乌克兰 (UP)|🇺🇦|UP|Ukraine|乌克兰" "阿联酋 (AE)|🇦🇪|AE|United Arab Emirates|UAE|阿联酋" "英国 (UK)|🇬🇧|UK|United Kingdom|Britain|英国" "美国 (US)|🇺🇸|US|United States|USA|America|美国" "乌拉圭 (UY)|🇺🇾|UY|Uruguay|乌拉圭" "乌兹别克斯坦 (UZ)|🇺🇿|UZ|Uzbekistan|乌兹别克斯坦" "委内瑞拉 (VE)|🇻🇪|VE|Venezuela|委内瑞拉" "越南 (VM)|🇻🇳|VM|Vietnam|越南"
    )
    FOUND_REGEXS=()
    echo -e "----------------------------------------"
    echo -e "${GREEN}检测到以下地区的节点：${PLAIN}"
    idx=1
    for item in "${REGION_DATA[@]}"; do
        NAME="${item%%|*}"
        KEYWORDS="${item#*|}"
        if echo "$NODE_TAGS" | grep -Eqi "$KEYWORDS"; then
            COUNT=$(echo "$NODE_TAGS" | grep -Ei "$KEYWORDS" | wc -l)
            echo -e "${GREEN}[$idx]${PLAIN} $NAME - ${YELLOW}$COUNT${PLAIN} 个节点"
            FOUND_REGEXS+=("$KEYWORDS")
            ((idx++))
        fi
    done
    echo -e "----------------------------------------"
    echo -e "${GREEN}[0]${PLAIN} 保留所有节点 (默认)"
    echo -e ""
    read -p "选择: " USER_CHOICE
    if [[ -n "$USER_CHOICE" && "$USER_CHOICE" != "0" ]]; then
        REGEX_PARTS=()
        for i in $USER_CHOICE; do
            REAL_IDX=$((i-1))
            if [[ -n "${FOUND_REGEXS[$REAL_IDX]}" ]]; then REGEX_PARTS+=("(${FOUND_REGEXS[$REAL_IDX]})"); fi
        done
        FINAL_REGEX=$(IFS="|"; echo "${REGEX_PARTS[*]}")
    fi

    # 4. 安装程序
    echo -e "${GREEN}步骤 3/6: 安装 Sing-box...${PLAIN}"
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

    # 5. WebUI
    WEBUI_DIR="/etc/sing-box/ui"
    mkdir -p "$WEBUI_DIR"
    wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
    unzip -q webui.zip
    mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
    rm -rf Yacd-meta-gh-pages webui.zip

    # 6. 注册服务 (无 Capability，兼容性最高)
    echo -e "${GREEN}步骤 4/6: 注册服务...${PLAIN}"
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

    # 7. 生成监控脚本 (兼容版)
    echo -e "${GREEN}步骤 5/6: 配置代理脚本...${PLAIN}"
    cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
SUB_URL="$SUB_URL"
FILTER_REGEX="$FINAL_REGEX"
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
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --proxy http://127.0.0.1:$PROXY_PORT https://www.google.com/generate_204)
    if [[ "\$http_code" == "204" ]]; then return 0; else return 1; fi
}

update_subscription() {
    systemctl stop sing-box
    rm -f "\$PROXY_PROFILE"
    unset http_proxy https_proxy all_proxy
    
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
        if [[ -n "\$FILTER_REGEX" ]] && [[ -s /tmp/singbox_new.json ]]; then
             jq --arg re "\$FILTER_REGEX" '.outbounds |= map(select((.type | test("Selector|URLTest|Direct|Block"; "i")) or (.tag | test(\$re; "i"))))' /tmp/singbox_new.json > /tmp/singbox_filtered.json
             mv /tmp/singbox_filtered.json /tmp/singbox_new.json
        fi
    else
        ENCODED_URL=\$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$SUB_URL")
        INCLUDE_PARAM=""
        if [[ -n "\$FILTER_REGEX" ]]; then
            ENCODED_REGEX=\$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$FILTER_REGEX")
            INCLUDE_PARAM="&include=\${ENCODED_REGEX}"
        fi
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json\${INCLUDE_PARAM}"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
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
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then jq --arg auto_tag "\$AUTO_TAG" '((.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // (.outbounds[] | select(.type=="selector").default)) = \$auto_tag' /tmp/singbox_merged.json > "\$CONFIG_FILE"; else mv /tmp/singbox_merged.json "\$CONFIG_FILE"; fi
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

    echo -e "${GREEN}步骤 6/6: 启动并应用环境...${PLAIN}"
    bash "$MONITOR_SCRIPT" force
    
    echo -e ""
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ 服务已启动 (兼容模式)${PLAIN}"
        echo -e "${YELLOW}>>> 正在刷新 Shell 环境... <<<${PLAIN}"
        sleep 2
        exec bash -l
    else
        echo -e "${RED}❌ 启动失败。${PLAIN}"
    fi
}

# 菜单
clear
echo -e "${BLUE}Sing-box 兼容模式脚本${PLAIN}"
echo -e "1. ${GREEN}安装 / 更新${PLAIN}"
echo -e "2. ${RED}卸载${PLAIN}"
echo -e "0. 退出"
read -p "选择: " choice
case $choice in
    1) install_singbox ;;
    2) uninstall_singbox ;;
    0) exit 0 ;;
    *) exit 1 ;;
esac
