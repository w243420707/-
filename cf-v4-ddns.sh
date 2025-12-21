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
#            -z example.com \          # will show you all zones if forgot, but you need this
#            -t A|AAAA                 # specify ipv4/ipv6, default: ipv4

# Optional flags:
#            -f false|true \           # force dns update, disregard local stored ip

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

    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       Cloudflare DDNS 一键安装脚本 (v2.2)                  ${NC}"
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

    if [[ -z "$CFZONE_NAME" ]]; then
        read -p "主域名 (Zone Name, 例如 example.com): " CFZONE_NAME
        while [[ -z "$CFZONE_NAME" ]]; do
            log_error "主域名不能为空。"
            read -p "主域名: " CFZONE_NAME
        done
    else
        log_info "主域名已提供: $CFZONE_NAME"
    fi

    if [[ -z "$CFRECORD_NAME" ]]; then
        read -p "DDNS 域名 (Hostname, 例如 ddns.example.com): " CFRECORD_NAME
        while [[ -z "$CFRECORD_NAME" ]]; do
            log_error "DDNS 域名不能为空。"
            read -p "DDNS 域名: " CFRECORD_NAME
        done
    else
        log_info "DDNS 域名已提供: $CFRECORD_NAME"
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
    # Normalize CFRECORD_NAME to FQDN if needed (ensure we clean the right cache file)
    if [[ "$CFRECORD_NAME" != "$CFZONE_NAME" ]] && [[ "${CFRECORD_NAME##*$CFZONE_NAME}" != "" ]]; then
        CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
        log_warn "主机名自动修正为 FQDN: $CFRECORD_NAME"
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
    CRON_CMD="$TARGET_PATH -k $CFKEY -u $CFUSER -h $CFRECORD_NAME -z $CFZONE_NAME -t $CFRECORD_TYPE"
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
    RUN_CMD="$TARGET_PATH -k $CFKEY -u $CFUSER -h $CFRECORD_NAME -z $CFZONE_NAME -t $CFRECORD_TYPE -f true"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        RUN_CMD="$RUN_CMD -T $TG_BOT_TOKEN -I $TG_CHAT_ID"
    fi
    $RUN_CMD

    if [ $? -eq 0 ]; then
        log_success "首次更新成功！"
    else
        log_error "首次更新失败。"
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
CFZONE_NAME=

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=

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

# If the hostname is not a FQDN
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  log_warn "主机名不是 FQDN，假设为 $CFRECORD_NAME"
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
WAN_IP=`curl -s ${WANIPSITE}`
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
if [ -f $ID_FILE ] && [ $(wc -l $ID_FILE | cut -d " " -f 1) == 4 ] \
  && [ "$(sed -n '3p' "$ID_FILE")" == "$CFZONE_NAME" ] \
  && [ "$(sed -n '4p' "$ID_FILE")" == "$CFRECORD_NAME" ] \
  && [ -n "$(sed -n '1p' "$ID_FILE")" ] \
  && [ -n "$(sed -n '2p' "$ID_FILE")" ]; then
    CFZONE_ID=$(sed -n '1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
else
    log_info "正在更新 zone_identifier 和 record_identifier"
    
    # Debug: Capture full response to diagnose issues
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
    
    # Extract Zone ID
    CFZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
    
    if [ -z "$CFZONE_ID" ]; then
        log_error "获取 Zone ID 失败！"
        log_error "Cloudflare API 响应内容: $ZONE_RESPONSE"
        log_error "请根据上方响应内容检查原因 (如 6003=Headers无效, 9103=未知错误等)"
        log_error "常见原因: 1. 使用了 API Token 而不是 Global Key; 2. 邮箱与 Key 不匹配; 3. 域名未在账号下激活"
        send_telegram "Cloudflare DDNS 配置失败！无法获取 Zone ID。响应: <pre>$ZONE_RESPONSE</pre>"
        exit 1
    fi

    # Get Record ID
    # 增加 &type=$CFRECORD_TYPE 以精确匹配记录类型
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME&type=$CFRECORD_TYPE" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
    
    CFRECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

    if [ -z "$CFRECORD_ID" ]; then
        log_warn "未找到现有的 $CFRECORD_TYPE 记录，准备创建新记录。"
        log_warn "查询域名: $CFRECORD_NAME"
        log_warn "API 响应: $RECORD_RESPONSE"
    else
        log_info "找到现有记录 ID: $CFRECORD_ID"
    fi

    echo "$CFZONE_ID" > $ID_FILE
    echo "$CFRECORD_ID" >> $ID_FILE
    echo "$CFZONE_NAME" >> $ID_FILE
    echo "$CFRECORD_NAME" >> $ID_FILE
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
