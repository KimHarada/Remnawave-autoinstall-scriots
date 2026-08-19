#!/bin/bash
set -euo pipefail

# ============================================================
#  Server Hardening: смена SSH-порта + ufw + fail2ban
#  Безопасная процедура — не закрывает старый порт,
#  пока вы не подтвердите, что новый порт реально работает.
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

# Проверяет, установлен ли пакет (по наличию бинарника или dpkg-записи).
# Возвращает 0 (успех/true), если пакет уже есть.
is_installed() {
    local bin="$1"
    command -v "$bin" >/dev/null 2>&1
}

# Устанавливает пакет только если его ещё нет. Если уже установлен —
# просто сообщает об этом и ничего не трогает (полная идемпотентность).
ensure_package() {
    local bin="$1"
    local pkg="${2:-$1}"
    if is_installed "$bin"; then
        info "${pkg} уже установлен — пропускаем установку."
        return 0
    fi
    log "Устанавливаем ${pkg}..."
    apt update -qq
    apt install -y "$pkg" >/dev/null
}

# Ждёт до 10 секунд, пока порт реально не появится в списке слушающих (не верим
# слепо коду возврата systemctl restart — сервис может "успешно перезапуститься"
# и тут же упасть или не забиндить порт из-за конфликта с чем-то другим).
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

dump_ssh_diagnostics() {
    echo "--- ss -tlnp | grep ssh ---"
    ss -tlnp 2>/dev/null | grep -i ssh || echo "  (ничего не найдено)"
    echo "--- sshd -T | grep port ---"
    sshd -T 2>/dev/null | grep -i "^port" || echo "  (не удалось получить)"
    echo "--- systemctl status ${SSH_SERVICE} (последние строки) ---"
    systemctl status "${SSH_SERVICE}" --no-pager -l 2>/dev/null | tail -15 || true
    echo "--- journalctl -u ${SSH_SERVICE} (последние 20 строк) ---"
    journalctl -u "${SSH_SERVICE}" -n 20 --no-pager 2>/dev/null || true
    echo "--- ssh.socket статус ---"
    systemctl is-active ssh.socket 2>/dev/null || echo "  (юнит отсутствует или неактивен)"
}

# Защита от повторной активации ssh.socket между шагами (например, из-за apt install,
# который может триггернуть systemd preset reset на некоторых системах).
ensure_no_ssh_socket() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        warn "ssh.socket снова оказался активен — отключаем повторно перед рестартом."
        systemctl stop ssh.socket >/dev/null 2>&1 || true
        systemctl disable ssh.socket >/dev/null 2>&1 || true
    fi
}

if [[ $EUID -ne 0 ]]; then
   err "Запускать нужно от root (sudo)."
   exit 1
fi

echo "============================================================"
echo " Server Hardening: SSH port + ufw + fail2ban"
echo "============================================================"
echo

SSHD_CONFIG="/etc/ssh/sshd_config"

# Определяем реальное имя systemd-юнита SSH — на Debian/Ubuntu это 'ssh',
# на RHEL/CentOS/Fedora — 'sshd'. Спрашиваем systemd напрямую про путь unit-файла,
# это надёжнее, чем парсить табличный вывод list-unit-files.
SSH_SERVICE=""
for candidate in ssh sshd; do
    FRAGMENT=$(systemctl show -p FragmentPath --value "${candidate}.service" 2>/dev/null || true)
    if [[ -n "$FRAGMENT" && "$FRAGMENT" != "/dev/null" ]]; then
        SSH_SERVICE="$candidate"
        break
    fi
done

if [[ -z "$SSH_SERVICE" ]]; then
    err "Не удалось определить systemd-юнит SSH через FragmentPath. Пробуем последний способ — по запущенному процессу..."
    if pgrep -x sshd >/dev/null 2>&1; then
        # Процесс sshd запущен, но юнит не нашли штатным способом — пробуем самый частый вариант
        if systemctl status ssh >/dev/null 2>&1; then
            SSH_SERVICE="ssh"
        elif systemctl status sshd >/dev/null 2>&1; then
            SSH_SERVICE="sshd"
        fi
    fi
fi

if [[ -z "$SSH_SERVICE" ]]; then
    err "Не удалось определить systemd-юнит SSH (ни ssh.service, ни sshd.service не найдены)."
    err "Проверьте вручную: systemctl status ssh   ИЛИ   systemctl status sshd"
    exit 1
fi
info "Определён systemd-юнит SSH: ${SSH_SERVICE}.service"

# ------------------------------------------------------------
# Критичная проверка: socket-активация SSH (ssh.socket)
# ------------------------------------------------------------
# На современных Ubuntu/Debian SSH может запускаться через ssh.socket,
# который сам слушает порт (обычно жёстко 22) и полностью ИГНОРИРУЕТ
# директиву Port из sshd_config. Из-за этого смена порта в конфиге
# ничего не даёт, пока socket-активация не отключена.
if systemctl list-units --all 2>/dev/null | grep -q "ssh\.socket"; then
    SOCKET_STATE=$(systemctl is-active ssh.socket 2>/dev/null || true)
    if [[ "$SOCKET_STATE" == "active" ]]; then
        warn "Обнаружена socket-активация SSH (ssh.socket) — она игнорирует Port из sshd_config."
        SOCKET_LISTEN=$(systemctl show -p Listen --value ssh.socket 2>/dev/null || true)
        info "Текущий Listen у ssh.socket: ${SOCKET_LISTEN:-неизвестно}"
        log "Отключаем ssh.socket, переводим SSH на обычный запуск через ${SSH_SERVICE}.service..."

        systemctl stop ssh.socket
        systemctl disable ssh.socket >/dev/null 2>&1 || true
        systemctl enable "${SSH_SERVICE}.service" >/dev/null 2>&1 || true
        systemctl restart "${SSH_SERVICE}.service"

        sleep 1
        if systemctl is-active --quiet ssh.socket; then
            err "Не удалось отключить ssh.socket. Откатываем на всякий случай не будем — проверьте вручную:"
            err "  systemctl status ssh.socket"
            exit 1
        fi

        # КРИТИЧНО: проверяем, что sshd реально слушает хоть что-то после смены
        # режима активации — иначе restart мог "успешно завершиться", но sshd
        # не забиндил порт (именно так и получилось в проблемном случае).
        sleep 1
        if ! ss -tlnp 2>/dev/null | grep -qi "sshd\|:22 \|:${CURRENT_SSH_PORT:-22} "; then
            err "После отключения ssh.socket sshd НЕ слушает ни одного порта! Откатываем обратно на socket-активацию."
            dump_ssh_diagnostics
            systemctl enable --now ssh.socket >/dev/null 2>&1 || true
            err "Откат выполнен, ssh.socket снова активен (было рабочее состояние). Разбирайтесь по диагностике выше."
            exit 1
        fi
        log "ssh.socket отключён, ${SSH_SERVICE}.service теперь слушает порты напрямую из sshd_config."
    else
        info "ssh.socket присутствует, но не активен — socket-активация не используется, пропускаем."
    fi
fi
echo

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

echo "------------------------------------------------------------"
log "Preflight-проверка sshd_config..."
echo "------------------------------------------------------------"

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.preflight.$(date +%s)"
log "Бэкап конфига создан."

# Собираем ВСЕ строки, начинающиеся с "Port " (с учётом регистра OpenSSH — обычно 'Port')
mapfile -t ALL_PORT_LINES < <(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null || true)

VALID_PORTS=()
INVALID_LINES=()

for line in "${ALL_PORT_LINES[@]}"; do
    val=$(echo "$line" | awk '{print $2}')
    if is_valid_port "$val"; then
        VALID_PORTS+=("$val")
    else
        INVALID_LINES+=("$line")
    fi
done

if (( ${#INVALID_LINES[@]} > 0 )); then
    warn "Найдены некорректные строки 'Port' в конфиге — удаляем:"
    for bad in "${INVALID_LINES[@]}"; do
        echo "    удаляю: $bad"
        # экранируем спецсимволы для sed на всякий случай
        escaped=$(printf '%s\n' "$bad" | sed 's/[.[\*^$/]/\\&/g')
        sed -i "/^${escaped}\$/d" "$SSHD_CONFIG"
    done
    log "Некорректные строки удалены."
else
    log "Некорректных строк 'Port' не найдено."
fi

if (( ${#VALID_PORTS[@]} == 0 )); then
    CURRENT_SSH_PORT=22
    info "Явных валидных строк 'Port' не найдено — используется дефолт: 22"
elif (( ${#VALID_PORTS[@]} == 1 )); then
    CURRENT_SSH_PORT="${VALID_PORTS[0]}"
    info "Текущий SSH-порт: ${CURRENT_SSH_PORT}"
else
    CURRENT_SSH_PORT="${VALID_PORTS[0]}"
    warn "Найдено несколько активных валидных портов SSH: ${VALID_PORTS[*]}"
    warn "Будет использован первый (${CURRENT_SSH_PORT}) как 'текущий' для сравнения, но SSH слушает их все."
fi

# Финальная проверка синтаксиса после чистки
if ! sshd -t 2>/tmp/sshd_preflight_err; then
    err "После автоисправления конфиг всё ещё содержит ошибки:"
    cat /tmp/sshd_preflight_err
    err "Восстановите вручную из бэкапа: ${SSHD_CONFIG}.bak.preflight.*"
    exit 1
fi
log "Конфиг sshd прошёл проверку синтаксиса (sshd -t)."

# Функция для надёжной очистки temp-правил ufw. Использует --force вместо
# 'yes | ufw delete N', т.к. номерное удаление требует интерактивного
# подтверждения (y/n), и pipe через yes не всегда доходит корректно —
# это и было причиной, почему temp-правила молча оставались висеть
# несмотря на лог 'успешно очищены'.
cleanup_temp_ufw_rules() {
    local stale
    stale=$(ufw status numbered 2>/dev/null | grep -E "\(temp\)" || true)
    if [[ -z "$stale" ]]; then
        return 0
    fi
    warn "Найдены временные SSH-правила ufw — очищаем:"
    echo "$stale"
    # ВАЖНО: ufw дополняет однозначные номера пробелом для выравнивания ("[ 4]", "[ 9]"),
    # поэтому извлекаем номер через sed с учётом произвольных пробелов внутри скобок —
    # прямой grep -oE '^\[[0-9]+\]' такие строки не матчит вообще (баг предыдущей версии).
    while IFS= read -r num; do
        [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
    done < <(ufw status numbered 2>/dev/null | grep -E "\(temp\)" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)

    # Проверяем, что реально удалилось, а не просто "попытались"
    local remaining
    remaining=$(ufw status numbered 2>/dev/null | grep -E "\(temp\)" || true)
    if [[ -n "$remaining" ]]; then
        warn "После очистки всё ещё остались temp-правила (возможно, версия ufw ведёт себя иначе):"
        echo "$remaining"
        warn "Попробуем удалить их ещё раз по отдельности..."
        while IFS= read -r num; do
            [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
        done < <(ufw status numbered 2>/dev/null | grep -E "\(temp\)" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)
        remaining=$(ufw status numbered 2>/dev/null | grep -E "\(temp\)" || true)
        if [[ -n "$remaining" ]]; then
            err "Не удалось автоматически удалить temp-правила ufw. Удалите вручную:"
            echo "$remaining"
            warn "Команда: ufw --force delete <номер_в_квадратных_скобках>"
        else
            log "Temp-правила удалены со второй попытки."
        fi
    else
        log "Temp-правила ufw успешно удалены (подтверждено повторной проверкой)."
    fi
}

# Чистим "хвосты" от предыдущих неудачных запусков в ufw (temp-правила)
if command -v ufw >/dev/null 2>&1; then
    cleanup_temp_ufw_rules
fi

echo "------------------------------------------------------------"
echo

read -rp "На какой порт перенести SSH? (например 2222): " NEW_SSH_PORT
if [[ -z "$NEW_SSH_PORT" ]] || ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]]; then
    err "Некорректный порт."
    exit 1
fi
if (( NEW_SSH_PORT < 1 || NEW_SSH_PORT > 65535 )); then
    err "Порт должен быть в диапазоне 1-65535. Введено: ${NEW_SSH_PORT}"
    exit 1
fi
if (( NEW_SSH_PORT < 1024 )); then
    warn "Порт ${NEW_SSH_PORT} ниже 1024 (привилегированный) — обычно используют 1024-65535 для нестандартных сервисов."
fi
SKIP_MIGRATION=false
if [[ "$NEW_SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
    warn "Новый порт совпадает с текущим (${CURRENT_SSH_PORT}) — SSH уже работает на нужном порту."
    warn "Полный цикл 'добавить-протестировать-закрыть старый' не нужен и рискован без реальной миграции."
    echo
    read -rp "Пропустить смену порта и сразу перейти к настройке ufw + fail2ban? [Y/n]: " SKIP_ANSWER
    if [[ "$SKIP_ANSWER" != "n" && "$SKIP_ANSWER" != "N" ]]; then
        SKIP_MIGRATION=true
        log "Пропускаем миграцию порта, порт ${NEW_SSH_PORT} уже активен и подтверждён."
    fi
fi
for existing in "${VALID_PORTS[@]:-}"; do
    if [[ "$existing" == "$NEW_SSH_PORT" ]]; then
        info "Порт ${NEW_SSH_PORT} уже активен в sshd_config."
        break
    fi
done

echo
read -rp "Разрешить порт 3001 (API ноды Remnawave) только для IP панели? IP панели (Enter чтобы пропустить): " PANEL_IP

if [[ "$SKIP_MIGRATION" != "true" ]]; then

echo
log "План действий:"
echo "  1. Добавим порт ${NEW_SSH_PORT} для SSH (старый ${CURRENT_SSH_PORT} пока останется активным)"
echo "  2. Откроем оба порта в ufw временно"
echo "  3. Вы протестируете подключение на НОВОМ порту в отдельном окне терминала"
echo "  4. После вашего подтверждения — закроем старый порт и включим строгий ufw"
echo "  5. Установим и настроим fail2ban под новый SSH-порт"
echo
read -rp "Продолжить? [y/N]: " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    warn "Отменено."
    exit 0
fi

# ------------------------------------------------------------
# 1. Добавляем новый порт в sshd_config, не трогая старый
# ------------------------------------------------------------
log "Бэкапим текущий sshd_config..."
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"

if ! grep -qE "^Port ${NEW_SSH_PORT}$" "$SSHD_CONFIG"; then
    log "Добавляем 'Port ${NEW_SSH_PORT}' в sshd_config (старый порт пока остаётся)..."
    echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
else
    info "Порт ${NEW_SSH_PORT} уже присутствует в конфиге."
fi

# ------------------------------------------------------------
# 2. Открываем оба порта в ufw (временно)
# ------------------------------------------------------------
log "Открываем оба SSH-порта временно..."
ensure_package ufw ufw

if ! ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH old (temp)' >/dev/null; then
    err "Не удалось открыть старый порт ${CURRENT_SSH_PORT} в ufw. Откатываем изменения sshd_config."
    sed -i "/^Port ${NEW_SSH_PORT}\$/d" "$SSHD_CONFIG"
    exit 1
fi
if ! ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH new (temp)' >/dev/null; then
    err "Не удалось открыть новый порт ${NEW_SSH_PORT} в ufw (проверьте что порт корректный). Откатываем изменения sshd_config."
    sed -i "/^Port ${NEW_SSH_PORT}\$/d" "$SSHD_CONFIG"
    ufw delete allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    exit 1
fi

if ! ufw status | grep -q "Status: active"; then
    log "Включаем ufw..."
    ufw --force enable >/dev/null
fi

# ------------------------------------------------------------
# 3. Перезапускаем sshd с двумя активными портами
# ------------------------------------------------------------
log "Проверяем синтаксис sshd_config перед перезапуском..."
if ! sshd -t 2>/tmp/sshd_test_err; then
    err "Ошибка в конфиге SSH:"
    cat /tmp/sshd_test_err
    err "Откатываем изменения."
    cp "${SSHD_CONFIG}.bak."* "$SSHD_CONFIG" 2>/dev/null || true
    exit 1
fi

ensure_no_ssh_socket
systemctl restart ${SSH_SERVICE}

# КРИТИЧНО: не верим коду возврата restart — реально проверяем, что порты слушаются
log "Проверяем, что оба порта реально слушаются (до 10 секунд ожидания)..."
OLD_OK=false
NEW_OK=false
if wait_for_port "${CURRENT_SSH_PORT}"; then OLD_OK=true; fi
if wait_for_port "${NEW_SSH_PORT}"; then NEW_OK=true; fi

if [[ "$NEW_OK" != "true" ]]; then
    err "Новый порт ${NEW_SSH_PORT} НЕ слушается после перезапуска! Это и привело бы к 'Connection refused'."
    dump_ssh_diagnostics
    err "Откатываем — убираем новый порт из конфига, оставляем только старый (${CURRENT_SSH_PORT})."
    sed -i "/^Port ${NEW_SSH_PORT}\$/d" "$SSHD_CONFIG"
    ufw delete allow "${NEW_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    systemctl restart ${SSH_SERVICE}
    if wait_for_port "${CURRENT_SSH_PORT}"; then
        err "Откат выполнен успешно, старый порт (${CURRENT_SSH_PORT}) снова единственный рабочий."
    else
        err "ВНИМАНИЕ: после отката старый порт тоже не подтверждён слушающим! Проверьте сервер немедленно вручную,"
        err "не закрывая текущую сессию. Диагностика выше поможет понять причину."
    fi
    exit 1
fi

if [[ "$OLD_OK" != "true" ]]; then
    warn "Старый порт ${CURRENT_SSH_PORT} не подтверждён слушающим (но новый ${NEW_SSH_PORT} — да)."
    warn "Это может быть нормально, если в конфиге раньше был только один порт и он уже заменён."
fi

log "Порт ${NEW_SSH_PORT} подтверждён — реально слушается. SSH перезапущен, активны: ${CURRENT_SSH_PORT} (было: ${OLD_OK}) и ${NEW_SSH_PORT} (подтверждено)"

# ------------------------------------------------------------
# 4. КРИТИЧЕСКИЙ ШАГ — просим подтвердить, что новый порт работает
# ------------------------------------------------------------
echo
warn "=========================================================="
warn " ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ!"
warn " Откройте НОВОЕ окно терминала и подключитесь так:"
echo
echo -e "   ${BLUE}ssh -p ${NEW_SSH_PORT} $(whoami)@$(curl -s -4 ifconfig.me 2>/dev/null || echo 'ВАШ_IP')${NC}"
echo
warn " Только убедившись, что подключение прошло успешно,"
warn " возвращайтесь сюда и подтверждайте продолжение."
warn "=========================================================="
echo
read -rp "Подключение на новом порту ${NEW_SSH_PORT} точно работает? Продолжить и закрыть старый порт? [y/N]: " PORT_CONFIRMED

if [[ "$PORT_CONFIRMED" != "y" && "$PORT_CONFIRMED" != "Y" ]]; then
    warn "Остановлено ПО ВАШЕМУ ВЫБОРУ. Старый порт (${CURRENT_SSH_PORT}) остаётся открытым и рабочим."
    warn "Новый порт (${NEW_SSH_PORT}) тоже настроен и доступен — можете протестировать и перезапустить скрипт позже,"
    warn "либо закрыть старый порт вручную командами ниже, когда будете готовы:"
    echo "  sed -i '/^Port ${CURRENT_SSH_PORT}\$/d' ${SSHD_CONFIG}"
    echo "  ufw delete allow ${CURRENT_SSH_PORT}/tcp"
    echo "  systemctl restart ${SSH_SERVICE}"
    exit 0
fi

# ------------------------------------------------------------
# 5. Закрываем старый порт, включаем строгий ufw
# ------------------------------------------------------------
if [[ "$CURRENT_SSH_PORT" == "$NEW_SSH_PORT" ]]; then
    warn "Старый и новый порт совпадают (${CURRENT_SSH_PORT}) — это одна и та же строка в конфиге."
    warn "Пропускаем удаление, иначе sshd останется вообще без директивы Port и откатится на дефолт (22)."
else
    log "Убираем старый порт (${CURRENT_SSH_PORT}) из sshd_config..."
    sed -i "/^Port ${CURRENT_SSH_PORT}\$/d" "$SSHD_CONFIG"
fi

# Финальная защита: убеждаемся, что нужный порт точно остался в конфиге
if ! grep -qE "^Port ${NEW_SSH_PORT}\$" "$SSHD_CONFIG"; then
    err "После правок в конфиге не осталось строки 'Port ${NEW_SSH_PORT}'! Восстанавливаем."
    echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
fi

if ! sshd -t 2>/tmp/sshd_test_err2; then
    err "Ошибка в конфиге SSH после удаления старого порта:"
    cat /tmp/sshd_test_err2
    exit 1
fi

ensure_no_ssh_socket
systemctl restart ${SSH_SERVICE}

log "Проверяем, что порт ${NEW_SSH_PORT} реально слушается после финального рестарта..."
if ! wait_for_port "${NEW_SSH_PORT}"; then
    err "КРИТИЧНО: порт ${NEW_SSH_PORT} НЕ слушается после закрытия старого порта!"
    dump_ssh_diagnostics
    err "Аварийный откат — возвращаем старый порт (${CURRENT_SSH_PORT}) обратно в конфиг."
    echo "Port ${CURRENT_SSH_PORT}" >> "$SSHD_CONFIG"
    ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'SSH rollback' >/dev/null 2>&1 || true
    systemctl restart ${SSH_SERVICE}
    if wait_for_port "${CURRENT_SSH_PORT}"; then
        err "Аварийный откат выполнен успешно — старый порт (${CURRENT_SSH_PORT}) снова работает. НЕ ЗАКРЫВАЙТЕ сессию, разберитесь по диагностике выше перед повторной попыткой."
    else
        err "ОЧЕНЬ ПЛОХО: ни новый, ни старый порт не подтверждаются слушающими. НЕ ЗАКРЫВАЙТЕ текущую сессию ни в коем случае — используйте её для восстановления вручную."
    fi
    exit 1
fi
log "SSH перезапущен и подтверждён. Теперь активен только порт ${NEW_SSH_PORT}."

else
    # SKIP_MIGRATION=true — порт уже правильный, миграция не нужна.
    # Убеждаемся, что ufw хотя бы установлен, раз шаги 1-2 (которые обычно это делают) пропущены.
    ensure_package ufw ufw
fi

log "Финальная зачистка любых оставшихся temp-правил перед хардненингом..."
cleanup_temp_ufw_rules

log "Настраиваем строгий ufw (закрываем всё лишнее)..."
ufw delete allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

ufw allow "${NEW_SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP (certbot)' >/dev/null
ufw allow 443/tcp comment 'HTTPS/HAProxy' >/dev/null
ufw allow 443/udp comment 'Hysteria2' >/dev/null

if [[ -n "${PANEL_IP:-}" ]]; then
    ufw allow from "$PANEL_IP" to any port 3001 proto tcp comment 'Node API - panel only' >/dev/null
    log "Порт 3001 открыт только для панели (${PANEL_IP})."
else
    info "IP панели не указан — порт 3001 НЕ открывается наружу вообще."
fi

ufw --force enable >/dev/null
log "ufw настроен и активен."

# ------------------------------------------------------------
# 6. Устанавливаем и настраиваем fail2ban
# ------------------------------------------------------------
ensure_package fail2ban-client fail2ban

log "Настраиваем jail.local под порт ${NEW_SSH_PORT}..."
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
log "fail2ban настроен и запущен."

# ------------------------------------------------------------
# 7. Часовой пояс — Asia/Irkutsk
# ------------------------------------------------------------
echo
log "Настраиваем часовой пояс..."
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
if [[ "$CURRENT_TZ" == "Asia/Irkutsk" ]]; then
    info "Часовой пояс уже Asia/Irkutsk — пропускаем."
else
    info "Текущий часовой пояс: ${CURRENT_TZ:-неизвестно}. Меняем на Asia/Irkutsk..."
    timedatectl set-timezone Asia/Irkutsk
    NEW_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    if [[ "$NEW_TZ" == "Asia/Irkutsk" ]]; then
        log "Часовой пояс успешно установлен: Asia/Irkutsk"
    else
        err "Не удалось установить часовой пояс. Текущее значение: ${NEW_TZ:-неизвестно}"
    fi
fi

# ------------------------------------------------------------
# 8. Ежедневная перезагрузка в 4:00 (по установленному часовому поясу)
# ------------------------------------------------------------
echo
log "Настраиваем ежедневную перезагрузку в 4:00..."
ensure_package crontab cron

CRON_JOB="0 4 * * * /sbin/shutdown -r now"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "$EXISTING_CRON" | grep -qF "shutdown -r now"; then
    info "Задача на перезагрузку уже присутствует в crontab — пропускаем добавление."
else
    log "Добавляем задачу в crontab root: '${CRON_JOB}'"
    ( echo "$EXISTING_CRON"; echo "$CRON_JOB" ) | grep -v '^$' | crontab -
fi

systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true

# Проверяем, что служба cron реально работает
CRON_SERVICE=""
for candidate in cron crond; do
    if systemctl is-active --quiet "$candidate" 2>/dev/null; then
        CRON_SERVICE="$candidate"
        break
    fi
done

if [[ -n "$CRON_SERVICE" ]]; then
    log "Служба ${CRON_SERVICE}: активна"
else
    err "Служба cron/crond не активна! Перезагрузка по расписанию работать не будет."
fi

# Проверяем, что задача реально видна в crontab
if crontab -l 2>/dev/null | grep -qF "shutdown -r now"; then
    log "Задача перезагрузки подтверждена в crontab root."
else
    err "Задача перезагрузки НЕ найдена в crontab после добавления! Проверьте вручную: crontab -l"
fi

# ------------------------------------------------------------
# 7. Финальная проверка
# ------------------------------------------------------------
echo
echo "============================================================"
log "Финальная проверка"
echo "============================================================"

if systemctl is-active --quiet ${SSH_SERVICE}; then
    log "${SSH_SERVICE}: активен"
else
    err "${SSH_SERVICE}: НЕ активен!"
fi

if systemctl is-active --quiet fail2ban; then
    log "fail2ban: активен"
else
    err "fail2ban: НЕ активен!"
fi

FINAL_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "неизвестно")
if [[ "$FINAL_TZ" == "Asia/Irkutsk" ]]; then
    log "Часовой пояс: Asia/Irkutsk"
else
    err "Часовой пояс: ${FINAL_TZ} (ожидался Asia/Irkutsk)"
fi

if [[ -n "${CRON_SERVICE:-}" ]]; then
    log "Служба cron (${CRON_SERVICE}): активна"
else
    err "Служба cron: НЕ активна!"
fi

if crontab -l 2>/dev/null | grep -qF "shutdown -r now"; then
    log "Задача ежедневной перезагрузки: настроена (04:00)"
else
    err "Задача ежедневной перезагрузки: НЕ найдена!"
fi

echo
info "ufw status:"
ufw status verbose

echo
info "fail2ban jail sshd:"
fail2ban-client status sshd || warn "Не удалось получить статус jail (проверьте вручную позже)."

echo
info "Текущее время сервера:"
date

echo
info "Текущий crontab root:"
crontab -l 2>/dev/null || echo "  (пусто)"

echo
echo "============================================================"
log "Готово!"
echo "  Новый SSH-порт:     ${NEW_SSH_PORT}"
echo "  Подключение:        ssh -p ${NEW_SSH_PORT} $(whoami)@ВАШ_IP"
echo "  fail2ban:           bantime=1d, findtime=1h, maxretry=3"
echo "  Часовой пояс:       Asia/Irkutsk"
echo "  Автоперезагрузка:   ежедневно в 04:00"
echo "============================================================"
warn "Не закрывайте текущую сессию, пока не проверите подключение с новым портом ещё раз в свежем терминале!"
