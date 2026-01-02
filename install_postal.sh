#!/bin/bash

# ==========================================
# Postal 邮件服务器 - 终极安装脚本
# ==========================================
# 特性：
# 1. 强力清除 Postfix/Exim4/Sendmail (解决端口占用核心痛点)
# 2. 自动修复 YAML 锚点错误
# 3. 自动补全官方资源文件
# 4. 自动配置 SSL (Caddy)
# 5. 自动配置数据库与 RabbitMQ
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
echo -e "${CYAN}   Postal 全自动安装脚本 (端口强力净化版)    ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 0. 强力清理端口占用 (新增核心步骤)
# ==========================================
echo -e "${YELLOW}[1/11] 检测并卸载冲突的邮件服务...${NC}"

# 停止常见邮件服务
systemctl stop postfix 2>/dev/null || true
systemctl stop sendmail 2>/dev/null || true
systemctl stop exim4 2>/dev/null || true

# 卸载它们 (防止重启复活)
echo "正在卸载 Postfix/Exim4/Sendmail 以释放 25 端口..."
apt-get remove --purge -y postfix postfix-sqlite postfix-mysql sendmail exim4 exim4-base exim4-config 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# 强杀残留进程
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 2>/dev/null || true
fi

echo -e "${GREEN}端口清理完毕。${NC}"

# ==========================================
# 1. 获取域名
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# ==========================================
# 2. 清理旧 Docker 环境
# ==========================================
echo -e "${YELLOW}[2/11] 清理旧 Docker 环境...${NC}"
docker stop postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
docker rm postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
rm -rf /opt/postal/install  # 重新拉取安装文件

# ==========================================
# 3. 安装依赖与 Docker
# ==========================================
echo -e "${YELLOW}[3/11] 安装系统依赖与 Docker...${NC}"
apt-get update -qq
apt-get install -y git curl jq gnupg lsb-release nano psmisc

if ! command -v docker &> /dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# ==========================================
# 4. 克隆官方仓库
# ==========================================
echo -e "${YELLOW}[4/11] 下载 Postal 资源文件...${NC}"
git clone https://github.com/postalserver/install /opt/postal/install
ln -sf /opt/postal/install/bin/postal /usr/bin/postal
chmod +x /opt/postal/install/bin/postal

# ==========================================
# 5. 生成标准配置文件
# ==========================================
echo -e "${YELLOW}[5/11] 生成标准 Docker 配置文件...${NC}"
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
# 6. 启动数据库并修正配置
# ==========================================
echo -e "${YELLOW}[6/11] 启动数据库并准备配置...${NC}"
docker compose -f /opt/postal/install/docker-compose.yml up -d mariadb rabbitmq
echo "等待数据库就绪 (10秒)..."
sleep 10

# 生成配置 (如果不存在)
if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

CONFIG_FILE="/opt/postal/config/postal.yml"

# 修正数据库连接
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

# 修正 RabbitMQ 连接
if ! grep -q "username: postal" "$CONFIG_FILE"; then
    sed -i '/rabbitmq:/,/vhost:/d' "$CONFIG_FILE"
    echo "rabbitmq:
  host: 127.0.0.1
  username: postal
  password: postal
  vhost: postal" >> "$CONFIG_FILE"
fi

# ==========================================
# 7. 初始化数据库
# ==========================================
echo -e "${YELLOW}[7/11] 初始化数据库结构...${NC}"
postal initialize

# ==========================================
# 8. 创建管理员
# ==========================================
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}[8/11] 创建管理员账户${NC}"
echo -e "${CYAN}请依次输入: 名字 -> 姓氏 -> 邮箱 -> 密码${NC}"
echo -e "${GREEN}=============================================${NC}"
postal make-user

# ==========================================
# 9. 启动 Postal
# ==========================================
echo -e "${YELLOW}[9/11] 启动 Postal 服务...${NC}"
postal start

# ==========================================
# 10. 最终端口检查
# ==========================================
echo -e "${YELLOW}[10/11] 最终端口检查...${NC}"
sleep 5
SMTP_PORT_CHECK=$(docker ps --format "{{.Ports}}" | grep "0.0.0.0:25")

if [ -n "$SMTP_PORT_CHECK" ]; then
    echo -e "${GREEN}检测通过: 25 端口已成功映射!${NC}"
else
    echo -e "${RED}警告: 端口映射似乎仍有问题。${NC}"
    echo -e "正在尝试最后一次重启..."
    postal stop
    fuser -k 25/tcp 2>/dev/null || true
    postal start
    sleep 5
fi

# ==========================================
# 11. 配置 Caddy
# ==========================================
echo -e "${YELLOW}[11/11] 配置 HTTPS (Caddy)...${NC}"
mkdir -p /opt/postal/caddy-data
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF
docker rm -f postal-caddy 2>/dev/null || true
docker run -d --name postal-caddy --restart always --network host \
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
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e ""
echo -e "${YELLOW}当前端口状态:${NC}"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep ":25"
echo -e ""
