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
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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
    # Configuration
    INSTALL_DIR="/usr/local/bin"
    SCRIPT_NAME="cf-ddns.sh"
    TARGET_PATH="$INSTALL_DIR/$SCRIPT_NAME"
    LOG_FILE="/var/log/cf-ddns.log"

    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}       Cloudflare DDNS One-Click Installer                  ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # Check Root
    if [[ $EUID -ne 0 ]]; then
       log_error "This script must be run as root." 
       exit 1
    fi

    # Install Dependencies
    log_info "Checking dependencies..."
    if ! command -v curl &> /dev/null; then
        log_warn "curl not found. Installing..."
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y curl
        elif [ -x "$(command -v apk)" ]; then
            apk add --no-cache curl
        else
            log_error "Could not install curl. Please install it manually."
            exit 1
        fi
    else
        log_success "Dependencies met."
    fi

    # Gather Information
    echo ""
    echo -e "${YELLOW}Please enter your Cloudflare configuration:${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"

    read -p "Cloudflare API Key (Global API Key): " CFKEY
    while [[ -z "$CFKEY" ]]; do
        log_error "API Key cannot be empty."
        read -p "Cloudflare API Key: " CFKEY
    done

    read -p "Cloudflare Email: " CFUSER
    while [[ -z "$CFUSER" ]]; do
        log_error "Email cannot be empty."
        read -p "Cloudflare Email: " CFUSER
    done

    read -p "Zone Name (e.g., example.com): " CFZONE_NAME
    while [[ -z "$CFZONE_NAME" ]]; do
        log_error "Zone Name cannot be empty."
        read -p "Zone Name: " CFZONE_NAME
    done

    read -p "Hostname to update (e.g., ddns.example.com): " CFRECORD_NAME
    while [[ -z "$CFRECORD_NAME" ]]; do
        log_error "Hostname cannot be empty."
        read -p "Hostname to update: " CFRECORD_NAME
    done

    read -p "Record Type (A for IPv4, AAAA for IPv6) [default: A]: " CFRECORD_TYPE
    CFRECORD_TYPE=${CFRECORD_TYPE:-A}
    if [[ "$CFRECORD_TYPE" != "A" && "$CFRECORD_TYPE" != "AAAA" ]]; then
        log_warn "Invalid record type. Defaulting to A."
        CFRECORD_TYPE="A"
    fi

    # Install Script
    echo ""
    log_info "Installing script to $TARGET_PATH..."
    # Resolve absolute path of current script
    if [[ "$0" = /* ]]; then
        SCRIPT_PATH="$0"
    else
        SCRIPT_PATH="$PWD/$0"
    fi
    
    cp "$SCRIPT_PATH" "$TARGET_PATH"
    chmod +x "$TARGET_PATH"
    log_success "Script installed."

    # Configure Cron
    log_info "Configuring Crontab..."
    CRON_CMD="$TARGET_PATH -k $CFKEY -u $CFUSER -h $CFRECORD_NAME -z $CFZONE_NAME -t $CFRECORD_TYPE >> $LOG_FILE 2>&1"
    JOB="*/1 * * * * $CRON_CMD"

    # Remove existing job for this script to prevent duplicates
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TMP_CRON" || true
    grep -v "$TARGET_PATH" "$TMP_CRON" > "$TMP_CRON.new" || true
    mv "$TMP_CRON.new" "$TMP_CRON"

    # Add new job
    echo "$JOB" >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm "$TMP_CRON"
    log_success "Crontab configured."

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}   Installation Complete!                                   ${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo -e "  Script Path : ${CYAN}$TARGET_PATH${NC}"
    echo -e "  Log Path    : ${CYAN}$LOG_FILE${NC}"
    echo -e "  Schedule    : ${CYAN}Every minute${NC}"
    echo ""
    log_info "Running first update now..."

    # Run immediately
    $TARGET_PATH -k "$CFKEY" -u "$CFUSER" -h "$CFRECORD_NAME" -z "$CFZONE_NAME" -t "$CFRECORD_TYPE" -f true

    if [ $? -eq 0 ]; then
        log_success "First update successful!"
    else
        log_error "First update failed. Check logs at $LOG_FILE"
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

WANIPSITE="http://ipv4.icanhazip.com"

# Site to retrieve WAN ip, other examples are: bot.whatismyipaddress.com, https://api.ipify.org/ ...
if [ "${1:-}" != "" ] && [ "${1:0:1}" != "-" ]; then
    # If first arg is not a flag and not 'install' (handled above), it might be a mistake or old usage
    # But since we use getopts, we just proceed.
    :
fi

# get parameter
while getopts k:u:h:z:t:f: opts; do
  case ${opts} in
    k) CFKEY=${OPTARG} ;;
    u) CFUSER=${OPTARG} ;;
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
    f) FORCE=${OPTARG} ;;
  esac
done

# If required settings are missing just exit
if [ "$CFKEY" = "" ]; then
  log_error "Missing api-key, get at: https://www.cloudflare.com/a/account/my-account"
  log_error "and save in ${0} or using the -k flag"
  exit 2
fi
if [ "$CFUSER" = "" ]; then
  log_error "Missing username, probably your email-address"
  log_error "and save in ${0} or using the -u flag"
  exit 2
fi
if [ "$CFRECORD_NAME" = "" ]; then 
  log_error "Missing hostname, what host do you want to update?"
  log_error "save in ${0} or using the -h flag"
  exit 2
fi

# If the hostname is not a FQDN
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  log_warn "Hostname is not a FQDN, assuming $CFRECORD_NAME"
fi

# Determine WAN IP Site based on record type
if [ "$CFRECORD_TYPE" = "A" ]; then
  WANIPSITE="http://ipv4.icanhazip.com"
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  log_error "$CFRECORD_TYPE specified is invalid, CFRECORD_TYPE can only be A(for IPv4)|AAAA(for IPv6)"
  exit 2
fi

# Get current and old WAN ip
WAN_IP=`curl -s ${WANIPSITE}`
WAN_IP_FILE=$HOME/.cf-wan_ip_$CFRECORD_NAME.txt
if [ -f $WAN_IP_FILE ]; then
  OLD_WAN_IP=`cat $WAN_IP_FILE`
else
  log_info "No file, need IP"
  OLD_WAN_IP=""
fi

# If WAN IP is unchanged an not -f flag, exit here
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  log_info "WAN IP Unchanged, to update anyway use flag -f true"
  exit 0
fi

# Get zone_identifier & record_identifier
ID_FILE=$HOME/.cf-id_$CFRECORD_NAME.txt
if [ -f $ID_FILE ] && [ $(wc -l $ID_FILE | cut -d " " -f 1) == 4 ] \
  && [ "$(sed -n '3,1p' "$ID_FILE")" == "$CFZONE_NAME" ] \
  && [ "$(sed -n '4,1p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1,1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2,1p' "$ID_FILE")
else
    log_info "Updating zone_identifier & record_identifier"
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1 )
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*' | head -1 )
    echo "$CFZONE_ID" > $ID_FILE
    echo "$CFRECORD_ID" >> $ID_FILE
    echo "$CFZONE_NAME" >> $ID_FILE
    echo "$CFRECORD_NAME" >> $ID_FILE
fi

# If WAN is changed, update cloudflare
log_info "Updating DNS to $WAN_IP"

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  -H "X-Auth-Email: $CFUSER" \
  -H "X-Auth-Key: $CFKEY" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL}")

if [ "$RESPONSE" != "${RESPONSE%success*}" ] && [ "$(echo $RESPONSE | grep "\"success\":true")" != "" ]; then
  log_success "Updated succesfuly!"
  echo $WAN_IP > $WAN_IP_FILE
  exit
else
  log_error 'Something went wrong :('
  log_error "Response: $RESPONSE"
  exit 1
fi
