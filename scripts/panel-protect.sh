#!/bin/bash
set -euo pipefail

# ============================================================
#  panel-protect — защита сервера панели
#  Открывает ТОЛЬКО 80, 443 и SSH-порт + fail2ban/таймзона/крон
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local def_label
    if [[ "$default" == "yes" ]]; then
        def_label="по умолчанию — 1"
    else
        def_label="по умолчанию — 2"
    fi
    echo "$prompt"
    echo "  1) Да"
    echo "  2) Нет"
    read -rp "Выбор [${def_label}]: " CHOICE_NUM
    if [[ -z "$CHOICE_NUM" ]]; then
        CHOICE_NUM=$([[ "$default" == "yes" ]] && echo 1 || echo 2)
    fi
    [[ "$CHOICE_NUM" == "1" ]]
}

cleanup_temp_ufw_rules() {
    local stale
    stale=$(ufw status numbered 2>/dev/null | grep -E "\(temp\)" || true)
    if [[ -z "$stale" ]]; then return 0; fi
    while IFS= read -r num; do
        [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
    done < <(ufw status numbered 2>/dev/null | grep -E "\(temp\)" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)
}

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " Защита панели — только 80, 443, SSH"
echo "============================================================"
echo

# Реальный слушающий порт через ss — не через config-парсинг
REAL_LISTEN_PORTS=()
mapfile -t REAL_LISTEN_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)

CONFIG_PORT=""
command -v sshd >/dev/null 2>&1 && CONFIG_PORT=$(sshd -T 2>/dev/null | grep -i "^port" | awk '{print $2}' | head -n1) || true

if (( ${#REAL_LISTEN_PORTS[@]} == 1 )); then
    DETECTED_SSH_PORT="${REAL_LISTEN_PORTS[0]}"
    info "Реально слушающий SSH-порт: ${DETECTED_SSH_PORT}"
elif (( ${#REAL_LISTEN_PORTS[@]} > 1 )); then
    warn "SSH слушает несколько портов: ${REAL_LISTEN_PORTS[*]}"
    DETECTED_SSH_PORT="${REAL_LISTEN_PORTS[0]}"
else
    err "ss не нашёл слушающий SSH-порт."
    DETECTED_SSH_PORT="${CONFIG_PORT:-22}"
    warn "Используем fallback: ${DETECTED_SSH_PORT}. Проверьте вручную перед продолжением!"
fi

echo
warn "ВАЖНО: убедитесь, что порт ниже — ТОЧНО тот, которым пользуетесь для SSH."
read -rp "Подтвердите SSH-порт (Enter — ${DETECTED_SSH_PORT}): " SSH_PORT_INPUT
SSH_PORT=${SSH_PORT_INPUT:-$DETECTED_SSH_PORT}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    err "Некорректный порт."
    exit 1
fi

if (( ${#REAL_LISTEN_PORTS[@]} > 0 )) && ! printf '%s\n' "${REAL_LISTEN_PORTS[@]}" | grep -qx "$SSH_PORT"; then
    err "ВНИМАНИЕ: порт ${SSH_PORT} НЕ входит в реально слушающие (${REAL_LISTEN_PORTS[*]})!"
    if ! ask_yes_no "Вы АБСОЛЮТНО уверены?" "no"; then
        err "Остановлено для вашей безопасности."
        exit 1
    fi
fi

if command -v ufw >/dev/null 2>&1; then
    info "ufw уже установлен."
else
    apt update -qq
    apt install -y ufw >/dev/null
fi

echo
info "Текущее состояние ufw:"
ufw status verbose 2>/dev/null || echo "  (не активирован)"
echo
echo "План: разрешить ${SSH_PORT}(SSH)/80/443, всё остальное закрыть."
if ! ask_yes_no "Продолжить?" "no"; then
    warn "Отменено."
    exit 0
fi

log "Открываем порты (старые SSH-правила пока не трогаем)..."
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
log "ufw активирован."

echo
warn "=========================================================="
warn " НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ! Проверьте в НОВОМ окне:"
echo "   ssh -p ${SSH_PORT} $(whoami)@$(curl -s -4 ifconfig.me 2>/dev/null || echo 'ВАШ_IP')"
warn "=========================================================="
echo

if ask_yes_no "Подключение работает? Убрать старые SSH-правила?" "no"; then
    log "Ищем старые SSH-правила..."
    STALE=$(ufw status numbered 2>/dev/null | grep -E "# SSH$" | grep -vE "^\[[[:space:]0-9]+\][[:space:]]+${SSH_PORT}/tcp" || true)
    if [[ -n "$STALE" ]]; then
        echo "$STALE"
        while IFS= read -r num; do
            [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
        done < <(echo "$STALE" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)
        log "Старые правила удалены."
    else
        info "Нечего чистить."
    fi
else
    warn "Оставлено как есть."
fi

cleanup_temp_ufw_rules

# fail2ban
if command -v fail2ban-client >/dev/null 2>&1; then
    info "fail2ban уже установлен."
else
    apt install -y fail2ban >/dev/null
fi
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 3
findtime = 1h
bantime  = 1d
EOF
systemctl restart fail2ban
systemctl enable fail2ban >/dev/null
log "fail2ban настроен."

# Часовой пояс
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
if [[ "$CURRENT_TZ" != "Asia/Irkutsk" ]]; then
    timedatectl set-timezone Asia/Irkutsk
    log "Часовой пояс: Asia/Irkutsk"
fi

# Cron
if ! command -v crontab >/dev/null 2>&1; then
    apt install -y cron >/dev/null
fi
CRON_JOB="0 4 * * * /sbin/shutdown -r now"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
if ! echo "$EXISTING_CRON" | grep -qF "shutdown -r now"; then
    ( echo "$EXISTING_CRON"; echo "$CRON_JOB" ) | grep -v '^$' | crontab -
    log "Автоперезагрузка 04:00 добавлена."
fi
systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true

echo
echo "============================================================"
log "Готово!"
echo "  Открыто: ${SSH_PORT}/tcp, 80/tcp, 443/tcp. Всё остальное закрыто."
echo "============================================================"
ufw status verbose
