#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions for logging
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# Automatically update your CloudFlare DNS record to the IP, Dynamic DNS
# Can retrieve cloudflare Domain id and list zone's, because, lazy

# Usage:
# ./cf-v4-ddns.sh install      # Run the interactive installer
#
# Or manual usage:
# cf-ddns.sh -k cloudflare-api-key \
#            -u user@example.com \
#            -h host.example.com \     # fqdn of the record you want to update
#            -t A|AAAA                 # specify ipv4/ipv6, default: ipv4
#
# The zone (main domain) is detected automatically from -h, so -z is no longer
# required. It is still accepted as an explicit override.

# Optional flags:
#            -z example.com \          # zone override, auto-detected when omitted
#            -f false|true \           # force dns update, disregard local stored ip

# Changelog:
#   v2.3 - Zone auto-detection: only the full DDNS hostname is asked, -z optional.
#   v2.2 - Telegram notifications, IPv6 support, install mode.

# ==============================================================================
# INSTALLATION MODE
# ==============================================================================
if [ "${1:-}" = "install" ]; then
    # Remove 'install' from arguments so we can parse flags
    shift

    # Configuration
    INSTALL_DIR="/usr/local/bin"
    SCRIPT_NAME="cf-ddns.sh"
    TARGET_PATH="$INSTALL_DIR/$SCRIPT_NAME"
    LOG_FILE="/var/log/cf-ddns.log"

    # Initialize variables
    CFKEY=""
    CFUSER=""
    CFZONE_NAME=""
    CFRECORD_NAME=""
    CFRECORD_TYPE=""
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""

    # Parse command line arguments for install mode
    while getopts k:u:h:z:t:T:I: opts; do
      case ${opts} in
        k) CFKEY=${OPTARG} ;;
        u) CFUSER=${OPTARG} ;;
        h) CFRECORD_NAME=${OPTARG} ;;
        z) CFZONE_NAME=${OPTARG} ;;
        t) CFRECORD_TYPE=${OPTARG} ;;
        T) TG_BOT_TOKEN=${OPTARG} ;;
        I) TG_CHAT_ID=${OPTARG} ;;
      esac
    done

    # 非交互环境（无 TERM）下 clear 会返回非零，别让 errexit 把脚本干掉
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       Cloudflare DDNS 一键安装脚本 (v2.3)                  ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # Check Root
    if [[ $EUID -ne 0 ]]; then
       log_error "此脚本必须以 root 身份运行。" 
       exit 1
    fi

    # Install Dependencies
    log_info "正在检查依赖..."
    
    # Function to install packages
    install_package() {
        local package=$1
        if command -v "$package" &> /dev/null; then
            return 0
        fi
        
        log_warn "未找到 $package。正在安装..."
        
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y "$package"
        elif [ -x "$(command -v dnf)" ]; then
            dnf install -y "$package"
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "$package"
        elif [ -x "$(command -v apk)" ]; then
            apk add --no-cache "$package"
        elif [ -x "$(command -v pacman)" ]; then
            pacman -Syu --noconfirm "$package"
        elif [ -x "$(command -v zypper)" ]; then
            zypper install -y "$package"
        else
            log_error "无法安装 $package。请手动安装。"
            return 1
        fi
    }

    # Check and install curl
    if ! install_package "curl"; then
        exit 1
    fi
    
    # Check and install grep (some minimal systems might need full grep, but usually present)
    # We rely on grep -o, which is standard in most modern grep implementations including busybox
    
    log_success "依赖检查通过。"

    # Gather Information
    echo ""
    echo -e "${YELLOW}请输入您的 Cloudflare 配置信息：${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"

    if [[ -z "$CFKEY" ]]; then
        read -p "Cloudflare API Key (Global API Key): " CFKEY
        while [[ -z "$CFKEY" ]]; do
            log_error "API Key 不能为空。"
            read -p "Cloudflare API Key: " CFKEY
        done
    else
        log_info "API Key 已提供。"
    fi

    if [[ -z "$CFUSER" ]]; then
        read -p "Cloudflare 邮箱 (Email): " CFUSER
        while [[ -z "$CFUSER" ]]; do
            log_error "邮箱不能为空。"
            read -p "Cloudflare 邮箱: " CFUSER
        done
    else
        log_info "邮箱已提供: $CFUSER"
    fi

    if [[ -z "$CFRECORD_NAME" ]]; then
        read -p "DDNS 域名 (完整域名, 例如 ddns.example.com): " CFRECORD_NAME
        while [[ -z "$CFRECORD_NAME" ]]; do
            log_error "DDNS 域名不能为空。"
            read -p "DDNS 域名: " CFRECORD_NAME
        done
    else
        log_info "DDNS 域名已提供: $CFRECORD_NAME"
    fi

    # FQDN 校验：主域名将从这里自动推导，只输入主机名无法识别
    CFRECORD_NAME="${CFRECORD_NAME%.}"
    while [[ "$CFRECORD_NAME" != *.* ]]; do
        log_error "请输入完整域名，例如 ddns.example.com（主域名将自动识别）。"
        read -p "DDNS 域名 (完整域名): " CFRECORD_NAME
        CFRECORD_NAME="${CFRECORD_NAME%.}"
    done

    if [[ -n "$CFZONE_NAME" ]]; then
        log_info "主域名已手动指定: $CFZONE_NAME"
    else
        log_info "主域名无需输入，将从 $CFRECORD_NAME 自动识别。"
    fi

    if [[ -z "$CFRECORD_TYPE" ]]; then
        read -p "记录类型 (A 为 IPv4, AAAA 为 IPv6) [默认: A]: " CFRECORD_TYPE
        CFRECORD_TYPE=${CFRECORD_TYPE:-A}
    else
        log_info "记录类型已提供: $CFRECORD_TYPE"
    fi

    if [[ "$CFRECORD_TYPE" != "A" && "$CFRECORD_TYPE" != "AAAA" ]]; then
        log_warn "无效的记录类型。默认使用 A (IPv4)。"
        CFRECORD_TYPE="A"
    fi

    if [[ -z "$TG_BOT_TOKEN" ]]; then
        read -p "Telegram Bot Token (可选，留空跳过): " TG_BOT_TOKEN
    else
        log_info "Telegram Bot Token 已提供。"
    fi

    if [[ -n "$TG_BOT_TOKEN" && -z "$TG_CHAT_ID" ]]; then
        read -p "Telegram Chat ID: " TG_CHAT_ID
        while [[ -z "$TG_CHAT_ID" ]]; do
            log_error "Chat ID 不能为空。"
            read -p "Telegram Chat ID: " TG_CHAT_ID
        done
    elif [[ -n "$TG_CHAT_ID" ]]; then
        log_info "Telegram Chat ID 已提供: $TG_CHAT_ID"
    fi
    # Cleanup Old Config/Cache
    log_info "正在清理旧配置和缓存..."
    # Remove cache files for the specific host being configured
    rm -f "$HOME/.cf-id_$CFRECORD_NAME.txt"
    rm -f "$HOME/.cf-wan_ip_$CFRECORD_NAME.txt"
    # Remove old log file if exists
    rm -f "$LOG_FILE"
    # Remove old script if exists
    rm -f "$TARGET_PATH"

    # Install Script
    echo ""
    log_info "正在安装脚本到 $TARGET_PATH..."
    # Resolve absolute path of current script
    if [[ "$0" = /* ]]; then
        SCRIPT_PATH="$0"
    else
        SCRIPT_PATH="$PWD/$0"
    fi
    
    cp "$SCRIPT_PATH" "$TARGET_PATH"
    chmod +x "$TARGET_PATH"
    log_success "脚本安装完成。"

    # Configure Cron
    log_info "正在配置定时任务 (Crontab)..."
    CRON_CMD="$TARGET_PATH -k $CFKEY -u $CFUSER -h $CFRECORD_NAME -t $CFRECORD_TYPE"
    # 仅在手动指定主域名时才写入 -z，其余交给脚本自动识别
    if [ -n "$CFZONE_NAME" ]; then
        CRON_CMD="$CRON_CMD -z $CFZONE_NAME"
    fi
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        CRON_CMD="$CRON_CMD -T $TG_BOT_TOKEN -I $TG_CHAT_ID"
    fi
    # Redirect to /dev/null to avoid log file usage
    CRON_CMD="$CRON_CMD > /dev/null 2>&1"
    
    JOB="*/1 * * * * $CRON_CMD"

    # Remove existing job for this script to prevent duplicates
    log_info "正在清理 Crontab 中旧的本脚本任务 (保留其他任务)..."
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TMP_CRON" || true
    # Use grep -F -v to match fixed string (not regex) and invert match
    # This ensures we only remove lines containing the exact script path
    grep -F -v "$TARGET_PATH" "$TMP_CRON" > "$TMP_CRON.new" || true
    mv "$TMP_CRON.new" "$TMP_CRON"

    # Add new job
    echo "$JOB" >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm "$TMP_CRON"
    log_success "定时任务配置完成。"

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}   安装成功！                                               ${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo -e "  脚本路径 : ${CYAN}$TARGET_PATH${NC}"
    echo -e "  日志     : ${CYAN}已禁用 (仅 Telegram 通知)${NC}"
    echo -e "  运行频率 : ${CYAN}每分钟${NC}"
    echo ""
    log_info "正在运行第一次更新..."

    # Run immediately
    RUN_CMD="$TARGET_PATH -k $CFKEY -u $CFUSER -h $CFRECORD_NAME -t $CFRECORD_TYPE -f true"
    if [ -n "$CFZONE_NAME" ]; then
        RUN_CMD="$RUN_CMD -z $CFZONE_NAME"
    fi
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        RUN_CMD="$RUN_CMD -T $TG_BOT_TOKEN -I $TG_CHAT_ID"
    fi
    # errexit 下必须用 if 包住，否则失败会直接中断而看不到提示
    if $RUN_CMD; then
        log_success "首次更新成功！"
    else
        log_error "首次更新失败。请检查上方日志，或手动执行: $RUN_CMD"
        exit 1
    fi
    
    exit 0
fi

# ==============================================================================
# DDNS LOGIC
# ==============================================================================

# default config

# API key, see https://www.cloudflare.com/a/account/my-account,
# incorrect api-key results in E_UNAUTH error
CFKEY=

# Username, eg: user@example.com
CFUSER=

# Zone name, eg: example.com
# Leave empty to auto-detect it from CFRECORD_NAME
CFZONE_NAME=

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=

# Resolved identifiers (filled in by the cache or the API)
CFZONE_ID=""
CFRECORD_ID=""

# Record type, A(IPv4)|AAAA(IPv6), default IPv4
CFRECORD_TYPE=A

# Cloudflare TTL for record, between 120 and 86400 seconds
CFTTL=120

# Ignore local file, update ip anyway
FORCE=false

# Telegram Bot Config
TG_BOT_TOKEN=""
TG_CHAT_ID=""

send_telegram() {
  local message="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="HTML" > /dev/null
  fi
}

# Cloudflare API GET helper, keeps auth headers in one place
cf_api_get() {
  curl -s --max-time 20 -X GET "https://api.cloudflare.com/client/v4/$1" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" || true
}

# First "id" value found in a Cloudflare JSON response
json_first_id() {
  printf '%s' "$1" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true
}

# First "message" value found in a Cloudflare JSON response
json_first_message() {
  printf '%s' "$1" | grep -o '"message":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true
}

# Derive the zone that owns a FQDN. Candidates are probed from the most
# specific name down to the TLD, so zones like example.co.uk work too.
# Sets CFZONE_NAME / CFZONE_ID on success, returns 1 when nothing matches.
resolve_zone_from_hostname() {
  local host="$1"
  local candidate="$host"
  local response zone_id

  while [[ "$candidate" == *.* ]]; do
    response=$(cf_api_get "zones?name=$candidate&per_page=1")
    zone_id=$(json_first_id "$response")

    if [ -n "$zone_id" ]; then
      CFZONE_NAME="$candidate"
      CFZONE_ID="$zone_id"
      return 0
    fi

    if [ -z "$response" ]; then
      log_error "无法连接 Cloudflare API，请检查服务器网络。"
      send_telegram "Cloudflare DDNS 配置失败！无法连接 Cloudflare API。"
      exit 1
    fi

    if printf '%s' "$response" | grep -q '"success":false'; then
      log_error "Cloudflare API 返回错误: $(json_first_message "$response")"
      log_error "响应内容: $response"
      log_error "常见原因: 1. 使用了 API Token 而不是 Global Key; 2. 邮箱与 Key 不匹配"
      send_telegram "Cloudflare DDNS 配置失败！API 报错: <pre>$response</pre>"
      exit 1
    fi

    candidate="${candidate#*.}"
  done
  return 1
}

WANIPSITE="http://ipv4.icanhazip.com"

# Site to retrieve WAN ip, other examples are: bot.whatismyipaddress.com, https://api.ipify.org/ ...
if [ "${1:-}" != "" ] && [ "${1:0:1}" != "-" ]; then
    # If first arg is not a flag and not 'install' (handled above), it might be a mistake or old usage
    # But since we use getopts, we just proceed.
    :
fi

# get parameter
while getopts k:u:h:z:t:f:T:I: opts; do
  case ${opts} in
    k) CFKEY=${OPTARG} ;;
    u) CFUSER=${OPTARG} ;;
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
    f) FORCE=${OPTARG} ;;
    T) TG_BOT_TOKEN=${OPTARG} ;;
    I) TG_CHAT_ID=${OPTARG} ;;
  esac
done

# If required settings are missing just exit
if [ "$CFKEY" = "" ]; then
  log_error "缺少 API Key，请在 https://www.cloudflare.com/a/account/my-account 获取"
  log_error "并保存到 ${0} 或使用 -k 参数"
  exit 2
fi
if [ "$CFUSER" = "" ]; then
  log_error "缺少用户名，通常是您的邮箱地址"
  log_error "并保存到 ${0} 或使用 -u 参数"
  exit 2
fi
if [ "$CFRECORD_NAME" = "" ]; then 
  log_error "缺少主机名，您想要更新哪个主机？"
  log_error "保存到 ${0} 或使用 -h 参数"
  exit 2
fi

# The hostname must be a FQDN: the zone is derived from it, so a bare label
# such as "homeserver" can no longer be expanded
CFRECORD_NAME="${CFRECORD_NAME%.}"
if [[ "$CFRECORD_NAME" != *.* ]]; then
  log_error "主机名必须是完整域名 (例如 ddns.example.com)，无法从 '$CFRECORD_NAME' 识别主域名"
  exit 2
fi

# Determine WAN IP Site based on record type
if [ "$CFRECORD_TYPE" = "A" ]; then
  WANIPSITE="http://ipv4.icanhazip.com"
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  log_error "$CFRECORD_TYPE 指定无效，CFRECORD_TYPE 只能是 A(IPv4) 或 AAAA(IPv6)"
  exit 2
fi

# Get current and old WAN ip
WAN_IP=`curl -s --max-time 20 "${WANIPSITE}"`

# Never push an empty record to Cloudflare
if [ -z "$WAN_IP" ]; then
  log_error "获取公网 IP 失败，请检查 ${WANIPSITE} 是否可访问"
  exit 1
fi

WAN_IP_FILE=$HOME/.cf-wan_ip_$CFRECORD_NAME.txt
if [ -f $WAN_IP_FILE ]; then
  OLD_WAN_IP=`cat $WAN_IP_FILE`
else
  log_info "没有本地 IP 记录，需要获取 IP"
  OLD_WAN_IP=""
fi

# If WAN IP is unchanged an not -f flag, exit here
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  log_info "WAN IP 未改变，如需强制更新请使用 -f true 参数"
  exit 0
fi

# Get zone_identifier & record_identifier
ID_FILE=$HOME/.cf-id_$CFRECORD_NAME.txt

# Reuse cached IDs. The zone is read back from the cache as well, so the
# auto-detection below only runs once per hostname.
if [ -f "$ID_FILE" ] && [ "$(wc -l < "$ID_FILE" | tr -d '[:space:]')" = "4" ]; then
  CACHED_ZONE=$(sed -n '3p' "$ID_FILE")
  CACHED_HOST=$(sed -n '4p' "$ID_FILE")
  if [ "$CACHED_HOST" = "$CFRECORD_NAME" ] \
    && [ -n "$CACHED_ZONE" ] \
    && { [ -z "$CFZONE_NAME" ] || [ "$CFZONE_NAME" = "$CACHED_ZONE" ]; } \
    && [ -n "$(sed -n '1p' "$ID_FILE")" ] \
    && [ -n "$(sed -n '2p' "$ID_FILE")" ]; then
      CFZONE_ID=$(sed -n '1p' "$ID_FILE")
      CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
      CFZONE_NAME="$CACHED_ZONE"
  fi
fi

if [ -z "$CFZONE_ID" ]; then
    log_info "正在解析主域名与记录 ID..."

    if [ -z "$CFZONE_NAME" ]; then
        log_info "正在从 $CFRECORD_NAME 自动识别主域名..."
        if ! resolve_zone_from_hostname "$CFRECORD_NAME"; then
            log_error "在您的 Cloudflare 账号中找不到 $CFRECORD_NAME 对应的主域名。"
            log_error "请确认该域名已添加到当前账号，或使用 -z 参数手动指定主域名。"
            send_telegram "Cloudflare DDNS 配置失败！无法从 $CFRECORD_NAME 识别主域名。"
            exit 1
        fi
        log_success "已识别主域名: $CFZONE_NAME"
    else
        log_info "使用指定的主域名: $CFZONE_NAME"
        ZONE_RESPONSE=$(cf_api_get "zones?name=$CFZONE_NAME&per_page=1")
        CFZONE_ID=$(json_first_id "$ZONE_RESPONSE")

        if [ -z "$CFZONE_ID" ]; then
            log_error "获取 Zone ID 失败！"
            log_error "Cloudflare API 响应内容: $ZONE_RESPONSE"
            log_error "请根据上方响应内容检查原因 (如 6003=Headers无效, 9103=未知错误等)"
            log_error "常见原因: 1. 使用了 API Token 而不是 Global Key; 2. 邮箱与 Key 不匹配; 3. 域名未在账号下激活"
            send_telegram "Cloudflare DDNS 配置失败！无法获取 Zone ID。响应: <pre>$ZONE_RESPONSE</pre>"
            exit 1
        fi
    fi

    # Get Record ID, &type=$CFRECORD_TYPE keeps the match on the right record type
    RECORD_RESPONSE=$(cf_api_get "zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME&type=$CFRECORD_TYPE")
    CFRECORD_ID=$(json_first_id "$RECORD_RESPONSE")

    if [ -z "$CFRECORD_ID" ]; then
        log_warn "未找到现有的 $CFRECORD_TYPE 记录，准备创建新记录。"
        log_warn "查询域名: $CFRECORD_NAME"
        log_warn "API 响应: $RECORD_RESPONSE"
    else
        log_info "找到现有记录 ID: $CFRECORD_ID"
    fi

    echo "$CFZONE_ID" > "$ID_FILE"
    echo "$CFRECORD_ID" >> "$ID_FILE"
    echo "$CFZONE_NAME" >> "$ID_FILE"
    echo "$CFRECORD_NAME" >> "$ID_FILE"
fi

# If WAN is changed, update cloudflare
log_info "正在更新 DNS 到 $WAN_IP"

if [ -z "$CFRECORD_ID" ]; then
    log_info "Cloudflare 上不存在该记录，正在尝试创建新记录..."
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL, \"proxied\":false}")
else
    log_info "记录已存在 (ID: $CFRECORD_ID)，正在更新..."
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
      -H "X-Auth-Email: $CFUSER" \
      -H "X-Auth-Key: $CFKEY" \
      -H "Content-Type: application/json" \
      --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL, \"proxied\":false}")
fi

if [ "$RESPONSE" != "${RESPONSE%success*}" ] && [ "$(echo $RESPONSE | grep "\"success\":true")" != "" ]; then
  log_success "更新成功！"
  send_telegram "Cloudflare DDNS 更新成功！
域名: <pre>$CFRECORD_NAME</pre>
新IP: <pre>$WAN_IP</pre>"
  echo $WAN_IP > $WAN_IP_FILE
  exit
else
  log_error '出错了 :('
  log_error "响应内容: $RESPONSE"
  send_telegram "Cloudflare DDNS 更新失败！
域名: <pre>$CFRECORD_NAME</pre>
错误信息: <pre>$RESPONSE</pre>"
  exit 1
fi
