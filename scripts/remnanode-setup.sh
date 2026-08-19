#!/bin/bash
set -euo pipefail

# ============================================================
#  remnanode setup — установка/настройка ноды Remnawave
#  Автоматически прописывает volumes (включая сертификаты для
#  Hysteria2) в docker-compose.yml — без ручной правки руками.
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

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " remnanode — установка и настройка"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Docker + Compose plugin — ставим, если нет
# ------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    info "Docker уже установлен ($(docker --version))."
else
    log "Docker не найден — устанавливаем..."
    if ! curl -fsSL https://get.docker.com | sh; then
        err "Не удалось установить Docker. Проверьте подключение к сети/репозиториям."
        exit 1
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    log "Docker установлен."
fi

if ! docker compose version >/dev/null 2>&1; then
    err "Плагин 'docker compose' недоступен даже после установки Docker."
    err "Проверьте вручную: docker compose version"
    exit 1
fi
info "docker compose: $(docker compose version --short 2>/dev/null || echo OK)"

# ------------------------------------------------------------
# 2. Каталог установки
# ------------------------------------------------------------
echo
read -rp "Каталог для remnanode (Enter — /opt/remnanode): " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/remnanode}
mkdir -p "$INSTALL_DIR"

COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

REINSTALL=false
if [[ -f "$COMPOSE_FILE" ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
    warn "Найдена существующая установка remnanode в ${INSTALL_DIR}."
    read -rp "Пропустить установку и просто проверить/дочинить volumes? [Y/n]: " SKIP_INSTALL
    if [[ "$SKIP_INSTALL" != "n" && "$SKIP_INSTALL" != "N" ]]; then
        REINSTALL=false
        info "Пропускаем пересоздание — будем работать с существующим compose-файлом."
    else
        REINSTALL=true
    fi
fi

# ------------------------------------------------------------
# 3. NODE_PORT и SECRET_KEY
# ------------------------------------------------------------
echo
EXISTING_NODE_PORT=""
EXISTING_SECRET_KEY=""
if [[ -f "$COMPOSE_FILE" ]]; then
    EXISTING_NODE_PORT=$(grep -oE 'NODE_PORT=[0-9]+' "$COMPOSE_FILE" | head -n1 | cut -d= -f2 || true)
    EXISTING_SECRET_KEY=$(grep -oE 'SECRET_KEY=.*' "$COMPOSE_FILE" | head -n1 | cut -d= -f2- || true)
fi

read -rp "NODE_PORT (Enter — ${EXISTING_NODE_PORT:-3001}): " NODE_PORT
NODE_PORT=${NODE_PORT:-${EXISTING_NODE_PORT:-3001}}
if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || (( NODE_PORT < 1 || NODE_PORT > 65535 )); then
    err "Некорректный NODE_PORT: ${NODE_PORT}"
    exit 1
fi

if [[ -n "$EXISTING_SECRET_KEY" ]]; then
    info "Найден существующий SECRET_KEY в конфиге."
    read -rp "Оставить текущий SECRET_KEY? [Y/n]: " KEEP_KEY
    if [[ "$KEEP_KEY" == "n" || "$KEEP_KEY" == "N" ]]; then
        EXISTING_SECRET_KEY=""
    fi
fi

if [[ -z "$EXISTING_SECRET_KEY" ]]; then
    echo
    echo "Вставьте SECRET_KEY из панели Remnawave (Nodes → нода → Secret Key)."
    read -rp "SECRET_KEY: " SECRET_KEY_INPUT
else
    SECRET_KEY_INPUT="$EXISTING_SECRET_KEY"
fi

# Защита от старой известной проблемы: если ключ случайно вставлен в кавычках —
# убираем их автоматически, а не роняем контейнер с 'Invalid SECRET_KEY payload'.
SECRET_KEY_CLEAN=$(echo "$SECRET_KEY_INPUT" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')

if [[ -z "$SECRET_KEY_CLEAN" ]]; then
    err "SECRET_KEY пустой — без него нода не запустится."
    exit 1
fi

if [[ "$SECRET_KEY_INPUT" != "$SECRET_KEY_CLEAN" ]]; then
    warn "Обнаружены и автоматически убраны лишние кавычки/пробелы вокруг SECRET_KEY."
fi

# ------------------------------------------------------------
# 4. Поиск сертификатов Let's Encrypt для Hysteria2
# ------------------------------------------------------------
echo
log "Ищем существующие сертификаты Let's Encrypt для Hysteria2..."

CERT_DOMAINS=()
if [[ -d /etc/letsencrypt/live ]]; then
    while IFS= read -r -d '' dir; do
        domain=$(basename "$dir")
        if [[ "$domain" != "README" && -f "${dir}/fullchain.pem" && -f "${dir}/privkey.pem" ]]; then
            CERT_DOMAINS+=("$domain")
        fi
    done < <(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

HYSTERIA_CERT_DIR=""
if (( ${#CERT_DOMAINS[@]} == 0 )); then
    warn "Сертификаты Let's Encrypt не найдены в /etc/letsencrypt/live/."
    warn "Если планируете использовать Hysteria2 — сначала выпустите сертификат"
    warn "(например через отдельный скрипт настройки HAProxy+Nginx+Certbot), затем перезапустите этот шаг."
    read -rp "Продолжить БЕЗ сертификата для Hysteria2 (только VLESS-протоколы)? [y/N]: " CONTINUE_NO_CERT
    if [[ "$CONTINUE_NO_CERT" != "y" && "$CONTINUE_NO_CERT" != "Y" ]]; then
        err "Остановлено. Настройте сертификат и запустите заново."
        exit 1
    fi
elif (( ${#CERT_DOMAINS[@]} == 1 )); then
    HYSTERIA_CERT_DIR="${CERT_DOMAINS[0]}"
    info "Найден сертификат: ${HYSTERIA_CERT_DIR} (будет использован для Hysteria2)."
else
    echo "Найдено несколько сертификатов:"
    local_i=1
    for d in "${CERT_DOMAINS[@]}"; do
        echo "  ${local_i}) ${d}"
        ((local_i++))
    done
    echo "  0) Не использовать (пропустить Hysteria2)"
    read -rp "Выберите номер: " CERT_CHOICE
    if [[ "$CERT_CHOICE" == "0" ]]; then
        HYSTERIA_CERT_DIR=""
    elif [[ "$CERT_CHOICE" =~ ^[0-9]+$ ]] && (( CERT_CHOICE >= 1 && CERT_CHOICE <= ${#CERT_DOMAINS[@]} )); then
        HYSTERIA_CERT_DIR="${CERT_DOMAINS[$((CERT_CHOICE-1))]}"
    else
        err "Некорректный выбор."
        exit 1
    fi
fi

if [[ -n "$HYSTERIA_CERT_DIR" ]]; then
    CERT_FULLCHAIN="/etc/letsencrypt/live/${HYSTERIA_CERT_DIR}/fullchain.pem"
    CERT_PRIVKEY="/etc/letsencrypt/live/${HYSTERIA_CERT_DIR}/privkey.pem"
    if [[ ! -f "$CERT_FULLCHAIN" || ! -f "$CERT_PRIVKEY" ]]; then
        err "Файлы сертификата не найдены по ожидаемым путям. Отменяем монтирование сертификата."
        HYSTERIA_CERT_DIR=""
    fi
fi

# ------------------------------------------------------------
# 5. Собираем docker-compose.yml — volumes прописываются АВТОМАТИЧЕСКИ
# ------------------------------------------------------------
echo
log "Собираем docker-compose.yml..."

if [[ -f "$COMPOSE_FILE" ]]; then
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%s)"
    info "Бэкап текущего compose-файла создан."
fi

{
    echo "services:"
    echo "  remnanode:"
    echo "    container_name: remnanode"
    echo "    hostname: remnanode"
    echo "    image: remnawave/node:latest"
    echo "    network_mode: host"
    echo "    restart: always"
    echo "    cap_add:"
    echo "      - NET_ADMIN"
    echo "    ulimits:"
    echo "      nofile:"
    echo "        soft: 1048576"
    echo "        hard: 1048576"
    echo "    environment:"
    echo "      - NODE_PORT=${NODE_PORT}"
    echo "      - SECRET_KEY=${SECRET_KEY_CLEAN}"
    echo "    volumes:"
    echo "      - /var/log/remnanode:/var/log/remnanode"
    if [[ -n "$HYSTERIA_CERT_DIR" ]]; then
        echo "      - ${CERT_FULLCHAIN}:/etc/hysteria/fullchain.pem:ro"
        echo "      - ${CERT_PRIVKEY}:/etc/hysteria/privkey.pem:ro"
    fi
} > "$COMPOSE_FILE"

log "docker-compose.yml записан: ${COMPOSE_FILE}"
if [[ -n "$HYSTERIA_CERT_DIR" ]]; then
    log "Volumes для Hysteria2 добавлены автоматически (домен: ${HYSTERIA_CERT_DIR})."
else
    info "Volumes для Hysteria2 не добавлены (сертификат не выбран)."
fi

# Проверка синтаксиса compose-файла ПЕРЕД запуском
if ! docker compose -f "$COMPOSE_FILE" config >/dev/null 2>/tmp/compose_err; then
    err "docker-compose.yml содержит ошибки синтаксиса:"
    cat /tmp/compose_err
    exit 1
fi
log "Синтаксис docker-compose.yml корректен."

# ------------------------------------------------------------
# 6. Запуск
# ------------------------------------------------------------
echo
log "Запускаем remnanode..."
mkdir -p /var/log/remnanode

cd "$INSTALL_DIR"
docker compose down >/dev/null 2>&1 || true
docker compose up -d

# ------------------------------------------------------------
# 7. Проверки после запуска
# ------------------------------------------------------------
echo
log "Проверяем, что контейнер поднялся..."

wait_for_container_running() {
    local tries=20
    local i=0
    while (( i < tries )); do
        if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q '^remnanode.*Up'; then
            return 0
        fi
        sleep 1
        ((i++))
    done
    return 1
}

if wait_for_container_running; then
    log "Контейнер remnanode запущен."
else
    err "Контейнер remnanode не поднялся за отведённое время. Логи:"
    docker logs remnanode --tail 50 2>&1 || true
    exit 1
fi

echo
log "Проверяем логи на успешный старт XRay Core (до 15 секунд)..."
XRAY_OK=false
for i in $(seq 1 15); do
    if docker logs remnanode 2>&1 | grep -q "XRay Core.*is up and running"; then
        XRAY_OK=true
        break
    fi
    sleep 1
done

if [[ "$XRAY_OK" == "true" ]]; then
    log "XRay Core успешно запущен внутри контейнера."
else
    warn "Не удалось подтвердить строку об успешном старте XRay Core в логах за 15 секунд."
    warn "Это не обязательно ошибка — панель могла ещё не запушить конфиг с инбаундами."
    echo "--- Последние строки логов ---"
    docker logs remnanode --tail 30 2>&1 || true
fi

echo
log "Проверяем, что NODE_PORT (${NODE_PORT}) слушается..."
sleep 1
if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
    log "Порт ${NODE_PORT} подтверждён слушающим."
else
    err "Порт ${NODE_PORT} НЕ слушается! Проверьте логи контейнера:"
    docker logs remnanode --tail 50 2>&1 || true
fi

if [[ -n "$HYSTERIA_CERT_DIR" ]]; then
    echo
    log "Проверяем, что сертификаты примонтировались внутрь контейнера..."
    if docker exec remnanode test -f /etc/hysteria/fullchain.pem 2>/dev/null && \
       docker exec remnanode test -f /etc/hysteria/privkey.pem 2>/dev/null; then
        log "Сертификаты внутри контейнера на месте (/etc/hysteria/fullchain.pem, privkey.pem)."
    else
        err "Сертификаты НЕ найдены внутри контейнера! Volumes не примонтировались."
        err "Проверьте вручную: docker exec remnanode ls -la /etc/hysteria/"
    fi
fi

# ------------------------------------------------------------
# 8. Итоговая сводка
# ------------------------------------------------------------
echo
echo "============================================================"
log "Готово!"
echo "  Каталог:        ${INSTALL_DIR}"
echo "  Compose-файл:   ${COMPOSE_FILE}"
echo "  NODE_PORT:      ${NODE_PORT}"
if [[ -n "$HYSTERIA_CERT_DIR" ]]; then
echo "  Hysteria2 cert: ${HYSTERIA_CERT_DIR} (примонтирован)"
else
echo "  Hysteria2 cert: не настроен"
fi
echo
echo "  Логи:           docker logs remnanode -f"
echo "  Перезапуск:     cd ${INSTALL_DIR} && docker compose restart"
echo "============================================================"
