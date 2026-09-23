#!/usr/bin/env bash
# DORIK toolkit — shared functions. Sourced by every step script.
# Safe to `set -euo pipefail` in callers; every risky pipeline here is
# guarded with `|| true` where a non-zero exit is expected/normal.

# needrestart НЕ должен сам решать перезапускать службы (в т.ч. sshd) в фоне
# после apt install/upgrade — экспортируем это сразу при подключении lib.sh,
# чтобы это действовало во ВСЕХ скриптах тулкита, а не только там, где вызван
# apt_upgrade_smart (haproxy-setup.sh тоже делает apt-get install напрямую).
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1

C_RESET="\e[0m"; C_G="\e[32m"; C_Y="\e[33m"; C_R="\e[31m"; C_B="\e[36m"
info()  { echo -e "${C_B}[i]${C_RESET} $*"; }
ok()    { echo -e "${C_G}[✓]${C_RESET} $*"; }
warn()  { echo -e "${C_Y}[!]${C_RESET} $*"; }
err()   { echo -e "${C_R}[✗]${C_RESET} $*"; }
step()  { echo -e "\n${C_B}==>${C_RESET} $*"; }

# Numbered yes/no prompt. Usage: if ask_yes_no "Продолжить?" "1"; then ...
# Second arg = default numeric choice (1=yes,2=no) used if ENTER pressed.
ask_yes_no() {
  local prompt="${1:-}" default="${2:-1}" ans
  while true; do
    read -r -p "$(echo -e "${C_Y}?${C_RESET} ${prompt} [1-Да / 2-Нет] (по умолчанию ${default}): ")" ans
    ans="${ans:-$default}"
    case "$ans" in
      1) return 0 ;;
      2) return 1 ;;
      *) echo "Введите 1 или 2." ;;
    esac
  done
}

ask_value() {
  local prompt="${1:-}" default="${2:-}" ans
  read -r -p "$(echo -e "${C_Y}?${C_RESET} ${prompt}$( [ -n "$default" ] && echo " [$default]" ): ")" ans
  echo "${ans:-$default}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запустите скрипт от root (sudo)."
    exit 1
  fi
}

# ---- apt upgrade with skip-if-nothing-to-do -------------------------------
apt_upgrade_smart() {
  step "Проверка обновлений пакетов"
  apt-get update -qq || true
  local cnt
  cnt=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing' || true)
  if [ "${cnt:-0}" -eq 0 ]; then
    ok "Пакеты уже актуальны, апгрейд не требуется."
  else
    info "Найдено обновлений: ${cnt}. Обновляю..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || true
    ok "Пакеты обновлены."
  fi
}

# ---- ssh.socket vs ssh.service ---------------------------------------------
# LoadState-проверка надёжнее grep по list-unit-files: формат вывода
# list-unit-files (колонки/пробелы) отличается между версиями systemd и
# однажды дал ложный результат — "sshd" вместо реального "ssh", и
# systemctl restart падал с "Unit sshd.service not found."
detect_ssh_unit() {
  local u
  for u in ssh sshd; do
    if [ "$(systemctl show -p LoadState --value "${u}.service" 2>/dev/null)" = "loaded" ]; then
      echo "$u"
      return 0
    fi
  done
  # ничего не нашли штатным способом — последняя попытка через list-unit-files
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "ssh"  # ssh.service — норма для Debian/Ubuntu, sshd.service — для RHEL/CentOS
  fi
}

# Перезапускает SSH-службу, определяя юнит заново и подстраховываясь
# альтернативным именем, если определение всё равно ошиблось.
restart_ssh_service() {
  local unit alt out
  unit="$(detect_ssh_unit)"
  out=$(systemctl restart "${unit}.service" 2>&1)
  if [ $? -ne 0 ]; then
    warn "systemctl restart ${unit}.service не сработал (${out}), пробую альтернативное имя."
    alt="sshd"; [ "$unit" = "sshd" ] && alt="ssh"
    if systemctl restart "${alt}.service" 2>&1; then
      unit="$alt"
    else
      err "Не удалось перезапустить ни ${unit}.service, ни ${alt}.service."
      return 1
    fi
  fi
  echo "$unit"
  return 0
}

ensure_no_ssh_socket() {
  if systemctl is-active ssh.socket &>/dev/null; then
    warn "ssh.socket активен и может переопределять порт — отключаю."
    systemctl stop ssh.socket 2>&1 || true
    systemctl disable ssh.socket 2>&1 || true
  fi
  local unit; unit="$(detect_ssh_unit)"
  systemctl enable "${unit}" &>/dev/null || true
}

wait_for_port() {
  local port="${1:-}" tries=0
  [ -z "$port" ] && return 1
  while [ $tries -lt 10 ]; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      return 0
    fi
    sleep 1; tries=$((tries+1))
  done
  return 1
}

# ---- ufw helpers -------------------------------------------------------
# Delete every numbered ufw rule matching a grep pattern, highest number first
# (fixes the padded-number bug: `[ 4]` etc, and avoids shifting numbers mid-loop).
ufw_delete_matching() {
  local pattern="${1:-}" nums n
  [ -z "$pattern" ] && return 0
  nums=$(ufw status numbered 2>/dev/null | grep -E "$pattern" \
        | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn || true)
  for n in $nums; do
    ufw --force delete "$n" &>/dev/null || true
  done
}

get_real_ssh_port() {
  ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | head -1 | tr -d ':'
}

# ---- настоящая проверка живого SSH -----------------------------------------
# wait_for_port проверяет только "что-то слушает порт" — этим "что-то" может
# быть ssh.socket, который слушает, но не гарантирует, что sshd реально
# поднят и обслуживает соединения. Здесь проверяем и юнит, и что порт слушает
# именно процесс sshd (а не socket-заглушка).
ssh_is_really_up() {
  local port="${1:-}" unit_ok=0 u
  [ -z "$port" ] && return 1
  for u in ssh sshd; do
    systemctl is-active --quiet "${u}.service" 2>/dev/null && unit_ok=1 && break
  done
  [ "$unit_ok" = "1" ] || return 1
  ss -tlnp 2>/dev/null | grep ":${port} " | grep -q sshd
}

# Самовосстановление: убирает ssh.socket с дороги, стартует сервис явно
# (не restart — если он уже мёртв, restart иногда ведёт себя иначе, чем start),
# и если порт всё равно не поднялся — сообщает явно, что чинить руками.
ssh_selfheal() {
  local port="${1:-}" unit
  if [ -z "$port" ]; then
    port="$(get_real_ssh_port)"
    port="${port:-22}"
  fi
  ensure_no_ssh_socket
  unit="$(detect_ssh_unit)"
  if ssh_is_really_up "$port"; then
    ok "SSH (${unit}.service) на порту ${port}: реально работает."
    return 0
  fi
  warn "SSH на порту ${port} не отвечает как положено — пробую поднять явно (systemctl start ${unit}.service)."
  systemctl start "${unit}.service" 2>&1 || true
  sleep 1
  if ssh_is_really_up "$port"; then
    ok "SSH (${unit}.service) поднят и работает на порту ${port}."
    return 0
  fi
  local alt="sshd"; [ "$unit" = "sshd" ] && alt="ssh"
  warn "${unit}.service не поднялся, пробую альтернативный юнит ${alt}.service."
  systemctl start "${alt}.service" 2>&1 || true
  sleep 1
  if ssh_is_really_up "$port"; then
    ok "SSH (${alt}.service) поднят и работает на порту ${port}."
    return 0
  fi
  err "SSH НЕ поднимается на порту ${port} ни под одним именем юнита. Требуется ручное вмешательство: journalctl -u ssh.service -n 50, sshd -t."
  return 1
}

# ---- DNS preflight ---------------------------------------------------------
# Certbot fails silently-ish ("challenge failed") if the domain doesn't point
# at this server yet. Checking this BEFORE calling certbot avoids burning
# Let's Encrypt's rate limit on doomed attempts and gives a clear reason.
get_public_ip() {
  curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null \
    || true
}

# Usage: dns_points_here <domain> <public_ip>  → 0 if match, 1 otherwise.
dns_points_here() {
  local domain="${1:-}" pubip="${2:-}" resolved
  [ -z "$domain" ] && return 1
  resolved=$(dig +short A "$domain" 2>/dev/null | tail -1)
  if [ -z "$resolved" ]; then
    resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  fi
  [ -n "$resolved" ] && [ -n "$pubip" ] && [ "$resolved" = "$pubip" ]
}

# ---- сертификат существует и не протух -------------------------------------
cert_is_valid() {
  local domain="${1:-}" cert
  [ -z "$domain" ] && return 1
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  [ -f "$cert" ] && openssl x509 -checkend 86400 -noout -in "$cert" &>/dev/null
}
