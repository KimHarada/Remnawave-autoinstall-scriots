#!/bin/bash
set -euo pipefail

# ============================================================
#  fix-ssh-access — восстановление SSH-доступа
#  Определяет РЕАЛЬНЫЙ слушающий порт (через ss, а не через
#  config-парсинг), чинит ufw и ssh.socket при необходимости.
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
echo " fix-ssh-access — диагностика и восстановление SSH-доступа"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Определяем СЕРВИС (ssh или sshd — зависит от дистрибутива)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# 1.5 Проверяем privilege separation directory (/run/sshd)
#     Частая причина ложной ошибки 'Missing privilege separation
#     directory' в sshd -t — это НЕ ошибка конфига, а просто
#     пропавшая служебная директория (например, после очистки /run).
#     sshd -t требует её для проверки, даже если конфиг корректен.
# ------------------------------------------------------------
echo
log "Проверяем privilege separation directory (/run/sshd)..."
if [[ -d /run/sshd ]]; then
    info "/run/sshd уже существует."
else
    warn "/run/sshd отсутствует — создаём (это не связано с содержимым конфига)."
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
    log "/run/sshd создана."
fi

# Проверяем, что есть системное правило автосоздания /run/sshd при каждой
# загрузке (обычно через systemd-tmpfiles) — если правило пропало, именно
# поэтому директория и не пересоздалась сама после рестарта/очистки /run.
TMPFILES_RULE_FOUND=false
for f in /usr/lib/tmpfiles.d/*.conf /etc/tmpfiles.d/*.conf; do
    [[ -f "$f" ]] || continue
    if grep -qE '^\s*d\s+/run/sshd\s' "$f" 2>/dev/null; then
        TMPFILES_RULE_FOUND=true
        info "Правило автосоздания /run/sshd найдено в: ${f}"
        break
    fi
done

if [[ "$TMPFILES_RULE_FOUND" != "true" ]]; then
    warn "Системное правило автосоздания /run/sshd не найдено — после перезагрузки директория может пропасть снова."
    log "Добавляем постоянное правило в /etc/tmpfiles.d/sshd.conf..."
    echo "d /run/sshd 0755 root root -" > /etc/tmpfiles.d/sshd.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf >/dev/null 2>&1 || true
    log "Правило добавлено — /run/sshd теперь будет создаваться автоматически при каждой загрузке."
else
    info "Системное правило автосоздания /run/sshd уже есть — перезагрузки безопасны."
fi

# ------------------------------------------------------------
# 2. Проверяем синтаксис sshd_config
# ------------------------------------------------------------
echo
log "Проверяем sshd_config..."
if sshd -t 2>/tmp/sshd_check_err; then
    log "Синтаксис sshd_config корректен."
else
    err "Обнаружена ошибка в sshd_config:"
    cat /tmp/sshd_check_err
    echo
    warn "Есть три варианта восстановления:"
    echo "  1) Восстановить из бэкапа (если он валидный)"
    echo "  2) Просто сбросить порт на 22 и перезапустить службу (без бэкапа)"
    echo "  3) Чинить вручную самому"
    read -rp "Выбор [1/2/3]: " RECOVERY_CHOICE

    case "$RECOVERY_CHOICE" in
        1)
            LATEST_BACKUP=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -n1 || true)
            if [[ -z "$LATEST_BACKUP" ]]; then
                err "Бэкапов не найдено."
                exit 1
            fi
            warn "Восстанавливаем из: ${LATEST_BACKUP}"
            cp "$LATEST_BACKUP" /etc/ssh/sshd_config
            if sshd -t 2>/tmp/sshd_check_err2; then
                log "Конфиг восстановлен и прошёл проверку."
                systemctl restart "${SSH_SERVICE}" 2>/dev/null || true
                log "Служба перезапущена."
            else
                err "Даже бэкап содержит ошибку:"
                cat /tmp/sshd_check_err2
                exit 1
            fi
            ;;
        2)
            warn "Сбрасываем порт на 22 (без восстановления из бэкапа)..."
            cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.reset.$(date +%s)"
            sed -i '/^Port /d' /etc/ssh/sshd_config
            echo "Port 22" >> /etc/ssh/sshd_config
            if sshd -t 2>/tmp/sshd_check_err3; then
                log "Порт сброшен на 22, конфиг прошёл проверку."
                systemctl restart "${SSH_SERVICE}" 2>/dev/null || true
                log "Служба перезапущена на порту 22."
            else
                err "Конфиг всё ещё содержит ошибку (дело не только в порте):"
                cat /tmp/sshd_check_err3
                err "Нужно чинить вручную: nano /etc/ssh/sshd_config"
                exit 1
            fi
            ;;
        *)
            err "Чините вручную: nano /etc/ssh/sshd_config, затем запустите скрипт заново."
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------
# 3. Проверяем ssh.socket (частая причина игнорирования Port)
# ------------------------------------------------------------
echo
log "Проверяем socket-активацию (ssh.socket)..."
if systemctl list-units --all 2>/dev/null | grep -q "ssh\.socket"; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "ssh.socket активен — он может игнорировать Port из sshd_config."
        SOCKET_LISTEN=$(systemctl show -p Listen --value ssh.socket 2>/dev/null || true)
        info "ssh.socket слушает: ${SOCKET_LISTEN:-неизвестно}"
        if ask_yes_no "Отключить ssh.socket и перейти на обычный запуск через ${SSH_SERVICE}.service?" "yes"; then
            systemctl stop ssh.socket
            systemctl disable ssh.socket >/dev/null 2>&1 || true
            systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
            systemctl restart "${SSH_SERVICE}.service"
            log "ssh.socket отключён."
        fi
    else
        info "ssh.socket присутствует, но неактивен — не мешает."
    fi
else
    info "ssh.socket не используется в этой системе."
fi

# ------------------------------------------------------------
# 4. Определяем РЕАЛЬНЫЙ слушающий порт (через ss — не через конфиг!)
# ------------------------------------------------------------
echo
log "Ищем реальный слушающий порт SSH через ss..."

# Пытаемся до 5 раз с паузой — на случай если служба ещё перезапускается
REAL_PORTS=()
for i in 1 2 3 4 5; do
    mapfile -t REAL_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
    if (( ${#REAL_PORTS[@]} > 0 )); then
        break
    fi
    sleep 1
done

if (( ${#REAL_PORTS[@]} == 0 )); then
    err "SSH вообще не слушает ни один порт! Служба не запущена?"
    systemctl status "${SSH_SERVICE}" --no-pager -l | tail -20
    err "Пробуем запустить..."
    systemctl restart "${SSH_SERVICE}"
    sleep 2
    mapfile -t REAL_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
    if (( ${#REAL_PORTS[@]} == 0 )); then
        err "Не удалось поднять SSH. Смотрите логи: journalctl -u ${SSH_SERVICE} -n 50"
        exit 1
    fi
fi

log "SSH реально слушает порт(ы): ${REAL_PORTS[*]}"

# Для сравнения — что показывает sshd -T (может отличаться, если конфиг
# поменяли, но службу ещё не перезапускали)
CONFIG_PORT=$(sshd -T 2>/dev/null | grep -i "^port" | awk '{print $2}' | head -n1 || true)
if [[ -n "$CONFIG_PORT" ]]; then
    info "sshd_config (после перезапуска) указывает порт: ${CONFIG_PORT}"
    if ! printf '%s\n' "${REAL_PORTS[@]}" | grep -qx "$CONFIG_PORT"; then
        warn "Внимание: конфиг говорит про порт ${CONFIG_PORT}, но реально слушается ${REAL_PORTS[*]}."
        warn "Возможно, служба не перезапускалась после последней правки конфига."
    fi
fi

# ------------------------------------------------------------
# 5. Проверяем ufw — открыты ли реальные порты
# ------------------------------------------------------------
echo
if ! command -v ufw >/dev/null 2>&1; then
    info "ufw не установлен — блокировки на этом уровне быть не может."
else
    log "Проверяем правила ufw..."
    UFW_ACTIVE=$(ufw status | head -n1)
    info "Статус ufw: ${UFW_ACTIVE}"

    MISSING_PORTS=()
    for p in "${REAL_PORTS[@]}"; do
        if ! ufw status | grep -qE "^${p}/tcp"; then
            MISSING_PORTS+=("$p")
        fi
    done

    if (( ${#MISSING_PORTS[@]} > 0 )); then
        err "Эти реально слушающие SSH-порты НЕ разрешены в ufw: ${MISSING_PORTS[*]}"
        if ask_yes_no "Открыть их в ufw прямо сейчас?" "yes"; then
            for p in "${MISSING_PORTS[@]}"; do
                ufw allow "${p}/tcp" comment 'SSH (restored)' >/dev/null
                log "Порт ${p}/tcp открыт в ufw."
            done
            # Если ufw ещё не был активен (default deny не применён) — включаем аккуратно
            if ! ufw status | grep -q "Status: active"; then
                warn "ufw был неактивен. Включаем."
                ufw --force enable >/dev/null
            fi
        fi
    else
        log "Все реально слушающие SSH-порты уже разрешены в ufw."
    fi
fi

# ------------------------------------------------------------
# 6. Финальная проверка
# ------------------------------------------------------------
echo
echo "============================================================"
log "Финальная проверка"
echo "============================================================"

if systemctl is-active --quiet "$SSH_SERVICE"; then
    log "${SSH_SERVICE}: активен"
else
    err "${SSH_SERVICE}: НЕ активен!"
fi

echo
info "Реально слушающие порты SSH:"
ss -tlnp 2>/dev/null | grep -i sshd

echo
info "ufw status:"
ufw status verbose 2>/dev/null || echo "  ufw не установлен"

echo
echo "============================================================"
log "Готово! Проверьте подключение в НОВОМ окне терминала, не закрывая текущее:"
for p in "${REAL_PORTS[@]}"; do
    echo "  ssh -p ${p} $(whoami)@ВАШ_IP"
done
echo "============================================================"
