#!/bin/bash

# ==========================================
# Postal Pro 安装脚本 (自动映射端口 + SSL)
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

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}      Postal 邮件服务器全自动安装脚本       ${NC}"
echo -e "${CYAN}=============================================${NC}"

# ==========================================
# 1. 获取基本信息
# ==========================================
read -p "请输入您的 Postal 域名 (例如 mail.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

# ==========================================
# 2. 安装基础环境
# ==========================================
echo -e "${YELLOW}[1/9] 安装系统基础依赖...${NC}"
apt-get update -qq
apt-get install -y git curl jq gnupg lsb-release nano

# ==========================================
# 3. 安装 Docker 环境
# ==========================================
echo -e "${YELLOW}[2/9] 检查 Docker 环境...${NC}"
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Docker 已安装。"
fi

# ==========================================
# 4. 准备 Postal 目录
# ==========================================
echo -e "${YELLOW}[3/9] 下载 Postal 配置文件...${NC}"
if [ ! -d "/opt/postal/install" ]; then
    git clone https://github.com/postalserver/install /opt/postal/install
else
    echo "目录已存在，更新中..."
    cd /opt/postal/install && git pull
fi

# 建立 CLI 软链接
if [ ! -L "/usr/bin/postal" ]; then
    ln -s /opt/postal/install/bin/postal /usr/bin/postal
fi

# ==========================================
# 5. 启动 MariaDB 数据库
# ==========================================
echo -e "${YELLOW}[4/9] 启动数据库服务...${NC}"

# 清理旧数据库容器(防止密码冲突)
if [ "$(docker ps -aq -f name=postal-mariadb)" ]; then
    echo "检测到旧数据库容器，正在重启..."
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
# 6. 生成并修正配置
# ==========================================
echo -e "${YELLOW}[5/9] 生成并修正配置文件...${NC}"

# 运行初始化生成配置
postal bootstrap "$POSTAL_DOMAIN"

CONFIG_FILE="/opt/postal/config/postal.yml"
COMPOSE_FILE="/opt/postal/install/docker-compose.yml"

# 1. 修正数据库密码和Host
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"

# 2. 关键步骤：自动注入 25 端口映射到 docker-compose.yml
# 我们使用 grep 检查是否已经存在 ports 映射，如果没有则添加
if ! grep -q "25:25" "$COMPOSE_FILE"; then
    echo "正在添加 SMTP 25 端口映射..."
    # 使用 sed 在 'smtp:' 服务定义的 image 行下面插入 ports 配置
    # 注意：这里匹配 image: .../postal... 行，并在其后追加 ports 配置
    sed -i '/image: ghcr.io\/postalserver\/postal/a \    ports:\n      - "25:25"' "$COMPOSE_FILE"
else
    echo "端口映射已存在，跳过。"
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
echo -e "${CYAN}请跟随提示输入: 名字 -> 姓氏 -> 邮箱 -> 密码${NC}"
echo -e "${GREEN}=============================================${NC}"

# 交互式创建
postal make-user

# ==========================================
# 9. 启动服务
# ==========================================
echo -e "${YELLOW}[8/9] 启动 Postal 所有组件...${NC}"
postal start

# ==========================================
# 10. 配置 Caddy (SSL/反向代理)
# ==========================================
echo -e "${YELLOW}[9/9] 配置 Caddy 自动 HTTPS...${NC}"

# 写入 Caddyfile
mkdir -p /opt/postal/caddy-data
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
# 完成检查
# ==========================================
echo -e ""
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}             安装全部完成!                  ${NC}"
echo -e "${GREEN}#############################################${NC}"
echo -e "管理后台: https://$POSTAL_DOMAIN"
echo -e ""
echo -e "${YELLOW}检查端口状态:${NC}"

# 简单的检查函数
check_port() {
    if docker ps | grep -q "$1"; then
        echo -e "  - $2: ${GREEN}运行中 (已映射)${NC}"
    else
        echo -e "  - $2: ${RED}未检测到 (请检查日志)${NC}"
    fi
}

check_port "0.0.0.0:25->25" "SMTP (25端口)"
check_port "postal-web" "Web 面板"
check_port "postal-caddy" "Caddy (SSL代理)"
echo -e ""
