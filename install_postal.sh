#!/bin/bash

# ==========================================
# Postal 邮件服务器 - 最终完美版 (带自修复)
# ==========================================
# 包含：环境清理、自动安装、配置修正、管理员创建、SSL配置
# 特性：自动检测并强制修复 25 端口映射
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
echo -e "${CYAN}   Postal 全自动安装脚本 (最终修复版)       ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 获取域名
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# ==========================================
# 2. 清理旧环境
# ==========================================
echo -e "${YELLOW}[1/10] 清理旧环境...${NC}"
docker stop postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
docker rm postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
rm -rf /opt/postal/install

# ==========================================
# 3. 安装依赖与 Docker
# ==========================================
echo -e "${YELLOW}[2/10] 安装依赖与 Docker...${NC}"
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
# 4. 克隆官方仓库
# ==========================================
echo -e "${YELLOW}[3/10] 下载 Postal 资源文件...${NC}"
git clone https://github.com/postalserver/install /opt/postal/install
ln -sf /opt/postal/install/bin/postal /usr/bin/postal
chmod +x /opt/postal/install/bin/postal

# ==========================================
# 5. 生成标准配置文件 (带端口)
# ==========================================
echo -e "${YELLOW}[4/10] 生成标准 Docker 配置文件...${NC}"
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
echo -e "${YELLOW}[5/10] 启动数据库并修正配置...${NC}"
docker compose -f /opt/postal/install/docker-compose.yml up -d mariadb rabbitmq
sleep 10

if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

CONFIG_FILE="/opt/postal/config/postal.yml"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

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
echo -e "${YELLOW}[6/10] 初始化数据库结构...${NC}"
postal initialize

# ==========================================
# 8. 创建管理员
# ==========================================
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}[7/10] 创建管理员账户${NC}"
echo -e "${CYAN}请依次输入: First Name, Last Name, Email, Password${NC}"
echo -e "${GREEN}=============================================${NC}"
postal make-user

# ==========================================
# 9. 启动 Postal
# ==========================================
echo -e "${YELLOW}[8/10] 启动 Postal 服务...${NC}"
postal start

# ==========================================
# 10. 自动修复端口映射 (关键新增步骤)
# ==========================================
echo -e "${YELLOW}[9/10] 检查并强制修复 25 端口...${NC}"

# 函数：检测 SMTP 容器端口
check_smtp_port() {
    # 查找容器 ID
    CID=$(docker ps -q -f name=smtp)
    if [ -z "$CID" ]; then return 1; fi
    # 检查端口映射
    docker port "$CID" 25 | grep -q "0.0.0.0:25"
}

sleep 5
if check_smtp_port; then
    echo -e "${GREEN}检测通过: 25 端口已正常映射。${NC}"
else
    echo -e "${RED}警告: 25 端口未正确映射，正在尝试强制修复...${NC}"
    
    # 强制停止
    postal stop
    
    # 再次覆盖写入 docker-compose (确保没被修改)
    # (此处省略 cat 内容，因上方已写过，逻辑上复用文件即可，这里做重启操作)
    
    echo "重启服务..."
    docker compose -f /opt/postal/install/docker-compose.yml up -d
    
    sleep 5
    if check_smtp_port; then
         echo -e "${GREEN}修复成功: 25 端口现已映射。${NC}"
    else
         echo -e "${RED}严重错误: 无法映射 25 端口。可能端口被 Postfix/Sendmail 占用。${NC}"
         echo -e "正在尝试杀掉占用进程..."
         fuser -k 25/tcp || true
         postal start
    fi
fi

# ==========================================
# 11. 配置 Caddy
# ==========================================
echo -e "${YELLOW}[10/10] 配置 HTTPS (Caddy)...${NC}"
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
echo -e "最后一次检查端口状态："
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep ":25"
echo -e ""
