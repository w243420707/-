#!/bin/bash

# ==========================================
# Postal 邮件服务器 - 最终完美版安装脚本
# ==========================================
# 修复了模板缺失、YAML格式错误、端口映射缺失等所有已知问题
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
# 2. 清理环境 (彻底清理旧残留)
# ==========================================
echo -e "${YELLOW}[1/9] 清理旧环境...${NC}"
docker stop postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
docker rm postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
rm -rf /opt/postal/install  # 删除旧的安装目录，重新拉取
# 注意：保留 /opt/postal/config 以防误删配置，如果需要全新安装请手动删

# ==========================================
# 3. 安装依赖与 Docker
# ==========================================
echo -e "${YELLOW}[2/9] 安装依赖与 Docker...${NC}"
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
# 4. 克隆官方仓库 (解决模板缺失问题)
# ==========================================
echo -e "${YELLOW}[3/9] 下载 Postal 资源文件...${NC}"
# 必须使用 git clone，否则 postal bootstrap 会报错找不到 templates
git clone https://github.com/postalserver/install /opt/postal/install

# 建立 CLI 链接
ln -sf /opt/postal/install/bin/postal /usr/bin/postal
chmod +x /opt/postal/install/bin/postal

# ==========================================
# 5. 覆盖写入 Docker Compose (解决端口和YAML错误)
# ==========================================
echo -e "${YELLOW}[4/9] 生成标准 Docker 配置文件...${NC}"

# 这里写入一个不使用复杂锚点、结构简单且包含端口映射的文件
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
# 6. 生成配置与启动数据库
# ==========================================
echo -e "${YELLOW}[5/9] 启动数据库并生成配置...${NC}"

# 先启动数据库，确保后续初始化能连接
docker compose -f /opt/postal/install/docker-compose.yml up -d mariadb rabbitmq
echo "等待数据库启动 (10秒)..."
sleep 10

# 生成 postal.yml (如果不存在)
if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

# 强制修正 postal.yml 中的密码，使其与 docker-compose 保持一致
# 这样避免了 bootstrap 生成随机密码导致无法连接的问题
CONFIG_FILE="/opt/postal/config/postal.yml"

# 修改数据库配置
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

# 修改 RabbitMQ 配置 (删除原有块，重写)
# 使用 python 或 perl 处理多行替换比较麻烦，这里用简易方法：如果没改过才追加
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
echo -e "${YELLOW}[6/9] 初始化数据库结构...${NC}"
postal initialize

# ==========================================
# 8. 创建管理员
# ==========================================
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}[7/9] 创建管理员账户${NC}"
echo -e "${CYAN}请依次输入: First Name, Last Name, Email, Password${NC}"
echo -e "${GREEN}=============================================${NC}"
postal make-user

# ==========================================
# 9. 启动 Postal
# ==========================================
echo -e "${YELLOW}[8/9] 启动所有组件...${NC}"
postal start

# ==========================================
# 10. 配置 Caddy SSL
# ==========================================
echo -e "${YELLOW}[9/9] 配置自动 HTTPS (Caddy)...${NC}"
mkdir -p /opt/postal/caddy-data

cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF

# 清理旧 Caddy
docker rm -f postal-caddy 2>/dev/null || true

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
echo -e "${GREEN}             安装成功!                      ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e ""
echo -e "${YELLOW}端口检查:${NC}"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep "0.0.0.0:25" && echo -e "${GREEN}SMTP 25 端口映射成功!${NC}" || echo -e "${RED}警告: 25 端口似乎未映射，请检查!${NC}"
echo -e ""
