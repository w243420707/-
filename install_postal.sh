#!/bin/bash

# ================= 配置区域 =================
# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
# ===========================================

echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}      Postal 邮件服务器全自动安装脚本 (智能版)         ${NC}"
echo -e "${GREEN}    自动检测网络环境 (国内/国外) - 自动适配镜像源      ${NC}"
echo -e "${GREEN}=======================================================${NC}"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 2. 获取用户配置
echo -e "${YELLOW}--- 配置向导 ---${NC}"
read -p "请输入您的域名 (例如 mail.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ 域名不能为空！${NC}"
    exit 1
fi

read -p "请输入 SMTP 端口 (直接回车默认使用 2525，推荐): " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-2525}

# 3. 基础依赖安装 & 网络检测
echo -e "${CYAN}正在安装基础工具...${NC}"
apt-get update
apt-get install -y curl git jq apt-transport-https ca-certificates gnupg lsb-release

# === 核心功能：自动检测网络环境 ===
echo -e "${CYAN}正在检测服务器网络环境...${NC}"
REGION="global"
# 尝试连接 Google，超时时间 3 秒
if curl -s --connect-timeout 3 https://www.google.com > /dev/null; then
    echo -e "${GREEN}🌍 检测结果：国际网络环境${NC}"
    DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
    DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
else
    echo -e "${YELLOW}🇨🇳 检测结果：中国大陆环境 (无法访问 Google)${NC}"
    echo -e "${YELLOW}🚀 自动切换至：阿里云镜像源${NC}"
    REGION="china"
    DOCKER_GPG_URL="https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg"
    DOCKER_REPO_URL="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
fi
# ==================================

# 4. 安装 Docker (基于检测结果)
if ! command -v docker &> /dev/null; then
    echo -e "${CYAN}正在安装 Docker (源: $DOCKER_REPO_URL)...${NC}"
    
    mkdir -p /etc/apt/keyrings
    # 删除旧密钥防止冲突
    rm -f /etc/apt/keyrings/docker.gpg

    # 下载 GPG 密钥
    if curl -fsSL "$DOCKER_GPG_URL" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        echo -e "✅ GPG 密钥添加成功"
    else
        echo -e "${RED}❌ GPG 密钥下载失败，请检查网络${NC}"
        exit 1
    fi
    
    # 写入软件源
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_REPO_URL \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      
    # 安装 Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    systemctl start docker
    systemctl enable docker
    echo -e "${GREEN}✅ Docker 安装完成！${NC}"
else
    echo -e "${GREEN}✅ Docker 已安装，跳过。${NC}"
fi

# 5. 准备 Postal 代码
echo -e "${CYAN}准备 Postal 安装文件...${NC}"
mkdir -p /opt/postal/config
rm -rf /opt/postal/install
# 如果是国内环境，Git Clone 可能会慢，但 Github 还是得连
# 可以在这里添加 host 加速，但为了稳定性暂时保持原样
git clone https://github.com/postalserver/install /opt/postal/install
ln -sf /opt/postal/install/bin/postal /usr/bin/postal

# 6. 生成配置文件 (自动填入端口)
echo -e "${CYAN}正在生成配置文件 (SMTP端口: $SMTP_PORT)...${NC}"
openssl_key=$(openssl rand -hex 16)

cat > /opt/postal/config/postal.yml <<EOF
web:
  host: $DOMAIN
  protocol: https

web_server:
  bind_address: 127.0.0.1
  port: 5000
  max_threads: 5

main_db:
  host: 127.0.0.1
  username: root
  password: postal
  database: postal

message_db:
  host: 127.0.0.1
  username: root
  password: postal
  prefix: postal

rabbitmq:
  host: 127.0.0.1
  username: postal
  password: postal
  vhost: postal

dns:
  mx_records:
    - mx.$DOMAIN
  smtp_server_hostname: $DOMAIN
  spf_include: spf.$DOMAIN
  return_path: rp.$DOMAIN
  route_domain: routes.$DOMAIN
  track_domain: track.$DOMAIN

smtp:
  host: 127.0.0.1
  port: $SMTP_PORT
  tls_enabled: false
  tls_certificate_path:
  tls_private_key_path:

smtp_server:
  port: $SMTP_PORT
  tls_enabled: false
  tls_certificate_path:
  tls_private_key_path:
  proxy_protocol: false
  log_connect: true
  strip_received_headers: false
  max_message_size: 10

rails:
  environment: production
  secret_key: $openssl_key

general:
  use_ip_pools: false

logging:
  stdout: true
EOF

# 7. 初始化 Postal
echo -e "${CYAN}正在初始化数据库 (请耐心等待)...${NC}"
postal bootstrap postal
postal initialize
postal make-user

# 8. 启动服务
echo -e "${CYAN}启动 Postal 服务...${NC}"
postal start

# 9. 安装 Caddy (Web服务器)
echo -e "${CYAN}配置 Caddy 反向代理...${NC}"
docker rm -f postal-caddy 2>/dev/null

cat > /opt/postal/config/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

docker run -d --name postal-caddy \
  --restart always \
  --network host \
  -v /opt/postal/config/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:alpine caddy run --config /etc/caddy/Caddyfile

# 10. 最终结果
echo -e ""
echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}    🎉 安装全部完成！   ${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo -e "🌍 检测到的地区: ${YELLOW}$([ "$REGION" == "china" ] && echo "中国大陆 (已加速)" || echo "海外/国际")${NC}"
echo -e "🏠 管理面板: ${YELLOW}https://$DOMAIN${NC}"
echo -e "📨 SMTP 端口: ${YELLOW}$SMTP_PORT${NC} (请确保防火墙/安全组已放行!)"
echo -e ""
echo -e "正在验证端口监听状态..."
sleep 5
if netstat -tulnp | grep ":$SMTP_PORT" > /dev/null; then
    echo -e "${GREEN}✅ 成功：检测到端口 $SMTP_PORT 正在运行！${NC}"
else
    echo -e "${RED}❌ 警告：未检测到端口 $SMTP_PORT，请运行 'docker logs install-smtp-1' 查看错误。${NC}"
fi
echo -e "${GREEN}=======================================================${NC}"
