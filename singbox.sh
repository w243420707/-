#!/bin/bash

# =================================================================
# Sing-box 修复版 (解决 Argument list too long 问题)
# 核心修复：使用文件传递 JSON 数据，而非命令行参数
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. 命令行参数解析
SUB_URL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sub)
            SUB_URL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 权限运行${NC}"; exit 1; fi

echo -e "${BLUE}>>> [1/7] 检查依赖...${NC}"
if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q curl jq tar
elif command -v yum >/dev/null; then yum install -y -q curl jq tar
elif command -v apk >/dev/null; then apk add -q curl jq tar
else echo -e "${RED}未知系统${NC}"; exit 1; fi

echo -e "${BLUE}>>> [2/7] 识别架构...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    armv7l) SING_ARCH="armv7" ;;
    *) echo -e "${RED}不支持: $ARCH${NC}"; exit 1 ;;
esac

echo -e "${BLUE}>>> [3/7] 安装 Sing-box...${NC}"
API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r ".assets[] | select(.name | contains(\"linux-$SING_ARCH\")) | select(.name | contains(\".tar.gz\")) | .browser_download_url" | head -n 1)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-$SING_ARCH.tar.gz"
fi
curl -L -s -o sing-box.tar.gz "$DOWNLOAD_URL"
tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
systemctl stop sing-box 2>/dev/null
cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

echo -e "${BLUE}>>> [4/7] 下载订阅配置...${NC}"
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ -z "$SUB_URL" ]; then read -p "请输入订阅链接: " SUB_URL; fi
if [ -z "$SUB_URL" ]; then echo -e "${RED}链接为空${NC}"; exit 1; fi

echo -e "正在下载配置..."
curl -L -s -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}无效的 JSON 配置${NC}"; exit 1; fi

echo -e "${BLUE}>>> [5/7] 正在扫描全量节点库...${NC}"
# 提取所有 Tag 到临时文件，避免变量过长
jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE" > /tmp/singbox_tags.txt
TOTAL_NODES_COUNT=$(wc -l < /tmp/singbox_tags.txt)

if [ "$TOTAL_NODES_COUNT" -eq 0 ]; then echo -e "${RED}未找到有效节点${NC}"; exit 1; fi

REGIONS_DB=(
"中华人民共和国|CH|🇨🇳|China" "香港|HK|🇭🇰|Hong Kong" "台湾|TW|🇹🇼|Taiwan" "澳门|MC|🇲🇴|Macau" "日本|JA|🇯🇵|Japan|JP" "韩国|KS|🇰🇷|Korea|KR" "新加坡|SN|🇸🇬|Singapore|SG" "美国|US|🇺🇸|United States|USA" "英国|UK|🇬🇧|United Kingdom|Britain" "德国|GM|🇩🇪|Germany|DE" "法国|FR|🇫🇷|France" "俄罗斯|RS|🇷🇺|Russia|RU" "加拿大|CA|🇨🇦|Canada" "澳大利亚|AS|🇦🇺|Australia|AU" "印度|IN|🇮🇳|India" "巴西|BR|🇧🇷|Brazil" "阿根廷|AR|🇦🇷|Argentina" "土耳其|TU|🇹🇷|Turkey" "荷兰|NL|🇳🇱|Netherlands" "意大利|IT|🇮🇹|Italy" "西班牙|SP|🇪🇸|Spain" "瑞士|SZ|🇨🇭|Switzerland" "瑞典|SW|🇸🇪|Sweden" "挪威|NO|🇳🇴|Norway" "芬兰|FI|🇫🇮|Finland" "丹麦|DA|🇩🇰|Denmark" "波兰|PL|🇵🇱|Poland" "乌克兰|UP|🇺🇦|Ukraine" "以色列|IS|🇮🇱|Israel" "阿联酋|AE|🇦🇪|UAE" "沙特阿拉伯|SA|🇸🇦|Saudi Arabia" "南非|SF|🇿🇦|South Africa" "埃及|EG|🇪🇬|Egypt" "泰国|TH|🇹🇭|Thailand" "越南|VM|🇻🇳|Vietnam" "印度尼西亚|ID|🇮🇩|Indonesia" "菲律宾|RP|🇵🇭|Philippines" "马来西亚|MY|🇲🇾|Malaysia" "柬埔寨|CB|🇰🇭|Cambodia" "老挝|LA|🇱🇦|Laos" "缅甸|BM|🇲🇲|Myanmar" "巴基斯坦|PK|🇵🇰|Pakistan" "伊朗|IR|🇮🇷|Iran" "伊拉克|IZ|🇮🇶|Iraq" "阿富汗|AF|🇦🇫|Afghanistan" "蒙古国|MG|🇲🇳|Mongolia" "朝鲜|KN|🇰🇵|North Korea" "新西兰|NZ|🇳🇿|New Zealand" "爱尔兰|EI|🇮🇪|Ireland" "奥地利|AU|🇦🇹|Austria" "比利时|BE|🇧🇪|Belgium" "捷克|EZ|🇨🇿|Czech" "匈牙利|HU|🇭🇺|Hungary" "罗马尼亚|RO|🇷🇴|Romania" "保加利亚|BU|🇧🇬|Bulgaria" "希腊|GR|🇬🇷|Greece" "葡萄牙|PO|🇵🇹|Portugal" "塞尔维亚|RI|🇷🇸|Serbia" "克罗地亚|HR|🇭🇷|Croatia" "斯洛伐克|LO|🇸🇰|Slovakia" "斯洛文尼亚|SI|🇸🇮|Slovenia" "冰岛|IC|🇮🇸|Iceland" "爱沙尼亚|EN|🇪🇪|Estonia" "拉脱维亚|LG|🇱🇻|Latvia" "立陶宛|LH|🇱🇹|Lithuania" "白俄罗斯|BO|🇧🇾|Belarus" "哈萨克斯坦|KZ|🇰🇿|Kazakhstan" "乌兹别克斯坦|UZ|🇺🇿|Uzbekistan" "吉尔吉斯斯坦|KG|🇰🇬|Kyrgyzstan" "塔吉克斯坦|TI|🇹🇯|Tajikistan" "土库曼斯坦|TX|🇹🇲|Turkmenistan" "格鲁吉亚|GG|🇬🇪|Georgia" "阿塞拜疆|AJ|🇦🇿|Azerbaijan" "亚美尼亚|AM|🇦🇲|Armenia" "墨西哥|MX|🇲🇽|Mexico" "智利|CI|🇨🇱|Chile" "哥伦比亚|CO|🇨🇴|Colombia" "秘鲁|PE|🇵🇪|Peru" "委内瑞拉|VE|🇻🇪|Venezuela" "古巴|CU|🇨🇺|Cuba" "尼日利亚|NI|🇳🇬|Nigeria" "肯尼亚|KE|🇰🇪|Kenya" "摩洛哥|MO|🇲🇦|Morocco" "阿尔及利亚|AG|🇩🇿|Algeria" "突尼斯|TS|🇹🇳|Tunisia" "利比亚|LY|🇱🇾|Libya" "卡塔尔|QA|🇶🇦|Qatar" "科威特|KU|🇰🇼|Kuwait" "阿曼|MU|🇴🇲|Oman" "也门|YM|🇾🇪|Yemen" "约旦|JO|🇯🇴|Jordan" "黎巴嫩|LE|🇱🇧|Lebanon" "叙利亚|SY|🇸🇾|Syria" "巴勒斯坦|GZ|🇵🇸|Palestine" "塞浦路斯|CY|🇨🇾|Cyprus" "马耳他|MT|🇲🇹|Malta" "卢森堡|LU|🇱🇺|Luxembourg" "摩纳哥|MN|🇲🇨|Monaco" "梵蒂冈|VT|🇻🇦|Vatican" "安道尔|AN|🇦🇩|Andorra" "圣马力诺|SM|🇸🇲|San Marino" "列支敦士登|LS|🇱🇮|Liechtenstein" "摩尔多瓦|MD|🇲🇩|Moldova" "波黑|BK|🇧🇦|Bosnia" "黑山|MJ|🇲🇪|Montenegro" "北马其顿|MK|🇲🇰|North Macedonia" "阿尔巴尼亚|AL|🇦🇱|Albania" "科索沃|KV|🇽🇰|Kosovo" "不丹|BT|🇧🇹|Bhutan" "尼泊尔|NP|🇳🇵|Nepal" "孟加拉国|BG|🇧🇩|Bangladesh" "斯里兰卡|CE|🇱🇰|Sri Lanka" "马尔代夫|MV|🇲🇻|Maldives" "文莱|BX|🇧🇳|Brunei" "东帝汶|TT|🇹🇱|East Timor" "巴布亚新几内亚|PP|🇵🇬|Papua New Guinea" "斐济|FJ|🇫🇯|Fiji" "所罗门群岛|BP|🇸🇧|Solomon" "瓦努阿图|NH|🇻🇺|Vanuatu" "萨摩亚|WS|🇼🇸|Samoa" "汤加|TN|🇹🇴|Tonga" "图瓦卢|TV|🇹🇻|Tuvalu" "基里巴斯|KR|🇰🇮|Kiribati" "瑙鲁|NR|🇳🇷|Nauru" "帕劳|PS|🇵🇼|Palau" "密克罗尼西亚|FM|🇫🇲|Micronesia" "马绍尔群岛|RM|🇲🇭|Marshall" "牙买加|JM|🇯🇲|Jamaica" "海地|HA|🇭🇹|Haiti" "多米尼加|DR|🇩🇴|Dominican" "巴哈马|BF|🇧🇸|Bahamas" "巴巴多斯|BB|🇧🇧|Barbados" "特立尼达和多巴哥|TD|🇹🇹|Trinidad" "哥斯达黎加|CS|🇨🇷|Costa Rica" "巴拿马|PM|🇵🇦|Panama" "危地马拉|GT|🇬🇹|Guatemala" "洪都拉斯|HO|🇭🇳|Honduras" "萨尔瓦多|ES|🇸🇻|El Salvador" "尼加拉瓜|NU|🇳🇮|Nicaragua" "伯利兹|BH|🇧🇿|Belize" "厄瓜多尔|EC|🇪🇨|Ecuador" "玻利维亚|BL|🇧🇴|Bolivia" "巴拉圭|PA|🇵🇾|Paraguay" "乌拉圭|UY|🇺🇾|Uruguay" "圭亚那|GY|🇬🇾|Guyana" "苏里南|NS|🇸🇷|Suriname" "埃塞俄比亚|ET|🇪🇹|Ethiopia" "坦桑尼亚|TZ|🇹🇿|Tanzania" "乌干达|UG|🇺🇬|Uganda" "卢旺达|RW|🇷🇼|Rwanda" "布隆迪|BY|🇧🇮|Burundi" "苏丹|SU|🇸🇩|Sudan" "南苏丹|OD|🇸🇸|South Sudan" "吉布提|DJ|🇩🇯|Djibouti" "索马里|SO|🇸🇴|Somalia" "厄立特里亚|ER|🇪🇷|Eritrea" "马达加斯加|MA|🇲🇬|Madagascar" "毛里求斯|MP|🇲🇺|Mauritius" "塞舌尔|SE|🇸🇨|Seychelles" "科摩罗|CN|🇰🇲|Comoros" "莫桑比克|MZ|🇲🇿|Mozambique" "津巴布韦|ZI|🇿🇼|Zimbabwe" "赞比亚|ZA|🇿🇲|Zambia" "马拉维|MI|🇲🇼|Malawi" "博茨瓦纳|BC|🇧🇼|Botswana" "纳米比亚|WA|🇳🇦|Namibia" "安哥拉|AO|🇦🇴|Angola" "刚果民主共和国|CG|🇨🇩|Congo" "刚果共和国|CF|🇨🇬|Congo" "加蓬|GB|🇬🇦|Gabon" "赤道几内亚|EK|🇬🇶|Equatorial Guinea" "喀麦隆|CM|🇨🇲|Cameroon" "乍得|CD|🇹🇩|Chad" "中非|CT|🇨🇫|Central African" "加纳|GH|🇬🇭|Ghana" "科特迪瓦|IV|🇨🇮|Cote dIvoire" "利比里亚|LI|🇱🇷|Liberia" "塞拉利昂|SL|🇸🇱|Sierra Leone" "几内亚|GV|🇬🇳|Guinea" "几内亚比绍|PU|🇬🇼|Guinea-Bissau" "塞内加尔|SG|🇸🇳|Senegal" "冈比亚|GA|🇬🇲|Gambia" "马里|ML|🇲🇱|Mali" "布基纳法索|UV|🇧🇫|Burkina Faso" "尼日尔|NG|🇳🇪|Niger" "贝宁|BN|🇧🇯|Benin" "多哥|TO|🇹🇬|Togo" "毛里塔尼亚|MR|🇲🇷|Mauritania" "西撒哈拉|WI|🇪🇭|Western Sahara"
)

declare -A REGION_COUNTS
declare -A REGION_REGEX
AVAILABLE_REGIONS=()

# 1. 全球选项
AVAILABLE_REGIONS+=("全球自动选择 (Global Auto)")
REGION_COUNTS["全球自动选择 (Global Auto)"]=$TOTAL_NODES_COUNT
REGION_REGEX["全球自动选择 (Global Auto)"]=".*"

echo -e "${BLUE}>>> 正在分析地区分布...${NC}"

# 使用 grep 统计，不加载到变量
for item in "${REGIONS_DB[@]}"; do
    IFS='|' read -r CN_NAME CODE EMOJI EN_KEY <<< "$item"
    if [ -n "$EN_KEY" ]; then MATCH_STR="($CN_NAME|$CODE|$EMOJI|$EN_KEY)"; else MATCH_STR="($CN_NAME|$CODE|$EMOJI)"; fi
    
    # 修复：从临时文件读取，避免 Argument list too long
    COUNT=$(grep -E -i "$MATCH_STR" /tmp/singbox_tags.txt | wc -l)
    
    if [ "$COUNT" -gt 0 ]; then
        DISPLAY_NAME="$EMOJI $CN_NAME ($CODE)"
        REGION_COUNTS["$DISPLAY_NAME"]=$COUNT
        REGION_REGEX["$DISPLAY_NAME"]="$MATCH_STR"
        AVAILABLE_REGIONS+=("$DISPLAY_NAME")
    fi
done

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}      检测到以下地区节点 (Total: $TOTAL_NODES_COUNT)${NC}"
echo -e "${GREEN}==============================================${NC}"

i=0
for region in "${AVAILABLE_REGIONS[@]}"; do
    printf " [%-2d] %-35s - %d 个节点\n" $i "$region" "${REGION_COUNTS[$region]}"
    ((i++))
done

echo -e "${YELLOW}------------------------------------------------${NC}"
read -p "选择: " SELECT_INDEX

if [[ "$SELECT_INDEX" =~ ^[0-9]+$ ]] && [ "$SELECT_INDEX" -lt "${#AVAILABLE_REGIONS[@]}" ]; then
    SELECTED_REGION_NAME="${AVAILABLE_REGIONS[$SELECT_INDEX]}"
    MATCH_KEY="${REGION_REGEX[$SELECTED_REGION_NAME]}"
    
    echo -e "${GREEN}你选择了: $SELECTED_REGION_NAME${NC}"
    echo -e "${BLUE}正在重构配置...${NC}"

    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

    # 关键修复：
    # 1. 使用 --slurpfile 读取原始 outbounds，避免命令行传递过大 JSON
    # 2. 在 jq 内部进行 filter，而不是在 bash 中处理
    
    jq -n \
        --slurpfile original_config "$CONFIG_FILE.bak" \
        --arg match_key "$MATCH_KEY" \
        '{
            "log": { "level": "info", "timestamp": true },
            "dns": {
                "servers": [
                    { "tag": "cloudflare-doh", "address": "https://1.1.1.1/dns-query", "detour": "direct" },
                    { "tag": "local", "address": "local", "detour": "direct" }
                ],
                "rules": [
                    { "outbound": "any", "server": "cloudflare-doh" }
                ]
            },
            "inbounds": [
                {
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": "0.0.0.0",
                    "listen_port": 2080,
                    "sniff": true
                }
            ],
            "outbounds": (
                # 从原始配置中提取并过滤
                ($original_config[0].outbounds | map(select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest" and (.tag | test($match_key; "i"))))) as $selected_tags |
                [
                    {
                        "type": "urltest",
                        "tag": "AUTO-SELECT-GROUP",
                        "outbounds": ($selected_tags | map(.tag)),
                        "url": "https://www.gstatic.com/generate_204",
                        "interval": "30s",
                        "tolerance": 50
                    },
                    { "type": "direct", "tag": "direct" },
                    { "type": "block", "tag": "block" }
                ] + $selected_tags + ($original_config[0].outbounds | map(select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block")))
            ),
            "route": {
                "rules": [
                    { "protocol": "dns", "outbound": "dns-out" },
                    { "inbound": "mixed-in", "action": "route", "outbound": "AUTO-SELECT-GROUP" }
                ],
                "auto_detect_interface": true
            }
        }' > "$CONFIG_FILE"
        
    echo -e "${GREEN}配置生成完毕！${NC}"

else
    echo -e "${RED}无效选择${NC}"; exit 1
fi

echo -e "${BLUE}>>> [7/7] 启动 Sing-box...${NC}"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

sleep 3

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}启动成功！${NC}"
    echo -e "监听端口: ${YELLOW}2080${NC}"
    echo -e "测试命令: curl -m 10 ipinfo.io"
else
    echo -e "${RED}启动失败${NC}"; journalctl -u sing-box -n 20 --no-pager
fi
