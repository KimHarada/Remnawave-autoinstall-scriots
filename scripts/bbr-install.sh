#!/bin/bash
set -euo pipefail

# ============================================================
#  bbr-install — установка/переустановка BBR3
#  Источник: https://github.com/ivan-nginx/bbr3
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

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " Установка BBR3 (ivan-nginx/bbr3)"
echo "============================================================"
echo

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
info "Текущий congestion control: ${CURRENT_CC}"

if [[ "$CURRENT_CC" == bbr* ]]; then
    warn "BBR (${CURRENT_CC}) уже активен на этом сервере."
    if ! ask_yes_no "Переустановить/обновить поверх текущего BBR?" "yes"; then
        warn "Отменено пользователем."
        exit 0
    fi
    log "Переустанавливаем BBR3 поверх текущей настройки..."
else
    info "BBR сейчас не активен (${CURRENT_CC}) — устанавливаем BBR3."
fi

echo
warn "Скрипт стороннего автора (ivan-nginx/bbr3), не наш. Запускаем как есть."
echo

# Сам скрипт интерактивный (задаёт свои вопросы) — запускаем напрямую,
# не через pipe, чтобы stdin остался доступен для его собственных промптов.
TMPFILE=$(mktemp /tmp/bbr3-XXXXXX.sh)
if ! curl -fsSL https://raw.githubusercontent.com/ivan-nginx/bbr3/main/optimize_network.sh -o "$TMPFILE"; then
    err "Не удалось скачать скрипт BBR3."
    rm -f "$TMPFILE"
    exit 1
fi
chmod +x "$TMPFILE"
bash "$TMPFILE"
BBR_EXIT_CODE=$?
rm -f "$TMPFILE"

echo
echo "============================================================"
log "Проверка результата"
echo "============================================================"

sleep 1
NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
info "Congestion control после установки: ${NEW_CC}"

if [[ "$NEW_CC" == bbr* ]]; then
    log "BBR активен: ${NEW_CC}"
else
    err "BBR не подтверждён как активный алгоритм (сейчас: ${NEW_CC})."
    err "Возможно, требуется перезагрузка сервера, либо скрипт завершился с ошибкой (код: ${BBR_EXIT_CODE})."
    warn "Проверьте вручную: sysctl net.ipv4.tcp_congestion_control"
fi

echo
info "Текущий qdisc:"
sysctl -n net.core.default_qdisc 2>/dev/null || echo "  неизвестно"

echo
echo "============================================================"
log "Готово."
echo "============================================================"
