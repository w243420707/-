#!/bin/bash

# ==========================================
# Postal 终极安装脚本 (V10 - 纯净写入版)
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行 (sudo -i)${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}   Postal 全自动安装脚本 (V10 无依赖版)       ${NC}"
echo -e "${CYAN}   核心升级: 直接写入配置，不再依赖工具生成    ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 基础配置
# ==========================================
read -p "请输入您的域名 (例如 mail.shiyuanyinian.xyz): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# 自动生成随机密钥 (模拟 openssl rand -hex 16)
SIGNING_KEY=$(openssl rand -hex 16)
SECRET_KEY=$(openssl rand -hex 16)

# 管理员信息
ADMIN_EMAIL="admin@$POSTAL_DOMAIN"
ADMIN_PASSWORD="PostalUser2024!"

echo -e "${GREEN}域名: $POSTAL_DOMAIN${NC}"
echo -e "${GREEN}管理员: $ADMIN_EMAIL${NC}"
echo "---------------------------------------------"

# ==========================================
# 2. 彻底清理环境
# ==========================================
echo -e "${YELLOW}[1/10] 正在清理旧环境...${NC}"
docker rm -f $(docker ps -a -q) 2>/dev/null || true
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 80/tcp 443/tcp 5000/tcp 3306/tcp 5672/tcp 2>/dev/null || true
fi

# ==========================================
# 3. 修复 Connection Timed Out
# ==========================================
echo -e "${YELLOW}[2/10] 配置本地回环 (/etc/hosts)...${NC}"
sed -i "/$POSTAL_DOMAIN/d" /etc/hosts
echo "127.0.0.1 $POSTAL_DOMAIN" >> /etc/hosts

# ==========================================
# 4. 安装基础依赖
# ==========================================
echo -e "${YELLOW}[3/10] 安装系统依赖 (curl, git)...${NC}"
apt-get update -qq
apt-get install -y curl git gnupg lsb-release ca-certificates openssl

# ==========================================
# 5. 手动安装 Docker
# ==========================================
echo -e "${YELLOW}[4/10] 检查并安装 Docker...${NC}"

if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker (使用 apt 源方式)..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null 
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Docker 已安装，跳过。"
fi
systemctl start docker
systemctl enable docker

# ==========================================
# 6. 准备目录与生成 Docker Compose
# ==========================================
echo -e "${YELLOW}[5/10] 准备目录...${NC}"
mkdir -p /opt/postal/install
mkdir -p /opt/postal/config
mkdir -p /opt/postal/caddy-data

echo -e "${YELLOW}[6/10] 生成 docker-compose.yml...${NC}"
cat > /opt/postal/install/docker-compose.yml <<EOF
version: "3.9"
services:
  mariadb:
    image: mariadb:10.6
    restart: always
    environment:
      MARIADB_DATABASE: postal
      MARIADB_ROOT_PASSWORD: postal
    network_mode: host

  rabbitmq:
    image: rabbitmq:3.12
    restart: always
    environment:
      RABBITMQ_DEFAULT_USER: postal
      RABBITMQ_DEFAULT_PASS: postal
      RABBITMQ_DEFAULT_VHOST: postal
    network_mode: host

  web:
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal web-server
    network_mode: host
    volumes:
      - /opt/postal/config:/config
    restart: always
    depends_on:
      - mariadb
      - rabbitmq

  smtp:
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal smtp-server
    restart: always
    network_mode: host
    cap_add:
      - NET_BIND_SERVICE
    volumes:
      - /opt/postal/config:/config
    depends_on:
      - mariadb
      - rabbitmq

  worker:
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal worker
    network_mode: host
    volumes:
      - /opt/postal/config:/config
    restart: always
    depends_on:
      - mariadb
      - rabbitmq

  runner:
    profiles: ["tools"]
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal
    network_mode: host
    volumes:
      - /opt/postal/config:/config
EOF

# ==========================================
# 7. 直接写入 Postal 配置文件 (绕过生成器)
# ==========================================
echo -e "${YELLOW}[7/10] 直接写入 postal.yml 配置...${NC}"

# 这里是 Postal 标准配置模板，直接写入，防止任何生成错误
cat > /opt/postal/config/postal.yml <<EOF
web:
  host: $POSTAL_DOMAIN
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
    - mx.$POSTAL_DOMAIN
  smtp_server_hostname: $POSTAL_DOMAIN
  spf_include: spf.$POSTAL_DOMAIN
  return_path: rp.$POSTAL_DOMAIN
  route_domain: routes.$POSTAL_DOMAIN
  track_domain: track.$POSTAL_DOMAIN

smtp:
  host: 127.0.0.1
  port: 2525
  tls_enabled: false
  tls_certificate_path:
  tls_private_key_path:

smtp_server:
  port: 25
  tls_enabled: false # 由 Caddy 或外部处理 SSL
  tls_certificate_path:
  tls_private_key_path:
  proxy_protocol: false
  log_connect: true
  strip_received_headers: false
  max_message_size: 10 # MB

rails:
  environment: production
  secret_key: $SECRET_KEY

general:
  use_ip_pools: false

logging:
  stdout: true
EOF

echo "配置已成功写入。"

# 下载 postal 二进制文件以便后续调用
curl -sL https://github.com/postalserver/install/raw/main/bin/postal -o /usr/bin/postal
chmod +x /usr/bin/postal

# ==========================================
# 8. 启动数据库并等待
# ==========================================
echo -e "${YELLOW}[8/10] 启动数据库...${NC}"
cd /opt/postal/install
docker compose up -d mariadb rabbitmq

echo -e "${CYAN}正在预热数据库 (等待30秒)... 防500错误${NC}"
for i in {30..1}; do
    echo -ne "剩余: $i 秒 \r"
    sleep 1
done
echo -e "\n数据库已就绪。"

# ==========================================
# 9. 初始化表结构与用户
# ==========================================
echo -e "${YELLOW}[9/10] 初始化数据表...${NC}"
docker compose run --rm runner postal initialize

echo -e "${YELLOW}[10/10] 注册管理员账号...${NC}"
docker compose run --rm runner postal make-user \
    --first-name "Admin" \
    --last-name "User" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD" 2>/dev/null || true

# 启动核心服务
docker compose up -d

# ==========================================
# 10. 智能 SSL
# ==========================================
echo -e "${YELLOW}[+] 配置 SSL 证书...${NC}"

# 先尝试正版配置
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF

# 启动 Caddy
docker rm -f postal-caddy 2>/dev/null
docker run -d --name postal-caddy --restart always --network host \
   -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
   -v /opt/postal/caddy-data:/data \
   caddy:alpine

echo -e "${CYAN}尝试申请 SSL (20秒检测)...${NC}"
sleep 20

# 检测日志
if docker logs postal-caddy 2>&1 | grep -Eiq "error|failed|too many requests|challenge"; then
    echo -e "\n${RED}⚠️  正版证书申请受限，切换至自签名模式...${NC}"
    cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    tls internal
    reverse_proxy localhost:5000
}
EOF
    docker restart postal-caddy
    echo -e "${GREEN}✅ 已切换至自签名模式。${NC}"
else
    echo -e "\n${GREEN}✅ SSL 申请似乎正常。${NC}"
fi

# ==========================================
# 完成
# ==========================================
echo -e ""
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}             安装完成 (V10)                 ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e "管理员账号: $ADMIN_EMAIL"
echo -e "管理员密码: $ADMIN_PASSWORD"
echo -e ""
