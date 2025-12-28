#!/usr/bin/env bash
set -euo pipefail

# sing-box 一键脚本（安装最新版 + 订阅拉取 + 节点地区识别(emoji优先) + 按地区统计/选择 + 启动）
#
# 用法：
#   sudo bash singbox-onekey.sh --sub "订阅链接"
#   sudo bash singbox-onekey.sh            # 交互输入订阅链接
#
# 输出：
#   - 按“中文名(代码)”统计节点数量（emoji 国旗优先识别）
#   - 选择地区后，保存该地区节点清单到 /etc/sing-box/selected_nodes.list
#
# 重要说明（务必看）：
# 1) 本脚本能：安装 sing-box + 统计/选择地区 + 启动本地 mixed/http/tun 代理服务。
# 2) 但：不同订阅格式（Clash/V2RayN/私有格式）要“转换成 sing-box outbounds”才可真正走代理节点。
#    - 如果你的订阅内容本身就是 sing-box 完整 JSON（包含 inbounds/outbounds），脚本会直接使用并启动（可真正代理）。
#    - 否则脚本仅生成基础配置（direct/block），并提醒你把 outbounds 替换成转换后的节点。
#
# 依赖：curl jq tar gzip unzip（可自动安装）；emoji 识别优先用 python3（可自动安装，缺失则回退中文名匹配）

INSTALL_DIR="/usr/local/bin"
SB_BIN="${INSTALL_DIR}/sing-box"
CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

WORKDIR="/tmp/singbox-installer.$$"
SUB_URL=""

cleanup(){ rm -rf "$WORKDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log(){ echo -e "[*] $*"; }
warn(){ echo -e "[!] $*" >&2; }
die(){ echo -e "[x] $*" >&2; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "需要 root 运行（sudo）。"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7|armhf) echo "armv7" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

detect_pkg_mgr() {
  if have_cmd apt-get; then echo "apt"
  elif have_cmd dnf; then echo "dnf"
  elif have_cmd yum; then echo "yum"
  elif have_cmd pacman; then echo "pacman"
  elif have_cmd apk; then echo "apk"
  else echo "unknown"
  fi
}

install_deps() {
  local pm; pm="$(detect_pkg_mgr)"
  log "包管理器: $pm"
  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y curl ca-certificates tar gzip jq unzip coreutils python3 >/dev/null || \
        apt-get install -y curl ca-certificates tar gzip jq unzip coreutils >/dev/null
      ;;
    dnf)
      dnf install -y curl ca-certificates tar gzip jq unzip coreutils python3 >/dev/null || \
        dnf install -y curl ca-certificates tar gzip jq unzip coreutils >/dev/null
      ;;
    yum)
      yum install -y curl ca-certificates tar gzip jq unzip coreutils python3 >/dev/null || \
        yum install -y curl ca-certificates tar gzip jq unzip coreutils >/dev/null
      ;;
    pacman)
      pacman -Sy --noconfirm curl ca-certificates tar gzip jq unzip coreutils python >/dev/null || \
        pacman -Sy --noconfirm curl ca-certificates tar gzip jq unzip coreutils >/dev/null
      ;;
    apk)
      apk add --no-cache curl ca-certificates tar gzip jq unzip coreutils python3 >/dev/null || \
        apk add --no-cache curl ca-certificates tar gzip jq unzip coreutils >/dev/null
      ;;
    *)
      die "未知包管理器，无法自动安装依赖。请手动安装 curl ca-certificates tar gzip jq unzip（可选 python3）"
      ;;
  esac
}

github_latest_tag() {
  curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name
}

download_and_install_singbox() {
  mkdir -p "$WORKDIR"
  local arch tag asset url extracted
  arch="$(detect_arch)"
  tag="$(github_latest_tag)"
  asset="sing-box-${tag#v}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset}"

  log "最新版本: $tag"
  log "下载: $url"
  curl -fL --retry 3 --retry-delay 1 -o "${WORKDIR}/${asset}" "$url"

  log "解压安装..."
  tar -xzf "${WORKDIR}/${asset}" -C "$WORKDIR"
  extracted="$(find "$WORKDIR" -maxdepth 1 -type d -name "sing-box-*-linux-${arch}" | head -n1 || true)"
  [[ -n "$extracted" ]] || die "解压后未找到 sing-box 目录"
  install -m 0755 "${extracted}/sing-box" "$SB_BIN"
  "$SB_BIN" version || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sub) SUB_URL="${2:-}"; shift 2 ;;
      --sub=*) SUB_URL="${1#*=}"; shift 1 ;;
      *) warn "未知参数: $1（忽略）"; shift 1 ;;
    esac
  done
}

prompt_sub() {
  if [[ -z "$SUB_URL" ]]; then
    read -r -p "请输入订阅链接: " SUB_URL
  fi
  [[ -n "$SUB_URL" ]] || die "订阅链接不能为空"
}

fetch_sub() {
  mkdir -p "$WORKDIR"
  log "拉取订阅..."
  curl -fsSL -A "Mozilla/5.0 singbox-onekey" -H "Accept: */*" \
    --retry 3 --retry-delay 1 "$SUB_URL" > "${WORKDIR}/sub.raw"
  [[ -s "${WORKDIR}/sub.raw" ]] || die "订阅内容为空或拉取失败"
}

is_base64_like() {
  local f="$1"
  if grep -qE 'proxies:|outbounds|inbounds|{|\bproxy-groups:' "$f"; then return 1; fi
  local non
  non="$(tr -d 'A-Za-z0-9+/=\r\n' < "$f" | wc -c | awk '{print $1}')"
  [[ "${non:-0}" -lt 5 ]]
}

decode_if_needed() {
  if is_base64_like "${WORKDIR}/sub.raw"; then
    log "可能是 Base64 订阅，尝试解码..."
    tr '_-' '/+' < "${WORKDIR}/sub.raw" | base64 -d 2>/dev/null > "${WORKDIR}/sub.txt" || true
    if [[ ! -s "${WORKDIR}/sub.txt" ]]; then
      tr -d '\n\r ' < "${WORKDIR}/sub.raw" | tr '_-' '/+' | base64 -d 2>/dev/null > "${WORKDIR}/sub.txt" || true
    fi
    [[ -s "${WORKDIR}/sub.txt" ]] || die "Base64 解码失败"
  else
    cp -f "${WORKDIR}/sub.raw" "${WORKDIR}/sub.txt"
  fi
}

extract_node_names() {
  local in="${WORKDIR}/sub.txt"
  local out="${WORKDIR}/nodes.list"
  : > "$out"

  # Clash YAML: name:
  grep -oE '^[[:space:]-]*name:[[:space:]]*.*$' "$in" \
    | sed -E 's/^[[:space:]-]*name:[[:space:]]*//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' \
    >> "$out" || true

  # sing-box JSON: "tag": "..."
  grep -oE '"tag"[[:space:]]*:[[:space:]]*"[^"]+"' "$in" \
    | sed -E 's/.*"tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
    >> "$out" || true

  # URI: 协议://...#备注
  grep -oE '(vmess|vless|trojan|ss|hysteria2|tuic|ssr)://[^[:space:]]+' "$in" \
    | sed -E 's/.*#(.*)$/\1/; t; s/.*/(no-name)/' \
    | sed -E 's/%20/ /g; s/%7C/|/g; s/%2D/-/g; s/%5B/\[/g; s/%5D/\]/g' \
    >> "$out" || true

  # 去空去重
  sed -i -E 's/\r$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$out" 2>/dev/null || true
  grep -vE '^\s*$' "$out" | sort -u > "${out}.tmp" || true
  mv -f "${out}.tmp" "$out"

  local n; n="$(wc -l < "$out" | awk '{print $1}')"
  [[ "${n:-0}" -gt 0 ]] || die "未识别到节点名称"
  log "节点数量: $n"
}

# ====== 地区映射（中文名 -> 代码）：你给的完整表 ======
read -r -d '' REGION_MAP_TSV <<'TSV'
中华人民共和国	CH
中非	CT
智利	CI
直布罗陀	GI
乍得	CD
扎伊尔	ZA
泽西	JE
赞比亚	ZA
越南	VM
约旦	JO
英属印度洋领地	IO
英属维尔京群岛	VI
英国	UK
印度尼西亚	ID
印度	IN
意大利	IT
以色列	IS
伊朗	IR
伊拉克	IZ
也门	YM
亚美尼亚	AM
牙买加	JM
叙利亚	SY
匈牙利	HU
新西兰	NZ
新喀里多尼亚	NC
新加坡	SN
香港	HK
希腊	GR
西印度群岛联邦	WI
西撒哈拉	WI
西班牙	SP
乌兹别克斯坦	UZ
乌拉圭	UY
乌克兰	UP
乌干达	UG
文莱	BX
委内瑞拉	VE
危地马拉	GT
瓦努阿图	NH
瓦利斯和富图纳	WF
托克劳	TL
土库曼斯坦	TX
土耳其	TU
图瓦卢	TV
突尼斯	TS
特立尼达和多巴哥	TD
特克斯和凯科斯群岛	TK
汤加	TN
坦桑尼亚	TZ
泰国	TH
台湾	TW
塔吉克斯坦	TI
索马里	SO
所罗门群岛	BP
苏联	UR
苏里南	NS
苏丹	SU
斯威士兰	WZ
斯洛文尼亚	SI
斯洛伐克	LO
斯里兰卡	CE
圣文森特和格林纳丁斯	VC
圣皮埃尔和密克隆	SB
圣马力诺	SM
圣卢西亚	ST
圣基茨和尼维斯	SC
圣赫勒拿、阿森松和特里斯坦-达库尼亚	SH
圣多美和普林西比	TP
圣诞岛	KT
圣巴泰勒米	TB
上沃尔特	VO
沙特阿拉伯	SA
塞舌尔	SE
塞浦路斯	CY
塞内加尔	SG
塞拉利昂	SL
塞尔维亚和黑山	SC
塞尔维亚	RI
萨摩亚	WS
萨尔瓦多	ES
瑞士	SZ
瑞典	SW
日本	JA
葡萄牙	PO
皮特凯恩群岛	PC
帕劳	PS
欧洲联盟	EU
诺福克岛	NF
挪威	NO
纽埃	NE
尼日利亚	NI
尼日尔	NG
尼泊尔	NP
尼加拉瓜	NU
瑙鲁	NR
南苏丹	OD
南斯拉夫	YU
南乔治亚和南桑威奇群岛	SX
南极洲	AY
南非	SF
纳米比亚	WA
墨西哥	MX
莫桑比克	MZ
摩纳哥	MN
摩洛哥	MO
摩尔多瓦	MD
缅甸	BM
密克罗尼西亚联邦	FM
秘鲁	PE
孟加拉国	BG
蒙特塞拉特	MH
蒙古国	MG
美属维尔京群岛	VQ
美属萨摩亚	AQ
美国本土外小岛屿	UM
美国	US
毛里塔尼亚	MR
毛里求斯	MP
马约特	MF
马提尼克	MB
马绍尔群岛	RM
马里	ML
马来西亚	MY
马拉维	MI
马耳他	MT
马尔代夫	MV
马恩岛	IM
马达加斯加	MA
罗马尼亚	RO
罗得西亚	RH
卢旺达	RW
卢森堡	LU
留尼汪	RE
列支敦士登	LS
联合国	UN
利比亚	LY
利比里亚	LI
立陶宛	LH
黎巴嫩	LE
老挝	LA
莱索托	LT
拉脱维亚	LG
库拉索	UC
库克群岛	CW
肯尼亚	KE
克罗地亚	HR
科威特	KU
科特迪瓦	IV
科索沃	KV
科摩罗	CN
科科斯（基林）群岛	CK
开曼群岛	CJ
卡塔尔	QA
喀麦隆	CM
津巴布韦	ZI
捷克斯洛伐克	TC
捷克	EZ
柬埔寨	CB
加蓬	GB
加纳	GH
加拿大	CA
几内亚比绍	PU
几内亚	GV
吉尔吉斯斯坦	KG
吉布提	DJ
基里巴斯	KR
洪都拉斯	HO
黑山	MJ
赫德岛和麦克唐纳群岛	HM
荷属圣马丁	NN
荷属安的列斯	NT
荷兰	NL
韩国	KS
海地	HA
哈萨克斯坦	KZ
圭亚那	GY
关岛	GQ
瓜德罗普	GP
古巴	CU
根西	GK
格鲁吉亚	GG
格陵兰	GL
格林纳达	GJ
哥斯达黎加	CS
哥伦比亚	CO
刚果民主共和国	CG
刚果共和国	CF
冈比亚	GA
福克兰群岛	FK
佛得角	CV
芬兰	FI
斐济	FJ
菲律宾	RP
非洲联盟	AU
梵蒂冈	VT
法属圣马丁	RN
法属南部和南极领地	FS
法属圭亚那	FG
法属波利尼西亚	FP
法罗群岛	FO
法国本土	FX
法国	FR
厄立特里亚	ER
厄瓜多尔	EC
俄罗斯	RS
多米尼克	DO
多米尼加	DR
多哥	TO
独立国家联合体	EN
东南亚国家联盟	ASEAN
东帝汶	TT
德国	GM
丹麦	DA
达荷美	DA
赤道几内亚	EK
朝鲜	KN
布韦岛	BV
布隆迪	BY
布基纳法索	UV
不丹	BT
博茨瓦纳	BC
伯利兹	BH
玻利维亚	BL
波希米亚	BO
波兰	PL
波黑	BK
波多黎各	RQ
冰岛	IC
比利时	BE
贝宁	BN
北马其顿	MK
北马里亚纳群岛	CQ
保加利亚	BU
百慕大	BD
白俄罗斯	BO
巴西	BR
巴拿马	PM
巴林	BA
巴勒斯坦	GZ
巴勒斯坦	WE
巴拉圭	PA
巴基斯坦	PK
巴哈马	BF
巴布亚新几内亚	PP
巴巴多斯	BB
澳门	MC
澳大利亚	AS
澳大拉西亚	AN
奥地利	AU
安提瓜和巴布达	AC
安圭拉	AV
安哥拉	AO
安道尔	AN
爱沙尼亚	EN
爱尔兰	EI
埃塞俄比亚	ET
埃及	EG
阿塞拜疆	AJ
阿曼	MU
阿鲁巴	AA
阿联酋	AE
阿拉伯联合共和国	UA
阿根廷	AR
阿富汗	AF
阿尔及利亚	AG
阿尔巴尼亚	AL
TSV

# ====== emoji 国旗识别：取第一个国旗，转 ISO2（如 HK/US/JP）=====
detect_iso2_from_emoji() {
  local s="$1"
  if have_cmd python3; then
    python3 - "$s" <<'PY'
import sys, re
s=sys.argv[1]
m = re.findall(r'[\U0001F1E6-\U0001F1FF]{2}', s)
if not m:
    sys.exit(0)
flag = m[0]
iso2 = "".join(chr(ord(c)-0x1F1E6+ord('A')) for c in flag)
print(iso2)
PY
  elif have_cmd python; then
    python - "$s" <<'PY'
import sys, re
s=sys.argv[1]
m = re.findall(u'[\U0001F1E6-\U0001F1FF]{2}', s)
if not m:
    sys.exit(0)
flag = m[0]
iso2 = u"".join(unichr(ord(c)-0x1F1E6+ord('A')) for c in flag)
print(iso2)
PY
  else
    echo ""
  fi
}

# ISO2 -> 你表内代码（你的代码并非 ISO，做兼容映射）
iso2_to_table_code() {
  local iso2="${1:-}"
  case "$iso2" in
    CN) echo "CH" ;;
    JP) echo "JA" ;;
    KR) echo "KS" ;;
    SG) echo "SN" ;;
    GB) echo "UK" ;;
    TR) echo "TU" ;;
    ZA) echo "SF" ;;  # 你表里“南非=SF”（同时 ZA 也给了扎伊尔/赞比亚；这里按常见 emoji ZA=南非优先）
    *)  echo "$iso2" ;;
  esac
}

# 从中文表匹配代码（最长中文名优先）
detect_code_from_cnmap() {
  local s="$1"
  awk -v s="$s" '
    function trim(x){ sub(/^[ \t\r\n]+/,"",x); sub(/[ \t\r\n]+$/,"",x); return x }
    BEGIN{
      n=0; max=0
      while ((getline line < "/dev/stdin") > 0) {
        line=trim(line); if(line==""||line~ /^#/) continue
        split(line,a,"\t"); k=trim(a[1]); v=trim(a[2])
        if(k!="" && v!=""){ keys[++n]=k; vals[n]=v; if(length(k)>max) max=length(k) }
      }
      for (L=max; L>=1; L--){
        for(i=1;i<=n;i++){
          if(length(keys[i])!=L) continue
          if(index(s, keys[i])) { print vals[i]; exit }
        }
      }
      print ""
    }
  ' <<<"$REGION_MAP_TSV"
}

code_to_cnname() {
  local code="$1"
  awk -F'\t' -v c="$code" '$2==c {print $1; exit}' <<<"$REGION_MAP_TSV"
}

detect_region_label() {
  local name="$1"
  local iso2 code cn

  # 1) emoji 优先
  iso2="$(detect_iso2_from_emoji "$name" || true)"
  if [[ -n "${iso2:-}" ]]; then
    code="$(iso2_to_table_code "$iso2")"
    cn="$(code_to_cnname "$code" 2>/dev/null || true)"
    if [[ -n "${cn:-}" ]]; then
      echo "${cn}(${code})"
      return
    fi
  fi

  # 2) 中文表匹配回退
  code="$(detect_code_from_cnmap "$name")"
  if [[ -z "${code:-}" ]]; then
    echo "其他(OTHER)"
    return
  fi
  cn="$(code_to_cnname "$code" 2>/dev/null || true)"
  [[ -n "${cn:-}" ]] || cn="$code"
  echo "${cn}(${code})"
}

region_stats_and_pick_and_save() {
  local nodes="${WORKDIR}/nodes.list"
  declare -A cnt
  declare -A sample

  while IFS= read -r name; do
    local label
    label="$(detect_region_label "$name")"
    ((cnt["$label"]++))
    [[ -n "${sample[$label]:-}" ]] || sample["$label"]="$name"
  done < "$nodes"

  log "按国家/地区统计（最终显示：中文名(代码)，emoji 国旗优先识别）："
  mapfile -t lines < <(
    for k in "${!cnt[@]}"; do
      printf "%s\t%d\n" "$k" "${cnt[$k]}"
    done | sort -k2,2nr -k1,1
  )

  local i=1
  for line in "${lines[@]}"; do
    local label num
    label="$(awk -F'\t' '{print $1}' <<<"$line")"
    num="$(awk -F'\t' '{print $2}' <<<"$line")"
    printf "%2d. %s (%d)\n" "$i" "$label" "$num"
    ((i++))
  done

  local total="${#lines[@]}"
  echo
  read -r -p "请选择地区编号 (1-${total}): " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "输入不是数字"
  (( idx>=1 && idx<=total )) || die "编号超出范围"

  local chosen_label
  chosen_label="$(awk -F'\t' '{print $1}' <<<"${lines[$((idx-1))]}")"
  log "你选择的地区: $chosen_label"

  mkdir -p "$CONF_DIR"
  local selected="${CONF_DIR}/selected_nodes.list"
  : > "$selected"
  while IFS= read -r name; do
    [[ "$(detect_region_label "$name")" == "$chosen_label" ]] && echo "$name" >> "$selected"
  done < "$nodes"
  log "已保存该地区节点清单: $selected（$(wc -l < "$selected" | awk '{print $1}') 条）"
}

write_config_and_service() {
  mkdir -p "$CONF_DIR"
  local sub="${WORKDIR}/sub.txt"

  if jq -e . >/dev/null 2>&1 < "$sub" && jq -e '.outbounds and .inbounds' >/dev/null 2>&1 < "$sub"; then
    log "检测到 sing-box 完整 JSON 配置订阅：直接写入并启动。"
    cp -f "$sub" "$CONF_FILE"
  else
    log "订阅不是 sing-box 完整 JSON：生成基础配置（需将订阅转换为 sing-box outbounds 才能真正走节点）。"
    cat > "$CONF_FILE" <<'JSON'
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "google", "address": "8.8.8.8" },
      { "tag": "cloudflare", "address": "1.1.1.1" }
    ],
    "final": "google"
  },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 1080, "sniff": true },
    { "type": "http",  "tag": "http-in",  "listen": "127.0.0.1", "listen_port": 8080, "sniff": true },
    { "type": "tun",   "tag": "tun-in",   "interface_name": "singbox0", "inet4_address": "172.19.0.1/30",
      "mtu": 9000, "auto_route": true, "strict_route": false, "sniff": true }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block" }
  ],
  "route": { "auto_detect_interface": true, "final": "direct" }
}
JSON
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now sing-box
}

main() {
  need_root
  parse_args "$@"
  install_deps
  download_and_install_singbox

  prompt_sub
  fetch_sub
  decode_if_needed
  extract_node_names

  region_stats_and_pick_and_save
  write_config_and_service

  log "服务状态："
  systemctl --no-pager --full status sing-box || true
  log "本地代理：socks5 127.0.0.1:1080；http 127.0.0.1:8080"
  log "TUN 已写入配置（透明代理）。"
  warn "提示：若订阅不是 sing-box JSON，需要把订阅转换成 sing-box outbounds 并替换 /etc/sing-box/config.json 才能真正走代理节点。"
}

main "$@"
