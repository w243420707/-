#!/bin/bash

# ==========================================
# Postal 邮件服务器 - 最终完美版
# ==========================================
# 1. 修正 SMTP 网络模式 (现在能看到端口映射了)
# 2. 自动生成管理员账号
# 3. 强力清理端口占用
# 4. 自动配置 HTTPS
# ==========================================

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
echo -e "${CYAN}   Postal 全自动安装脚本 (端口修正版)        ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 获取域名与生成账号
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# 生成随机管理员信息
ADMIN_FNAME="Admin"
ADMIN_LNAME="User"
ADMIN_PASSWORD=$(date +%s | sha256sum | base64 | head -c 12)
ADMIN_EMAIL="admin@$POSTAL_DOMAIN"

echo -e "${GREEN}将自动创建管理员:${NC}"
echo -e "用户: $ADMIN_FNAME $ADMIN_LNAME"
echo -e "邮箱: $ADMIN_EMAIL"
echo -e "密码: (安装完成后显示)"
echo "---------------------------------------------"

# ==========================================
# 2. 强力环境清理
# ==========================================
echo -e "${YELLOW}[1/10] 正在扫描并清理冲突服务...${NC}"
systemctl stop postfix sendmail exim4 nginx apache2 2>/dev/null || true
apt-get remove --purge -y postfix postfix-sqlite postfix-mysql sendmail exim4 exim4-base exim4-config 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# 清理旧容器
docker stop postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
docker rm postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq 2>/dev/null || true
rm -rf /opt/postal/install

# 杀掉残留进程
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 80/tcp 443/tcp 2>/dev/null || true
fi

# ==========================================
# 3. 安装依赖与 Docker
# ==========================================
echo -e "${YELLOW}[2/10] 安装系统依赖与 Docker...${NC}"
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
echo -e "${YELLOW}[3/10] 下载 Postal 资源文件...${NC}"
git clone https://github.com/postalserver/install /opt/postal/install
ln -sf /opt/postal/install/bin/postal /usr/bin/postal
chmod +x /opt/postal/install/bin/postal

# ==========================================
# 5. 生成标准配置文件 (核心修正：移除 SMTP 的 host 模式)
# ==========================================
echo -e "${YELLOW}[4/10] 生成 Docker 配置文件...${NC}"
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
    # 核心修正：移除 network_mode: host，改为端口映射
    ports:
      - "25:25"
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
echo -e "${YELLOW}[5/10] 启动数据库并准备配置...${NC}"
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
# 8. 自动创建管理员
# ==========================================
echo -e "${YELLOW}[7/10] 正在自动创建管理员账户...${NC}"
docker compose -f /opt/postal/install/docker-compose.yml run --rm runner postal make-user \
    --first-name "$ADMIN_FNAME" \
    --last-name "$ADMIN_LNAME" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD"

# ==========================================
# 9. 启动 Postal
# ==========================================
echo -e "${YELLOW}[8/10] 启动 Postal 服务...${NC}"
postal start

# ==========================================
# 10. 端口检查与修复
# ==========================================
echo -e "${YELLOW}[9/10] 检查 SMTP 端口映射...${NC}"
sleep 5
# 现在由于使用了端口映射，docker ps 应该能看到了
SMTP_PORT_CHECK=$(docker ps --format "{{.Ports}}" | grep "0.0.0.0:25")

if [ -z "$SMTP_PORT_CHECK" ]; then
    echo -e "${RED}警告: 端口映射失败，尝试强制修复...${NC}"
    postal stop
    fuser -k 25/tcp 2>/dev/null || true
    postal start
    sleep 3
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
echo -e "${CYAN}=== 管理员账号信息 ===${NC}"
echo -e "登录邮箱: ${YELLOW}$ADMIN_EMAIL${NC}"
echo -e "登录密码: ${YELLOW}$ADMIN_PASSWORD${NC}"
echo -e "${CYAN}======================${NC}"
echo -e ""
echo -e "${YELLOW}端口映射状态 (现在应该能看到 :25 了):${NC}"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "smtp|:25"
echo -e ""
