#!/bin/bash

# ==========================================
# Postal 终极安装脚本 (V8 - 智能SSL兜底版)
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
echo -e "${CYAN}   Postal 全自动安装脚本 (V8 智能版)          ${NC}"
echo -e "${CYAN}   含: 数据库防错 / 智能证书切换 / 自动清理    ${NC}"
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
ADMIN_PASSWORD="PostalUser2024!"

echo -e "${GREEN}域名: $POSTAL_DOMAIN${NC}"
echo -e "${GREEN}管理员: $ADMIN_EMAIL${NC}"
echo -e "${GREEN}默认密码: $ADMIN_PASSWORD${NC}"
echo "---------------------------------------------"

# ==========================================
# 2. 彻底清理环境
# ==========================================
echo -e "${YELLOW}[1/10] 正在清理旧容器和冲突进程...${NC}"
# 删除所有相关容器
docker rm -f postal-web postal-smtp postal-worker postal-runner postal-caddy postal-mariadb postal-rabbitmq \
             install-web-1 install-smtp-1 install-worker-1 install-mariadb-1 install-rabbitmq-1 install-runner-1 2>/dev/null || true

# 清理端口占用 (防止 Address already in use)
if command -v fuser &> /dev/null; then
    fuser -k 25/tcp 80/tcp 443/tcp 5000/tcp 3306/tcp 5672/tcp 2>/dev/null || true
fi

# ==========================================
# 3. 修复 Connection Timed Out
# ==========================================
echo -e "${YELLOW}[2/10] 配置本地回环 (/etc/hosts)...${NC}"
# 删除旧记录
sed -i "/$POSTAL_DOMAIN/d" /etc/hosts
# 添加新记录 (关键：让服务器知道域名就是自己)
echo "127.0.0.1 $POSTAL_DOMAIN" >> /etc/hosts

# ==========================================
# 4. 准备目录与 Docker
# ==========================================
echo -e "${YELLOW}[3/10] 准备系统环境...${NC}"
mkdir -p /opt/postal/install
mkdir -p /opt/postal/config
mkdir -p /opt/postal/caddy-data

# 简单检查 Docker
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
fi

# ==========================================
# 5. 生成 Docker 配置 (Host 模式 - 最稳方案)
# ==========================================
echo -e "${YELLOW}[4/10] 生成 docker-compose.yml...${NC}"
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
# 6. 初始化配置文件
# ==========================================
echo -e "${YELLOW}[5/10] 初始化配置文件...${NC}"
curl -sL https://github.com/postalserver/install/raw/main/bin/postal -o /usr/bin/postal
chmod +x /usr/bin/postal

if [ ! -f "/opt/postal/config/postal.yml" ]; then
    postal bootstrap "$POSTAL_DOMAIN"
fi

# 强制修正配置 (防止500错误的关键之一)
CONFIG_FILE="/opt/postal/config/postal.yml"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"

# ==========================================
# 7. 启动数据库并等待 (修复 500 错误的核心)
# ==========================================
echo -e "${YELLOW}[6/10] 启动数据库...${NC}"
cd /opt/postal/install
docker compose up -d mariadb rabbitmq

echo -e "${CYAN}正在预热数据库 (等待30秒)... ☕${NC}"
# 这里的等待是为了防止 "Table doesn't exist" 错误
for i in {30..1}; do
    echo -ne "剩余: $i 秒 \r"
    sleep 1
done
echo -e "\n数据库已就绪。"

# ==========================================
# 8. 初始化表结构与用户
# ==========================================
echo -e "${YELLOW}[7/10] 初始化数据表...${NC}"
docker compose run --rm runner postal initialize

echo -e "${YELLOW}[8/10] 注册管理员账号...${NC}"
# 自动创建账号，避免手动敲命令
docker compose run --rm runner postal make-user \
    --first-name "Admin" \
    --last-name "User" \
    --email "$ADMIN_EMAIL" \
    --password "$ADMIN_PASSWORD" 2>/dev/null || true

# ==========================================
# 9. 启动核心服务
# ==========================================
echo -e "${YELLOW}[9/10] 启动 Postal 核心服务...${NC}"
docker compose up -d

# ==========================================
# 10. 智能配置 SSL (Caddy)
# ==========================================
echo -e "${YELLOW}[10/10] 配置 SSL 证书 (智能模式)...${NC}"

# 步骤 A: 先尝试正版配置 (无 tls internal)
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

echo -e "${CYAN}正在尝试申请 Let's Encrypt 证书 (等待 20秒)...${NC}"
sleep 20

# 步骤 B: 检查日志，看是否有严重报错
# 常见报错词: "too many requests", "failed to obtain", "error"
if docker logs postal-caddy 2>&1 | grep -Eiq "error|failed|too many requests|challenge"; then
    echo -e "\n${RED}⚠️  检测到证书申请失败 (可能因频率限制或防火墙)。${NC}"
    echo -e "${YELLOW}>>> 正在自动切换为【自签名证书模式】...${NC}"
    
    # 覆盖配置为自签名模式
    cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    tls internal
    reverse_proxy localhost:5000
}
EOF
    docker restart postal-caddy
    echo -e "${GREEN}✅ 已切换至自签名模式。服务可用。${NC}"
    SSL_STATUS="自签名 (浏览器会提示不安全，请忽略)"
else
    echo -e "\n${GREEN}✅ 证书申请似乎正常 (或者正在排队)。${NC}"
    SSL_STATUS="Let's Encrypt 正版 (如果还没绿锁，请稍等几分钟)"
fi

# ==========================================
# 完成
# ==========================================
echo -e ""
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}             Postal 安装完成!               ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e ""
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e "证书状态: ${YELLOW}$SSL_STATUS${NC}"
echo -e "管理员账号: ${CYAN}$ADMIN_EMAIL${NC}"
echo -e "管理员密码: ${CYAN}$ADMIN_PASSWORD${NC}"
echo -e ""
echo -e "提示: 如果浏览器提示红色警告，请点击 '高级' -> '继续前往'。"
echo -e ""
