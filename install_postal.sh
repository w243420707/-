
#!/bin/bash

# ==========================================
# Postal 一键安装脚本 (基于用户提供的教程)
# 环境要求: Ubuntu 20.04/22.04 LTS
# ==========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查是否为 Root 用户
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本 (sudo -i)${NC}"
  exit 1
fi

echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}      Postal Mail Server 一键安装脚本      ${NC}"
echo -e "${GREEN}=============================================${NC}"

# ==========================================
# 1. 获取用户输入
# ==========================================
read -p "请输入您的 Postal 域名 (例如 postal.example.com): " POSTAL_DOMAIN
if [ -z "$POSTAL_DOMAIN" ]; then
    echo -e "${RED}域名不能为空!${NC}"
    exit 1
fi

read -p "请输入管理员邮箱: " ADMIN_EMAIL
read -p "请输入管理员密码: " ADMIN_PASSWORD

# ==========================================
# 2. 安装基础依赖
# ==========================================
echo -e "${YELLOW}[1/7] 安装系统依赖...${NC}"
apt-get update
apt-get install -y git curl jq gnupg lsb-release

# ==========================================
# 3. 安装 Docker (如果未安装)
# ==========================================
echo -e "${YELLOW}[2/7] 检查并安装 Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Docker 已安装，跳过。"
fi

# ==========================================
# 4. 安装 Postal CLI
# ==========================================
echo -e "${YELLOW}[3/7] 安装 Postal CLI...${NC}"
if [ ! -d "/opt/postal/install" ]; then
    git clone https://github.com/postalserver/install /opt/postal/install
else
    echo "Postal 目录已存在，尝试更新..."
    cd /opt/postal/install && git pull
fi

# 创建软链接
if [ ! -L "/usr/bin/postal" ]; then
    ln -s /opt/postal/install/bin/postal /usr/bin/postal
fi

# ==========================================
# 5. 启动 MariaDB 容器
# ==========================================
echo -e "${YELLOW}[4/7] 启动 MariaDB...${NC}"

# 检查是否已存在同名容器，如果存在则跳过或删除
if [ "$(docker ps -aq -f name=postal-mariadb)" ]; then
    echo "发现旧的 postal-mariadb 容器，正在停止并删除..."
    docker rm -f postal-mariadb
fi

# 运行 MariaDB (密码硬编码为 postal，与教程一致)
docker run -d \
   --name postal-mariadb \
   -p 127.0.0.1:3306:3306 \
   --restart always \
   -e MARIADB_DATABASE=postal \
   -e MARIADB_ROOT_PASSWORD=postal \
   mariadb:10.6

echo "等待数据库启动 (10秒)..."
sleep 10

# ==========================================
# 6. 配置 Postal
# ==========================================
echo -e "${YELLOW}[5/7] 生成并配置 Postal...${NC}"

# 运行 Bootstrap
postal bootstrap "$POSTAL_DOMAIN"

# 修改配置文件 postal.yml 以匹配上面启动的 MariaDB 密码 'postal'
CONFIG_FILE="/opt/postal/config/postal.yml"

echo "正在修正数据库配置..."
# 使用 sed 替换数据库密码 (注意：这里假设生成的配置结构标准)
# 替换 main_db 下的 password
sed -i 's/password: .*/password: postal/' "$CONFIG_FILE"
# 确保 host 是 127.0.0.1 (Bootstrap 默认通常就是，但为了保险)
sed -i 's/host: .*/host: 127.0.0.1/' "$CONFIG_FILE"

# 初始化数据库
echo "正在初始化数据库 schema..."
postal initialize

# 创建管理员用户
echo "正在创建管理员账户..."
# 使用 expect 风格的输入重定向来自动填充 postal make-user 的交互
postal make-user <<EOF
Admin
User
$ADMIN_EMAIL
$ADMIN_PASSWORD
EOF

# 启动 Postal
echo "启动 Postal 服务..."
postal start

# ==========================================
# 7. 配置 Caddy (反向代理与 SSL)
# ==========================================
echo -e "${YELLOW}[6/7] 配置 Caddy 反向代理...${NC}"

# 创建 Caddyfile
cat > /opt/postal/config/Caddyfile <<EOF
$POSTAL_DOMAIN {
    reverse_proxy localhost:5000
}
EOF

# 启动 Caddy 容器
if [ "$(docker ps -aq -f name=postal-caddy)" ]; then
    docker rm -f postal-caddy
fi

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
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}      安装完成! Setup Completed!            ${NC}"
echo -e "${GREEN}=============================================${NC}"
echo -e "访问地址: https://$POSTAL_DOMAIN"
echo -e "管理员邮箱: $ADMIN_EMAIL"
echo -e "管理员密码: (您刚才输入的密码)"
echo -e ""
echo -e "${YELLOW}!!! 重要提示 (DNS 设置) !!!${NC}"
echo -e "请务必到您的域名服务商处添加以下 A 记录:"
echo -e "  $POSTAL_DOMAIN -> $(curl -s ifconfig.me)"
echo -e ""
echo -e "登录后台后，请依照界面提示配置 DKIM, SPF 和 Return-Path 记录。"
echo -e "祝您使用愉快！"
