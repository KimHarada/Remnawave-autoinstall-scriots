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
    echo

    # ВАЖНО: tcp_available_congestion_control показывает только УЖЕ
    # загруженные модули. Модуль bbr может существовать на диске, но
    # быть не загруженным — поэтому сначала реально пробуем modprobe,
    # а не просто смотрим на список "доступного".
    log "Пробуем загрузить модуль tcp_bbr..."
    MODPROBE_ERR=""
    if modprobe tcp_bbr 2>/tmp/modprobe_err; then
        log "Модуль tcp_bbr успешно загружен."
    else
        MODPROBE_ERR=$(cat /tmp/modprobe_err 2>/dev/null || true)
        warn "modprobe tcp_bbr не сработал: ${MODPROBE_ERR}"
    fi

    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    info "Доступные алгоритмы после попытки загрузки: ${AVAILABLE_CC}"

    if echo "$AVAILABLE_CC" | grep -qw "bbr3"; then
        warn "bbr3 доступен, но не был включён автоматически — возможно, нужна перезагрузка."
    elif echo "$AVAILABLE_CC" | grep -qw "bbr2"; then
        warn "true bbr3 недоступен, но найден bbr2."
        if ask_yes_no "Включить bbr2?" "yes"; then
            sysctl -w net.ipv4.tcp_congestion_control=bbr2 >/dev/null
            echo "net.ipv4.tcp_congestion_control=bbr2" >> /etc/sysctl.d/99-bbr-fallback.conf
            log "bbr2 включён."
        fi
    elif echo "$AVAILABLE_CC" | grep -qw "bbr"; then
        warn "true bbr3/bbr2 недоступны на этом ядре (обычно требуют кастомную сборку,"
        warn "например Xanmod) — стоковое ядро Ubuntu/Debian их не содержит."
        warn "Обычный bbr (BBR1) загружен и доступен — он тоже заметно лучше cubic."
        if ask_yes_no "Включить обычный bbr?" "yes"; then
            sysctl -w net.core.default_qdisc=fq >/dev/null
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
            {
                echo "net.core.default_qdisc=fq"
                echo "net.ipv4.tcp_congestion_control=bbr"
            } >> /etc/sysctl.d/99-bbr-fallback.conf
            log "bbr включён."
            FINAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
            if [[ "$FINAL_CC" == bbr* ]]; then
                log "Подтверждено: ${FINAL_CC}"
            else
                err "Даже обычный bbr не включился (сейчас: ${FINAL_CC}). Нужна ручная диагностика."
            fi
        fi
    else
        err "Модуль tcp_bbr не удалось загрузить, и его нет в списке доступных."
        echo
        MODULE_FILE=$(find "/lib/modules/$(uname -r)" -iname "tcp_bbr*" 2>/dev/null | head -n1)
        if [[ -n "$MODULE_FILE" ]]; then
            warn "Файл модуля найден на диске (${MODULE_FILE}), но modprobe его не загрузил."
            warn "Ошибка modprobe: ${MODPROBE_ERR:-нет данных}"
            warn "Возможно, требуется перезагрузка сервера, чтобы модуль подхватился."
        else
            warn "Файл модуля tcp_bbr НЕ найден в /lib/modules/$(uname -r)/."
            warn "На некоторых минимальных/облачных сборках ядра он вынесен в отдельный пакет."
            if ask_yes_no "Попробовать установить linux-modules-extra-\$(uname -r) и повторить?" "yes"; then
                if apt install -y "linux-modules-extra-$(uname -r)" 2>/tmp/apt_modules_err; then
                    log "Пакет установлен. Пробуем modprobe ещё раз..."
                    if modprobe tcp_bbr 2>/dev/null; then
                        sysctl -w net.core.default_qdisc=fq >/dev/null
                        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
                        {
                            echo "net.core.default_qdisc=fq"
                            echo "net.ipv4.tcp_congestion_control=bbr"
                        } >> /etc/sysctl.d/99-bbr-fallback.conf
                        FINAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
                        if [[ "$FINAL_CC" == bbr* ]]; then
                            log "Успех! bbr включён: ${FINAL_CC}"
                        else
                            err "Модуль загрузился, но sysctl всё равно не подтверждает bbr (${FINAL_CC})."
                        fi
                    else
                        err "modprobe всё ещё не срабатывает после установки пакета."
                        err "Скорее всего нужна перезагрузка сервера."
                    fi
                else
                    err "Не удалось установить пакет:"
                    cat /tmp/apt_modules_err
                    err "Такого пакета может не быть для этого ядра/провайдера (частый случай на урезанных облачных образах)."
                fi
            fi
        fi
    fi
    warn "Проверить вручную в любой момент: sysctl net.ipv4.tcp_congestion_control"
fi

echo
info "Текущий qdisc:"
sysctl -n net.core.default_qdisc 2>/dev/null || echo "  неизвестно"

echo
echo "============================================================"
log "Готово."
echo "============================================================"
