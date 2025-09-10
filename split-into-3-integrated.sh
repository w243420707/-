#!/usr/bin/env bash
set -euo pipefail

log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

# 使 snap (LXD) 在 PATH 中
export PATH="/snap/bin:$PATH"; hash -r || true

# 全局可调
WAIT_MAX_TRIES="${WAIT_MAX_TRIES:-60}"  # 等待网络最多尝试次数，每次 2s
IMAGE="images:debian/12"
NAMES=(vps1 vps2 vps3)
SSH_PORTS=(10022 20022 30022)
RANGE_STARTS=(10000 20000 30000)
RANGE_ENDS=(19999 29999 39999)

# 0) 必须 root
if [[ $EUID -ne 0 ]]; then
  err "请用 root 运行：sudo -i 后再执行本脚本"
  exit 1
fi

# 1) 主机资源评估与 swap 兜底
log "检测主机资源..."
cores=$(nproc)
mem_total_mib=$(awk '/MemTotal/ {printf("%d", $2/1024)}' /proc/meminfo)
swap_total_mib=$(awk '/SwapTotal/ {printf("%d", $2/1024)}' /proc/meminfo || echo 0)
disk_avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
reserve_mem=512
mem_limit_each=$(( (mem_total_mib - reserve_mem) / 3 ))
(( mem_limit_each < 2048 )) && mem_limit_each=2048

target_total_need_mib=$(( 3*2048 + reserve_mem ))
have_now_mib=$(( mem_total_mib + swap_total_mib ))
need_swap_mib=0
(( have_now_mib < target_total_need_mib )) && need_swap_mib=$(( target_total_need_mib - have_now_mib ))

pool_size_gb=$(( disk_avail_gb * 70 / 100 ))
(( pool_size_gb < 7 )) && warn "/ 可用 ${disk_avail_gb}GiB，池预计 ${pool_size_gb}GiB，可能紧张。尝试继续。"
disk_each=$(( pool_size_gb / 3 )); (( disk_each < 2 )) && disk_each=2

echo "========== 资源预估 =========="
echo "CPU: ${cores} 核"
echo "物理内存: ${mem_total_mib}MiB (swap: ${swap_total_mib}MiB)"
echo "容器内存上限: ${mem_limit_each}MiB/台（不足由宿主 swap 兜底）"
echo "/ 可用磁盘: ${disk_avail_gb}GiB -> 池: ${pool_size_gb}GiB -> 每台: ${disk_each}GiB"
echo "================================"

log "准备宿主 swap 兜底..."
if (( need_swap_mib > 0 )); then
  log "新增 swap: ${need_swap_mib}MiB"
  fallocate -l ${need_swap_mib}M /swapfile-lxd || dd if=/dev/zero of=/swapfile-lxd bs=1M count=${need_swap_mib}
  chmod 600 /swapfile-lxd
  mkswap /swapfile-lxd
  swapon /swapfile-lxd
  grep -q '^/swapfile-lxd ' /etc/fstab || echo '/swapfile-lxd none swap sw 0 0' >> /etc/fstab
else
  log "内存+swap 已满足最低需求，无需新增。"
fi
sysctl -w vm.swappiness=60 >/dev/null
sed -i '/^vm.swappiness/d' /etc/sysctl.conf; echo 'vm.swappiness=60' >> /etc/sysctl.conf

# 2) 安装依赖与 LXD/Incus
log "安装基础依赖..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd curl gpg ca-certificates util-linux
systemctl enable --now snapd || true
sleep 3
ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
export PATH="/snap/bin:$PATH"; hash -r || true

CLI_BIN=""; INIT_CMD=""; PRESEED_FILE="/root/lxd-preseed.yaml"

install_lxd_snap() {
  log "尝试通过 snap 安装 LXD..."
  snap install core || true
  snap install lxd --channel=latest/stable || true
  snap wait system seed.loaded || true
  export PATH="/snap/bin:$PATH"; hash -r || true
  if command -v lxd >/dev/null 2>&1; then
    CLI_BIN="lxc"; INIT_CMD="lxd init --preseed"
    log "LXD 安装/就绪。"
    return 0
  fi
  return 1
}

install_incus_apt() {
  log "LXD 不可用，切换安装 Incus（APT）..."
  . /etc/os-release
  curl -fsSL https://repo.zabbly.com/key.asc | gpg --dearmor -o /usr/share/keyrings/zabbly.gpg
  echo "deb [signed-by=/usr/share/keyrings/zabbly.gpg] https://repo.zabbly.com/incus/stable/${ID}/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/zabbly-incus.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y incus
  if command -v incus >/dev/null 2>&1; then
    CLI_BIN="incus"; INIT_CMD="incus admin init --preseed"
    log "Incus 安装/就绪。"
    return 0
  fi
  return 1
}

if ! install_lxd_snap; then
  if ! install_incus_apt; then
    err "LXD/Incus 均不可用，请检查 snap/apt 环境。"
    exit 1
  fi
fi

# 3) lxd/incus 初始化（优先 btrfs，失败回退 dir），已初始化则忽略错误
STORAGE_DRIVER="btrfs"
HAS_DISK_QUOTA=1 # dir 不支持 size

write_preseed() {
  cat >"${PRESEED_FILE}" <<EOF
config: {}
networks:
- config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: none
  description: "Auto NAT bridge"
  name: lxdbr0
  type: bridge
storage_pools:
- name: default
  driver: ${STORAGE_DRIVER}
  config:
$(if [[ "${STORAGE_DRIVER}" != "dir" ]]; then echo "    size: ${pool_size_gb}GB"; fi)
profiles:
- name: default
  description: "Default profile"
  devices:
    eth0:
      type: nic
      name: eth0
      network: lxdbr0
    root:
      type: disk
      path: /
      pool: default
$(if (( HAS_DISK_QUOTA==1 )); then echo "      size: ${disk_each}GB"; fi)
cluster: null
EOF
}

log "初始化 ${CLI_BIN^^}..."
write_preseed
set +e
bash -lc "${INIT_CMD} < ${PRESEED_FILE}"
rc_init=$?
set -e
if (( rc_init != 0 )); then
  warn "btrfs 初始化失败或已初始化，尝试回退 dir（若已初始化则跳过回退）"
  if grep -q "not supported" <<<"$( (bash -lc "${INIT_CMD} < ${PRESEED_FILE}" ) 2>&1 || true)"; then
    STORAGE_DRIVER="dir"; HAS_DISK_QUOTA=0
    write_preseed
    set +e
    bash -lc "${INIT_CMD} < ${PRESEED_FILE}"
    set -e
  fi
fi

# 确保 images 远端存在（存在则不再添加，避免提示）
if ! ${CLI_BIN} remote list 2>/dev/null | awk '{print $1}' | grep -qx images; then
  log "添加 images 远端..."
  ${CLI_BIN} remote add images https://images.linuxcontainers.org --protocol simplestreams || true
fi

# 4) 确保 lxdbr0 NAT/DHCP/DNS（不使用 restart）
if ! ${CLI_BIN} network show lxdbr0 >/dev/null 2>&1; then
  log "创建 lxdbr0（NAT）..."
  ${CLI_BIN} network create lxdbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none || true
fi
${CLI_BIN} network set lxdbr0 ipv4.nat true || true
${CLI_BIN} network set lxdbr0 ipv4.dhcp true || true
${CLI_BIN} network set lxdbr0 dns.mode managed 2>/dev/null || true
${CLI_BIN} network set lxdbr0 dns.nameservers "1.1.1.1 8.8.8.8" 2>/dev/null || true

# 打开宿主内核转发（瞬时 + 持久）
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
grep -q '^net.ipv4.conf.all.forwarding=1' /etc/sysctl.conf || echo 'net.ipv4.conf.all.forwarding=1' >> /etc/sysctl.conf

# default profile 自愈
if ! ${CLI_BIN} profile show default | grep -q 'eth0:'; then
  ${CLI_BIN} profile device add default eth0 nic network=lxdbr0 name=eth0 \
    || ${CLI_BIN} profile device add default eth0 nic nictype=bridged parent=lxdbr0 name=eth0
fi
if (( HAS_DISK_QUOTA==1 )); then
  ${CLI_BIN} profile device set default root size ${disk_each}GB || true
else
  warn "当前存储驱动为 dir，不支持硬性磁盘配额。"
fi

# 5) 创建并启动容器（幂等） + 配额
cpu_base=$(( cores / 3 )); cpu_rem=$(( cores % 3 ))
declare -a cpu
for i in 0 1 2; do
  extra=0; (( i < cpu_rem )) && extra=1
  cpu[$i]=$(( cpu_base + extra ))
  (( cpu[$i] < 1 )) && cpu[$i]=1
done

log "创建并启动容器（幂等）..."
for i in 0 1 2; do
  n=${NAMES[$i]}
  if ! ${CLI_BIN} info "$n" >/dev/null 2>&1; then
    ${CLI_BIN} launch "$IMAGE" "$n"
  else
    ${CLI_BIN} start "$n" >/dev/null 2>&1 || true
  fi
  ${CLI_BIN} config set "$n" limits.cpu "${cpu[$i]}" || true
  ${CLI_BIN} config set "$n" limits.memory "${mem_limit_each}MiB" || true
  ${CLI_BIN} config set "$n" limits.memory.swap true || true
done

# 6) 等待容器网络（尽量判断，失败不阻断）
net_ready() {
  local name="$1" tries="${2:-$WAIT_MAX_TRIES}"
  for t in $(seq 1 "$tries"); do
    if ${CLI_BIN} exec "$name" -- bash -lc 'ip -4 -o addr show dev eth0 | grep -q "inet " && ip -4 r | grep -q "^default "' 2>/dev/null; then
      ${CLI_BIN} exec "$name" -- bash -lc 'ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || (timeout 2 bash -lc "</dev/tcp/1.1.1.1/53" >/dev/null 2>&1) || (timeout 2 bash -lc "</dev/tcp/8.8.8.8/53" >/dev/null 2>&1)' && return 0
    fi
    sleep 2
  done
  return 1
}

log "容器内初始化（SSH + root 登录）..."
declare -a ROOT_PASS IPS
for n in "${NAMES[@]}"; do
  if ! net_ready "$n" "$WAIT_MAX_TRIES"; then
    warn "容器 $n 网络连通性未通过（可能屏蔽 ICMP 或外网受限），继续执行。"
  fi

  set +e
  ${CLI_BIN} exec "$n" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server e2fsprogs'
  rc_apt=$?
  set -e
  (( rc_apt != 0 )) && warn "$n apt 安装失败，可能无法访问外网；稍后可手动：apt-get update && apt-get install -y openssh-server"

  # 为 root 生成随机密码并启用 root + 密码登录
  pass="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12 || echo TempRoot123)"
  ${CLI_BIN} exec "$n" -- bash -lc "echo 'root:${pass}' | chpasswd" || warn "$n 设置 root 密码失败"

  # 写入 drop-in 配置启用 root + 密码登录（Debian 12 默认读取 sshd_config.d）
  ${CLI_BIN} exec "$n" -- bash -lc "mkdir -p /etc/ssh/sshd_config.d && cat >/etc/ssh/sshd_config.d/00-enable-root.conf <<'CONF'
PermitRootLogin yes
PasswordAuthentication yes
UsePAM yes
CONF"
  ${CLI_BIN} exec "$n" -- systemctl enable --now ssh || warn "$n 启用 SSH 失败"
  ${CLI_BIN} exec "$n" -- systemctl reload ssh >/dev/null 2>&1 || ${CLI_BIN} exec "$n" -- systemctl restart ssh || true

  ROOT_PASS+=("$pass")

  # 获取 IPv4
  ip=""
  for t in $(seq 1 30); do
    ip=$(${CLI_BIN} list "$n" -c 4 --format csv | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
    [[ -n "$ip" ]] && break
    sleep 1
  done
  IPS+=("${ip:-N/A}")
done

# 7) 容器内 swap（按根盘大小）
log "为容器创建自适应 swap..."
container_swap_mib=1024
(( disk_each <= 2 )) && container_swap_mib=256
(( disk_each > 2 && disk_each <= 3 )) && container_swap_mib=512

for n in "${NAMES[@]}"; do
  ${CLI_BIN} exec "$n" -- bash -lc "
    set -e
    mkdir -p /swap
    if stat -f -c %T / | grep -qi btrfs; then chattr +C /swap || true; fi
    avail=\$(df -m / | awk 'NR==2 {print \$4}')
    want=${container_swap_mib}
    if [ \"\$avail\" -gt 512 ]; then
      max=\$(( avail - 256 ))
      if [ \$want -gt \$max ]; then want=\$max; fi
    else
      want=0
    fi
    if [ \$want -ge 128 ]; then
      if [ ! -f /swap/swapfile ]; then
        (fallocate -l \${want}M /swap/swapfile || dd if=/dev/zero of=/swap/swapfile bs=1M count=\${want})
        chmod 600 /swap/swapfile
        mkswap /swap/swapfile
      fi
      swapon /swap/swapfile || (mkswap /swap/swapfile && swapon /swap/swapfile)
      grep -q '^/swap/swapfile ' /etc/fstab || echo '/swap/swapfile none swap sw 0 0' >> /etc/fstab
      sysctl -w vm.swappiness=60 >/dev/null
      sed -i '/^vm.swappiness/d' /etc/sysctl.conf; echo 'vm.swappiness=60' >> /etc/sysctl.conf
    else
      echo '[INFO] 容器根盘空间紧张，跳过容器内 swap 创建'
    fi
  " || warn "$n 容器内 swap 创建失败（可忽略）"
done

# 8) 端口映射（范围 + SSH 独立端口）
log "配置端口映射..."
for i in 0 1 2; do
  n=${NAMES[$i]}
  s=${RANGE_STARTS[$i]}
  e=${RANGE_ENDS[$i]}
  sp=${SSH_PORTS[$i]}
  pre=$((sp-1)); post=$((sp+1))

  # 清理残留设备
  ${CLI_BIN} config device remove "$n" tcp-range1 >/dev/null 2>&1 || true
  ${CLI_BIN} config device remove "$n" tcp-range2 >/dev/null 2>&1 || true
  ${CLI_BIN} config device remove "$n" udp-range1 >/dev/null 2>&1 || true
  ${CLI_BIN} config device remove "$n" udp-range2 >/dev/null 2>&1 || true
  ${CLI_BIN} config device remove "$n" ssh        >/dev/null 2>&1 || true

  # 前半段范围（避开 SSH 端口）
  if (( s <= pre )); then
    ${CLI_BIN} config device add "$n" tcp-range1 proxy listen=tcp:0.0.0.0:${s}-${pre}   connect=tcp:127.0.0.1:${s}-${pre}   || true
    ${CLI_BIN} config device add "$n" udp-range1 proxy listen=udp:0.0.0.0:${s}-${pre}   connect=udp:127.0.0.1:${s}-${pre}   || true
  fi
  # 后半段范围
  if (( post <= e )); then
    ${CLI_BIN} config device add "$n" tcp-range2 proxy listen=tcp:0.0.0.0:${post}-${e}  connect=tcp:127.0.0.1:${post}-${e}  || true
    ${CLI_BIN} config device add "$n" udp-range2 proxy listen=udp:0.0.0.0:${post}-${e}  connect=udp:127.0.0.1:${post}-${e}  || true
  fi
  # SSH 独立端口
  ${CLI_BIN} config device add "$n" ssh proxy listen=tcp:0.0.0.0:${sp} connect=tcp:127.0.0.1:22 || true
done

# 9) 输出连接信息（屏幕 + 文件）
log "生成连接信息..."
host_ip=$(hostname -I | awk '{print $1}')
outfile="/root/three-vps-info.txt"
: > "$outfile"
echo "宿主机IP: ${host_ip:-你的宿主机IP}" | tee -a "$outfile"
echo "" | tee -a "$outfile"

ranges_desc=("10000-19999（避开 10022）" "20000-29999（避开 20022）" "30000-39999（避开 30022）")
for i in 0 1 2; do
  n=${NAMES[$i]}
  ip=${IPS[$i]}
  sp=${SSH_PORTS[$i]}
  r=${ranges_desc[$i]}
  pw=${ROOT_PASS[$i]}
  {
    echo "- ${n}:"
    echo "  容器IP: ${ip}"
    echo "  SSH: ${host_ip:-你的宿主机IP}:${sp}"
    echo "  用户: root"
    echo "  密码: ${pw}"
    echo "  可用端口范围: ${r}（TCP/UDP，通过宿主同端口访问）"
    echo ""
  } | tee -a "$outfile"
done

log "完成！信息写入：$outfile"
echo "示例登录：ssh -p 10022 root@${host_ip:-宿主机IP}"
