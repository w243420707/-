#!/bin/bash

# ==========================================
# Postal 终极一键安装脚本 (V6 - 修复版)
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
echo -e "${CYAN}   Postal 全自动安装脚本 (最终修复版)        ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 基础配置
# ==========================================
read -p "请输入您的域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# 管理员信息
ADMIN_EMAIL="admin@$POSTAL_DOMAIN"
ADMIN_PASSWORD="PostalUser2024!" # 您可以稍后在后台修改

echo -e "${GREEN}域名: $POSTAL_DOMAIN${NC}"
echo -e "${GREEN}管理员: $ADMIN_EMAIL / $ADMIN_PASSWORD${NC}"
echo "---------------------------------------------"

# ==========================================
# 2. 彻底清理旧环境 (防止端口/容器冲突)
# ==========================================
echo -e "${YELLOW}[1/8] 正在暴力清理旧容器...${NC}"
# 停止并删除所有可能相关的容器
docker rm -f postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq install-web-1 install-smtp-1 install-worker-1 install-mariadb-1 install-rabbitmq-1 install-runner-1 2>/dev/null || true

# 清理残留端口进程
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 80/tcp 443/tcp 5000/tcp 2>/dev/null || true
fi

# ==========================================
# 3. 修复 Connection Timed Out (关键!)
# ==========================================
echo -e "${YELLOW}[2/8] 修复服务器自连超时问题 (/etc/hosts)...${NC}"
# 删除旧记录（如果存在）
sed -i "/$POSTAL_DOMAIN/d" /etc/hosts
# 添加新记录：强制域名指向本地
echo "127.0.0.1 $POSTAL_DOMAIN" >> /etc/hosts
echo -e "${GREEN}已添加 hosts 记录: 127.0.0.1 $POSTAL_DOMAIN${NC}"

# ==========================================
# 4. 准备文件与目录
# ==========================================
echo -e "${YELLOW}[3/8] 准备配置文件...${NC}"
mkdir -p /opt/postal/install
mkdir -p /opt/postal/config
mkdir -p /opt/postal/caddy-data

# 如果没有安装 git/docker，这里简单补充一下（假设已安装）
if ! command -v docker &> /dev/null; then
    apt-get update && apt-get install -y docker.compose docker-compose-plugin
fi

# ==========================================
# 5. 生成 Docker 配置 (使用最稳定的 Host 模式)
# ==========================================
echo -e "${YELLOW}[4/8] 生成 docker-compose.yml...${NC}"
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
# 6. 初始化配置与数据库
# ==========================================
echo -e "${YELLOW}[5/8] 初始化数据库...${NC}"
# 下载 postal 命令行工具
curl -sL https://github.com/postalserver/install/raw/main/bin/postal -o /usr/bin/postal
chmod +x /usr/bin/postal

# 生成初始配置 (如果不存在)
if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

# 修正 postal.yml 配置 (确保指向本地)
CONFIG_FILE="/opt/postal/config/postal.yml"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

# 启动数据库
cd /opt/postal/install
docker compose up -d mariadb rabbitmq
sleep 8

# 初始化表结构
postal initialize

# 创建管理员
echo -e "${YELLOW}[6/8] 创建管理员账号...${NC}"
docker compose run --rm runner postal make-user \
    --first-name "Admin" \
    --last-name "User" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD" 2>/dev/null || true

# ==========================================
# 7. 启动核心服务
# ==========================================
echo -e "${YELLOW}[7/8] 启动 Postal 服务...${NC}"
docker compose up -d
sleep 5

# ==========================================
# 8. 配置 HTTPS (自签名模式 - 防止 429 报错)
# ==========================================
echo -e "${YELLOW}[8/8] 配置 Caddy (自签名 SSL)...${NC}"

# 使用 tls internal 规避 Let's Encrypt 限制
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
echo -e "${GREEN}             安装修复完成!                  ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e "${RED}注意: 浏览器会提示不安全(红色警告)，这是正常的！${NC}"
echo -e "请点击 '高级' -> '继续访问' 即可进入。"
echo -e ""
echo -e "${CYAN}管理员账号: $ADMIN_EMAIL${NC}"
echo -e "${CYAN}管理员密码: $ADMIN_PASSWORD${NC}"
echo -e ""
echo -e "${YELLOW}检查端口状态 (如果您看到下面的 :25，说明端口已正常监听):${NC}"
# 使用 ss 或 netstat 检查宿主机实际监听情况
if command -v ss &> /dev/null; then
    ss -tlnp | grep :25
else
    netstat -tlnp | grep :25
fi
echo -e ""
