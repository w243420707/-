#!/bin/bash

# ==========================================
# Postal 完整安装脚本 (修复版)
# ==========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本 (sudo -i)${NC}"
  exit 1
fi

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}      Postal 安装脚本 (修复交互版)          ${NC}"
echo -e "${GREEN}=============================================${NC}"

# ==========================================
# 1. 获取域名 (仅需输入一次)
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# ==========================================
# 2. 安装基础依赖
# ==========================================
echo -e "${YELLOW}[1/8] 安装系统依赖...${NC}"
apt-get update
apt-get install -y git curl jq gnupg lsb-release

# ==========================================
# 3. 安装 Docker
# ==========================================
echo -e "${YELLOW}[2/8] 检查 Docker 环境...${NC}"
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Docker 已安装。"
fi

# ==========================================
# 4. 安装 Postal CLI
# ==========================================
echo -e "${YELLOW}[3/8] 配置 Postal CLI...${NC}"
if [ ! -d "/opt/postal/install" ]; then
    git clone https://github.com/postalserver/install /opt/postal/install
else
    # 如果目录存在，确保 git 配置也是新的，或者忽略更新直接使用
    echo "Postal 目录已存在，跳过克隆。"
fi

if [ ! -L "/usr/bin/postal" ]; then
    ln -s /opt/postal/install/bin/postal /usr/bin/postal
fi

# ==========================================
# 5. 启动 MariaDB
# ==========================================
echo -e "${YELLOW}[4/8] 启动数据库...${NC}"
# 清理可能存在的旧数据库容器
if [ "$(docker ps -aq -f name=postal-mariadb)" ]; then
    docker rm -f postal-mariadb
fi

docker run -d \
   --name postal-mariadb \
   -p 127.0.0.1:3306:3306 \
   --restart always \
   -e MARIADB_DATABASE=postal \
   -e MARIADB_ROOT_PASSWORD=postal \
   mariadb:10.6

echo "等待数据库初始化 (10秒)..."
sleep 10

# ==========================================
# 6. 配置 Postal
# ==========================================
echo -e "${YELLOW}[5/8] 生成配置并初始化...${NC}"

# 运行 Bootstrap (会覆盖旧配置)
postal bootstrap "$POSTAL_DOMAIN"

CONFIG_FILE="/opt/postal/config/postal.yml"
# 修正数据库密码为 'postal'
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"

# 初始化数据库结构
postal initialize

# ==========================================
# 7. 创建管理员 (交互式)
# ==========================================
echo -e "${GREEN}=============================================${NC}"
echo -e "${YELLOW}[6/8] 创建管理员账户 (重要!)${NC}"
echo -e "${GREEN}请在下方直接输入管理员信息:${NC}"
echo -e "注意: First Name 和 Last Name 可以随意填"
echo -e "${GREEN}=============================================${NC}"

# 直接调用交互式命令，不再使用 pipe，避免 TTY 错误
postal make-user

echo -e "${GREEN}管理员创建步骤结束。${NC}"

# ==========================================
# 8. 启动 Postal
# ==========================================
echo -e "${YELLOW}[7/8] 启动 Postal 服务...${NC}"
postal start

# ==========================================
# 9. 配置 Caddy
# ==========================================
echo -e "${YELLOW}[8/8] 配置 Caddy (SSL 反向代理)...${NC}"

# 写入 Caddyfile
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF

# 清理旧 Caddy
if [ "$(docker ps -aq -f name=postal-caddy)" ]; then
    docker rm -f postal-caddy
fi

# 启动 Caddy
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
echo -e "管理后台地址: https://$POSTAL_DOMAIN"
echo -e "DNS 设置提示:"
echo -e "请确保您的域名 $POSTAL_DOMAIN 解析到了本机 IP: $(curl -s ifconfig.me)"
echo -e ""
