#!/usr/bin/env bash
set -euo pipefail

log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

# 可调参数：网络等待最多尝试次数（默认 60 次，每次 2 秒 => 最长 ~120 秒）
WAIT_MAX_TRIES="${WAIT_MAX_TRIES:-60}"

# 0) 必须 root
if [[ $EUID -ne 0 ]]; then
  err "请用 root 运行：sudo -i 然后再执行本脚本"
  exit 1
fi

# 1) 检测资源（低内存也继续，用 swap 兜底）
log "检测主机资源..."
cores=$(nproc)
mem_total_mib=$(awk '/MemTotal/ {printf("%d", $2/1024)}' /proc/meminfo)
swap_total_mib=$(awk '/SwapTotal/ {printf("%d", $2/1024)}' /proc/meminfo || echo 0)
disk_avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')

reserve_mem=512   # 为宿主预留（MiB）

# 每容器内存上限：至少 2GiB；若物理更高再提升
mem_phys_each=$(( (mem_total_mib - reserve_mem) / 3 ))
mem_limit_each=$mem_phys_each
if (( mem_limit_each < 2048 )); then mem_limit_each=2048; fi

# 兜底 swap：保证 3 台 * 2GiB + 宿主预留
target_total_need_mib=$(( 3*2048 + reserve_mem ))
have_now_mib=$(( mem_total_mib + swap_total_mib ))
need_swap_mib=0
if (( have_now_mib < target_total_need_mib )); then
  need_swap_mib=$(( target_total_need_mib - have_now_mib ))
fi

# 存储池使用 / 可用空间的 70%
pool_size_gb=$(( disk_avail_gb * 70 / 100 ))
if (( pool_size_gb < 7 )); then
  warn "/ 可用 ${disk_avail_gb}GiB，池预计 ${pool_size_gb}GiB，可能紧张。尝试继续。"
fi
disk_each=$(( pool_size_gb / 3 ))
if (( disk_each < 2 )); then disk_each=2; fi

echo "========== 资源预估 =========="
echo "CPU: ${cores} 核"
echo "物理内存: ${mem_total_mib}MiB  (现有 swap: ${swap_total_mib}MiB)"
echo "容器内存上限: ${mem_limit_each}MiB/台（不足由宿主 swap 兜底）"
echo "/ 可用磁盘: ${disk_avail_gb}GiB -> 池: ${pool_size_gb}GiB -> 每台: ${disk_each}GiB (目标硬限≥2GiB)"
echo "================================"

# 2) 准备宿主 swap 兜底
log "准备宿主 swap（确保至少满足 3x2GiB + 预留 ${reserve_mem}MiB）..."
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
# 调整 swappiness（更愿意使用 swap，降低 OOM 风险）
sysctl -w vm.swappiness=60 >/dev/null
sed -i '/^vm.swappiness/d' /etc/sysctl.conf; echo 'vm.swappiness=60' >> /etc/sysctl.conf

# 3) 安装基础依赖 & snapd
log "安装基础依赖..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd curl gpg ca-certificates util-linux
systemctl enable --now snapd || true
sleep 3
ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
export PATH=/snap/bin:$PATH

# 4) 安装 LXD（snap）或回退到 Incus（APT）
CLI_BIN=""; INIT_CMD=""; PRESEED_FILE="/root/lxd-preseed.yaml"
install_lxd_snap() {
  log "尝试通过 snap 安装 LXD..."
  snap install core || true
  snap install lxd --channel=latest/stable || true
  snap wait system seed.loaded || true
  export PATH=/snap/bin:$PATH
  if command -v lxd >/dev/null 2>&1; then
    CLI_BIN="lxc"
    INIT_CMD="lxd init --preseed"
    log "LXD 安装成功。"
    return 0
  fi
  return 1
}
install_incus_apt() {
  log "LXD 不可用，切换安装 Incus（APT 仓库）..."
  . /etc/os-release
  curl -fsSL https://repo.zabbly.com/key.asc | gpg --dearmor -o /usr/share/keyrings/zabbly.gpg
  echo "deb [signed-by=/usr/share/keyrings/zabbly.gpg] https://repo.zabbly.com/incus/stable/${ID}/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/zabbly-incus.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y incus
  if command -v incus >/dev/null 2>&1; then
    CLI_BIN="incus"
    INIT_CMD="incus admin init --preseed"
    log "Incus 安装成功。"
    return 0
  fi
  return 1
}
if ! install_lxd_snap; then
  if ! install_incus_apt; then
    err "LXD/Incus 都不可用，请检查系统是否支持 snap 或 Incus 仓库添加是否成功。"
    exit 1
  fi
fi

# 5) 生成并应用 preseed（优先 btrfs，失败回退 dir）
STORAGE_DRIVER="btrfs"
HAS_DISK_QUOTA=1 # btrfs/zfs/lvm 才支持 size 配额；dir 不支持

write_preseed() {
  cat >"${PRESEED_FILE}" <<EOF
config: {}
networks:
- config:
    ipv4.address: auto
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

log "初始化 ${CLI_BIN^^}（优先 btrfs 循环池）..."
write_preseed
set +e
bash -lc "${INIT_CMD} < ${PRESEED_FILE}"
rc_init=$?
set -e
if (( rc_init != 0 )); then
  warn "btrfs 初始化失败，回退为 dir 驱动（将无法硬性限制磁盘配额）。"
  STORAGE_DRIVER="dir"; HAS_DISK_QUOTA=0
  write_preseed
  bash -lc "${INIT_CMD} < ${PRESEED_FILE}"
fi

# 自愈：确保 images 远端存在（Incus 某些环境默认没有）
if ! ${CLI_BIN} remote list 2>/dev/null | grep -qE '(^|\s)images(\s|$)'; then
  log "添加 images 远端..."
  ${CLI_BIN} remote add images https://images.linuxcontainers.org --protocol simplestreams || true
fi

# 自愈：确保 lxdbr0 存在且启用 NAT
if ! ${CLI_BIN} network show lxdbr0 >/dev/null 2>&1; then
  log "创建 lxdbr0（NAT）..."
  ${CLI_BIN} network create lxdbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none
fi

# 自愈：default profile 具备网卡 & （如可用）root size
if ! ${CLI_BIN} profile show default | grep -q 'eth0:'; then
  ${CLI_BIN} profile device add default eth0 nic network=lxdbr0 name=eth0 \
    || ${CLI_BIN} profile device add default eth0 nic nictype=bridged parent=lxdbr0 name=eth0
fi
if (( HAS_DISK_QUOTA==1 )); then
  ${CLI_BIN} profile device set default root size ${disk_each}GB || true
else
  warn "当前存储驱动不支持硬性配额（dir），无法对容器根盘设置硬限。"
fi

# 6) 创建容器并设置配额
names=(vps1 vps2 vps3)
image="images:debian/12"

# 均分 CPU（至少 1）
cpu_base=$(( cores / 3 ))
cpu_rem=$(( cores % 3 ))
declare -a cpu
for i in {0..2}; do
  extra=0
  if (( i < cpu_rem )); then extra=1; fi
  cpu[$i]=$(( cpu_base + extra ))
  if (( cpu[$i] < 1 )); then cpu[$i]=1; fi
done

log "创建三台容器并设置配额..."
for i in {0..2}; do
  n=${names[$i]}
  log "启动 ${n} ..."
  if ! ${CLI_BIN} launch "$image" "$n"; then
    sleep 2
    ${CLI_BIN} launch "$image" "$n"
  fi
  ${CLI_BIN} config set "$n" limits.cpu "${cpu[$i]}"
  ${CLI_BIN} config set "$n" limits.memory "${mem_limit_each}MiB"
  ${CLI_BIN} config set "$n" limits.memory.swap true
done

# 7) 等待容器网络就绪（改进且有超时）并初始化：SSH + 用户 + 获取 IP
net_ready() {
  local name="$1"
  local tries="${2:-$WAIT_MAX_TRIES}"
  for t in $(seq 1 "$tries"); do
    # 条件1：容器已有 IPv4 和默认路由
    if ${CLI_BIN} exec "$name" -- bash -lc 'ip -4 -o addr show dev eth0 | grep -qE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" && ip -4 r | grep -q "^default "' 2>/dev/null; then
      # 条件2：ICMP 或 TCP 53 任一可用即视为可用
      if ${CLI_BIN} exec "$name" -- bash -lc 'ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 || (timeout 2 bash -lc "</dev/tcp/1.1.1.1/53" >/dev/null 2>&1) || (timeout 2 bash -lc "</dev/tcp/8.8.8.8/53" >/dev/null 2>&1)'; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

log "容器内初始化与 SSH 配置..."
declare -a passw ips
for n in "${names[@]}"; do
  if ! net_ready "$n" "$WAIT_MAX_TRIES"; then
    warn "容器 $n 网络连通性检测未通过（可能屏蔽 ICMP 或外网受限），继续执行后续步骤。"
  fi

  # 初始化 SSH 和 admin 用户
  set +e
  ${CLI_BIN} exec "$n" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sudo e2fsprogs'
  rc_apt=$?
  set -e
  if (( rc_apt != 0 )); then
    warn "$n apt 安装失败，可能无法访问外网。稍后可进入容器手动执行：apt-get update && apt-get install -y openssh-server sudo"
  fi

  user="admin"
  pass="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)"
  ${CLI_BIN} exec "$n" -- bash -lc "id -u $user >/dev/null 2>&1 || useradd -m -s /bin/bash $user"
  ${CLI_BIN} exec "$n" -- bash -lc "echo '$user:$pass' | chpasswd && usermod -aG sudo $user" || warn "$n 设置用户密码失败"
  ${CLI_BIN} exec "$n" -- systemctl enable --now ssh || warn "$n 启用 SSH 失败"
  passw+=("$pass")

  # 获取容器 IPv4
  ip=""
  for t in {1..30}; do
    ip=$(${CLI_BIN} list "$n" -c 4 --format csv | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
    [[ -n "$ip" ]] && break
    sleep 1
  done
  ips+=("${ip:-N/A}")
done
# 8) 容器内 swap（小盘自适应，避免挤爆 2GiB 根盘）
log "为容器创建自适应 swap（根据根盘大小）..."
container_swap_mib=1024
if (( disk_each <= 2 )); then
  container_swap_mib=256
elif (( disk_each <= 3 )); then
  container_swap_mib=512
fi

for n in "${names[@]}"; do
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

# 9) 端口映射（整段 TCP/UDP，避开 SSH 专用端口）
log "配置端口映射（范围较大，确保宿主性能充足）..."
starts=(10000 20000 30000)
ends=(19999 29999 39999)
ssh_ports=(10022 20022 30022)

for i in {0..2}; do
  n=${names[$i]}
  s=${starts[$i]}
  e=${ends[$i]}
  sp=${ssh_ports[$i]}
  pre=$((sp-1))
  post=$((sp+1))

  # 映射前半段 [start, ssh-1]
  if (( s <= pre )); then
    ${CLI_BIN} config device add "$n" tcp-range1 proxy listen=tcp:0.0.0.0:${s}-${pre}   connect=tcp:127.0.0.1:${s}-${pre}   || true
    ${CLI_BIN} config device add "$n" udp-range1 proxy listen=udp:0.0.0.0:${s}-${pre}   connect=udp:127.0.0.1:${s}-${pre}   || true
  fi
  # 映射后半段 [ssh+1, end]
  if (( post <= e )); then
    ${CLI_BIN} config device add "$n" tcp-range2 proxy listen=tcp:0.0.0.0:${post}-${e}  connect=tcp:127.0.0.1:${post}-${e}  || true
    ${CLI_BIN} config device add "$n" udp-range2 proxy listen=udp:0.0.0.0:${post}-${e}  connect=udp:127.0.0.1:${post}-${e}  || true
  fi
  # 独立 SSH（宿主 sp -> 容器 22）
  ${CLI_BIN} config device add "$n" ssh proxy listen=tcp:0.0.0.0:${sp} connect=tcp:127.0.0.1:22 || true
done

# 10) 输出连接信息（屏幕显示 + 写入文件，包含密码）
log "输出连接信息..."
host_ip=$(hostname -I | awk '{print $1}')
outfile="/root/three-vps-info.txt"
: > "$outfile"

echo "宿主机IP: ${host_ip:-你的宿主IP}" | tee -a "$outfile"
echo "" | tee -a "$outfile"

ranges_desc=("10000-19999（避开 10022）" "20000-29999（避开 20022）" "30000-39999（避开 30022）")
for i in {0..2}; do
  n=${names[$i]}
  ip=${ips[$i]}
  sp=${ssh_ports[$i]}
  r=${ranges_desc[$i]}
  pw=${passw[$i]}
  {
    echo "- ${n}:"
    echo "  容器IP: ${ip}"
    echo "  SSH: ${host_ip:-你的宿主机IP}:${sp}"
    echo "  用户: admin"
    echo "  密码: ${pw}"
    echo "  可用端口范围: ${r}（TCP/UDP，通过宿主同端口访问）"
    echo ""
  } | tee -a "$outfile"
done

log "完成！详细信息已写入：$outfile"
echo "示例登录：ssh -p 10022 admin@${host_ip:-宿主机IP}"
