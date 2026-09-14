#!/bin/bash
set -euo pipefail

# ============================================================
#  Server Hardening: SSH port + ufw + fail2ban + timezone + cron
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

wait_for_port() {
    local port="$1"
    local tries=20
    local i=0
    while (( i < tries )); do
        if ss -tlnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
            return 0
        fi
        sleep 0.5
        ((i++))
    done
    return 1
}

ensure_no_ssh_socket() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "ssh.socket снова активен — отключаем."
        systemctl stop ssh.socket >/dev/null 2>&1 || true
        systemctl disable ssh.socket >/dev/null 2>&1 || true
    fi
}

cleanup_temp_ufw_rules() {
    local stale
    stale=$(ufw status numbered 2>/dev/null | grep -E "\(temp\)" || true)
    if [[ -z "$stale" ]]; then return 0; fi
    warn "Найдены временные SSH-правила ufw — очищаем:"
    echo "$stale"
    while IFS= read -r num; do
        [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
    done < <(ufw status numbered 2>/dev/null | grep -E "\(temp\)" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)
}

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " Server Hardening: SSH port + ufw + fail2ban"
echo "============================================================"
echo

SSHD_CONFIG="/etc/ssh/sshd_config"

SSH_SERVICE=""
for candidate in ssh sshd; do
    FRAGMENT=$(systemctl show -p FragmentPath --value "${candidate}.service" 2>/dev/null || true)
    if [[ -n "$FRAGMENT" && "$FRAGMENT" != "/dev/null" ]]; then
        SSH_SERVICE="$candidate"
        break
    fi
done
SSH_SERVICE=${SSH_SERVICE:-ssh}
info "systemd-юнит SSH: ${SSH_SERVICE}.service"

# Проверка автозапуска
ENABLED_STATE=$(systemctl is-enabled "${SSH_SERVICE}.service" 2>/dev/null || true)
if [[ "$ENABLED_STATE" != "enabled" ]]; then
    err "Служба ${SSH_SERVICE}.service не включена для автозапуска (${ENABLED_STATE:-нет данных})!"
    systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1
    log "Автозапуск включён."
fi

# Проверка /run/sshd
if [[ ! -d /run/sshd ]]; then
    warn "/run/sshd отсутствует — создаём."
    mkdir -p /run/sshd && chmod 0755 /run/sshd
fi

# Отключение socket-активации
if systemctl list-units --all 2>/dev/null | grep -q "ssh\.socket"; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "Обнаружена socket-активация SSH — она игнорирует Port из sshd_config. Отключаем."
        systemctl stop ssh.socket
        systemctl disable ssh.socket >/dev/null 2>&1 || true
        systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
        systemctl restart "${SSH_SERVICE}.service"
        sleep 1
        log "ssh.socket отключён."
    fi
fi
echo

# Preflight — чистим битые строки Port
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( $1 >= 1 && $1 <= 65535 )) || return 1
    return 0
}

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.preflight.$(date +%s)"
mapfile -t ALL_PORT_LINES < <(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null || true)
VALID_PORTS=()
for line in "${ALL_PORT_LINES[@]}"; do
    val=$(echo "$line" | awk '{print $2}')
    if is_valid_port "$val"; then
        VALID_PORTS+=("$val")
    else
        escaped=$(printf '%s\n' "$line" | sed 's/[.[\*^$/]/\\&/g')
        sed -i "/^${escaped}\$/d" "$SSHD_CONFIG"
    fi
done

if (( ${#VALID_PORTS[@]} == 0 )); then
    CURRENT_SSH_PORT=22
elif (( ${#VALID_PORTS[@]} == 1 )); then
    CURRENT_SSH_PORT="${VALID_PORTS[0]}"
else
    CURRENT_SSH_PORT="${VALID_PORTS[0]}"
    warn "Найдено несколько портов SSH: ${VALID_PORTS[*]}"
fi
info "Текущий SSH-порт: ${CURRENT_SSH_PORT}"

if ! sshd -t 2>/tmp/sshd_preflight_err; then
    err "Конфиг sshd содержит ошибки:"
    cat /tmp/sshd_preflight_err
    exit 1
fi

if command -v ufw >/dev/null 2>&1; then
    cleanup_temp_ufw_rules
fi
echo

read -rp "На какой порт перенести SSH (Enter — оставить ${CURRENT_SSH_PORT}): " NEW_SSH_PORT
NEW_SSH_PORT=${NEW_SSH_PORT:-$CURRENT_SSH_PORT}
if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT < 1 || NEW_SSH_PORT > 65535 )); then
    err "Некорректный порт: ${NEW_SSH_PORT}"
    exit 1
fi

SKIP_MIGRATION=false
if [[ "$NEW_SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
    warn "Новый порт совпадает с текущим — миграция не нужна."
    if ask_yes_no "Пропустить миграцию и сразу перейти к ufw+fail2ban?" "yes"; then
        SKIP_MIGRATION=true
    fi
fi

echo
read -rp "Разрешить порт 3001 (API ноды) только для IP панели? IP панели (Enter — пропустить): " PANEL_IP

if [[ "$SKIP_MIGRATION" != "true" ]]; then
echo
log "План: добавим ${NEW_SSH_PORT}, протестируем, закроем ${CURRENT_SSH_PORT}."
if ! ask_yes_no "Продолжить?" "no"; then
    warn "Отменено."
    exit 0
fi

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
if ! grep -qE "^Port ${NEW_SSH_PORT}\$" "$SSHD_CONFIG"; then
    echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
fi

apt update -qq
apt install -y ufw >/dev/null

ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH old (temp)' >/dev/null
ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH new (temp)' >/dev/null
if ! ufw status | grep -q "Status: active"; then
    ufw --force enable >/dev/null
fi

if ! sshd -t 2>/tmp/sshd_test_err; then
    err "Ошибка конфига:"; cat /tmp/sshd_test_err
    exit 1
fi

ensure_no_ssh_socket
systemctl restart "${SSH_SERVICE}"

log "Проверяем, что оба порта слушаются..."
NEW_OK=false
wait_for_port "${NEW_SSH_PORT}" && NEW_OK=true

if [[ "$NEW_OK" != "true" ]]; then
    err "Новый порт ${NEW_SSH_PORT} НЕ слушается!"
    sed -i "/^Port ${NEW_SSH_PORT}\$/d" "$SSHD_CONFIG"
    ufw delete allow "${NEW_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    systemctl restart "${SSH_SERVICE}"
    exit 1
fi
log "Порт ${NEW_SSH_PORT} подтверждён."

echo
warn "=========================================================="
warn " НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ! Проверьте в НОВОМ окне:"
echo "   ssh -p ${NEW_SSH_PORT} $(whoami)@$(curl -s -4 ifconfig.me 2>/dev/null || echo 'ВАШ_IP')"
warn "=========================================================="
echo

if ! ask_yes_no "Подключение на порту ${NEW_SSH_PORT} точно работает? Закрыть старый порт?" "no"; then
    warn "Старый порт (${CURRENT_SSH_PORT}) остаётся открытым."
    exit 0
fi

if [[ "$CURRENT_SSH_PORT" == "$NEW_SSH_PORT" ]]; then
    warn "Порты совпадают — пропускаем удаление."
else
    sed -i "/^Port ${CURRENT_SSH_PORT}\$/d" "$SSHD_CONFIG"
fi
grep -qE "^Port ${NEW_SSH_PORT}\$" "$SSHD_CONFIG" || echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"

if ! sshd -t 2>/tmp/sshd_test_err2; then
    err "Ошибка конфига:"; cat /tmp/sshd_test_err2
    exit 1
fi

ensure_no_ssh_socket
systemctl restart "${SSH_SERVICE}"

if ! wait_for_port "${NEW_SSH_PORT}"; then
    err "КРИТИЧНО: порт ${NEW_SSH_PORT} не слушается после финального рестарта!"
    echo "Port ${CURRENT_SSH_PORT}" >> "$SSHD_CONFIG"
    ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH rollback' >/dev/null 2>&1 || true
    systemctl restart "${SSH_SERVICE}"
    exit 1
fi
log "Финальный рестарт подтверждён. Активен только порт ${NEW_SSH_PORT}."

cleanup_temp_ufw_rules
log "Настраиваем строгий ufw..."
ufw delete allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true

else
    apt update -qq >/dev/null 2>&1 || true
    apt install -y ufw >/dev/null 2>&1 || true
fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'Hysteria2' >/dev/null

if [[ -n "${PANEL_IP:-}" ]]; then
    ufw allow from "$PANEL_IP" to any port 3001 proto tcp comment 'Node API' >/dev/null
    log "Порт 3001 открыт для ${PANEL_IP}."
fi

ufw --force enable >/dev/null
log "ufw активен."

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
port     = ${NEW_SSH_PORT}
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
else
    info "Часовой пояс уже Asia/Irkutsk."
fi

# Cron перезагрузка 4:00
if ! command -v crontab >/dev/null 2>&1; then
    apt install -y cron >/dev/null
fi
CRON_JOB="0 4 * * * /sbin/shutdown -r now"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
if ! echo "$EXISTING_CRON" | grep -qF "shutdown -r now"; then
    ( echo "$EXISTING_CRON"; echo "$CRON_JOB" ) | grep -v '^$' | crontab -
    log "Задача перезагрузки в 04:00 добавлена."
else
    info "Задача перезагрузки уже есть."
fi
systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true

echo
echo "============================================================"
log "Готово!"
echo "  SSH-порт: ${NEW_SSH_PORT}"
echo "  Подключение: ssh -p ${NEW_SSH_PORT} $(whoami)@ВАШ_IP"
echo "============================================================"
ufw status verbose
