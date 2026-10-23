#!/usr/bin/env bash
# DORIK toolkit — единая точка входа для настройки сервера.
# Сначала ставит базовые пакеты, затем собирает ВСЕ параметры один раз и
# выполняет весь пайплайн без вопросов:
#   обновление пакетов -> SSH -> firewall/fail2ban -> (нода: nginx+haproxy+bbr+remnanode)
#
# Без вопросов (cloud-init): ASSUME_YES=1 и параметры в переменных окружения,
# список переменных — в README.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"

source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  LIBTMP="$(mktemp)"; curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$LIBTMP" && source "$LIBTMP"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }

require_root
require_apt_os
ensure_tty

echo -e "${C_B}=========================================================${C_RESET}"
echo -e "${C_B}  DORIK — единая настройка сервера${C_RESET}"
echo -e "${C_B}  Сейчас зададим все вопросы, потом всё пройдёт само,${C_RESET}"
echo -e "${C_B}  без остановок и конфликтов.${C_RESET}"
echo -e "${C_B}=========================================================${C_RESET}"

# ---------------------------------------------------------------------------
# ШАГ 0. Базовые пакеты (нужны уже для вопросов: dig, curl, ufw, cron)
# ---------------------------------------------------------------------------
ensure_base_packages || warn "Базовые пакеты установились не полностью — часть проверок может не работать."

# ---------------------------------------------------------------------------
# ШАГ 1. Сбор параметров (никаких вопросов после этого блока)
# ---------------------------------------------------------------------------
step "Вопросы"

echo "Что настраиваем на этом сервере?"
echo "  1) Полноценная нода (Nginx self-steal + HAProxy + BBR + Remnanode)"
echo "  2) Только сервер панели (жёсткий firewall: SSH+80+443, без ноды)"
ROLE=$(ask_valid "Выбор" "${ROLE:-1}" is_valid_choice12) || exit 1

CUR_SSH_PORT=$(get_real_ssh_port)
CUR_SSH_PORT=${CUR_SSH_PORT:-22}
info "Текущий SSH порт: ${CUR_SSH_PORT}"
NEW_SSH_PORT=$(ask_valid "Новый SSH порт (Enter — оставить как есть)" "${NEW_SSH_PORT:-$CUR_SSH_PORT}" is_valid_port) || exit 1

if [ "$ROLE" = "1" ]; then
  DOMAIN_TCP=$(ask_valid "Домен для VLESS REALITY TCP (обязателен)" "${DOMAIN_TCP:-}" is_valid_domain) || exit 1
  DOMAIN_GRPC=$(ask_valid "Домен для VLESS gRPC (Enter — не использовать)" "${DOMAIN_GRPC:-}" is_valid_domain 1) || exit 1
  DOMAIN_XHTTP=$(ask_valid "Домен для VLESS XHTTP (Enter — не использовать)" "${DOMAIN_XHTTP:-}" is_valid_domain 1) || exit 1
  DOMAIN_HY2=$(ask_valid "Домен для Hysteria2 (Enter — не использовать)" "${DOMAIN_HY2:-}" is_valid_domain 1) || exit 1
  DOMAIN_TCP="${DOMAIN_TCP,,}"; DOMAIN_GRPC="${DOMAIN_GRPC,,}"; DOMAIN_XHTTP="${DOMAIN_XHTTP,,}"; DOMAIN_HY2="${DOMAIN_HY2,,}"

  # ---- предварительная проверка DNS сразу после ввода доменов --------------
  # Видно сразу, до подтверждения запуска, пока ещё можно поправить A-записи
  # и не жечь лимит Let's Encrypt.
  step "Предварительная проверка DNS"
  PREFLIGHT_PUB_IP="$(get_public_ip)"
  if [ -z "$PREFLIGHT_PUB_IP" ]; then
    warn "Не удалось определить публичный IP сервера — проверку DNS пропускаю."
  else
    info "Публичный IP сервера: ${PREFLIGHT_PUB_IP}"
    DNS_PREFLIGHT_BAD=0
    for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
      [ -z "$d" ] && continue
      if dns_points_here "$d" "$PREFLIGHT_PUB_IP"; then
        ok "${d}: DNS указывает на этот сервер."
      else
        RESOLVED=$(dig +short A "$d" 2>/dev/null | tail -1)
        warn "${d}: DNS указывает на '${RESOLVED:-<нет ответа>}', а не на ${PREFLIGHT_PUB_IP}. Сертификат для этого домена НЕ будет выпущен, пока не поправишь A-запись."
        DNS_PREFLIGHT_BAD=1
      fi
    done
    if [ "$DNS_PREFLIGHT_BAD" = "1" ]; then
      warn "Часть доменов пока не указывает на этот сервер. Можно продолжить — эти сертификаты не выпустятся сейчас, скрипт подхватит их при повторном запуске."
    fi
  fi

  if ask_yes_no "Ставить страницу-заглушку (decoy) для self-steal?" "1"; then
    INSTALL_DECOY=1
  else
    INSTALL_DECOY=0
    warn "Заглушка не будет установлена — self-steal всё равно настроится (TLS-листенер на 127.0.0.1:8081 нужен для Reality), но отдавать будет только базовую пустую страницу."
  fi

  USE_HY2=0
  if [ -n "$DOMAIN_HY2" ] && ask_yes_no "Использовать Hysteria2 на этой ноде?" "1"; then
    USE_HY2=1
  fi
  if ask_yes_no "Ставить BBR и сетевую оптимизацию?" "1"; then USE_BBR=1; else USE_BBR=0; fi

  NODE_PORT=$(ask_valid "Порт remnanode (для связи с панелью)" "${NODE_PORT:-$DEFAULT_NODE_PORT}" is_valid_port) || exit 1
  OPEN_NODE_PORT=0
  if ask_yes_no "Открыть порт ${NODE_PORT} для панели в firewall сейчас?" "1"; then
    OPEN_NODE_PORT=1
    PANEL_IP=$(ask_valid "IP панели (Enter — открыть порт для всех)" "${PANEL_IP:-}" is_valid_ip 1) || exit 1
  fi

  # SECRET_KEY: если нода уже ставилась, ключ можно не вводить заново.
  OLD_KEY=""
  [ -f /opt/remnanode/docker-compose.yml ] && \
    OLD_KEY=$(grep -oE 'SECRET_KEY=.*' /opt/remnanode/docker-compose.yml | head -1 | sed 's/SECRET_KEY=//')
  while true; do
    if [ -n "$OLD_KEY" ]; then
      SECRET_KEY=$(ask_value "SECRET_KEY ноды (Enter — оставить текущий)" "${SECRET_KEY:-}")
    else
      SECRET_KEY=$(ask_value "SECRET_KEY ноды (из панели Remnawave, обязателен)" "${SECRET_KEY:-}")
    fi
    # Убираем случайные кавычки/переводы строк — частая причина "Invalid SECRET_KEY payload"
    SECRET_KEY=$(echo -n "$SECRET_KEY" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')
    if [ -n "$SECRET_KEY" ] || [ -n "$OLD_KEY" ]; then break; fi
    err "SECRET_KEY не может быть пустым."
    [ "${ASSUME_YES:-0}" = "1" ] && exit 1
  done
else
  USE_HY2=0; USE_BBR=0; OPEN_NODE_PORT=0
  PANEL_IP=$(ask_valid "IP панели (если нужно ограничить доступ, Enter — пропустить)" "${PANEL_IP:-}" is_valid_ip 1) || exit 1
fi

if ask_yes_no "Ежедневная перезагрузка сервера в 04:00 (${DORIK_TZ})?" "1"; then
  ENABLE_REBOOT=1
else
  ENABLE_REBOOT=0
fi

echo
warn "Все вопросы заданы. Дальше скрипт выполнит все шаги подряд БЕЗ остановок."
if [ "$NEW_SSH_PORT" != "$CUR_SSH_PORT" ]; then
  warn "SSH переедет с порта ${CUR_SSH_PORT} на ${NEW_SSH_PORT}. Текущая сессия не оборвётся, но следующее подключение — только на ${NEW_SSH_PORT}."
fi
if ! ask_yes_no "Начать выполнение сейчас?" "1"; then
  err "Отменено пользователем."
  exit 1
fi

FAIL_LOG=()
run_step() {
  local title="${1:-step}"; shift
  step "$title"
  if "$@"; then
    ok "$title — готово"
  else
    err "$title — ОШИБКА (продолжаю дальше, см. итог в конце)"
    FAIL_LOG+=("$title")
  fi
}

# ---------------------------------------------------------------------------
# ШАГ A. Обновление пакетов
# ---------------------------------------------------------------------------
run_step "Обновление пакетов" apt_upgrade_smart

# ---------------------------------------------------------------------------
# ШАГ B. SSH (безопасная миграция порта)
# ---------------------------------------------------------------------------
do_ssh_harden() {
  if [ "${NEW_SSH_PORT}" = "${CUR_SSH_PORT}" ]; then
    ok "SSH порт не меняется (${CUR_SSH_PORT})."
    ufw allow "${CUR_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true
    return 0
  fi

  info "Меняю SSH порт ${CUR_SSH_PORT} -> ${NEW_SSH_PORT}"
  # Сначала открываем новый порт в ufw, потом двигаем sshd: иначе при включении
  # firewall'а позже новый порт оказался бы закрыт.
  ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true
  if ssh_apply_port "${NEW_SSH_PORT}"; then
    ok "Новый SSH порт ${NEW_SSH_PORT}: реально работает (не просто слушает, а живой sshd)."
    ufw_close_port "${CUR_SSH_PORT}"
  else
    err "Порт не переехал — SSH остался на ${CUR_SSH_PORT}."
    ufw_close_port "${NEW_SSH_PORT}"
    NEW_SSH_PORT="${CUR_SSH_PORT}"
    ssh_selfheal "${CUR_SSH_PORT}" || true
    return 1
  fi
}
run_step "Настройка SSH" do_ssh_harden

# ---------------------------------------------------------------------------
# ШАГ C. Firewall + fail2ban + таймзона + ребут по расписанию
# ---------------------------------------------------------------------------
do_protect_common() {
  local rc=0
  if ! command -v ufw &>/dev/null; then
    apt_install ufw || { err "ufw не установился — firewall НЕ настроен."; rc=1; }
  fi

  if command -v ufw &>/dev/null; then
    ufw default deny incoming &>/dev/null || true
    ufw default allow outgoing &>/dev/null || true
    ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true

    if [ "$ROLE" = "1" ]; then
      ufw allow 80/tcp comment "HTTP (certbot)" &>/dev/null || true
      ufw allow 443/tcp comment "HTTPS TCP" &>/dev/null || true
      [ "$USE_HY2" = "1" ] && { ufw allow 443/udp comment "Hysteria2" &>/dev/null || true; }
      if [ "$OPEN_NODE_PORT" = "1" ]; then
        # Старое правило «для всех» (от прошлого запуска) свело бы на нет
        # ограничение по IP панели — убираем перед добавлением нового.
        ufw_close_port "${NODE_PORT}"
        if [ -n "$PANEL_IP" ]; then
          ufw allow from "$PANEL_IP" to any port "${NODE_PORT}" proto tcp comment "Node panel" &>/dev/null || true
        else
          ufw allow "${NODE_PORT}/tcp" comment "Node panel" &>/dev/null || true
        fi
      fi
    else
      ufw allow 80/tcp comment "HTTP" &>/dev/null || true
      ufw allow 443/tcp comment "HTTPS" &>/dev/null || true
      ufw_delete_matching "3001"
    fi
    ufw --force enable &>/dev/null || { err "ufw не включился."; rc=1; }
  fi

  # fail2ban: backend=systemd обязателен на Ubuntu 24.04/Debian 12 — там нет
  # /var/log/auth.log, и без него jail sshd не стартует вовсе.
  if ! command -v fail2ban-client &>/dev/null; then
    apt_install fail2ban || { err "fail2ban не установился."; rc=1; }
  fi
  if [ -d /etc/fail2ban ]; then
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${NEW_SSH_PORT}
backend  = systemd
maxretry = 3
findtime = 1h
bantime  = 1d
EOF
    systemctl enable fail2ban &>/dev/null || true
    systemctl restart fail2ban 2>&1 || { err "fail2ban не перезапустился (journalctl -u fail2ban)."; rc=1; }
  fi

  timedatectl set-timezone "${DORIK_TZ}" 2>&1 || warn "Не удалось выставить таймзону ${DORIK_TZ}."

  # Старая запись в crontab root (прежние версии скрипта) -> /etc/cron.d
  if command -v crontab &>/dev/null; then
    crontab -l 2>/dev/null | grep -q 'shutdown -r now' && \
      { crontab -l 2>/dev/null | grep -v 'shutdown -r now' | crontab - || true; }
  fi
  if [ "$ENABLE_REBOOT" = "1" ]; then
    echo "0 4 * * * root /sbin/shutdown -r now" > /etc/cron.d/dorik-reboot
    chmod 644 /etc/cron.d/dorik-reboot
    systemctl enable --now cron &>/dev/null || true
  else
    rm -f /etc/cron.d/dorik-reboot
  fi
  return $rc
}
run_step "Firewall/fail2ban/таймзона/ребут" do_protect_common

# ---------------------------------------------------------------------------
# Дальше — только для роли "нода"
# ---------------------------------------------------------------------------
if [ "$ROLE" = "1" ]; then

  do_nginx_haproxy() {
    local src; src="$(get_script haproxy-setup.sh)" || { err "Не удалось получить haproxy-setup.sh"; return 1; }
    DOMAIN_TCP="$DOMAIN_TCP" DOMAIN_GRPC="$DOMAIN_GRPC" DOMAIN_XHTTP="$DOMAIN_XHTTP" \
    DOMAIN_HY2="$DOMAIN_HY2" USE_HY2="$USE_HY2" INSTALL_DECOY="$INSTALL_DECOY" \
    NONINTERACTIVE=1 bash "$src"
  }
  run_step "Nginx (self-steal) + HAProxy + Certbot" do_nginx_haproxy

  if [ "$USE_BBR" = "1" ]; then
    do_bbr() {
      local src; src="$(get_script bbr-install.sh)" || { err "Не удалось получить bbr-install.sh"; return 1; }
      NONINTERACTIVE=1 bash "$src"
    }
    run_step "BBR + сетевая оптимизация" do_bbr
  fi

  do_remnanode() {
    local src; src="$(get_script remnanode-setup.sh)" || { err "Не удалось получить remnanode-setup.sh"; return 1; }
    NODE_PORT="$NODE_PORT" USE_HY2="$USE_HY2" SECRET_KEY="$SECRET_KEY" \
      DOMAIN_HY2="$DOMAIN_HY2" NONINTERACTIVE=1 bash "$src"
  }
  run_step "Установка Remnanode (+ автопривязка Hysteria2 volume)" do_remnanode

fi

# ---------------------------------------------------------------------------
# Финальная страховочная проверка SSH
# ---------------------------------------------------------------------------
# Промежуточные шаги (apt install nginx/haproxy/certbot, docker install)
# тоже дёргают apt — перепроверяем SSH ещё раз в самом конце.
run_step "Финальная проверка SSH" ssh_selfheal "${NEW_SSH_PORT}"

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo
echo -e "${C_B}=========================================================${C_RESET}"
if [ "${#FAIL_LOG[@]}" -eq 0 ]; then
  ok "Готово. Все шаги выполнены без ошибок."
else
  warn "Готово, но с ошибками на шагах:"
  for f in "${FAIL_LOG[@]}"; do echo "   - $f" >&2; done
  warn "Проверьте вывод выше по этим шагам. Скрипт можно запустить повторно — он идемпотентен."
fi
echo -e "SSH порт: ${NEW_SSH_PORT}"
if [ -f /var/run/reboot-required ]; then
  warn "Нужна перезагрузка для применения обновлений ядра: reboot"
fi
echo -e "${C_B}=========================================================${C_RESET}"

[ "${#FAIL_LOG[@]}" -eq 0 ]
