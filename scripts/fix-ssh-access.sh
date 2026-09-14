#!/bin/bash
set -euo pipefail

# ============================================================
#  fix-ssh-access — диагностика и восстановление SSH-доступа
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

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " fix-ssh-access — диагностика и восстановление SSH-доступа"
echo "============================================================"
echo

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

echo
log "Проверяем автозапуск..."
ENABLED_STATE=$(systemctl is-enabled "${SSH_SERVICE}.service" 2>/dev/null || true)
if [[ "$ENABLED_STATE" != "enabled" ]]; then
    err "Служба не включена для автозапуска (${ENABLED_STATE:-нет данных})!"
    systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1
    log "Автозапуск включён."
else
    log "Автозапуск уже включён."
fi

echo
log "Проверяем privilege separation directory (/run/sshd)..."
if [[ -d /run/sshd ]]; then
    info "/run/sshd уже существует."
else
    warn "/run/sshd отсутствует — создаём."
    mkdir -p /run/sshd && chmod 0755 /run/sshd
    log "/run/sshd создана."
fi

TMPFILES_RULE_FOUND=false
for f in /usr/lib/tmpfiles.d/*.conf /etc/tmpfiles.d/*.conf; do
    [[ -f "$f" ]] || continue
    if grep -qE '^\s*d\s+/run/sshd\s' "$f" 2>/dev/null; then
        TMPFILES_RULE_FOUND=true
        break
    fi
done
if [[ "$TMPFILES_RULE_FOUND" != "true" ]]; then
    warn "Правило автосоздания /run/sshd не найдено — добавляем постоянное."
    echo "d /run/sshd 0755 root root -" > /etc/tmpfiles.d/sshd.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf >/dev/null 2>&1 || true
else
    info "Правило автосоздания /run/sshd уже есть."
fi

echo
log "Проверяем sshd_config..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if sshd -t 2>/tmp/sshd_check_err; then
    log "Синтаксис sshd_config корректен."
else
    err "Обнаружена ошибка в sshd_config:"
    cat /tmp/sshd_check_err
    echo
    warn "Варианты восстановления:"
    echo "  1) Восстановить из бэкапа"
    echo "  2) Сбросить порт на 22 (без бэкапа)"
    echo "  3) Чинить вручную"
    read -rp "Выбор [1/2/3]: " RECOVERY_CHOICE

    case "$RECOVERY_CHOICE" in
        1)
            LATEST_BACKUP=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -n1 || true)
            if [[ -z "$LATEST_BACKUP" ]]; then
                err "Бэкапов не найдено."
                exit 1
            fi
            cp "$LATEST_BACKUP" "$SSHD_CONFIG"
            if sshd -t 2>/tmp/sshd_check_err2; then
                log "Конфиг восстановлен."
                systemctl restart "${SSH_SERVICE}" 2>/dev/null || true
            else
                err "Бэкап тоже содержит ошибку:"; cat /tmp/sshd_check_err2
                exit 1
            fi
            ;;
        2)
            cp "$SSHD_CONFIG" "/etc/ssh/sshd_config.bak.reset.$(date +%s)"
            sed -i '/^Port /d' "$SSHD_CONFIG"
            echo "Port 22" >> "$SSHD_CONFIG"
            if sshd -t 2>/tmp/sshd_check_err3; then
                log "Порт сброшен на 22."
                systemctl restart "${SSH_SERVICE}" 2>/dev/null || true
            else
                err "Конфиг всё ещё битый:"; cat /tmp/sshd_check_err3
                exit 1
            fi
            ;;
        *)
            err "Чините вручную: nano ${SSHD_CONFIG}"
            exit 1
            ;;
    esac
fi

echo
log "Проверяем socket-активацию (ssh.socket)..."
if systemctl list-units --all 2>/dev/null | grep -q "ssh\.socket"; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "ssh.socket активен — отключаем."
        systemctl stop ssh.socket
        systemctl disable ssh.socket >/dev/null 2>&1 || true
        systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
        systemctl restart "${SSH_SERVICE}.service"
        log "ssh.socket отключён."
    else
        info "ssh.socket неактивен."
    fi
else
    info "ssh.socket не используется."
fi

echo
log "Ищем реальный слушающий порт..."
REAL_PORTS=()
for i in 1 2 3 4 5; do
    mapfile -t REAL_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
    (( ${#REAL_PORTS[@]} > 0 )) && break
    sleep 1
done

if (( ${#REAL_PORTS[@]} == 0 )); then
    err "SSH не слушает ни один порт! Пробуем запустить..."
    systemctl status "${SSH_SERVICE}" --no-pager -l 2>&1 | tail -20 || true
    systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
    systemctl restart "${SSH_SERVICE}"
    sleep 2
    mapfile -t REAL_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
    if (( ${#REAL_PORTS[@]} == 0 )); then
        err "Не удалось поднять SSH. journalctl -u ${SSH_SERVICE} -n 50"
        exit 1
    fi
    log "SSH поднят."
fi
log "SSH реально слушает: ${REAL_PORTS[*]}"

echo
if command -v ufw >/dev/null 2>&1; then
    MISSING_PORTS=()
    for p in "${REAL_PORTS[@]}"; do
        ufw status | grep -qE "^${p}/tcp" || MISSING_PORTS+=("$p")
    done
    if (( ${#MISSING_PORTS[@]} > 0 )); then
        err "Порты НЕ разрешены в ufw: ${MISSING_PORTS[*]}"
        if ask_yes_no "Открыть их сейчас?" "yes"; then
            for p in "${MISSING_PORTS[@]}"; do
                ufw allow "${p}/tcp" comment 'SSH (restored)' >/dev/null
            done
            ufw status | grep -q "Status: active" || ufw --force enable >/dev/null
            log "Порты открыты."
        fi
    else
        log "Все SSH-порты уже разрешены в ufw."
    fi
fi

echo
echo "============================================================"
log "Готово! Проверьте подключение в НОВОМ окне:"
for p in "${REAL_PORTS[@]}"; do
    echo "  ssh -p ${p} $(whoami)@ВАШ_IP"
done
echo "============================================================"
