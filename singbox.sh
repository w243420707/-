#!/bin/bash

# =================================================================
# Sing-box 终极完整版 (Ultimate Fix)
# 1. 完整国家库 (200+地区)
# 2. 修复 Argument list too long (使用文件处理)
# 3. 修复 Duplicate Tag (彻底去重逻辑)
# 4. 修复 DNS (强制 DoH)
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
        --sub) SUB_URL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 权限运行${NC}"; exit 1; fi

# 2. 依赖检查
echo -e "${BLUE}>>> [1/7] 检查依赖...${NC}"
for pkg in curl jq tar; do
    if ! command -v $pkg >/dev/null; then
        if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q $pkg
        elif command -v yum >/dev/null; then yum install -y -q $pkg
        elif command -v apk >/dev/null; then apk add -q $pkg
        else echo -e "${RED}请手动安装: curl jq tar${NC}"; exit 1; fi
    fi
done

# 3. 安装 Sing-box
echo -e "${BLUE}>>> [2/7] 安装 Sing-box...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    *) echo -e "${RED}不支持: $ARCH${NC}"; exit 1 ;;
esac

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

# 4. 下载订阅
echo -e "${BLUE}>>> [3/7] 下载配置...${NC}"
mkdir -p /etc/sing-box
CONFIG_FILE="/etc/sing-box/config.json"

if [ -z "$SUB_URL" ]; then read -p "请输入订阅链接: " SUB_URL; fi
if [ -z "$SUB_URL" ]; then echo -e "${RED}链接为空${NC}"; exit 1; fi

echo -e "正在下载..."
curl -L -s -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}无效的 JSON 订阅${NC}"; exit 1; fi

# 5. 扫描节点 (使用文件缓存避免参数过长)
echo -e "${BLUE}>>> [4/7] 扫描节点库...${NC}"
jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE" > /tmp/singbox_tags.txt
TOTAL_COUNT=$(wc -l < /tmp/singbox_tags.txt)

if [ "$TOTAL_COUNT" -eq 0 ]; then echo -e "${RED}未找到可用节点${NC}"; exit 1; fi

# ================= 完整国家数据库 (无阉割) =================
REGIONS_DB=(
"中华人民共和国|CH|🇨🇳|China" "香港|HK|🇭🇰|Hong Kong" "台湾|TW|🇹🇼|Taiwan" "澳门|MC|🇲🇴|Macau" "日本|JA|🇯🇵|Japan|JP" "韩国|KS|🇰🇷|Korea|KR" "新加坡|SN|🇸🇬|Singapore|SG" "美国|US|🇺🇸|United States|USA" "英国|UK|🇬🇧|United Kingdom|Britain" "德国|GM|🇩🇪|Germany|DE" "法国|FR|🇫🇷|France" "俄罗斯|RS|🇷🇺|Russia|RU" "加拿大|CA|🇨🇦|Canada" "澳大利亚|AS|🇦🇺|Australia|AU" "印度|IN|🇮🇳|India" "巴西|BR|🇧🇷|Brazil" "阿根廷|AR|🇦🇷|Argentina" "土耳其|TU|🇹🇷|Turkey" "荷兰|NL|🇳🇱|Netherlands" "意大利|IT|🇮🇹|Italy" "西班牙|SP|🇪🇸|Spain" "瑞士|SZ|🇨🇭|Switzerland" "瑞典|SW|🇸🇪|Sweden" "挪威|NO|🇳🇴|Norway" "芬兰|FI|🇫🇮|Finland" "丹麦|DA|🇩🇰|Denmark" "波兰|PL|🇵🇱|Poland" "乌克兰|UP|🇺🇦|Ukraine" "以色列|IS|🇮🇱|Israel" "阿联酋|AE|🇦🇪|UAE" "沙特阿拉伯|SA|🇸🇦|Saudi Arabia" "南非|SF|🇿🇦|South Africa" "埃及|EG|🇪🇬|Egypt" "泰国|TH|🇹🇭|Thailand" "越南|VM|🇻🇳|Vietnam" "印度尼西亚|ID|🇮🇩|Indonesia" "菲律宾|RP|🇵🇭|Philippines" "马来西亚|MY|🇲🇾|Malaysia" "柬埔寨|CB|🇰🇭|Cambodia" "老挝|LA|🇱🇦|Laos" "缅甸|BM|🇲🇲|Myanmar" "巴基斯坦|PK|🇵🇰|Pakistan" "伊朗|IR|🇮🇷|Iran" "伊拉克|IZ|🇮🇶|Iraq" "阿富汗|AF|🇦🇫|Afghanistan" "蒙古国|MG|🇲🇳|Mongolia" "朝鲜|KN|🇰🇵|North Korea" "新西兰|NZ|🇳🇿|New Zealand" "爱尔兰|EI|🇮🇪|Ireland" "奥地利|AU|🇦🇹|Austria" "比利时|BE|🇧🇪|Belgium" "捷克|EZ|🇨🇿|Czech" "匈牙利|HU|🇭🇺|Hungary" "罗马尼亚|RO|🇷🇴|Romania" "保加利亚|BU|🇧🇬|Bulgaria" "希腊|GR|🇬🇷|Greece" "葡萄牙|PO|🇵🇹|Portugal" "塞尔维亚|RI|🇷🇸|Serbia" "克罗地亚|HR|🇭🇷|Croatia" "斯洛伐克|LO|🇸🇰|Slovakia" "斯洛文尼亚|SI|🇸🇮|Slovenia" "冰岛|IC|🇮🇸|Iceland" "爱沙尼亚|EN|🇪🇪|Estonia" "拉脱维亚|LG|🇱🇻|Latvia" "立陶宛|LH|🇱🇹|Lithuania" "白俄罗斯|BO|🇧🇾|Belarus" "哈萨克斯坦|KZ|🇰🇿|Kazakhstan" "乌兹别克斯坦|UZ|🇺🇿|Uzbekistan" "吉尔吉斯斯坦|KG|🇰🇬|Kyrgyzstan" "塔吉克斯坦|TI|🇹🇯|Tajikistan" "土库曼斯坦|TX|🇹🇲|Turkmenistan" "格鲁吉亚|GG|🇬🇪|Georgia" "阿塞拜疆|AJ|🇦🇿|Azerbaijan" "亚美尼亚|AM|🇦🇲|Armenia" "墨西哥|MX|🇲🇽|Mexico" "智利|CI|🇨🇱|Chile" "哥伦比亚|CO|🇨🇴|Colombia" "秘鲁|PE|🇵🇪|Peru" "委内瑞拉|VE|🇻🇪|Venezuela" "古巴|CU|🇨🇺|Cuba" "尼日利亚|NI|🇳🇬|Nigeria" "肯尼亚|KE|🇰🇪|Kenya" "摩洛哥|MO|🇲🇦|Morocco" "阿尔及利亚|AG|🇩🇿|Algeria" "突尼斯|TS|🇹🇳|Tunisia" "利比亚|LY|🇱🇾|Libya" "卡塔尔|QA|🇶🇦|Qatar" "科威特|KU|🇰🇼|Kuwait" "阿曼|MU|🇴🇲|Oman" "也门|YM|🇾🇪|Yemen" "约旦|JO|🇯🇴|Jordan" "黎巴嫩|LE|🇱🇧|Lebanon" "叙利亚|SY|🇸🇾|Syria" "巴勒斯坦|GZ|🇵🇸|Palestine" "塞浦路斯|CY|🇨🇾|Cyprus" "马耳他|MT|🇲🇹|Malta" "卢森堡|LU|🇱🇺|Luxembourg" "摩纳哥|MN|🇲🇨|Monaco" "梵蒂冈|VT|🇻🇦|Vatican" "安道尔|AN|🇦🇩|Andorra" "圣马力诺|SM|🇸🇲|San Marino" "列支敦士登|LS|🇱🇮|Liechtenstein" "摩尔多瓦|MD|🇲🇩|Moldova" "波黑|BK|🇧🇦|Bosnia" "黑山|MJ|🇲🇪|Montenegro" "北马其顿|MK|🇲🇰|North Macedonia" "阿尔巴尼亚|AL|🇦🇱|Albania" "科索沃|KV|🇽🇰|Kosovo" "不丹|BT|🇧🇹|Bhutan" "尼泊尔|NP|🇳🇵|Nepal" "孟加拉国|BG|🇧🇩|Bangladesh" "斯里兰卡|CE|🇱🇰|Sri Lanka" "马尔代夫|MV|🇲🇻|Maldives" "文莱|BX|🇧🇳|Brunei" "东帝汶|TT|🇹🇱|East Timor" "巴布亚新几内亚|PP|🇵🇬|Papua New Guinea" "斐济|FJ|🇫🇯|Fiji" "所罗门群岛|BP|🇸🇧|Solomon" "瓦努阿图|NH|🇻🇺|Vanuatu" "萨摩亚|WS|🇼🇸|Samoa" "汤加|TN|🇹🇴|Tonga" "图瓦卢|TV|🇹🇻|Tuvalu" "基里巴斯|KR|🇰🇮|Kiribati" "瑙鲁|NR|🇳🇷|Nauru" "帕劳|PS|🇵🇼|Palau" "密克罗尼西亚|FM|🇫🇲|Micronesia" "马绍尔群岛|RM|🇲🇭|Marshall" "牙买加|JM|🇯🇲|Jamaica" "海地|HA|🇭🇹|Haiti" "多米尼加|DR|🇩🇴|Dominican" "巴哈马|BF|🇧🇸|Bahamas" "巴巴多斯|BB|🇧🇧|Barbados" "特立尼达和多巴哥|TD|🇹🇹|Trinidad" "哥斯达黎加|CS|🇨🇷|Costa Rica" "巴拿马|PM|🇵🇦|Panama" "危地马拉|GT|🇬🇹|Guatemala" "洪都拉斯|HO|🇭🇳|Honduras" "萨尔瓦多|ES|🇸🇻|El Salvador" "尼加拉瓜|NU|🇳🇮|Nicaragua" "伯利兹|BH|🇧🇿|Belize" "厄瓜多尔|EC|🇪🇨|Ecuador" "玻利维亚|BL|🇧🇴|Bolivia" "巴拉圭|PA|🇵🇾|Paraguay" "乌拉圭|UY|🇺🇾|Uruguay" "圭亚那|GY|🇬🇾|Guyana" "苏里南|NS|🇸🇷|Suriname" "埃塞俄比亚|ET|🇪🇹|Ethiopia" "坦桑尼亚|TZ|🇹🇿|Tanzania" "乌干达|UG|🇺🇬|Uganda" "卢旺达|RW|🇷🇼|Rwanda" "布隆迪|BY|🇧🇮|Burundi" "苏丹|SU|🇸🇩|Sudan" "南苏丹|OD|🇸🇸|South Sudan" "吉布提|DJ|🇩🇯|Djibouti" "索马里|SO|🇸🇴|Somalia" "厄立特里亚|ER|🇪🇷|Eritrea" "马达加斯加|MA|🇲🇬|Madagascar" "毛里求斯|MP|🇲🇺|Mauritius" "塞舌尔|SE|🇸🇨|Seychelles" "科摩罗|CN|🇰🇲|Comoros" "莫桑比克|MZ|🇲🇿|Mozambique" "津巴布韦|ZI|🇿🇼|Zimbabwe" "赞比亚|ZA|🇿🇲|Zambia" "马拉维|MI|🇲🇼|Malawi" "博茨瓦纳|BC|🇧🇼|Botswana" "纳米比亚|WA|🇳🇦|Namibia" "安哥拉|AO|🇦🇴|Angola" "刚果民主共和国|CG|🇨🇩|Congo" "刚果共和国|CF|🇨🇬|Congo" "加蓬|GB|🇬🇦|Gabon" "赤道几内亚|EK|🇬🇶|Equatorial Guinea" "喀麦隆|CM|🇨🇲|Cameroon" "乍得|CD|🇹🇩|Chad" "中非|CT|🇨🇫|Central African" "加纳|GH|🇬🇭|Ghana" "科特迪瓦|IV|🇨🇮|Cote dIvoire" "利比里亚|LI|🇱🇷|Liberia" "塞拉利昂|SL|🇸🇱|Sierra Leone" "几内亚|GV|🇬🇳|Guinea" "几内亚比绍|PU|🇬🇼|Guinea-Bissau" "塞内加尔|SG|🇸🇳|Senegal" "冈比亚|GA|🇬🇲|Gambia" "马里|ML|🇲🇱|Mali" "布基纳法索|UV|🇧🇫|Burkina Faso" "尼日尔|NG|🇳🇪|Niger" "贝宁|BN|🇧🇯|Benin" "多哥|TO|🇹🇬|Togo" "毛里塔尼亚|MR|🇲🇷|Mauritania" "西撒哈拉|WI|🇪🇭|Western Sahara"
)

AVAILABLE_REGIONS=()
declare -A REGION_COUNTS
declare -A REGION_REGEX

# 全球选项
AVAILABLE_REGIONS+=("全球自动选择 (Global Auto)")
REGION_COUNTS["全球自动选择 (Global Auto)"]=$TOTAL_COUNT
REGION_REGEX["全球自动选择 (Global Auto)"]=".*"

# 遍历匹配 (使用文件缓存避免变量溢出)
for item in "${REGIONS_DB[@]}"; do
    IFS='|' read -r CN_NAME CODE EMOJI EN_KEY <<< "$item"
    if [ -n "$EN_KEY" ]; then MATCH_STR="($CN_NAME|$CODE|$EMOJI|$EN_KEY)"; else MATCH_STR="($CN_NAME|$CODE|$EMOJI)"; fi
    
    # 核心：使用 grep 文件的方式
    COUNT=$(grep -E -i "$MATCH_STR" /tmp/singbox_tags.txt | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        DISPLAY_NAME="$EMOJI $CN_NAME ($CODE)"
        AVAILABLE_REGIONS+=("$DISPLAY_NAME")
        REGION_COUNTS["$DISPLAY_NAME"]=$COUNT
        REGION_REGEX["$DISPLAY_NAME"]="$MATCH_STR"
    fi
done

# 6. 选择菜单
echo -e "${GREEN}=====================================${NC}"
i=0
for region in "${AVAILABLE_REGIONS[@]}"; do
    printf " [%-2d] %-35s - %d 节点\n" $i "$region" "${REGION_COUNTS[$region]}"
    ((i++))
done
echo -e "${YELLOW}-------------------------------------${NC}"
read -p "请选择: " IDX

if [[ ! "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -ge "${#AVAILABLE_REGIONS[@]}" ]; then
    echo -e "${RED}无效选择${NC}"; exit 1
fi

SELECTED_NAME="${AVAILABLE_REGIONS[$IDX]}"
MATCH_KEY="${REGION_REGEX[$SELECTED_NAME]}"
echo -e "${GREEN}已选: $SELECTED_NAME${NC}"

# 7. 重构配置 (修复重复 Tag 问题)
echo -e "${BLUE}>>> [5/7] 生成配置 (Fix Duplicate Tag)...${NC}"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# 核心 jq 逻辑：
# 1. --slurpfile 读取原始文件 (避免参数过长)
# 2. 提取并过滤节点 (filter)
# 3. 构造新的 outbounds 数组 (只包含: urltest组 + 直连 + 阻断 + 筛选出的节点)
# 4. 绝不盲目合并原始 outbounds，从而杜绝 duplicate tag
jq -n \
    --slurpfile original "$CONFIG_FILE.bak" \
    --arg match_key "$MATCH_KEY" \
    '{
    "log": { "level": "info", "timestamp": true },
    "dns": {
        "servers": [
            { "tag": "cf-doh", "address": "https://1.1.1.1/dns-query", "detour": "direct" },
            { "tag": "local", "address": "local", "detour": "direct" }
        ],
        "rules": [
            { "outbound": "any", "server": "cf-doh" }
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
        # 1. 提取所有实际节点 (排除系统内置)
        ($original[0].outbounds | map(select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest"))) as $all_nodes |
        
        # 2. 根据正则筛选节点
        ($all_nodes | map(select(.tag | test($match_key; "i")))) as $selected_nodes |
        
        # 3. 组装最终列表 (UrlTest组 + 系统内置 + 筛选节点)
        # 注意：这里我们抛弃了所有未被选中的节点，保证文件体积小且无冲突
        [
            {
                "type": "urltest",
                "tag": "AUTO-SELECT-GROUP",
                "outbounds": ($selected_nodes | map(.tag)),
                "url": "https://www.gstatic.com/generate_204",
                "interval": "30s",
                "tolerance": 50
            },
            { "type": "direct", "tag": "direct" },
            { "type": "block", "tag": "block" }
        ] + $selected_nodes
    ),
    "route": {
        "rules": [
            { "protocol": "dns", "outbound": "dns-out" },
            { "inbound": "mixed-in", "action": "route", "outbound": "AUTO-SELECT-GROUP" }
        ],
        "auto_detect_interface": true
    }
}' > "$CONFIG_FILE"

# 8. 启动服务
echo -e "${BLUE}>>> [6/7] 启动服务...${NC}"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box

sleep 3
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}✅ 启动成功！${NC}"
    echo -e "监听端口: ${YELLOW}2080${NC}"
    echo -e "测试命令: curl -m 10 ipinfo.io"
    echo -e "----------------------------------"
    
    # 自动测试
    export http_proxy="http://127.0.0.1:2080"
    export https_proxy="http://127.0.0.1:2080"
    RES=$(curl -s -m 5 ipinfo.io)
    if [[ $RES == *"ip"* ]]; then
        echo -e "${GREEN}🎉 网络通畅！${NC}"
        echo "$RES"
    else
        echo -e "${RED}⚠️  测试超时，请手动尝试。${NC}"
    fi
else
    echo -e "${RED}启动失败，日志如下：${NC}"
    journalctl -u sing-box -n 20 --no-pager
fi
