#!/usr/bin/env bash
# DORIK toolkit — shared functions. Sourced by every step script.
# Safe to `set -euo pipefail` in callers; every risky pipeline here is
# guarded with `|| true` where a non-zero exit is expected/normal.

C_RESET="\e[0m"; C_G="\e[32m"; C_Y="\e[33m"; C_R="\e[31m"; C_B="\e[36m"
info()  { echo -e "${C_B}[i]${C_RESET} $*"; }
ok()    { echo -e "${C_G}[✓]${C_RESET} $*"; }
warn()  { echo -e "${C_Y}[!]${C_RESET} $*"; }
err()   { echo -e "${C_R}[✗]${C_RESET} $*"; }
step()  { echo -e "\n${C_B}==>${C_RESET} $*"; }

# Numbered yes/no prompt. Usage: if ask_yes_no "Продолжить?" "1"; then ...
# Second arg = default numeric choice (1=yes,2=no) used if ENTER pressed.
ask_yes_no() {
  local prompt="$1" default="${2:-1}" ans
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
  local prompt="$1" default="$2" ans
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
detect_ssh_unit() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "sshd"
  fi
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
  local port="$1" tries=0
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
  local pattern="$1" nums n
  nums=$(ufw status numbered 2>/dev/null | grep -E "$pattern" \
        | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn || true)
  for n in $nums; do
    ufw --force delete "$n" &>/dev/null || true
  done
}

get_real_ssh_port() {
  ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | head -1 | tr -d ':'
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
  local domain="$1" pubip="$2" resolved
  resolved=$(dig +short A "$domain" 2>/dev/null | tail -1)
  if [ -z "$resolved" ]; then
    resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  fi
  [ -n "$resolved" ] && [ -n "$pubip" ] && [ "$resolved" = "$pubip" ]
}

# ---- сертификат существует и не протух -------------------------------------
cert_is_valid() {
  local domain="$1" cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  [ -f "$cert" ] && openssl x509 -checkend 86400 -noout -in "$cert" &>/dev/null
}
