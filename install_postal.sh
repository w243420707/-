#!/bin/bash

# ================= 配置区域 =================
# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
# ===========================================

echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}    Postal 邮件服务器全自动安装脚本 (独立架构版)       ${NC}"
echo -e "${GREEN}    内置数据库与消息队列 | 修复500错误 | 自动SSL       ${NC}"
echo -e "${GREEN}=======================================================${NC}"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 2. 获取用户配置
read -p "请输入您的域名 (例如 mail.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ 域名不能为空！${NC}"
    exit 1
fi

read -p "请输入 SMTP 端口 (默认 2525，防止封锁): " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-2525}

# 3. 基础依赖安装 & 网络检测
echo -e "${CYAN}--- 步骤 1/7: 准备系统环境 ---${NC}"
apt-get update
apt-get install -y curl git jq apt-transport-https ca-certificates gnupg lsb-release net-tools

# === 智能 Docker 安装逻辑 ===
echo -e "${CYAN}正在检测网络环境...${NC}"
REGION="global"
DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"

if ! curl -s --connect-timeout 3 https://www.google.com > /dev/null; then
    echo -e "${YELLOW}🇨🇳 检测到中国大陆环境，切换至阿里云镜像源...${NC}"
    REGION="china"
    DOCKER_GPG_URL="https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg"
    DOCKER_REPO_URL="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
fi

if ! command -v docker &> /dev/null; then
    echo -e "${CYAN}正在安装 Docker...${NC}"
    mkdir -p /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL "$DOCKER_GPG_URL" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_REPO_URL $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl start docker
    systemctl enable docker
else
    echo -e "${GREEN}✅ Docker 已安装${NC}"
fi

# 4. 创建专用网络与清理旧容器
echo -e "${CYAN}--- 步骤 2/7: 清理与网络配置 ---${NC}"
docker rm -f postal-caddy postal-web postal-worker postal-smtp postal-mariadb postal-rabbitmq 2>/dev/null
docker network rm postal 2>/dev/null
docker network create postal
echo -e "${GREEN}✅ Docker 网络 'postal' 创建成功${NC}"

# 5. 启动基础架构 (数据库 & MQ)
echo -e "${CYAN}--- 步骤 3/7: 启动数据库和消息队列 ---${NC}"

# 5.1 启动 RabbitMQ
echo -e "启动 RabbitMQ..."
docker run -d --name postal-rabbitmq \
    --network postal \
    --restart always \
    rabbitmq:3.8

# 5.2 启动 MariaDB
echo -e "启动 MariaDB..."
docker run -d --name postal-mariadb \
    --network postal \
    --restart always \
    -e MYSQL_ROOT_PASSWORD=postal \
    mariadb:10.6

echo -e "${YELLOW}等待数据库初始化 (15秒)...${NC}"
sleep 15

# 5.3 配置 RabbitMQ
echo -e "配置 RabbitMQ 权限..."
docker exec postal-rabbitmq rabbitmqctl add_vhost postal 2>/dev/null || true
docker exec postal-rabbitmq rabbitmqctl add_user postal postal 2>/dev/null || true
docker exec postal-rabbitmq rabbitmqctl set_permissions -p postal postal ".*" ".*" ".*" 2>/dev/null || true

# 6. 生成配置文件
echo -e "${CYAN}--- 步骤 4/7: 生成配置文件 ---${NC}"
mkdir -p /opt/postal/config
openssl_key=$(openssl rand -hex 16)

# 注意：host 这里全部填写容器名 (mariadb / rabbitmq)
cat > /opt/postal/config/postal.yml <<EOF
web:
  host: $DOMAIN
  protocol: https
web_server:
  bind_address: 0.0.0.0
  port: 5000
  max_threads: 5
main_db:
  host: postal-mariadb
  username: root
  password: postal
  database: postal
message_db:
  host: postal-mariadb
  username: root
  password: postal
  prefix: postal
rabbitmq:
  host: postal-rabbitmq
  username: postal
  password: postal
  vhost: postal
dns:
  mx_records: [mx.$DOMAIN]
  smtp_server_hostname: $DOMAIN
  spf_include: spf.$DOMAIN
  return_path: rp.$DOMAIN
  route_domain: routes.$DOMAIN
  track_domain: track.$DOMAIN
smtp:
  host: 127.0.0.1
  port: $SMTP_PORT
  tls_enabled: false
smtp_server:
  port: $SMTP_PORT
  tls_enabled: false
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

# 7. 初始化 Postal
echo -e "${CYAN}--- 步骤 5/7: 初始化 Postal 核心 ---${NC}"
echo -e "${YELLOW}正在初始化数据库结构...${NC}"
docker run --rm --network postal \
    -v /opt/postal/config/postal.yml:/config/postal.yml \
    ghcr.io/postalserver/postal:3.3.4 postal initialize

echo -e "${YELLOW}创建管理员账户...${NC}"
docker run --rm -it --network postal \
    -v /opt/postal/config/postal.yml:/config/postal.yml \
    ghcr.io/postalserver/postal:3.3.4 postal make-user

# 8. 启动 Postal 组件
echo -e "${CYAN}--- 步骤 6/7: 启动应用容器 ---${NC}"

# 8.1 启动 Web
docker run -d --name postal-web \
    --network postal \
    --restart always \
    -v /opt/postal/config/postal.yml:/config/postal.yml \
    ghcr.io/postalserver/postal:3.3.4 postal web-server

# 8.2 启动 SMTP (映射端口到宿主机)
docker run -d --name postal-smtp \
    --network postal \
    --restart always \
    -v /opt/postal/config/postal.yml:/config/postal.yml \
    -p $SMTP_PORT:$SMTP_PORT \
    ghcr.io/postalserver/postal:3.3.4 postal smtp-server

# 8.3 启动 Worker
docker run -d --name postal-worker \
    --network postal \
    --restart always \
    -v /opt/postal/config/postal.yml:/config/postal.yml \
    ghcr.io/postalserver/postal:3.3.4 postal worker

# 9. 配置 Caddy
echo -e "${CYAN}--- 步骤 7/7: 配置 Caddy 反向代理 ---${NC}"
cat > /opt/postal/config/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy postal-web:5000
}
EOF

# 注意：Caddy 需要加入 postal 网络才能访问 web，同时需要 host 网络或者端口映射来对外提供服务
# 这里我们让 Caddy 加入 postal 网络，并映射 80/443
docker run -d --name postal-caddy \
  --restart always \
  --network postal \
  -p 80:80 -p 443:443 \
  -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:alpine caddy run --config /etc/caddy/Caddyfile

# 10. 最终检查
echo -e ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}    🎉 安装全部完成！   ${NC}"
echo -e "${GREEN}=======================================================${NC}"

# === 新增：自动获取 IPv4 地址 ===
PUBLIC_IP=$(curl -s -4 ifconfig.me)
# ==============================

echo -e "🏠 管理面板: ${YELLOW}https://$DOMAIN${NC}"
echo -e "📨 SMTP 端口: ${YELLOW}$SMTP_PORT${NC}"
echo -e ""
echo -e "$DOMAIN${NC}.	1	IN	A	$PUBLIC_IP ; cf_tags=cf-proxied:false"
echo -e "rp.$DOMAIN${NC}.	1	IN	A	$PUBLIC_IP ; cf_tags=cf-proxied:false"
echo -e "routes.$DOMAIN${NC}.	1	IN	MX	10 $DOMAIN${NC}."
echo -e "rp.$DOMAIN${NC}.	1	IN	MX	10 $DOMAIN${NC}."
echo -e "rp.$DOMAIN${NC}.	1	IN	TXT	\"v=spf1 a mx include:spf.$DOMAIN${NC} ~all\""
echo -e "spf.$DOMAIN${NC}.	1	IN	TXT	\"v=spf1 ip4:$PUBLIC_IP ~all\""
echo -e ""
echo -e "正在验证服务状态..."
sleep 5

if [ "$(docker inspect -f '{{.State.Running}}' postal-web)" = "true" ]; then
    echo -e "${GREEN}✅ Web 服务运行中${NC}"
else
    echo -e "${RED}❌ Web 服务启动失败${NC}"
fi

if [ "$(docker inspect -f '{{.State.Running}}' postal-mariadb)" = "true" ]; then
    echo -e "${GREEN}✅ 数据库运行中${NC}"
else
    echo -e "${RED}❌ 数据库启动失败${NC}"
fi

echo -e "${GREEN}=======================================================${NC}"
