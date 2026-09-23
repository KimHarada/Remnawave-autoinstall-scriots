#!/usr/bin/env bash
# DORIK toolkit — единая точка входа.
# Собирает ВСЕ параметры один раз в начале, затем выполняет весь пайплайн
# без дополнительных вопросов: защита сервера -> (нода: nginx+haproxy+bbr+remnanode).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
RAW="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  LIBTMP="$(mktemp)"; curl -fsSL "${RAW}/scripts/lib.sh" -o "$LIBTMP"; source "$LIBTMP"
}

require_root

echo -e "${C_B}=========================================================${C_RESET}"
echo -e "${C_B}  DORIK — единая настройка сервера${C_RESET}"
echo -e "${C_B}  Сейчас зададим все вопросы, потом всё пройдёт само,${C_RESET}"
echo -e "${C_B}  без остановок и конфликтов.${C_RESET}"
echo -e "${C_B}=========================================================${C_RESET}"

# ---------------------------------------------------------------------------
# ШАГ 0. Сбор параметров (никаких вопросов после этого блока)
# ---------------------------------------------------------------------------
step "1/1 — Вопросы"

echo "Что настраиваем на этом сервере?"
echo "  1) Полноценная нода (Nginx self-steal + HAProxy + BBR + Remnanode)"
echo "  2) Только сервер панели (жёсткий firewall: SSH+80+443, без ноды)"
ROLE=$(ask_value "Выбор" "1")

CUR_SSH_PORT=$(get_real_ssh_port)
CUR_SSH_PORT=${CUR_SSH_PORT:-22}
info "Текущий SSH порт: ${CUR_SSH_PORT}"
NEW_SSH_PORT=$(ask_value "Новый SSH порт (Enter — оставить как есть)" "${CUR_SSH_PORT}")

if [ "$ROLE" = "1" ]; then
  DOMAIN_TCP=$(ask_value "Домен для VLESS REALITY TCP" "")
  DOMAIN_GRPC=$(ask_value "Домен для VLESS gRPC" "")
  DOMAIN_XHTTP=$(ask_value "Домен для VLESS XHTTP" "")
  DOMAIN_HY2=$(ask_value "Домен для Hysteria2" "")
  if ask_yes_no "Использовать Hysteria2 на этой ноде?" "1"; then
    USE_HY2=1
  else
    USE_HY2=0
  fi
  if ask_yes_no "Ставить BBR (BBR3)?" "1"; then
    USE_BBR=1
  else
    USE_BBR=0
  fi
  NODE_PORT=$(ask_value "Порт remnanode (для связи с панелью)" "3001")
  if ask_yes_no "Открыть порт ${NODE_PORT} для панели в firewall сейчас?" "1"; then
    OPEN_NODE_PORT=1
  else
    OPEN_NODE_PORT=0
  fi
  SECRET_KEY=$(ask_value "SECRET_KEY ноды (из панели Remnawave)" "")
  SECRET_KEY=$(echo -n "$SECRET_KEY" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')
else
  PANEL_IP=$(ask_value "IP панели (если нужно ограничить доступ, Enter — пропустить)" "")
fi

echo
warn "Все вопросы заданы. Дальше скрипт выполнит все шаги подряд БЕЗ остановок."
if ! ask_yes_no "Начать выполнение сейчас?" "1"; then
  err "Отменено пользователем."
  exit 1
fi

FAIL_LOG=()
run_step() {
  local title="$1"; shift
  step "$title"
  if "$@"; then
    ok "$title — готово"
  else
    err "$title — ОШИБКА (продолжаю дальше, см. итог в конце)"
    FAIL_LOG+=("$title")
  fi
}

# ---------------------------------------------------------------------------
# ШАГ A. Базовые пакеты
# ---------------------------------------------------------------------------
do_apt() { apt_upgrade_smart; }
run_step "Обновление пакетов" do_apt

# ---------------------------------------------------------------------------
# ШАГ B. SSH hardening (безопасная миграция порта)
# ---------------------------------------------------------------------------
do_ssh_harden() {
  ensure_no_ssh_socket

  if [ "${NEW_SSH_PORT}" != "${CUR_SSH_PORT}" ]; then
    info "Меняю SSH порт ${CUR_SSH_PORT} -> ${NEW_SSH_PORT}"
    cp -f /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    sed -i -E "/^[#[:space:]]*Port[[:space:]]+[0-9]+/d" /etc/ssh/sshd_config
    echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
    mkdir -p /run/sshd
    ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH new" &>/dev/null || true
    restart_ssh_service >/dev/null
    if wait_for_port "${NEW_SSH_PORT}"; then
      ok "Новый SSH порт ${NEW_SSH_PORT} слушает."
      ufw_delete_matching ":${CUR_SSH_PORT}[[:space:]]"
    else
      err "Новый порт не поднялся — откатываю на ${CUR_SSH_PORT}."
      sed -i -E "/^Port ${NEW_SSH_PORT}$/d" /etc/ssh/sshd_config
      echo "Port ${CUR_SSH_PORT}" >> /etc/ssh/sshd_config
      restart_ssh_service >/dev/null
      NEW_SSH_PORT="${CUR_SSH_PORT}"
      return 1
    fi
  else
    ok "SSH порт не меняется (${CUR_SSH_PORT})."
    ufw allow "${CUR_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true
  fi
}
run_step "Настройка SSH" do_ssh_harden

# ---------------------------------------------------------------------------
# ШАГ C. Firewall base + fail2ban + timezone + reboot cron
# ---------------------------------------------------------------------------
do_protect_common() {
  ufw --force enable &>/dev/null || true
  ufw default deny incoming &>/dev/null || true
  ufw default allow outgoing &>/dev/null || true
  ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true

  if [ "$ROLE" = "1" ]; then
    ufw allow 80/tcp comment "HTTP" &>/dev/null || true
    ufw allow 443/tcp comment "HTTPS TCP" &>/dev/null || true
    if [ "$USE_HY2" = "1" ]; then
      ufw allow 443/udp comment "Hysteria2" &>/dev/null || true
    fi
    if [ "$OPEN_NODE_PORT" = "1" ]; then
      ufw allow "${NODE_PORT}/tcp" comment "Node panel" &>/dev/null || true
    fi
  else
    ufw allow 80/tcp comment "HTTP" &>/dev/null || true
    ufw allow 443/tcp comment "HTTPS" &>/dev/null || true
    # жёсткая блокировка всего остального уже обеспечена default deny
    ufw_delete_matching "3001"
  fi

  if ! apt list --installed 2>/dev/null | grep -q '^fail2ban'; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban || true
  fi
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ${NEW_SSH_PORT}
bantime = 1d
findtime = 1h
maxretry = 3
EOF
  systemctl restart fail2ban 2>&1 || true
  systemctl enable fail2ban &>/dev/null || true

  timedatectl set-timezone Asia/Irkutsk 2>&1 || true

  ( crontab -l 2>/dev/null | grep -v 'shutdown -r now' ; echo "0 4 * * * /sbin/shutdown -r now" ) | crontab -
}
run_step "Firewall/fail2ban/таймзона/крон" do_protect_common

# ---------------------------------------------------------------------------
# Дальше — только для роли "нода"
# ---------------------------------------------------------------------------
if [ "$ROLE" = "1" ]; then

  do_nginx_haproxy() {
    if [ -f "${SCRIPT_DIR}/haproxy-setup.sh" ]; then
      SRC="${SCRIPT_DIR}/haproxy-setup.sh"
    else
      SRC="$(mktemp)"; curl -fsSL "${RAW}/scripts/haproxy-setup.sh" -o "$SRC"
    fi
    DOMAIN_TCP="$DOMAIN_TCP" DOMAIN_GRPC="$DOMAIN_GRPC" DOMAIN_XHTTP="$DOMAIN_XHTTP" \
    DOMAIN_HY2="$DOMAIN_HY2" USE_HY2="$USE_HY2" NONINTERACTIVE=1 \
      bash "$SRC"
  }
  run_step "Nginx (self-steal) + HAProxy + Certbot" do_nginx_haproxy

  if [ "$USE_BBR" = "1" ]; then
    do_bbr() {
      if [ -f "${SCRIPT_DIR}/bbr-install.sh" ]; then
        SRC="${SCRIPT_DIR}/bbr-install.sh"
      else
        SRC="$(mktemp)"; curl -fsSL "${RAW}/scripts/bbr-install.sh" -o "$SRC"
      fi
      # NONINTERACTIVE=1 обязателен: без него bbr-install.sh на повторном
      # запуске, увидев что BBR уже стоит, задаёт интерактивный вопрос
      # "переустановить?" — а в этом пайплайне спрашивать уже нельзя.
      NONINTERACTIVE=1 bash "$SRC"
    }
    run_step "BBR3" do_bbr
  fi

  do_remnanode() {
    if [ -f "${SCRIPT_DIR}/remnanode-setup.sh" ]; then
      SRC="${SCRIPT_DIR}/remnanode-setup.sh"
    else
      SRC="$(mktemp)"; curl -fsSL "${RAW}/scripts/remnanode-setup.sh" -o "$SRC"
    fi
    NODE_PORT="$NODE_PORT" USE_HY2="$USE_HY2" SECRET_KEY="$SECRET_KEY" \
      DOMAIN_HY2="$DOMAIN_HY2" NONINTERACTIVE=1 bash "$SRC"
  }
  run_step "Установка Remnanode (+ автопривязка Hysteria2 volume)" do_remnanode

fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo
echo -e "${C_B}=========================================================${C_RESET}"
if [ "${#FAIL_LOG[@]}" -eq 0 ]; then
  ok "Готово. Все шаги выполнены без ошибок."
else
  warn "Готово, но с ошибками на шагах:"
  for f in "${FAIL_LOG[@]}"; do echo "   - $f"; done
  warn "Проверьте вывод выше по этим шагам."
fi
echo -e "SSH порт: ${NEW_SSH_PORT}"
echo -e "${C_B}=========================================================${C_RESET}"
