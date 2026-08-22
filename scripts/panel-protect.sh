#!/bin/bash
set -euo pipefail

# ============================================================
#  panel-protect — защита сервера панели
#  Открывает ТОЛЬКО 80, 443 и SSH-порт, всё остальное закрыто.
#  Плюс: fail2ban, часовой пояс Asia/Irkutsk, автоперезагрузка 04:00.
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

# Числовое подтверждение вместо y/n.
# ask_yes_no "Текст вопроса" "default" — default: "yes" или "no"
# Возвращает 0 (успех/да) если выбрано "1", 1 (нет) если "2".
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
echo " Защита панели — открыты только 80, 443 и SSH"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Определяем текущий SSH-порт
#    ВАЖНО: используем ss (реально слушающий сокет) как основной
#    источник истины, а не только sshd -T (парсинг конфига) —
#    если конфиг и реальность разошлись (например, служба не была
#    перезапущена после правки), config-based детекция обманет
#    и приведёт к блокировке реального порта в ufw.
# ------------------------------------------------------------
REAL_LISTEN_PORTS=()
mapfile -t REAL_LISTEN_PORTS < <(ss -tlnp 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)

CONFIG_PORT=""
if command -v sshd >/dev/null 2>&1; then
    CONFIG_PORT=$(sshd -T 2>/dev/null | grep -i "^port" | awk '{print $2}' | head -n1) || true
fi

if (( ${#REAL_LISTEN_PORTS[@]} == 1 )); then
    DETECTED_SSH_PORT="${REAL_LISTEN_PORTS[0]}"
    info "Реально слушающий SSH-порт (по ss): ${DETECTED_SSH_PORT}"
    if [[ -n "$CONFIG_PORT" && "$CONFIG_PORT" != "$DETECTED_SSH_PORT" ]]; then
        warn "Конфиг sshd_config указывает порт ${CONFIG_PORT}, но реально слушается ${DETECTED_SSH_PORT}."
        warn "Используем реально слушающий порт — именно он важен для firewall."
    fi
elif (( ${#REAL_LISTEN_PORTS[@]} > 1 )); then
    warn "SSH слушает НЕСКОЛЬКО портов одновременно: ${REAL_LISTEN_PORTS[*]}"
    DETECTED_SSH_PORT="${REAL_LISTEN_PORTS[0]}"
    warn "Взят первый (${DETECTED_SSH_PORT}) как предложение — проверьте внимательно перед подтверждением."
else
    err "Не удалось определить порт SSH через ss (сервис не слушает ни один порт?)."
    if [[ -n "$CONFIG_PORT" ]]; then
        warn "Используем значение из конфига как fallback: ${CONFIG_PORT}"
        DETECTED_SSH_PORT="$CONFIG_PORT"
    else
        err "Fallback тоже недоступен. Используем дефолт 22 — ОБЯЗАТЕЛЬНО проверьте вручную перед продолжением!"
        DETECTED_SSH_PORT=22
    fi
fi

echo
warn "ВАЖНО: убедитесь, что порт ниже — это ТОЧНО тот порт, которым вы пользуетесь для SSH."
warn "Если ошибётесь — после включения ufw вы потеряете доступ к серверу."
read -rp "Подтвердите SSH-порт (Enter — ${DETECTED_SSH_PORT}): " SSH_PORT_INPUT
SSH_PORT=${SSH_PORT_INPUT:-$DETECTED_SSH_PORT}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    err "Некорректный порт: ${SSH_PORT}"
    exit 1
fi

# Финальная защитная проверка: если введённый порт не совпадает
# ни с одним реально слушающим — предупреждаем явно и требуем
# отдельного подтверждения, а не тихо продолжаем.
if (( ${#REAL_LISTEN_PORTS[@]} > 0 )) && ! printf '%s\n' "${REAL_LISTEN_PORTS[@]}" | grep -qx "$SSH_PORT"; then
    err "ВНИМАНИЕ: порт ${SSH_PORT} НЕ входит в реально слушающие SSH-порты (${REAL_LISTEN_PORTS[*]})!"
    err "Если продолжить — вы, скорее всего, потеряете доступ к серверу после включения ufw."
    if ! ask_yes_no "Вы АБСОЛЮТНО уверены, что хотите использовать именно порт ${SSH_PORT}?" "no"; then
        err "Остановлено для вашей безопасности. Перепроверьте порт и запустите скрипт заново."
        exit 1
    fi
fi

# ------------------------------------------------------------
# 2. Устанавливаем ufw, если нет
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    info "ufw уже установлен."
else
    log "Устанавливаем ufw..."
    apt update -qq
    apt install -y ufw >/dev/null
fi

# ------------------------------------------------------------
# 3. Показываем текущее состояние перед изменением
# ------------------------------------------------------------
echo
info "Текущее состояние ufw:"
ufw status verbose 2>/dev/null || echo "  (ufw ещё не активирован)"

echo
echo "План действий:"
echo "  - Разрешить: ${SSH_PORT}/tcp (SSH)"
echo "  - Разрешить: 80/tcp (HTTP)"
echo "  - Разрешить: 443/tcp (HTTPS)"
echo "  - Всё остальное — ЗАКРЫТО (default deny incoming)"
echo "  - Настроить fail2ban для SSH"
echo "  - Установить часовой пояс Asia/Irkutsk"
echo "  - Настроить ежедневную перезагрузку в 04:00"
echo

if ! ask_yes_no "Продолжить и применить эти правила?" "no"; then
    warn "Отменено пользователем."
    exit 0
fi

# ------------------------------------------------------------
# 4. Применяем правила (безопасно — не закрываем старые SSH-порты
#    сразу, только после вашего подтверждения, что новый работает)
# ------------------------------------------------------------
log "Открываем нужные порты (старые SSH-правила пока не трогаем)..."

ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
log "ufw активирован. SSH-порт ${SSH_PORT}, 80 и 443 открыты."

echo
warn "=========================================================="
warn " ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ!"
warn " Откройте НОВОЕ окно терминала и подключитесь так:"
echo
echo -e "   ssh -p ${SSH_PORT} $(whoami)@$(curl -s -4 ifconfig.me 2>/dev/null || echo 'ВАШ_IP')"
echo
warn " Только убедившись, что подключение прошло успешно,"
warn " возвращайтесь сюда и подтверждайте продолжение."
warn "=========================================================="
echo

CLEANUP_OLD_SSH=false
if ask_yes_no "Подключение на порту ${SSH_PORT} точно работает? Убрать старые SSH-правила (если есть)?" "no"; then
    CLEANUP_OLD_SSH=true
else
    warn "Оставлено как есть. Старые SSH-правила (если были) НЕ удалены — можете почистить вручную позже:"
    echo "  ufw status numbered"
    echo "  ufw --force delete <номер>"
fi

if [[ "$CLEANUP_OLD_SSH" == "true" ]]; then
    log "Ищем старые SSH-правила (по комментарию '# SSH'), отличные от порта ${SSH_PORT}..."

    # ВАЖНО: номера правил у ufw дополняются пробелом для выравнивания
    # (например "[ 4]"), поэтому извлекаем номер через sed, а не через
    # grep -oE '^\[[0-9]+\]', который такие строки не матчит вообще.
    STALE_SSH_RULES=$(ufw status numbered 2>/dev/null | grep -E "# SSH$" | grep -vE "^\[[[:space:]0-9]+\][[:space:]]+${SSH_PORT}/tcp" || true)

    if [[ -n "$STALE_SSH_RULES" ]]; then
        warn "Найдены старые SSH-правила для удаления:"
        echo "$STALE_SSH_RULES"
        while IFS= read -r num; do
            [[ -n "$num" ]] && ufw --force delete "$num" >/dev/null 2>&1
        done < <(echo "$STALE_SSH_RULES" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn)

        REMAINING=$(ufw status numbered 2>/dev/null | grep -E "# SSH$" | grep -vE "^\[[[:space:]0-9]+\][[:space:]]+${SSH_PORT}/tcp" || true)
        if [[ -z "$REMAINING" ]]; then
            log "Старые SSH-правила удалены."
        else
            warn "Не всё удалилось автоматически, осталось:"
            echo "$REMAINING"
        fi
    else
        info "Старых SSH-правил не найдено — нечего чистить."
    fi
fi

# ------------------------------------------------------------
# 5. fail2ban — защита SSH от брутфорса
# ------------------------------------------------------------
echo
if command -v fail2ban-client >/dev/null 2>&1; then
    info "fail2ban уже установлен."
else
    log "Устанавливаем fail2ban..."
    apt update -qq
    apt install -y fail2ban >/dev/null
fi

log "Настраиваем jail.local под порт ${SSH_PORT}..."
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
log "fail2ban настроен и запущен."

# ------------------------------------------------------------
# 6. Часовой пояс — Asia/Irkutsk
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
# 7. Ежедневная перезагрузка в 4:00
# ------------------------------------------------------------
echo
log "Настраиваем ежедневную перезагрузку в 4:00..."
if command -v crontab >/dev/null 2>&1; then
    info "cron уже установлен."
else
    log "Устанавливаем cron..."
    apt update -qq
    apt install -y cron >/dev/null
fi

CRON_JOB="0 4 * * * /sbin/shutdown -r now"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "$EXISTING_CRON" | grep -qF "shutdown -r now"; then
    info "Задача на перезагрузку уже присутствует в crontab — пропускаем добавление."
else
    log "Добавляем задачу в crontab root: '${CRON_JOB}'"
    ( echo "$EXISTING_CRON"; echo "$CRON_JOB" ) | grep -v '^$' | crontab -
fi

systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true

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

if crontab -l 2>/dev/null | grep -qF "shutdown -r now"; then
    log "Задача перезагрузки подтверждена в crontab root."
else
    err "Задача перезагрузки НЕ найдена в crontab после добавления! Проверьте вручную: crontab -l"
fi

# ------------------------------------------------------------
# 8. Финальная проверка
# ------------------------------------------------------------
echo
echo "============================================================"
log "Финальная проверка"
echo "============================================================"

if systemctl is-active --quiet ufw 2>/dev/null || ufw status | grep -q "Status: active"; then
    log "ufw активен."
else
    err "ufw НЕ активен! Проверьте вручную: ufw status verbose"
fi

echo
ufw status verbose

echo
if ufw status | grep -qE "^${SSH_PORT}/tcp"; then
    log "SSH-порт ${SSH_PORT} подтверждён открытым."
else
    err "SSH-порт ${SSH_PORT} НЕ найден в правилах ufw! Проверьте, чтобы не потерять доступ."
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
info "fail2ban jail sshd:"
fail2ban-client status sshd 2>/dev/null || warn "Не удалось получить статус jail."

echo
echo "============================================================"
log "Готово!"
echo "  Открыто:            ${SSH_PORT}/tcp (SSH), 80/tcp, 443/tcp"
echo "  Всё остальное:      закрыто"
echo "  fail2ban:           bantime=1d, findtime=1h, maxretry=3"
echo "  Часовой пояс:       Asia/Irkutsk"
echo "  Автоперезагрузка:   ежедневно в 04:00"
echo "============================================================"
warn "Не закрывайте текущую сессию, пока не проверите подключение в новом окне терминала!"
