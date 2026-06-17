#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/root/vps_cleanup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

PATTERNS=(
  'xmrig'
  'c3pool'
  'gh\.felicity\.ac\.cn'
  'auto\.c3pool'
  'SystemLoger'
  '/opt/systemlog'
  '/opt/nezha'
  '/dev/shm/\.kwo'
  '/tmp/b'
  '/tmp/tm\.sh'
  '4AP5ivAuWpC8ykYe83hUHjViNNoEZuMuHgExKvo9snqZarHaoYzUnj3fTskEgBAUGm5qVhoaRtp3bXVNzRtPu6rqTjG85WW'
  'fuckx86'
  'stratum'
  'miner'
  'kworkerd'
  'kinsing'
  'watchdog'
)

remove_if_exists() {
  for target in "$@"; do
    if [ -e "$target" ]; then
      echo "[DEL] $target"
      rm -rf -- "$target"
    fi
  done
}

kill_matches() {
  local regex
  regex=$(IFS='|'; echo "${PATTERNS[*]}")
  echo "[KILL] matching processes"
  pkill -9 -f "$regex" 2>/dev/null || true
}

disable_systemd_units() {
  local units=()
  while IFS= read -r line; do
    units+=("$line")
  done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'nezha|systemlog|xmrig|miner|c3pool' || true)

  if [ "${#units[@]}" -gt 0 ]; then
    echo "[SYSTEMD] disabling suspicious units: ${units[*]}"
    systemctl stop "${units[@]}" 2>/dev/null || true
    systemctl disable "${units[@]}" 2>/dev/null || true
  fi

  for unit_file in \
    /etc/systemd/system/nezha-agent.service \
    /etc/systemd/system/nezha-agent-5379450.service \
    /etc/systemd/system/nezha-agent-1107b03.service \
    /etc/systemd/system/systemlog.service
  do
    if [ -f "$unit_file" ]; then
      echo "[DEL] $unit_file"
      rm -f -- "$unit_file"
    fi
  done

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

clean_cron() {
  local crontab_file="/var/spool/cron/crontabs/root"
  if [ -f "$crontab_file" ]; then
    echo "[CRON] cleaning root crontab file"
    cp -a "$crontab_file" "${crontab_file}.bak.$(date +%s)"
    grep -vE 'xmrig|c3pool|SystemLoger|/dev/shm|\.kwo|gh\.felicity|4AP5ivAu|stratum|/tmp/b|tm\.sh|nezha' "$crontab_file" > "${crontab_file}.new" || true
    mv "${crontab_file}.new" "$crontab_file"
    chmod 600 "$crontab_file" || true
  fi

  if command -v crontab >/dev/null 2>&1; then
    local current
    current=$(crontab -l 2>/dev/null || true)
    if [ -n "$current" ]; then
      echo "[CRON] filtering active root crontab"
      printf '%s\n' "$current" | grep -vE 'xmrig|c3pool|SystemLoger|/dev/shm|\.kwo|gh\.felicity|4AP5ivAu|stratum|/tmp/b|tm\.sh|nezha' | crontab - || true
    fi
  fi
}

clean_authorized_keys() {
  local auth_file="/root/.ssh/authorized_keys"
  if [ -f "$auth_file" ]; then
    echo "[SSH] filtering authorized_keys"
    cp -a "$auth_file" "${auth_file}.bak.$(date +%s)"
    grep -vE 'fuckx86|IBqaw3soJ/1SbxtsBG4G35e/xnsIcQfQQ1ff0h2Gw/9Y|xmrig|c3pool|SystemLoger|nezha' "$auth_file" > "${auth_file}.new" || true
    mv "${auth_file}.new" "$auth_file"
    chmod 600 "$auth_file" || true
  fi
}

clean_shell_startup() {
  local files=(
    /etc/profile
    /etc/bash.bashrc
    /root/.bashrc
    /root/.profile
    /root/.zshrc
    /etc/profile.d/*.sh
  )
  local file
  for file in "${files[@]}"; do
    [ -e "$file" ] || continue
    if grep -Eq 'xmrig|c3pool|SystemLoger|/dev/shm|\.kwo|gh\.felicity|4AP5ivAu|stratum|/tmp/b|tm\.sh|nezha' "$file" 2>/dev/null; then
      echo "[WARN] suspicious startup reference in $file; inspect manually"
    fi
  done
}

remove_known_artifacts() {
  remove_if_exists \
    /tmp/b \
    /tmp/tm.sh \
    /tmp/.bashrc \
    /tmp/.zshrc \
    /opt/systemlog \
    /opt/nezha \
    /dev/shm/.start_task.pl \
    /dev/shm/.panelTask.pl \
    /root/.ssh/sshkey \
    /root/.ssh/sshkey.pub

  for payload in /dev/shm/.kwo* /opt/nezha/agent/xmrig-* /opt/nezha/agent/x.tar.gz; do
    [ -e "$payload" ] && remove_if_exists "$payload"
  done
}

scan_network() {
  echo "[NET] suspicious sockets after cleanup"
  ss -plant 2>/dev/null | grep -Ei 'xmrig|c3pool|SystemLoger|nezha|memfd|3333|4444|5555|7777|14444|stratum|24\.144\.123\.109|170\.9\.40\.181|192\.227\.223\.187|auto\.c3pool' || true
}

scan_recent_files() {
  echo "[SCAN] recent suspicious files after cleanup"
  find /dev/shm /tmp /var/tmp /opt /etc/systemd/system /var/spool/cron /www/server/cron -maxdepth 3 -type f \( -perm -111 -o -name '.*' \) -printf '%TY-%Tm-%Td %TH:%TM %m %u %g %s %p\n' 2>/dev/null | \
    grep -Ei 'xmrig|c3pool|SystemLoger|nezha|\.kwo|gh\.felicity|4AP5ivAu|stratum|/tmp/b|tm\.sh|/opt/systemlog|/opt/nezha|x\.tar\.gz' || true
}

final_process_scan() {
  echo "[PROC] suspicious processes after cleanup"
  ps -eo pid,ppid,user,stat,pcpu,pmem,comm,args --sort=-pcpu | \
    grep -Ei 'xmrig|c3pool|SystemLoger|nezha|memfd|/dev/shm|/tmp/|\.kwo|stratum|miner|gh\.felicity|4AP5ivAu|/opt/systemlog' | grep -v grep || true
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
  fi

  echo "=== VPS cleanup started: $(date) ==="
  echo "Log: $LOG_FILE"
  kill_matches
  disable_systemd_units
  clean_cron
  clean_authorized_keys
  clean_shell_startup
  remove_known_artifacts
  final_process_scan
  scan_network
  scan_recent_files
  echo "=== VPS cleanup finished: $(date) ==="
  echo "建议执行后立刻修改 root/面板/数据库密码，并重启 VPS 后再跑一遍本脚本复查。"
}

main "$@"
