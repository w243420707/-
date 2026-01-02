#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}    Postal 邮件服务器一键安装脚本 (增强版)    ${NC}"
echo -e "${GREEN}    兼容阿里云/腾讯云 - 支持自定义端口        ${NC}"
echo -e "${GREEN}==============================================${NC}"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 2. 获取用户输入
echo -e "${YELLOW}请配置您的服务器信息：${NC}"
read -p "请输入您的域名 (例如 mail.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空！${NC}"
    exit 1
fi

read -p "请输入 SMTP 端口 (直接回车默认使用 2525，防止被云厂商封锁): " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-2525}

echo -e "${GREEN}正在准备安装环境...${NC}"
apt-get update
apt-get install -y curl git jq apt-transport-https ca-certificates gnupg lsb-release

# 3. 安装 Docker (如果未安装)
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}正在安装 Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
else
    echo -e "${GREEN}Docker 已安装，跳过。${NC}"
fi

# 4. 准备 Postal 目录
echo -e "${YELLOW}配置 Postal 目录...${NC}"
mkdir -p /opt/postal/config
git clone https://github.com/postalserver/install /opt/postal/install
ln -s /opt/postal/install/bin/postal /usr/bin/postal

# 5. 生成配置文件 (关键步骤：自动写入正确的端口)
echo -e "${YELLOW}正在生成配置文件 (SMTP端口: $SMTP_PORT)...${NC}"
openssl_key=$(openssl rand -hex 16)

cat > /opt/postal/config/postal.yml <<EOF
web:
  host: $DOMAIN
  protocol: https

web_server:
  bind_address: 127.0.0.1
  port: 5000
  max_threads: 5

main_db:
  host: 127.0.0.1
  username: root
  password: postal
  database: postal

message_db:
  host: 127.0.0.1
  username: root
  password: postal
  prefix: postal

rabbitmq:
  host: 127.0.0.1
  username: postal
  password: postal
  vhost: postal

dns:
  mx_records:
    - mx.$DOMAIN
  smtp_server_hostname: $DOMAIN
  spf_include: spf.$DOMAIN
  return_path: rp.$DOMAIN
  route_domain: routes.$DOMAIN
  track_domain: track.$DOMAIN

smtp:
  host: 127.0.0.1
  port: $SMTP_PORT
  tls_enabled: false
  tls_certificate_path:
  tls_private_key_path:

smtp_server:
  port: $SMTP_PORT
  tls_enabled: false
  tls_certificate_path:
  tls_private_key_path:
  proxy_protocol: false
  log_connect: true
  strip_received_headers: false
  max_message_size: 10

rails:
  environment: production
  secret_key: $openssl_key

general:
  use_ip_pools: false

logging:
  stdout: true
EOF

# 6. 初始化数据库和容器
echo -e "${YELLOW}正在初始化数据库 (这可能需要几分钟)...${NC}"
postal bootstrap postal
postal initialize
postal make-user

# 7. 启动 Postal
echo -e "${YELLOW}正在启动所有 Postal 服务...${NC}"
postal start

# 8. 安装并配置 Caddy (自动 HTTPS)
echo -e "${YELLOW}正在安装 Caddy 并配置 SSL...${NC}"
docker run -d --name postal-caddy \
  --restart always \
  --network host \
  -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:alpine caddy run --config /etc/caddy/Caddyfile

# 生成 Caddyfile
cat > /opt/postal/config/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

# 重启 Caddy 加载配置
docker restart postal-caddy

# 9. 最终检查
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}    安装完成！   ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "访问地址: ${YELLOW}https://$DOMAIN${NC}"
echo -e "SMTP 端口: ${YELLOW}$SMTP_PORT${NC} (请在安全组放行此端口)"
echo -e ""
echo -e "正在检查端口状态..."
sleep 5
if netstat -tulnp | grep ":$SMTP_PORT" > /dev/null; then
    echo -e "${GREEN}✅ 检测到 $SMTP_PORT 端口已正常监听！${NC}"
else
    echo -e "${RED}❌ 警告：未检测到 $SMTP_PORT 端口，请检查 logs。${NC}"
fi
echo -e "${GREEN}==============================================${NC}"
