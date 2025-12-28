#!/bin/bash

# =================================================================
# Sing-box 全球地区智能识别与负载均衡脚本 (Ultimate Edition)
# 集成 200+ 国家/地区识别库
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 解析命令行参数
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

# 检查权限
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 权限运行 (sudo su)${NC}"; exit 1; fi

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   Sing-box 全球节点智能识别系统              ${NC}"
echo -e "${BLUE}==============================================${NC}"

# 1. 依赖安装
echo -e "${BLUE}>>> [1/7] 检查依赖...${NC}"
if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -y -q curl jq tar
elif command -v yum >/dev/null; then yum install -y -q curl jq tar
elif command -v apk >/dev/null; then apk add -q curl jq tar
else echo -e "${RED}未知系统，请手动安装 curl jq tar${NC}"; exit 1; fi

# 2. 架构识别
echo -e "${BLUE}>>> [2/7] 识别架构...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) SING_ARCH="amd64" ;;
    aarch64|arm64) SING_ARCH="arm64" ;;
    armv7l) SING_ARCH="armv7" ;;
    *) echo -e "${RED}不支持: $ARCH${NC}"; exit 1 ;;
esac

# 3. 安装 Sing-box
echo -e "${BLUE}>>> [3/7] 安装 Sing-box...${NC}"
API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r ".assets[] | select(.name | contains(\"linux-$SING_ARCH\")) | select(.name | contains(\".tar.gz\")) | .browser_download_url" | head -n 1)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.0/sing-box-1.9.0-linux-$SING_ARCH.tar.gz"
fi
curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
tar -xzf sing-box.tar.gz
DIR_NAME=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
systemctl stop sing-box 2>/dev/null
cp "$DIR_NAME/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box.tar.gz "$DIR_NAME"

# 4. 下载订阅
echo -e "${BLUE}>>> [4/7] 下载订阅配置...${NC}"
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ -z "$SUB_URL" ]; then read -p "请输入订阅链接: " SUB_URL; fi
if [ -z "$SUB_URL" ]; then echo -e "${RED}链接为空${NC}"; exit 1; fi

echo -e "正在下载: $SUB_URL"
curl -L -A "Mozilla/5.0" -o "$CONFIG_FILE" "$SUB_URL"
if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "${RED}下载失败或非 JSON 格式。${NC}"; exit 1
fi

# 5. 智能地区识别与统计
echo -e "${BLUE}>>> [5/7] 正在扫描全量节点库...${NC}"

# 提取所有实际可用节点
RAW_TAGS=$(jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest") | .tag' "$CONFIG_FILE")
TOTAL_NODES_COUNT=$(echo "$RAW_TAGS" | wc -l)

if [ "$TOTAL_NODES_COUNT" -eq 0 ]; then
    echo -e "${RED}未在订阅中找到有效节点！${NC}"; exit 1
fi

# ================= 庞大的国家数据库 =================
# 格式: "中文名|代码|可能的英文关键字"
# 注意：代码(如HK)和中文名会自动用于正则匹配
REGIONS_DB=(
"中华人民共和国|CH|China" "中非|CT|Central African" "智利|CI|Chile" "直布罗陀|GI|Gibraltar" "乍得|CD|Chad" "扎伊尔|ZA|Zaire" "泽西|JE|Jersey" "赞比亚|ZA|Zambia" "越南|VM|Vietnam" "约旦|JO|Jordan" "英属印度洋领地|IO|Indian Ocean" "英属维尔京群岛|VI|Virgin Islands" "英国|UK|United Kingdom|Britain" "印度尼西亚|ID|Indonesia" "印度|IN|India" "意大利|IT|Italy" "以色列|IS|Israel" "伊朗|IR|Iran" "伊拉克|IZ|Iraq" "也门|YM|Yemen" "亚美尼亚|AM|Armenia" "牙买加|JM|Jamaica" "叙利亚|SY|Syria" "匈牙利|HU|Hungary" "新西兰|NZ|New Zealand" "新喀里多尼亚|NC|New Caledonia" "新加坡|SN|Singapore|SG" "香港|HK|Hong Kong" "希腊|GR|Greece" "西印度群岛联邦|WI|West Indies" "西撒哈拉|WI|Western Sahara" "西班牙|SP|Spain" "乌兹别克斯坦|UZ|Uzbekistan" "乌拉圭|UY|Uruguay" "乌克兰|UP|Ukraine" "乌干达|UG|Uganda" "文莱|BX|Brunei" "委内瑞拉|VE|Venezuela" "危地马拉|GT|Guatemala" "瓦努阿图|NH|Vanuatu" "瓦利斯和富图纳|WF|Wallis" "托克劳|TL|Tokelau" "土库曼斯坦|TX|Turkmenistan" "土耳其|TU|Turkey" "图瓦卢|TV|Tuvalu" "突尼斯|TS|Tunisia" "特立尼达和多巴哥|TD|Trinidad" "特克斯和凯科斯群岛|TK|Turks" "汤加|TN|Tonga" "坦桑尼亚|TZ|Tanzania" "泰国|TH|Thailand" "台湾|TW|Taiwan" "塔吉克斯坦|TI|Tajikistan" "索马里|SO|Somalia" "所罗门群岛|BP|Solomon" "苏联|UR|USSR" "苏里南|NS|Suriname" "苏丹|SU|Sudan" "斯威士兰|WZ|Swaziland" "斯洛文尼亚|SI|Slovenia" "斯洛伐克|LO|Slovakia" "斯里兰卡|CE|Sri Lanka" "圣文森特和格林纳丁斯|VC|Saint Vincent" "圣皮埃尔和密克隆|SB|Saint Pierre" "圣马力诺|SM|San Marino" "圣卢西亚|ST|Saint Lucia" "圣基茨和尼维斯|SC|Saint Kitts" "圣赫勒拿|SH|Saint Helena" "圣多美和普林西比|TP|Sao Tome" "圣诞岛|KT|Christmas Island" "圣巴泰勒米|TB|Saint Barthelemy" "上沃尔特|VO|Upper Volta" "沙特阿拉伯|SA|Saudi Arabia" "塞舌尔|SE|Seychelles" "塞浦路斯|CY|Cyprus" "塞内加尔|SG|Senegal" "塞拉利昂|SL|Sierra Leone" "塞尔维亚|RI|Serbia" "萨摩亚|WS|Samoa" "萨尔瓦多|ES|El Salvador" "瑞士|SZ|Switzerland" "瑞典|SW|Sweden" "日本|JA|Japan|JP" "葡萄牙|PO|Portugal" "皮特凯恩群岛|PC|Pitcairn" "帕劳|PS|Palau" "欧洲联盟|EU|Europe" "诺福克岛|NF|Norfolk" "挪威|NO|Norway" "纽埃|NE|Niue" "尼日利亚|NI|Nigeria" "尼日尔|NG|Niger" "尼泊尔|NP|Nepal" "尼加拉瓜|NU|Nicaragua" "瑙鲁|NR|Nauru" "南苏丹|OD|South Sudan" "南斯拉夫|YU|Yugoslavia" "南乔治亚|SX|South Georgia" "南极洲|AY|Antarctica" "南非|SF|South Africa" "纳米比亚|WA|Namibia" "墨西哥|MX|Mexico" "莫桑比克|MZ|Mozambique" "摩纳哥|MN|Monaco" "摩洛哥|MO|Morocco" "摩尔多瓦|MD|Moldova" "缅甸|BM|Myanmar|Burma" "密克罗尼西亚|FM|Micronesia" "秘鲁|PE|Peru" "孟加拉国|BG|Bangladesh" "蒙特塞拉特|MH|Montserrat" "蒙古国|MG|Mongolia" "美属维尔京群岛|VQ|Virgin Islands" "美属萨摩亚|AQ|American Samoa" "美国|US|United States|USA" "毛里塔尼亚|MR|Mauritania" "毛里求斯|MP|Mauritius" "马约特|MF|Mayotte" "马提尼克|MB|Martinique" "马绍尔群岛|RM|Marshall" "马里|ML|Mali" "马来西亚|MY|Malaysia" "马拉维|MI|Malawi" "马耳他|MT|Malta" "马尔代夫|MV|Maldives" "马恩岛|IM|Isle of Man" "马达加斯加|MA|Madagascar" "罗马尼亚|RO|Romania" "罗得西亚|RH|Rhodesia" "卢旺达|RW|Rwanda" "卢森堡|LU|Luxembourg" "留尼汪|RE|Reunion" "列支敦士登|LS|Liechtenstein" "联合国|UN|United Nations" "利比亚|LY|Libya" "利比里亚|LI|Liberia" "立陶宛|LH|Lithuania" "黎巴嫩|LE|Lebanon" "老挝|LA|Laos" "莱索托|LT|Lesotho" "拉脱维亚|LG|Latvia" "库拉索|UC|Curacao" "库克群岛|CW|Cook Islands" "肯尼亚|KE|Kenya" "克罗地亚|HR|Croatia" "科威特|KU|Kuwait" "科特迪瓦|IV|Cote dIvoire" "科索沃|KV|Kosovo" "科摩罗|CN|Comoros" "科科斯|CK|Cocos" "开曼群岛|CJ|Cayman" "卡塔尔|QA|Qatar" "喀麦隆|CM|Cameroon" "津巴布韦|ZI|Zimbabwe" "捷克斯洛伐克|TC|Czechoslovakia" "捷克|EZ|Czech" "柬埔寨|CB|Cambodia" "加蓬|GB|Gabon" "加纳|GH|Ghana" "加拿大|CA|Canada" "几内亚比绍|PU|Guinea-Bissau" "几内亚|GV|Guinea" "吉尔吉斯斯坦|KG|Kyrgyzstan" "吉布提|DJ|Djibouti" "基里巴斯|KR|Kiribati" "洪都拉斯|HO|Honduras" "黑山|MJ|Montenegro" "赫德岛|HM|Heard Island" "荷属圣马丁|NN|Sint Maarten" "荷属安的列斯|NT|Netherlands Antilles" "荷兰|NL|Netherlands" "韩国|KS|Korea|KR" "海地|HA|Haiti" "哈萨克斯坦|KZ|Kazakhstan" "圭亚那|GY|Guyana" "关岛|GQ|Guam" "瓜德罗普|GP|Guadeloupe" "古巴|CU|Cuba" "根西|GK|Guernsey" "格鲁吉亚|GG|Georgia" "格陵兰|GL|Greenland" "格林纳达|GJ|Grenada" "哥斯达黎加|CS|Costa Rica" "哥伦比亚|CO|Colombia" "刚果民主共和国|CG|Congo" "刚果共和国|CF|Congo" "冈比亚|GA|Gambia" "福克兰群岛|FK|Falkland" "佛得角|CV|Cape Verde" "芬兰|FI|Finland" "斐济|FJ|Fiji" "菲律宾|RP|Philippines" "非洲联盟|AU|African Union" "梵蒂冈|VT|Vatican" "法属圣马丁|RN|Saint Martin" "法属南部和南极领地|FS|French Southern" "法属圭亚那|FG|French Guiana" "法属波利尼西亚|FP|French Polynesia" "法罗群岛|FO|Faroe" "法国|FR|France|FX" "厄立特里亚|ER|Eritrea" "厄瓜多尔|EC|Ecuador" "俄罗斯|RS|Russia|RU" "多米尼克|DO|Dominica" "多米尼加|DR|Dominican" "多哥|TO|Togo" "独立国家联合体|EN|CIS" "东南亚国家联盟|ASEAN|ASEAN" "东帝汶|TT|East Timor" "德国|GM|Germany|DE" "丹麦|DA|Denmark" "达荷美|DA|Dahomey" "赤道几内亚|EK|Equatorial Guinea" "朝鲜|KN|North Korea" "布韦岛|BV|Bouvet" "布隆迪|BY|Burundi" "布基纳法索|UV|Burkina Faso" "不丹|BT|Bhutan" "博茨瓦纳|BC|Botswana" "伯利兹|BH|Belize" "玻利维亚|BL|Bolivia" "波希米亚|BO|Bohemia" "波兰|PL|Poland" "波黑|BK|Bosnia" "波多黎各|RQ|Puerto Rico" "冰岛|IC|Iceland" "比利时|BE|Belgium" "贝宁|BN|Benin" "北马其顿|MK|North Macedonia" "北马里亚纳群岛|CQ|Northern Mariana" "保加利亚|BU|Bulgaria" "百慕大|BD|Bermuda" "白俄罗斯|BO|Belarus" "巴西|BR|Brazil" "巴拿马|PM|Panama" "巴林|BA|Bahrain" "巴勒斯坦|GZ|Palestine" "巴勒斯坦|WE|Palestine" "巴拉圭|PA|Paraguay" "巴基斯坦|PK|Pakistan" "巴哈马|BF|Bahamas" "巴布亚新几内亚|PP|Papua New Guinea" "巴巴多斯|BB|Barbados" "澳门|MC|Macau" "澳大利亚|AS|Australia|AU" "澳大拉西亚|AN|Australasia" "奥地利|AU|Austria" "安提瓜和巴布达|AC|Antigua" "安圭拉|AV|Anguilla" "安哥拉|AO|Angola" "安道尔|AN|Andorra" "爱沙尼亚|EN|Estonia" "爱尔兰|EI|Ireland" "埃塞俄比亚|ET|Ethiopia" "埃及|EG|Egypt" "阿塞拜疆|AJ|Azerbaijan" "阿曼|MU|Oman" "阿鲁巴|AA|Aruba" "阿联酋|AE|UAE|United Arab Emirates" "阿拉伯联合共和国|UA|United Arab Republic" "阿根廷|AR|Argentina" "阿富汗|AF|Afghanistan" "阿尔及利亚|AG|Algeria" "阿尔巴尼亚|AL|Albania"
)

# 动态数组用于存储结果
declare -A REGION_COUNTS
declare -A REGION_REGEX
AVAILABLE_REGIONS=()

# 1. 先加入“所有地区”选项
AVAILABLE_REGIONS+=("全球自动选择 (Global Auto)")
REGION_COUNTS["全球自动选择 (Global Auto)"]=$TOTAL_NODES_COUNT
REGION_REGEX["全球自动选择 (Global Auto)"]=".*"

# 2. 遍历数据库进行匹配
echo -e "${BLUE}>>> 正在分析地区分布 (共 ${#REGIONS_DB[@]} 个识别规则)...${NC}"

for item in "${REGIONS_DB[@]}"; do
    IFS='|' read -r CN_NAME CODE EN_KEY <<< "$item"
    
    # 构建正则：匹配 "中文名" 或 "代码" 或 "英文关键字"
    # 示例: 香港|HK -> (香港|HK|Hong Kong)
    if [ -n "$EN_KEY" ]; then
        MATCH_STR="($CN_NAME|$CODE|$EN_KEY)"
    else
        MATCH_STR="($CN_NAME|$CODE)"
    fi
    
    # 统计数量
    COUNT=$(echo "$RAW_TAGS" | grep -E -i "$MATCH_STR" | wc -l)
    
    # 如果订阅里有这个国家的节点，就加入菜单
    if [ "$COUNT" -gt 0 ]; then
        # 格式化显示名称：例如 "香港 (HK)"
        DISPLAY_NAME="$CN_NAME ($CODE)"
        REGION_COUNTS["$DISPLAY_NAME"]=$COUNT
        REGION_REGEX["$DISPLAY_NAME"]="$MATCH_STR"
        AVAILABLE_REGIONS+=("$DISPLAY_NAME")
    fi
done

# 6. 用户选择菜单
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}      检测到以下地区节点 (Total: $TOTAL_NODES_COUNT)${NC}"
echo -e "${GREEN}==============================================${NC}"

i=0
for region in "${AVAILABLE_REGIONS[@]}"; do
    # 格式化输出，对齐更好看
    printf " [%-2d] %-30s - %d 个节点\n" $i "$region" "${REGION_COUNTS[$region]}"
    ((i++))
done

echo -e "${YELLOW}------------------------------------------------${NC}"
echo -e "${YELLOW}请选择一个选项 (输入数字):${NC}"
echo -e "${YELLOW}说明：选择特定地区后，将只使用该地区节点并每10秒测速。${NC}"

read -p "选择: " SELECT_INDEX

if [[ "$SELECT_INDEX" =~ ^[0-9]+$ ]] && [ "$SELECT_INDEX" -lt "${#AVAILABLE_REGIONS[@]}" ]; then
    SELECTED_REGION_NAME="${AVAILABLE_REGIONS[$SELECT_INDEX]}"
    MATCH_KEY="${REGION_REGEX[$SELECTED_REGION_NAME]}"
    
    echo -e "${GREEN}你选择了: $SELECTED_REGION_NAME${NC}"
    echo -e "${BLUE}正在重构配置 (检测间隔: 10s)...${NC}"
    
    # 7. 重构配置文件
    
    # 提取符合条件的节点 Tag JSON 数组
    # 使用 jq -R . | jq -s . 将 grep 输出的每行转为 JSON 字符串数组
    FILTERED_TAGS_JSON=$(echo "$RAW_TAGS" | grep -E -i "$MATCH_KEY" | jq -R . | jq -s .)
    
    # 构造 urltest 对象
    NEW_OUTBOUND_JSON=$(jq -n \
        --argjson tags "$FILTERED_TAGS_JSON" \
        --arg name "AUTO-SELECT-GROUP" \
        '{
            "type": "urltest",
            "tag": $name,
            "outbounds": $tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "10s",
            "tolerance": 50
        }'
    )
    
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    
    # 注入配置
    jq --argjson newgroup "$NEW_OUTBOUND_JSON" '
        .outbounds = [$newgroup] + .outbounds | 
        if .route.rules then
            .route.rules = [{"network": ["tcp","udp"], "outbound": "AUTO-SELECT-GROUP"}] + .route.rules
        else
            .route = {"rules": [{"network": ["tcp","udp"], "outbound": "AUTO-SELECT-GROUP"}]}
        end
    ' "$CONFIG_FILE.bak" > "$CONFIG_FILE"
    
    echo -e "${GREEN}配置完成！服务已配置为自动选择 [$SELECTED_REGION_NAME] 区域的最佳节点。${NC}"

else
    echo -e "${RED}无效选择，退出脚本。${NC}"; exit 1
fi

# 8. 启动服务
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

sleep 2
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}启动成功！${NC}"
    echo -e "当前策略: $SELECTED_REGION_NAME"
    echo -e "日志查看: journalctl -u sing-box -f"
else
    echo -e "${RED}启动失败${NC}"; journalctl -u sing-box -n 20 --no-pager
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
fi
