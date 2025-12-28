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

# ==========================================
# 1. Root 检查
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

clear
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e "${BLUE}#                                                           #${PLAIN}"
echo -e "${BLUE}#   Sing-box 旗舰版 (自动识别 TUN/普通模式 + 故障降级)      #${PLAIN}"
echo -e "${BLUE}#                                                           #${PLAIN}"
echo -e "${BLUE}#############################################################${PLAIN}"
echo -e ""

# ==========================================
# 2. 用户交互与订阅智能处理
# ==========================================
echo -e "${GREEN}步骤 1/5: 初始化环境...${PLAIN}"
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget tar unzip jq python3 cron >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1
    systemctl start cron >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y curl wget tar unzip jq python3 crontabs >/dev/null 2>&1
    systemctl enable crond >/dev/null 2>&1
    systemctl start crond >/dev/null 2>&1
fi

echo -e ""

# ==========================================
# 优先读取命令行参数 $1
# ==========================================
if [[ -n "$1" ]]; then
    SUB_URL="$1"
    echo -e "${YELLOW}已检测到命令行参数，自动使用订阅: ${SUB_URL}${PLAIN}"
else
    echo -e "${YELLOW}请输入你的节点订阅链接:${PLAIN}"
    read -p "链接: " SUB_URL
fi

FINAL_REGEX=""
USE_CONVERSION=true 

if [[ -z "$SUB_URL" ]]; then
    echo -e "${RED}未输入链接，脚本无法继续。${PLAIN}"
    exit 1
else
    echo -e "${GREEN}正在尝试直接下载订阅...${PLAIN}"
    
    wget --no-check-certificate -q -O /tmp/singbox_raw.json "$SUB_URL"
    
    if [[ -s /tmp/singbox_raw.json ]] && jq -e '.outbounds' /tmp/singbox_raw.json >/dev/null 2>&1; then
        echo -e "${GREEN}检测到链接已经是 Sing-box 格式，跳过第三方转换。${PLAIN}"
        cp /tmp/singbox_raw.json /tmp/singbox_pre.json
        USE_CONVERSION=false
    else
        echo -e "${YELLOW}原始链接不是标准配置，尝试使用 API 转换...${PLAIN}"
        ENCODED_URL=$(urlencode "$SUB_URL")
        PRE_API="https://api.v1.mk/sub?target=sing-box&url=${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json"
        wget --no-check-certificate -q -O /tmp/singbox_pre.json "$PRE_API"
    fi
    
    if [[ ! -s /tmp/singbox_pre.json ]]; then
        echo -e "${RED}严重错误：无法解析订阅。请检查链接是否正确或服务器是否可达。${PLAIN}"; exit 1
    fi

    NODE_TAGS=$(jq -r '.outbounds[] | select(.type | test("Selector|URLTest|Direct|Block") | not) | .tag' /tmp/singbox_pre.json)
    
    REGION_DATA=(
"阿富汗 (AF)|🇦🇫|AF|Afghanistan|阿富汗" "阿尔巴尼亚 (AL)|🇦🇱|AL|Albania|阿尔巴尼亚" "阿尔及利亚 (AG)|🇩🇿|AG|Algeria|阿尔及利亚" "美属萨摩亚 (AQ)|🇦🇸|AQ|American Samoa|美属萨摩亚" "安道尔 (AN)|🇦🇩|AN|Andorra|安道尔" "安哥拉 (AO)|🇦🇴|AO|Angola|安哥拉" "安圭拉 (AV)|🇦🇮|AV|Anguilla|安圭拉" "南极洲 (AY)|🇦🇶|AY|Antarctica|南极洲" "安提瓜和巴布达 (AC)|🇦🇬|AC|Antigua|Barbuda|安提瓜" "阿根廷 (AR)|🇦🇷|AR|Argentina|阿根廷" "亚美尼亚 (AM)|🇦🇲|AM|Armenia|亚美尼亚" "阿鲁巴 (AA)|🇦🇼|AA|Aruba|阿鲁巴" "澳大利亚 (AS)|🇦🇺|AS|Australia|澳大利亚" "奥地利 (AU)|🇦🇹|AU|Austria|奥地利" "阿塞拜疆 (AJ)|🇦🇿|AJ|Azerbaijan|阿塞拜疆" "巴哈马 (BF)|🇧🇸|BF|Bahamas|巴哈马" "巴林 (BA)|🇧🇭|BA|Bahrain|巴林" "孟加拉国 (BG)|🇧🇩|BG|Bangladesh|孟加拉" "巴巴多斯 (BB)|🇧🇧|BB|Barbados|巴巴多斯" "白俄罗斯 (BO)|🇧🇾|BO|Belarus|白俄罗斯" "比利时 (BE)|🇧🇪|BE|Belgium|比利时" "伯利兹 (BH)|🇧🇿|BH|Belize|伯利兹" "贝宁 (BN)|🇧🇯|BN|Benin|贝宁" "百慕大 (BD)|🇧🇲|BD|Bermuda|百慕大" "不丹 (BT)|🇧🇹|BT|Bhutan|不丹" "玻利维亚 (BL)|🇧🇴|BL|Bolivia|玻利维亚" "波黑 (BK)|🇧🇦|BK|Bosnia|波黑" "博茨瓦纳 (BC)|🇧🇼|BC|Botswana|博茨瓦纳" "巴西 (BR)|🇧🇷|BR|Brazil|巴西" "英属印度洋领地 (IO)|🇮🇴|IO|British Indian Ocean|英属印度洋" "英属维尔京群岛 (VI)|🇻🇬|VI|Virgin Islands|英属维尔京" "文莱 (BX)|🇧🇳|BX|Brunei|文莱" "保加利亚 (BU)|🇧🇬|BU|Bulgaria|保加利亚" "布基纳法索 (UV)|🇧🇫|UV|Burkina Faso|布基纳法索" "缅甸 (BM)|🇲🇲|BM|Myanmar|Burma|缅甸" "布隆迪 (BY)|🇧🇮|BY|Burundi|布隆迪" "佛得角 (CV)|🇨🇻|CV|Cape Verde|佛得角" "柬埔寨 (CB)|🇰🇭|CB|Cambodia|柬埔寨" "喀麦隆 (CM)|🇨🇲|CM|Cameroon|喀麦隆" "加拿大 (CA)|🇨🇦|CA|Canada|加拿大" "开曼群岛 (CJ)|🇰🇾|CJ|Cayman|开曼" "中非 (CT)|🇨🇫|CT|Central African|中非" "乍得 (CD)|🇹🇩|CD|Chad|乍得" "智利 (CI)|🇨🇱|CI|Chile|智利" "中国 (CN)|🇨🇳|CN|China|中国|回国" "圣诞岛 (KT)|🇨🇽|KT|Christmas Island|圣诞岛" "哥伦比亚 (CO)|🇨🇴|CO|Colombia|哥伦比亚" "科摩罗 (CN)|🇰🇲|CN|Comoros|科摩罗" "刚果 (CG)|🇨🇬|CG|Congo|刚果" "库克群岛 (CW)|🇨🇰|CW|Cook Islands|库克群岛" "哥斯达黎加 (CS)|🇨🇷|CS|Costa Rica|哥斯达黎加" "科特迪瓦 (IV)|🇨🇮|IV|Ivory Coast|科特迪瓦" "克罗地亚 (HR)|🇭🇷|HR|Croatia|克罗地亚" "古巴 (CU)|🇨🇺|CU|Cuba|古巴" "库拉索 (UC)|🇨🇼|UC|Curacao|库拉索" "塞浦路斯 (CY)|🇨🇾|CY|Cyprus|塞浦路斯" "捷克 (EZ)|🇨🇿|EZ|Czech|捷克" "丹麦 (DA)|🇩🇰|DA|Denmark|丹麦" "吉布提 (DJ)|🇩🇯|DJ|Djibouti|吉布提" "多米尼克 (DO)|🇩🇲|DO|Dominica|多米尼克" "多米尼加 (DR)|🇩🇴|DR|Dominican|多米尼加" "厄瓜多尔 (EC)|🇪🇨|EC|Ecuador|厄瓜多尔" "埃及 (EG)|🇪🇬|EG|Egypt|埃及" "萨尔瓦多 (ES)|🇸🇻|ES|El Salvador|萨尔瓦多" "赤道几内亚 (EK)|🇬🇶|EK|Equatorial Guinea|赤道几内亚" "厄立特里亚 (ER)|🇪🇷|ER|Eritrea|厄立特里亚" "爱沙尼亚 (EN)|🇪🇪|EN|Estonia|爱沙尼亚" "埃塞俄比亚 (ET)|🇪🇹|ET|Ethiopia|埃塞俄比亚" "法罗群岛 (FO)|🇫🇴|FO|Faroe|法罗" "斐济 (FJ)|🇫🇯|FJ|Fiji|斐济" "芬兰 (FI)|🇫🇮|FI|Finland|芬兰" "法国 (FR)|🇫🇷|FR|France|法国" "法属圭亚那 (FG)|🇬🇫|FG|French Guiana|法属圭亚那" "法属波利尼西亚 (FP)|🇵🇫|FP|French Polynesia|法属波利尼西亚" "加蓬 (GB)|🇬🇦|GB|Gabon|加蓬" "冈比亚 (GA)|🇬🇲|GA|Gambia|冈比亚" "巴勒斯坦 (GZ)|🇵🇸|GZ|Palestine|巴勒斯坦" "格鲁吉亚 (GG)|🇬🇪|GG|Georgia|格鲁吉亚" "德国 (DE)|🇩🇪|DE|Germany|德国" "加纳 (GH)|🇬🇭|GH|Ghana|加纳" "直布罗陀 (GI)|🇬🇮|GI|Gibraltar|直布罗陀" "希腊 (GR)|🇬🇷|GR|Greece|希腊" "格陵兰 (GL)|🇬🇱|GL|Greenland|格陵兰" "格林纳达 (GJ)|🇬🇩|GJ|Grenada|格林纳达" "关岛 (GQ)|🇬🇺|GQ|Guam|关岛" "危地马拉 (GT)|🇬🇹|GT|Guatemala|危地马拉" "几内亚 (GV)|🇬🇳|GV|Guinea|几内亚" "几内亚比绍 (PU)|🇬🇼|PU|Guinea-Bissau|几内亚比绍" "圭亚那 (GY)|🇬🇾|GY|Guyana|圭亚那" "海地 (HA)|🇭🇹|HA|Haiti|海地" "梵蒂冈 (VT)|🇻🇦|VT|Vatican|梵蒂冈" "洪都拉斯 (HO)|🇭🇳|HO|Honduras|洪都拉斯" "香港 (HK)|🇭🇰|HK|Hong Kong|HongKong|香港" "匈牙利 (HU)|🇭🇺|HU|Hungary|匈牙利" "冰岛 (IC)|🇮🇸|IC|Iceland|冰岛" "印度 (IN)|🇮🇳|IN|India|印度" "印度尼西亚 (ID)|🇮🇩|ID|Indonesia|印尼|印度尼西亚" "伊朗 (IR)|🇮🇷|IR|Iran|伊朗" "伊拉克 (IZ)|🇮🇶|IZ|Iraq|伊拉克" "爱尔兰 (EI)|🇮🇪|EI|Ireland|爱尔兰" "以色列 (IS)|🇮🇱|IS|Israel|以色列" "意大利 (IT)|🇮🇹|IT|Italy|意大利" "牙买加 (JM)|🇯🇲|JM|Jamaica|牙买加" "日本 (JP)|🇯🇵|JP|Japan|日本" "约旦 (JO)|🇯🇴|JO|Jordan|约旦" "哈萨克斯坦 (KZ)|🇰🇿|KZ|Kazakhstan|哈萨克斯坦" "肯尼亚 (KE)|🇰🇪|KE|Kenya|肯尼亚" "基里巴斯 (KR)|🇰🇮|KR|Kiribati|基里巴斯" "朝鲜 (KN)|🇰🇵|KN|North Korea|朝鲜" "韩国 (KR)|🇰🇷|KR|South Korea|Korea|韩国" "科索沃 (KV)|🇽🇰|KV|Kosovo|科索沃" "科威特 (KU)|🇰🇼|KU|Kuwait|科威特" "吉尔吉斯斯坦 (KG)|🇰🇬|KG|Kyrgyzstan|吉尔吉斯" "老挝 (LA)|🇱🇦|LA|Laos|老挝" "拉脱维亚 (LG)|🇱🇻|LG|Latvia|拉脱维亚" "黎巴嫩 (LE)|🇱🇧|LE|Lebanon|黎巴嫩" "莱索托 (LT)|🇱🇸|LT|Lesotho|莱索托" "利比里亚 (LI)|🇱🇷|LI|Liberia|利比里亚" "利比亚 (LY)|🇱🇾|LY|Libya|利比亚" "列支敦士登 (LS)|🇱🇮|LS|Liechtenstein|列支敦士登" "立陶宛 (LH)|🇱🇹|LH|Lithuania|立陶宛" "卢森堡 (LU)|🇱🇺|LU|Luxembourg|卢森堡" "澳门 (MC)|🇲🇴|MC|Macao|Macau|澳门" "北马其顿 (MK)|🇲🇰|MK|Macedonia|北马其顿" "马达加斯加 (MA)|🇲🇬|MA|Madagascar|马达加斯加" "马拉维 (MI)|🇲🇼|MI|Malawi|马拉维" "马来西亚 (MY)|🇲🇾|MY|Malaysia|马来西亚" "马尔代夫 (MV)|🇲🇻|MV|Maldives|马尔代夫" "马里 (ML)|🇲🇱|ML|Mali|马里" "马耳他 (MT)|🇲🇹|MT|Malta|马耳他" "马绍尔群岛 (RM)|🇲🇭|RM|Marshall Islands|马绍尔群岛" "马提尼克 (MB)|🇲🇶|MB|Martinique|马提尼克" "毛里塔尼亚 (MR)|🇲🇷|MR|Mauritania|毛里塔尼亚" "毛里求斯 (MP)|🇲🇺|MP|Mauritius|毛里求斯" "墨西哥 (MX)|🇲🇽|MX|Mexico|墨西哥" "密克罗尼西亚 (FM)|🇫🇲|FM|Micronesia|密克罗尼西亚" "摩尔多瓦 (MD)|🇲🇩|MD|Moldova|摩尔多瓦" "摩纳哥 (MN)|🇲🇨|MN|Monaco|摩纳哥" "蒙古 (MG)|🇲🇳|MG|Mongolia|蒙古" "黑山 (MJ)|🇲🇪|MJ|Montenegro|黑山" "摩洛哥 (MO)|🇲🇦|MO|Morocco|摩洛哥" "莫桑比克 (MZ)|🇲🇿|MZ|Mozambique|莫桑比克" "纳米比亚 (WA)|🇳🇦|WA|Namibia|纳米比亚" "瑙鲁 (NR)|🇳🇷|NR|Nauru|瑙鲁" "尼泊尔 (NP)|🇳🇵|NP|Nepal|尼泊尔" "荷兰 (NL)|🇳🇱|NL|Netherlands|Holland|荷兰" "新喀里多尼亚 (NC)|🇳🇨|NC|New Caledonia|新喀里多尼亚" "新西兰 (NZ)|🇳🇿|NZ|New Zealand|新西兰" "尼加拉瓜 (NU)|🇳🇮|NU|Nicaragua|尼加拉瓜" "尼日尔 (NG)|🇳🇪|NG|Niger|尼日尔" "尼日利亚 (NI)|🇳🇬|NI|Nigeria|尼日利亚" "纽埃 (NE)|🇳🇺|NE|Niue|纽埃" "挪威 (NO)|🇳🇴|NO|Norway|挪威" "阿曼 (MU)|🇴🇲|MU|Oman|阿曼" "巴基斯坦 (PK)|🇵🇰|PK|Pakistan|巴基斯坦" "帕劳 (PS)|🇵🇼|PS|Palau|帕劳" "巴拿马 (PM)|🇵🇦|PM|Panama|巴拿马" "巴布亚新几内亚 (PP)|🇵🇬|PP|Papua New Guinea|巴布亚新几内亚" "巴拉圭 (PA)|🇵🇾|PA|Paraguay|巴拉圭" "秘鲁 (PE)|🇵🇪|PE|Peru|秘鲁" "菲律宾 (RP)|🇵🇭|RP|Philippines|菲律宾" "波兰 (PL)|🇵🇱|PL|Poland|波兰" "葡萄牙 (PO)|🇵🇹|PO|Portugal|葡萄牙" "波多黎各 (RQ)|🇵🇷|RQ|Puerto Rico|波多黎各" "卡塔尔 (QA)|🇶🇦|QA|Qatar|卡塔尔" "留尼汪 (RE)|🇷🇪|RE|Reunion|留尼汪" "罗马尼亚 (RO)|🇷🇴|RO|Romania|罗马尼亚" "台湾 (TW)|🇹🇼|TW|Taiwan|TaiWan|台湾" "俄罗斯 (RS)|🇷🇺|RS|Russia|俄罗斯" "卢旺达 (RW)|🇷🇼|RW|Rwanda|卢旺达" "圣赫勒拿 (SH)|🇸🇭|SH|Saint Helena|圣赫勒拿" "圣基茨和尼维斯 (SC)|🇰🇳|SC|Saint Kitts|圣基茨" "圣卢西亚 (ST)|🇱🇨|ST|Saint Lucia|圣卢西亚" "圣文森特 (VC)|🇻🇨|VC|Saint Vincent|圣文森特" "萨摩亚 (WS)|🇼🇸|WS|Samoa|萨摩亚" "圣马力诺 (SM)|🇸🇲|SM|San Marino|圣马力诺" "沙特阿拉伯 (SA)|🇸🇦|SA|Saudi Arabia|沙特" "塞内加尔 (SG)|🇸🇳|SG|Senegal|塞内加尔" "塞尔维亚 (RI)|🇷🇸|RI|Serbia|塞尔维亚" "塞舌尔 (SE)|🇸🇨|SE|Seychelles|塞舌尔" "塞拉利昂 (SL)|🇸🇱|SL|Sierra Leone|塞拉利昂" "新加坡 (SG)|🇸🇬|SG|Singapore|新加坡" "斯洛伐克 (LO)|🇸🇰|LO|Slovakia|斯洛伐克" "斯洛文尼亚 (SI)|🇸🇮|SI|Slovenia|斯洛文尼亚" "索马里 (SO)|🇸🇴|SO|Somalia|索马里" "南非 (SF)|🇿🇦|SF|South Africa|南非" "南苏丹 (OD)|🇸🇸|OD|South Sudan|南苏丹" "西班牙 (SP)|🇪🇸|SP|Spain|西班牙" "斯里兰卡 (CE)|🇱🇰|CE|Sri Lanka|斯里兰卡" "苏丹 (SU)|🇸🇩|SU|Sudan|苏丹" "苏里南 (NS)|🇸🇷|NS|Suriname|苏里南" "斯威士兰 (WZ)|🇸🇿|WZ|Swaziland|斯威士兰" "瑞典 (SW)|🇸🇪|SW|Sweden|瑞典" "瑞士 (SZ)|🇨🇭|SZ|Switzerland|瑞士" "叙利亚 (SY)|🇸🇾|SY|Syria|叙利亚" "塔吉克斯坦 (TI)|🇹🇯|TI|Tajikistan|塔吉克斯坦" "坦桑尼亚 (TZ)|🇹🇿|TZ|Tanzania|坦桑尼亚" "泰国 (TH)|🇹🇭|TH|Thailand|泰国" "东帝汶 (TT)|🇹🇱|TT|Timor-Leste|东帝汶" "多哥 (TO)|🇹🇬|TO|Togo|多哥" "汤加 (TN)|🇹🇴|TN|Tonga|汤加" "特立尼达和多巴哥 (TD)|🇹🇹|TD|Trinidad|特立尼达" "突尼斯 (TS)|🇹🇳|TS|Tunisia|突尼斯" "土耳其 (TU)|🇹🇷|TU|Turkey|土耳其" "土库曼斯坦 (TX)|🇹🇲|TX|Turkmenistan|土库曼斯坦" "图瓦卢 (TV)|🇹🇻|TV|Tuvalu|图瓦卢" "乌干达 (UG)|🇺🇬|UG|Uganda|乌干达" "乌克兰 (UP)|🇺🇦|UP|Ukraine|乌克兰" "阿联酋 (AE)|🇦🇪|AE|United Arab Emirates|UAE|阿联酋" "英国 (UK)|🇬🇧|UK|United Kingdom|Britain|英国" "美国 (US)|🇺🇸|US|United States|USA|America|美国" "乌拉圭 (UY)|🇺🇾|UY|Uruguay|乌拉圭" "乌兹别克斯坦 (UZ)|🇺🇿|UZ|Uzbekistan|乌兹别克斯坦" "瓦努阿图 (NH)|🇻🇺|NH|Vanuatu|瓦努阿图" "委内瑞拉 (VE)|🇻🇪|VE|Venezuela|委内瑞拉" "越南 (VM)|🇻🇳|VM|Vietnam|越南" "也门 (YM)|🇾🇪|YM|Yemen|也门" "赞比亚 (ZA)|🇿🇲|ZA|Zambia|赞比亚" "津巴布韦 (ZI)|🇿🇼|ZI|Zimbabwe|津巴布韦"
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
    
    echo -e "${YELLOW}请输入要保留的地区编号 (例如 1 3，空格分隔)，或输入 0 全选:${PLAIN}"
    read -p "选择: " USER_CHOICE

    if [[ -n "$USER_CHOICE" && "$USER_CHOICE" != "0" ]]; then
        REGEX_PARTS=()
        SELECTED_NAMES=""
        for i in $USER_CHOICE; do
            REAL_IDX=$((i-1))
            if [[ -n "${FOUND_REGEXS[$REAL_IDX]}" ]]; then
                REGEX_PARTS+=("(${FOUND_REGEXS[$REAL_IDX]})")
                SELECTED_NAMES+="${FOUND_NAMES[$REAL_IDX]} "
            fi
        done
        FINAL_REGEX=$(IFS="|"; echo "${REGEX_PARTS[*]}")
        echo -e "${GREEN}已设定持久化过滤：$SELECTED_NAMES${PLAIN}"
    else
        echo -e "${GREEN}保留所有节点。${PLAIN}"
    fi
fi

# ==========================================
# 3. 安装 Sing-box 核心
# ==========================================
echo -e ""
echo -e "${GREEN}步骤 2/5: 安装 Sing-box...${PLAIN}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) singbox_arch="amd64" ;;
    aarch64) singbox_arch="arm64" ;;
    armv7l) singbox_arch="armv7" ;;
    *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1 ;;
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

# ==========================================
# 4. 安装 WebUI
# ==========================================
echo -e "${GREEN}步骤 3/5: 部署 WebUI...${PLAIN}"
WEBUI_DIR="/etc/sing-box/ui"
rm -rf "$WEBUI_DIR"
mkdir -p "$WEBUI_DIR"
wget -q -O webui.zip https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip
unzip -q webui.zip
mv Yacd-meta-gh-pages/* "$WEBUI_DIR"
rm -rf Yacd-meta-gh-pages webui.zip

# ==========================================
# 5. 生成智能监控脚本 (含 TUN 检测与降级)
# ==========================================
echo -e "${GREEN}步骤 4/5: 生成自动化脚本 (Watchdog)...${PLAIN}"

# 生成 monitor.sh
cat > "$MONITOR_SCRIPT" <<EOF
#!/bin/bash
# Sing-box Watchdog - 智能 TUN/普通模式切换版

SUB_URL="$SUB_URL"
FILTER_REGEX="$FINAL_REGEX"
CONFIG_FILE="$CONFIG_FILE"
WEBUI_DIR="$WEBUI_DIR"
LOG_FILE="$LOG_FILE"
PROXY_PORT=2080
MAX_RETRIES=3
USE_CONVERSION=$USE_CONVERSION

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

urlencode() {
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "\$1"
}

# 检查代理连通性
check_proxy() {
    # 统一通过本地 HTTP 代理测试，无论是否开启 TUN，2080 端口都应存在
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --proxy http://127.0.0.1:\$PROXY_PORT https://www.google.com/generate_204)
    if [[ "\$http_code" == "204" ]]; then return 0; else return 1; fi
}

update_subscription() {
    echo "\$(timestamp) - [核心] 正在停止服务以进行无干扰更新..." >> "\$LOG_FILE"
    systemctl stop sing-box
    
    echo "\$(timestamp) - 开始下载最新订阅..." >> "\$LOG_FILE"
    
    if [[ "\$USE_CONVERSION" == "false" ]]; then
        # === 直连模式 ===
        wget --no-check-certificate -q -O /tmp/singbox_new.json "\$SUB_URL"
        if [[ -n "\$FILTER_REGEX" ]] && [[ -s /tmp/singbox_new.json ]]; then
             echo "\$(timestamp) - 执行本地过滤: \$FILTER_REGEX" >> "\$LOG_FILE"
             jq --arg re "\$FILTER_REGEX" '
                .outbounds |= map(
                    select(
                        (.type | test("Selector|URLTest|Direct|Block"; "i")) or 
                        (.tag | test(\$re; "i"))
                    )
                )
             ' /tmp/singbox_new.json > /tmp/singbox_filtered.json
             mv /tmp/singbox_filtered.json /tmp/singbox_new.json
        fi
    else
        # === API 转换模式 ===
        ENCODED_URL=\$(urlencode "\$SUB_URL")
        INCLUDE_PARAM=""
        if [[ -n "\$FILTER_REGEX" ]]; then
            ENCODED_REGEX=\$(urlencode "\$FILTER_REGEX")
            INCLUDE_PARAM="&include=\${ENCODED_REGEX}"
        fi
        API_URL="https://api.v1.mk/sub?target=sing-box&url=\${ENCODED_URL}&insert=false&config=https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Json/config.json\${INCLUDE_PARAM}"
        wget -q -O /tmp/singbox_new.json "\$API_URL"
    fi
    
    # === 关键逻辑：检测 TUN 支持 ===
    # 尝试创建 TUN 设备节点（如果不存在）
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 >/dev/null 2>&1
        chmod 600 /dev/net/tun >/dev/null 2>&1
    fi

    INBOUND_CONFIG=""
    
    if [[ -c /dev/net/tun ]]; then
        echo "\$(timestamp) - [模式] 检测到 TUN 设备，启用全局 TUN 模式。" >> "\$LOG_FILE"
        INBOUND_CONFIG='{
          "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "inet4_address": "172.19.0.1/30",
                "mtu": 1400,
                "auto_route": true,
                "strict_route": false,
                "stack": "system",
                "sniff": true
            },
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "::",
                "listen_port": 2080
            }
          ]
        }'
    else
        echo "\$(timestamp) - [模式] 未检测到 TUN 设备 (LXC/OpenVZ?)，启用标准混合端口模式。" >> "\$LOG_FILE"
        INBOUND_CONFIG='{
          "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "::",
                "listen_port": 2080
            }
          ]
        }'
    fi
    
    # 基础 WebUI 配置
    WEBUI_BASE='{
      "experimental": {
        "cache_file": { "enabled": true, "path": "cache.db" },
        "clash_api": {
          "external_controller": "0.0.0.0:9090",
          "external_ui": "/etc/sing-box/ui",
          "secret": "",
          "default_mode": "Rule",
          "access_control_allow_origin": ["*"],
          "access_control_allow_private_network": true
        }
      }
    }'

    if [[ -s /tmp/singbox_new.json ]] && jq . /tmp/singbox_new.json >/dev/null 2>&1; then
        # 1. 移除旧 inbound，准备合并
        jq 'del(.inbounds)' /tmp/singbox_new.json > /tmp/singbox_clean.json
        
        # 2. 组合 (WebUI + Inbounds)
        echo "\$WEBUI_BASE" > /tmp/webui.json
        echo "\$INBOUND_CONFIG" > /tmp/inbound.json
        jq -s '.[0] * .[1]' /tmp/webui.json /tmp/inbound.json > /tmp/config_base.json
        
        # 3. 最终合并 (订阅 + 基础配置)
        jq -s '.[0] * .[1]' /tmp/singbox_clean.json /tmp/config_base.json > /tmp/singbox_merged.json
        
        # 4. 强制锁定 Auto 组
        AUTO_TAG=\$(jq -r '.outbounds[] | select(.type=="urltest") | .tag' /tmp/singbox_merged.json | head -n 1)
        if [[ -n "\$AUTO_TAG" ]]; then
             jq --arg auto_tag "\$AUTO_TAG" '
                (
                  (.outbounds[] | select(.tag=="Proxy" and .type=="selector").default) // 
                  (.outbounds[] | select(.type=="selector").default)
                ) = \$auto_tag
             ' /tmp/singbox_merged.json > "\$CONFIG_FILE"
        else
             mv /tmp/singbox_merged.json "\$CONFIG_FILE"
        fi
        
        echo "\$(timestamp) - 配置生成完毕，尝试启动服务..." >> "\$LOG_FILE"
        systemctl start sing-box
        sleep 10 
        
        if check_proxy; then
            echo "\$(timestamp) - [成功] 服务已恢复，代理可用。" >> "\$LOG_FILE"
        else
            echo "\$(timestamp) - [失败] 新节点依然无法连通，停止服务以释放网络。" >> "\$LOG_FILE"
            systemctl stop sing-box
        fi
    else
        echo "\$(timestamp) - [错误] 订阅下载失败，保持服务关闭状态。" >> "\$LOG_FILE"
    fi
}

# 逻辑入口
if [[ "\$1" == "force" ]]; then
    update_subscription
    exit 0
fi

if systemctl is-active --quiet sing-box; then
    # 服务在运行，检查连通性
    FAIL_COUNT=0
    for ((i=1; i<=MAX_RETRIES; i++)); do
        if check_proxy; then
            exit 0 # 一切正常
        else
            FAIL_COUNT=\$((FAIL_COUNT+1))
            sleep 2
        fi
    done
    
    if [[ \$FAIL_COUNT -eq \$MAX_RETRIES ]]; then
        echo "\$(timestamp) - 检测到节点不可用，触发故障恢复流程..." >> "\$LOG_FILE"
        update_subscription
    fi
else
    # 服务停止中，尝试恢复
    echo "\$(timestamp) - 服务当前处于停止状态，尝试更新订阅并重新启动..." >> "\$LOG_FILE"
    update_subscription
fi
EOF

chmod +x "$MONITOR_SCRIPT"

# 设置 Crontab
crontab -l | grep -v "$MONITOR_SCRIPT" > /tmp/cron_bk
echo "*/5 * * * * $MONITOR_SCRIPT" >> /tmp/cron_bk 
crontab /tmp/cron_bk
rm /tmp/cron_bk

echo -e "${GREEN}监控脚本已部署：每5分钟检测一次连通性。${PLAIN}"

# ==========================================
# 6. 初次生成与启动
# ==========================================
echo -e "${GREEN}步骤 5/5: 初次生成配置并启动...${PLAIN}"

# 执行一次强制更新流程 (force 模式)
bash "$MONITOR_SCRIPT" force

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
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
systemctl disable sing-box > /dev/null 2>&1 

if command -v ufw > /dev/null; then
    ufw allow 9090/tcp >/dev/null
    ufw allow 2080/tcp >/dev/null
elif command -v firewall-cmd > /dev/null; then
    firewall-cmd --zone=public --add-port=9090/tcp --permanent >/dev/null 2>&1
    firewall-cmd --zone=public --add-port=2080/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
else
    iptables -I INPUT -p tcp --dport 9090 -j ACCEPT >/dev/null 2>&1
    iptables -I INPUT -p tcp --dport 2080 -j ACCEPT >/dev/null 2>&1
fi

IPV4=$(curl -s4m8 ip.sb)

echo -e ""
echo -e "${GREEN}=========================================${PLAIN}"
echo -e "${GREEN}           全自动部署完成！              ${PLAIN}"
echo -e "${GREEN}=========================================${PLAIN}"
echo -e "WebUI 面板:     ${BLUE}http://${IPV4}:9090/ui/${PLAIN}"
echo -e "代理端口:       ${YELLOW}2080${PLAIN} (Mixed)"
echo -e "-----------------------------------------"
echo -e "故障处理:       节点挂掉 -> 自动停止代理 -> 更新订阅 -> 尝试重启"
echo -e "筛选规则:       ${YELLOW}${FINAL_REGEX:-全部保留}${PLAIN}"
echo -e "模式自检:       脚本将自动识别是否支持 TUN"
echo -e "${GREEN}=========================================${PLAIN}"
