#!/bin/bash

# ==========================================
# Postal 邮件服务器最终完美安装脚本
# ==========================================
# 功能：全自动安装 Docker、配置数据库、RabbitMQ、Postal (带25端口)、Caddy (SSL)
# ==========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 权限运行此脚本 (sudo -i)${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}      Postal 邮件服务器安装 (最终稳定版)      ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 获取用户输入
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# ==========================================
# 2. 清理旧环境 (防止冲突)
# ==========================================
echo -e "${YELLOW}[1/8] 清理旧环境...${NC}"
docker stop postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
docker rm postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
# 不删除数据卷，保留数据

# ==========================================
# 3. 安装依赖与 Docker
# ==========================================
echo -e "${YELLOW}[2/8] 安装系统依赖与 Docker...${NC}"
apt-get update -qq
apt-get install -y git curl jq gnupg lsb-release nano

if ! command -v docker &> /dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# ==========================================
# 4. 准备目录与 Postal CLI
# ==========================================
echo -e "${YELLOW}[3/8] 准备 Postal 目录...${NC}"
mkdir -p /opt/postal/install
mkdir -p /opt/postal/config

# 下载 Postal CLI (如果不存在)
if [ ! -f "/usr/bin/postal" ]; then
    curl -L https://github.com/postalserver/install/raw/main/bin/postal -o /usr/bin/postal
    chmod +x /usr/bin/postal
fi

# ==========================================
# 5. 生成完美的 docker-compose.yml
# ==========================================
echo -e "${YELLOW}[4/8] 写入 Docker 配置文件 (强制覆盖)...${NC}"
# 直接写入完整文件，包含 25 端口映射，不依赖 sed 修改，避免格式错误
cat > /opt/postal/install/docker-compose.yml <<EOF
version: "3.9"

services:
  mariadb:
    image: mariadb:10.6
    restart: always
    environment:
      MARIADB_DATABASE: postal
      MARIADB_ROOT_PASSWORD: postal
    ports:
      - "127.0.0.1:3306:3306"

  rabbitmq:
    image: rabbitmq:3.12
    restart: always
    environment:
      RABBITMQ_DEFAULT_USER: postal
      RABBITMQ_DEFAULT_PASS: postal
      RABBITMQ_DEFAULT_VHOST: postal

  web:
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal web-server
    network_mode: host
    volumes:
      - /opt/postal/config:/config
    restart: unless-stopped
    depends_on:
      - mariadb
      - rabbitmq

  smtp:
    image: ghcr.io/postalserver/postal:3.3.4
    command: postal smtp-server
    restart: always
    ports:
      - "25:25"
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
    restart: unless-stopped
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
# 6. 初始化配置与数据库
# ==========================================
echo -e "${YELLOW}[5/8] 初始化数据库与配置...${NC}"

# 先启动数据库和MQ
docker compose -f /opt/postal/install/docker-compose.yml up -d mariadb rabbitmq
echo "等待数据库就绪 (10秒)..."
sleep 10

# 生成配置文件 (如果不存在)
if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
    # 修正配置文件连接信息
    sed -i 's/password: .*/password: postal/' /opt/postal/config/postal.yml
    sed -i 's/host: .*/host: 127.0.0.1/' /opt/postal/config/postal.yml
    # 修正 RabbitMQ 密码 (bootstrap 默认生成的可能是随机的)
    sed -i 's/rabbitmq:/rabbitmq:\n  host: 127.0.0.1\n  username: postal\n  password: postal\n  vhost: postal/' /opt/postal/config/postal.yml
fi

# 初始化数据库结构
postal initialize

# ==========================================
# 7. 创建管理员 (交互式)
# ==========================================
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}[6/8] 创建管理员账户${NC}"
echo -e "${CYAN}请跟随提示输入: 名字 -> 姓氏 -> 邮箱 -> 密码${NC}"
echo -e "${GREEN}=============================================${NC}"

# 交互式创建
postal make-user

# ==========================================
# 8. 启动所有服务
# ==========================================
echo -e "${YELLOW}[7/8] 启动 Postal 服务...${NC}"
postal start

# ==========================================
# 9. 配置 Caddy
# ==========================================
echo -e "${YELLOW}[8/8] 配置 Caddy (HTTPS)...${NC}"

mkdir -p /opt/postal/caddy-data
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF

docker run -d \
   --name postal-caddy \
   --restart always \
   --network host \
   -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
   -v /opt/postal/caddy-data:/data \
   caddy:alpine

# ==========================================
# 完成
# ==========================================
echo -e ""
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}             安装全部完成!                  ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "Web 后台: https://$POSTAL_DOMAIN"
echo -e ""
echo -e "${YELLOW}当前端口状态:${NC}"
docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"
echo -e ""
echo -e "如果 postal-smtp 显示 0.0.0.0:25->25/tcp 则说明映射成功。"
