#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# 默认配置
CFKEY=e80a9bfb256d5d060aa8a4f55a7da43fdf135  # API 密钥
CFUSER=yooyu@msn.com  # 用户名
CFZONE_NAME=fly64jfgwhale.xyz  # 区域名称
CFRECORD_NAME=hy-nl-l4ehusajhz18.fly64jfgwhale.xyz  # 要更新的主机名
CFRECORD_TYPE=A  # 记录类型，A(IPv4)或AAAA(IPv6)
CFTTL=120  # Cloudflare 记录的 TTL
FORCE=true  # 忽略本地文件，反正要更新 IP

WANIPSITE="http://ipv4.icanhazip.com"  # 获取 WAN IP 的站点

# 如果记录类型为 AAAA，则更改 WANIPSITE
if [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
elif [ "$CFRECORD_TYPE" != "A" ]; then
  echo "$CFRECORD_TYPE 指定无效，CFRECORD_TYPE 只能是 A（用于 IPv4）或 AAAA（用于 IPv6）"
  exit 2
fi

# 获取当前和旧的 WAN IP
WAN_IP=$(curl -s ${WANIPSITE})
WAN_IP_FILE=$HOME/.cf-wan_ip_$CFRECORD_NAME.txt
if [ -f $WAN_IP_FILE ]; then
  OLD_WAN_IP=$(cat $WAN_IP_FILE)
else
  OLD_WAN_IP=""
fi

# 如果 WAN IP 未更改且未使用 FORCE 标志，则在此退出
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  exit 0
fi

# 获取 zone_identifier 和 record_identifier
ID_FILE=$HOME/.cf-id_$CFRECORD_NAME.txt
if [ -f $ID_FILE ] && [ $(wc -l < $ID_FILE) -eq 4 ] \
  && [ "$(sed -n '3p' "$ID_FILE")" == "$CFZONE_NAME" ] \
  && [ "$(sed -n '4p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
else
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1 )
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*' | head -1 )
    echo "$CFZONE_ID" > $ID_FILE
    echo "$CFRECORD_ID" >> $ID_FILE
    echo "$CFZONE_NAME" >> $ID_FILE
    echo "$CFRECORD_NAME" >> $ID_FILE
fi

# 更新 Cloudflare
RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  -H "X-Auth-Email: $CFUSER" \
  -H "X-Auth-Key: $CFKEY" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL}")

if [[ $RESPONSE == *"\"success\":true"* ]]; then
  echo $WAN_IP > $WAN_IP_FILE
else
  echo "更新失败: $RESPONSE"
  exit 1
fi
