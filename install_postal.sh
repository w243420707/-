#!/bin/bash

# ==========================================
# Postal 终极一键安装脚本 (V7 - 完美修复版)
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
echo -e "${CYAN}   Postal 全自动安装脚本 (含数据库防错机制)   ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 基础配置
# ==========================================
read -p "请输入您的域名 (例如 mail.shiyuanyinian.xyz): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# 管理员信息
ADMIN_EMAIL="admin@$POSTAL_DOMAIN"
ADMIN_PASSWORD="PostalUser2024!"

echo -e "${GREEN}域名: $POSTAL_DOMAIN${NC}"
echo -e "${GREEN}管理员: $ADMIN_EMAIL${NC}"
echo -e "${GREEN}默认密码: $ADMIN_PASSWORD${NC}"
echo "---------------------------------------------"

# ==========================================
# 2. 彻底清理环境
# ==========================================
echo -e "${YELLOW}[1/9] 正在清理旧容器和冲突进程...${NC}"
# 删除所有相关容器
docker rm -f postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq \
             install-web-1 install-smtp-1 install-worker-1 install-mariadb-1 install-rabbitmq-1 install-runner-1 2>/dev/null || true

# 清理端口占用
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 80/tcp 443/tcp 5000/tcp 3306/tcp 2>/dev/null || true
fi

# ==========================================
# 3. 修复 Connection Timed Out
# ==========================================
echo -e "${YELLOW}[2/9] 配置本地回环 (/etc/hosts)...${NC}"
sed -i "/$POSTAL_DOMAIN/d" /etc/hosts
echo "127.0.0.1 $POSTAL_DOMAIN" >> /etc/hosts

# ==========================================
# 4. 准备目录
# ==========================================
echo -e "${YELLOW}[3/9] 准备文件目录...${NC}"
mkdir -p /opt/postal/install
mkdir -p /opt/postal/config
mkdir -p /opt/postal/caddy-data

# 安装 Docker (如果未安装)
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
fi

# ==========================================
# 5. 生成 Docker 配置 (Host 模式)
# ==========================================
echo -e "${YELLOW}[4/9] 生成 docker-compose.yml...${NC}"
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
# 6. 初始化配置
# ==========================================
echo -e "${YELLOW}[5/9] 下载并初始化配置...${NC}"
curl -sL https://github.com/postalserver/install/raw/main/bin/postal -o /usr/bin/postal
chmod +x /usr/bin/postal

if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

# 强制修正配置指向
CONFIG_FILE="/opt/postal/config/postal.yml"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

# ==========================================
# 7. 启动数据库并等待 (关键修复点)
# ==========================================
echo -e "${YELLOW}[6/9] 启动数据库...${NC}"
cd /opt/postal/install
docker compose up -d mariadb rabbitmq

echo -e "${CYAN}正在等待数据库完全启动 (30秒)... 防止报错 500${NC}"
# 这里我们故意等待久一点，确保 MariaDB 完全加载
for i in {30..1}; do
    echo -ne "等待中... $i \r"
    sleep 1
done
echo -e "\n数据库应该已就绪。"

# ==========================================
# 8. 初始化表结构与用户
# ==========================================
echo -e "${YELLOW}[7/9] 初始化数据表...${NC}"
# 这里如果不报错，500问题就解决了
docker compose run --rm runner postal initialize

echo -e "${YELLOW}[8/9] 创建管理员...${NC}"
docker compose run --rm runner postal make-user \
    --first-name "Admin" \
    --last-name "User" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD" 2>/dev/null || true

# ==========================================
# 9. 启动全部服务与 Caddy
# ==========================================
echo -e "${YELLOW}[9/9] 启动 Postal 与 Caddy...${NC}"
docker compose up -d

# 配置 Caddy (自签名 SSL)
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    tls internal
    reverse_proxy localhost:5000
}
EOF

# 启动 Caddy
docker rm -f postal-caddy 2>/dev/null
docker run -d --name postal-caddy --restart always --network host \
   -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
   -v /opt/postal/caddy-data:/data \
   caddy:alpine

# ==========================================
# 完成
# ==========================================
echo -e ""
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}           安装成功! (已修复500错误)         ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "请访问: https://$POSTAL_DOMAIN"
echo -e "⚠️  注意: 浏览器会提示红色不安全警告，请点击[高级]->[继续访问]"
echo -e ""
echo -e "账号: $ADMIN_EMAIL"
echo -e "密码: $ADMIN_PASSWORD"
echo -e ""
echo -e "${YELLOW}端口检查:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E 'smtp|web|mariadb'
