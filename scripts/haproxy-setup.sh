#!/bin/bash
set -euo pipefail

# ============================================================
#  Multi-Protocol Setup: HAProxy + Nginx Decoy + Certbot
#  REALITY TCP / gRPC / XHTTP (через HAProxy на 443/tcp)
#  Hysteria2 (напрямую на 443/udp через Xray в контейнере)
#  v2: с проверками DNS, портов, сертификатов
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

# Проверяет, существует ли файл конфига, и если да — спрашивает,
# перезаписывать его или оставить как есть.
# Возвращает 0 (true) если нужно писать/перезаписывать, 1 если пропустить.
confirm_overwrite() {
    local file="$1"
    local label="$2"
    if [[ -f "$file" ]]; then
        warn "${label} уже существует: ${file}"
        if ! ask_yes_no "Перезаписать существующий конфиг?" "no"; then
            info "Оставляем существующий ${label} без изменений."
            return 1
        fi
    fi
    return 0
}

if [[ $EUID -ne 0 ]]; then
   err "Запускать нужно от root (sudo)."
   exit 1
fi

echo "============================================================"
echo " Настройка мультипротокольной схемы: HAProxy + Nginx + Certbot"
echo "============================================================"
echo

# ------------------------------------------------------------
# 0. Проверка необходимых утилит
# ------------------------------------------------------------
for cmd in curl dig; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Утилита '$cmd' не найдена, будет установлена вместе с dnsutils/curl."
    fi
done

# ------------------------------------------------------------
# 1. Сбор доменов у пользователя
# ------------------------------------------------------------
read -rp "Домен для REALITY TCP (например rutm1.example.net): " DOMAIN_TCP
read -rp "Домен для gRPC        (например rutm2.example.net): " DOMAIN_GRPC
read -rp "Домен для XHTTP       (например rutm3.example.net): " DOMAIN_XHTTP
read -rp "Домен для Hysteria2   (например rutm4.example.net): " DOMAIN_HY2
read -rp "Email для Let's Encrypt (для certbot): " LE_EMAIL

echo
read -rp "Порт REALITY TCP (внутренний, дефолт 56789): " PORT_TCP
PORT_TCP=${PORT_TCP:-56789}
read -rp "Порт gRPC (внутренний, дефолт 56790): " PORT_GRPC
PORT_GRPC=${PORT_GRPC:-56790}
read -rp "Порт XHTTP (внутренний, дефолт 56791): " PORT_XHTTP
PORT_XHTTP=${PORT_XHTTP:-56791}

echo
log "Проверьте введённые данные:"
echo "  REALITY TCP : $DOMAIN_TCP -> 127.0.0.1:$PORT_TCP"
echo "  gRPC        : $DOMAIN_GRPC -> 127.0.0.1:$PORT_GRPC"
echo "  XHTTP       : $DOMAIN_XHTTP -> 127.0.0.1:$PORT_XHTTP"
echo "  Hysteria2   : $DOMAIN_HY2 (напрямую, 443/udp)"
echo "  Email       : $LE_EMAIL"
echo
if ! ask_yes_no "Всё верно? Продолжить установку?" "no"; then
    warn "Отменено пользователем."
    exit 0
fi

# ------------------------------------------------------------
# 2. Установка пакетов
# ------------------------------------------------------------
log "Обновляем apt и ставим пакеты (nginx, haproxy, certbot, ufw, dnsutils, curl)..."
apt update -qq
apt install -y nginx haproxy certbot python3-certbot-nginx ufw dnsutils curl >/dev/null

# ------------------------------------------------------------
# 2.5 Проверка DNS — все домены должны указывать на этот сервер
# ------------------------------------------------------------
log "Определяем внешний IP этого сервера..."
SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || true)
if [[ -z "$SERVER_IP" ]]; then
    warn "Не удалось автоматически определить внешний IP. Пропускаем DNS-проверку."
else
    info "Внешний IP сервера: $SERVER_IP"
    echo
    DNS_OK=true
    for DOMAIN in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
        RESOLVED_IP=$(dig +short A "$DOMAIN" | tail -n1)
        if [[ -z "$RESOLVED_IP" ]]; then
            err "  $DOMAIN -> DNS не резолвится вообще (A-запись отсутствует)"
            DNS_OK=false
        elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
            err "  $DOMAIN -> указывает на $RESOLVED_IP, а не на $SERVER_IP"
            DNS_OK=false
        else
            log "  $DOMAIN -> $RESOLVED_IP (OK)"
        fi
    done
    echo
    if [[ "$DNS_OK" != "true" ]]; then
        err "Не все домены указывают на этот сервер. Certbot гарантированно не пройдёт валидацию."
        if ! ask_yes_no "Продолжить всё равно? Обычно не имеет смысла." "no"; then
            err "Остановлено. Поправьте DNS-записи и запустите скрипт заново."
            exit 1
        fi
    else
        log "Все домены корректно указывают на этот сервер."
    fi
fi

# ------------------------------------------------------------
# 2.6 Проверка занятости портов 80/443 сторонними процессами
# ------------------------------------------------------------
log "Проверяем, не заняты ли порты 80/443 другими процессами..."
for PORT in 80 443; do
    OCCUPANT=$(ss -tlnp 2>/dev/null | awk -v p=":$PORT " '$4 ~ p {print $0}')
    if [[ -n "$OCCUPANT" ]]; then
        if echo "$OCCUPANT" | grep -qE "nginx|haproxy"; then
            info "  Порт $PORT занят nginx/haproxy — это ожидаемо при повторном запуске, продолжаем."
        else
            warn "  Порт $PORT занят посторонним процессом:"
            echo "    $OCCUPANT"
            warn "  Это может помешать nginx/haproxy запуститься. Проверьте вручную при ошибках ниже."
        fi
    fi
done

# ------------------------------------------------------------
# 3. Firewall
# ------------------------------------------------------------
log "Открываем нужные порты в ufw..."
ufw allow 80/tcp >/dev/null || true
ufw allow 443/tcp >/dev/null || true
ufw allow 443/udp >/dev/null || true

# ------------------------------------------------------------
# 3.5 Чистим только симлинки sites-enabled (безопасно, не трогает
#     сами файлы конфигов в sites-available — их обрабатываем
#     дальше с явным вопросом о перезаписи)
# ------------------------------------------------------------
log "Пересоздаём симлинки sites-enabled..."
rm -f /etc/nginx/sites-enabled/decoy-http.conf
rm -f /etc/nginx/sites-enabled/decoy-tls.conf

# ------------------------------------------------------------
# 4. Временный HTTP-вхост для выпуска сертификата
# ------------------------------------------------------------
log "Готовим временный HTTP vhost для certbot..."
mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default

if confirm_overwrite "/etc/nginx/sites-available/decoy-http.conf" "HTTP-vhost для certbot"; then
cat > /etc/nginx/sites-available/decoy-http.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_TCP} ${DOMAIN_GRPC} ${DOMAIN_XHTTP} ${DOMAIN_HY2};

    root /var/www/html;

    location /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF
fi

ln -sf /etc/nginx/sites-available/decoy-http.conf /etc/nginx/sites-enabled/decoy-http.conf

if ! nginx -t 2>/tmp/nginx_test_err; then
    err "Ошибка синтаксиса nginx (шаг HTTP-vhost):"
    cat /tmp/nginx_test_err
    exit 1
fi
systemctl restart nginx
log "Nginx HTTP-vhost поднят успешно."

# ------------------------------------------------------------
# 5. Выпуск сертификата — с проверкой на уже существующий
# ------------------------------------------------------------
CERT_DIR="/etc/letsencrypt/live/${DOMAIN_TCP}"

if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    log "Сертификат для ${DOMAIN_TCP} уже существует, проверяем что он покрывает все нужные домены..."
    EXISTING_SANS=$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)
    MISSING=false
    for DOMAIN in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
        if ! echo "$EXISTING_SANS" | grep -q "$DOMAIN"; then
            warn "  Домен $DOMAIN отсутствует в текущем сертификате."
            MISSING=true
        fi
    done
    if [[ "$MISSING" == "true" ]]; then
        log "Расширяем существующий сертификат недостающими доменами..."
        certbot certonly --nginx \
          -d "$DOMAIN_TCP" -d "$DOMAIN_GRPC" -d "$DOMAIN_XHTTP" -d "$DOMAIN_HY2" \
          --agree-tos -m "$LE_EMAIL" --no-eff-email --expand --non-interactive
    else
        log "Сертификат уже покрывает все 4 домена, повторный выпуск не требуется."
    fi
else
    log "Выпускаем новый сертификат Let's Encrypt на все 4 домена..."
    certbot certonly --nginx \
      -d "$DOMAIN_TCP" -d "$DOMAIN_GRPC" -d "$DOMAIN_XHTTP" -d "$DOMAIN_HY2" \
      --agree-tos -m "$LE_EMAIL" --no-eff-email --expand --non-interactive
fi

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]] || [[ ! -f "${CERT_DIR}/privkey.pem" ]]; then
    err "Сертификат не найден в ${CERT_DIR} после попытки выпуска."
    err "Проверьте DNS-записи доменов и вывод certbot выше."
    exit 1
fi

# Проверка срока действия
EXPIRY=$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate | cut -d= -f2)
log "Сертификат готов: ${CERT_DIR}/fullchain.pem (действителен до: ${EXPIRY})"

# ------------------------------------------------------------
# 6. Своя decoy-страница
# ------------------------------------------------------------
log "Создаём собственную decoy-страницу (без сторонних сайтов)..."
mkdir -p /var/www/decoy
mkdir -p /var/log/nginx

cat > /var/www/decoy/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Site</title>
<style>
body{font-family:Arial,sans-serif;background:#f4f4f4;display:flex;height:100vh;
align-items:center;justify-content:center;margin:0;color:#333}
.box{text-align:center}
</style>
</head>
<body>
<div class="box">
<h1>It works</h1>
<p>Nothing to see here.</p>
</div>
</body>
</html>
EOF

if [[ ! -f /var/www/decoy/index.html ]]; then
    err "Не удалось создать decoy-страницу /var/www/decoy/index.html"
    exit 1
fi
log "Decoy-страница создана."

# ------------------------------------------------------------
# 7. Nginx decoy на 127.0.0.1:8081 (target для Reality)
# ------------------------------------------------------------
log "Настраиваем decoy-vhosts на 127.0.0.1:8081 для Reality target..."

if confirm_overwrite "/etc/nginx/sites-available/decoy-tls.conf" "Decoy TLS vhosts"; then
cat > /etc/nginx/sites-available/decoy-tls.conf <<EOF
server {
    listen 127.0.0.1:8081 ssl http2;
    server_name ${DOMAIN_TCP};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    root /var/www/decoy;
    index index.html;

    access_log /var/log/nginx/decoy-${DOMAIN_TCP}.log;
}

server {
    listen 127.0.0.1:8081 ssl http2;
    server_name ${DOMAIN_GRPC};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    root /var/www/decoy;
    index index.html;

    access_log /var/log/nginx/decoy-${DOMAIN_GRPC}.log;
}

server {
    listen 127.0.0.1:8081 ssl http2;
    server_name ${DOMAIN_XHTTP};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    root /var/www/decoy;
    index index.html;

    access_log /var/log/nginx/decoy-${DOMAIN_XHTTP}.log;
}
EOF
fi

ln -sf /etc/nginx/sites-available/decoy-tls.conf /etc/nginx/sites-enabled/decoy-tls.conf

if ! nginx -t 2>/tmp/nginx_test_err2; then
    err "Ошибка синтаксиса nginx (шаг decoy-tls):"
    cat /tmp/nginx_test_err2
    exit 1
fi
systemctl reload nginx
log "Decoy TLS vhosts подняты успешно."

# ------------------------------------------------------------
# 8. HAProxy — SNI-роутинг на 443/tcp
# ------------------------------------------------------------
log "Настраиваем HAProxy (SNI-роутинг для трёх VLESS-протоколов)..."

if confirm_overwrite "/etc/haproxy/haproxy.cfg" "HAProxy конфиг"; then
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4096

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend fe_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    use_backend be_reality_tcp if { req.ssl_sni -i ${DOMAIN_TCP} }
    use_backend be_grpc        if { req.ssl_sni -i ${DOMAIN_GRPC} }
    use_backend be_xhttp       if { req.ssl_sni -i ${DOMAIN_XHTTP} }

    default_backend be_reality_tcp

backend be_reality_tcp
    mode tcp
    server xray1 127.0.0.1:${PORT_TCP} check

backend be_grpc
    mode tcp
    server xray2 127.0.0.1:${PORT_GRPC} check

backend be_xhttp
    mode tcp
    server xray3 127.0.0.1:${PORT_XHTTP} check
EOF
fi

if ! haproxy -c -f /etc/haproxy/haproxy.cfg 2>/tmp/haproxy_test_err; then
    err "Ошибка синтаксиса haproxy.cfg:"
    cat /tmp/haproxy_test_err
    exit 1
fi

systemctl enable haproxy >/dev/null
systemctl restart haproxy
log "HAProxy настроен и перезапущен."

# ------------------------------------------------------------
# 8.5 Порт уже установленной ноды (remnanode) — для доступа панели
# ------------------------------------------------------------
echo
log "Ищем уже установленную ноду remnanode, чтобы определить её NODE_PORT..."

DETECTED_NODE_PORT=""
DETECTED_COMPOSE_PATH=""

for CANDIDATE in /opt/remnanode/docker-compose.yml /root/remnanode/docker-compose.yml; do
    if [[ -f "$CANDIDATE" ]]; then
        PORT_FOUND=$(grep -oE 'NODE_PORT=[0-9]+' "$CANDIDATE" | head -n1 | cut -d= -f2 || true)
        if [[ -n "$PORT_FOUND" ]]; then
            DETECTED_NODE_PORT="$PORT_FOUND"
            DETECTED_COMPOSE_PATH="$CANDIDATE"
            break
        fi
    fi
done

# Если в стандартных местах не нашли — пробуем поискать шире (но не слишком долго)
if [[ -z "$DETECTED_NODE_PORT" ]]; then
    FOUND_COMPOSE=$(find /opt /root /home -maxdepth 4 -iname "docker-compose.yml" 2>/dev/null \
        | xargs -r grep -l "remnanode" 2>/dev/null | head -n1 || true)
    if [[ -n "$FOUND_COMPOSE" ]]; then
        PORT_FOUND=$(grep -oE 'NODE_PORT=[0-9]+' "$FOUND_COMPOSE" | head -n1 | cut -d= -f2 || true)
        if [[ -n "$PORT_FOUND" ]]; then
            DETECTED_NODE_PORT="$PORT_FOUND"
            DETECTED_COMPOSE_PATH="$FOUND_COMPOSE"
        fi
    fi
fi

if [[ -n "$DETECTED_NODE_PORT" ]]; then
    log "Найдена нода: ${DETECTED_COMPOSE_PATH}, NODE_PORT=${DETECTED_NODE_PORT}"
else
    warn "Не удалось автоматически найти установленную ноду или её NODE_PORT."
fi

read -rp "Порт ноды для доступа панели (Enter — ${DETECTED_NODE_PORT:-3001}): " NODE_PORT_INPUT
NODE_PORT_FINAL=${NODE_PORT_INPUT:-${DETECTED_NODE_PORT:-3001}}

if ! [[ "$NODE_PORT_FINAL" =~ ^[0-9]+$ ]] || (( NODE_PORT_FINAL < 1 || NODE_PORT_FINAL > 65535 )); then
    err "Некорректный порт: ${NODE_PORT_FINAL}. Пропускаем открытие порта для панели."
else
    echo
    if ask_yes_no "Открыть порт ${NODE_PORT_FINAL} в ufw для доступа панели?" "no"; then
        read -rp "IP панели (Enter — открыть всем, менее безопасно): " PANEL_IP_INPUT
        if [[ -n "$PANEL_IP_INPUT" ]]; then
            ufw allow from "$PANEL_IP_INPUT" to any port "$NODE_PORT_FINAL" proto tcp comment 'Node API - panel' >/dev/null || true
            log "Порт ${NODE_PORT_FINAL} открыт только для IP панели (${PANEL_IP_INPUT})."
        else
            ufw allow "${NODE_PORT_FINAL}/tcp" comment 'Node API - panel (open)' >/dev/null || true
            warn "Порт ${NODE_PORT_FINAL} открыт для ВСЕХ — IP панели не был указан."
        fi
    else
        info "Порт ${NODE_PORT_FINAL} НЕ открывается этим скриптом."
        info "Текущее состояние firewall для этого порта не меняется — ни открытие, ни закрытие."
    fi
fi

# ------------------------------------------------------------
# 9. Автопродление сертификата + hook
# ------------------------------------------------------------
log "Настраиваем автопродление сертификата..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
    docker restart remnanode
fi
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

systemctl enable --now certbot.timer >/dev/null

# ------------------------------------------------------------
# 10. ФИНАЛЬНАЯ ПРОВЕРКА — что реально поднялось
# ------------------------------------------------------------
echo
echo "============================================================"
log "Финальная проверка сервисов и портов"
echo "============================================================"

ALL_OK=true

# Сервисы
for SERVICE in nginx haproxy; do
    if systemctl is-active --quiet "$SERVICE"; then
        log "  Служба $SERVICE: активна"
    else
        err "  Служба $SERVICE: НЕ активна"
        ALL_OK=false
    fi
done

# Порты
for CHECK in "80:tcp" "443:tcp"; do
    PORT="${CHECK%%:*}"
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        log "  Порт ${PORT}/tcp: слушается"
    else
        err "  Порт ${PORT}/tcp: НЕ слушается"
        ALL_OK=false
    fi
done

# Сертификат
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    log "  Сертификат: найден (${CERT_DIR}/fullchain.pem)"
else
    err "  Сертификат: НЕ найден"
    ALL_OK=false
fi

# Decoy-страница доступна изнутри
if curl -sk --max-time 5 https://127.0.0.1:8081/ -H "Host: ${DOMAIN_TCP}" | grep -q "It works"; then
    log "  Decoy-сайт: отвечает корректно"
else
    warn "  Decoy-сайт: не удалось проверить ответ (может быть нормально, если nginx ещё не разогрелся)"
fi

echo
if [[ "$ALL_OK" == "true" ]]; then
    log "Все базовые проверки пройдены успешно."
else
    err "Обнаружены проблемы выше — проверьте их перед тем как продолжать настройку ноды."
fi

echo
echo "============================================================"
log "Настройка volumes для Hysteria2 в docker-compose.yml ноды"
echo "============================================================"

if [[ -n "${DETECTED_COMPOSE_PATH:-}" && -f "$DETECTED_COMPOSE_PATH" ]] && command -v docker >/dev/null 2>&1; then
    if grep -q "/etc/hysteria/fullchain.pem" "$DETECTED_COMPOSE_PATH" 2>/dev/null; then
        info "В ${DETECTED_COMPOSE_PATH} volumes для Hysteria2 уже присутствуют — ничего не меняем."
    else
        echo
        info "Найден compose-файл ноды: ${DETECTED_COMPOSE_PATH}"
        if ask_yes_no "Автоматически дописать volumes для Hysteria2 и перезапустить ноду?" "yes"; then
            cp "$DETECTED_COMPOSE_PATH" "${DETECTED_COMPOSE_PATH}.bak.$(date +%s)"
            info "Бэкап текущего compose-файла создан."

            if grep -q "^\s*volumes:" "$DETECTED_COMPOSE_PATH"; then
                # Секция volumes уже есть — дописываем строки сразу после неё
                sed -i "/^\s*volumes:/a\\      - ${CERT_DIR}/fullchain.pem:/etc/hysteria/fullchain.pem:ro\\n      - ${CERT_DIR}/privkey.pem:/etc/hysteria/privkey.pem:ro" "$DETECTED_COMPOSE_PATH"
            else
                # Секции volumes нет вообще — добавляем в конец файла
                {
                    echo "    volumes:"
                    echo "      - /var/log/remnanode:/var/log/remnanode"
                    echo "      - ${CERT_DIR}/fullchain.pem:/etc/hysteria/fullchain.pem:ro"
                    echo "      - ${CERT_DIR}/privkey.pem:/etc/hysteria/privkey.pem:ro"
                } >> "$DETECTED_COMPOSE_PATH"
            fi

            if docker compose -f "$DETECTED_COMPOSE_PATH" config >/dev/null 2>/tmp/compose_patch_err; then
                log "docker-compose.yml успешно обновлён и прошёл проверку синтаксиса."
                COMPOSE_DIR=$(dirname "$DETECTED_COMPOSE_PATH")
                log "Перезапускаем ноду..."
                (cd "$COMPOSE_DIR" && docker compose down >/dev/null 2>&1 && docker compose up -d)

                sleep 3
                if docker exec remnanode test -f /etc/hysteria/fullchain.pem 2>/dev/null; then
                    log "Сертификат подтверждён внутри контейнера (/etc/hysteria/fullchain.pem)."
                else
                    warn "Не удалось подтвердить наличие сертификата внутри контейнера. Проверьте вручную:"
                    warn "  docker exec remnanode ls -la /etc/hysteria/"
                fi
            else
                err "После правки docker-compose.yml обнаружены ошибки синтаксиса:"
                cat /tmp/compose_patch_err
                err "Откатываем изменения из бэкапа."
                cp "${DETECTED_COMPOSE_PATH}.bak."* "$DETECTED_COMPOSE_PATH"
            fi
        else
            info "Пропущено по вашему выбору. Добавьте volumes вручную (пример ниже)."
        fi
    fi
else
    if [[ -z "${DETECTED_COMPOSE_PATH:-}" ]]; then
        warn "Установленная нода не найдена автоматически — volumes нужно добавить вручную."
    else
        warn "Docker не найден в PATH — не могу автоматически перезапустить ноду. Добавьте volumes вручную."
    fi
fi

echo
echo "-----------------------------------------------------------------"
echo "Пример volumes для ручного добавления (если нужно):"
cat <<EOF
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - ${CERT_DIR}/fullchain.pem:/etc/hysteria/fullchain.pem:ro
      - ${CERT_DIR}/privkey.pem:/etc/hysteria/privkey.pem:ro
EOF
echo "-----------------------------------------------------------------"
echo
log "В панели Remnawave настройте инбаунды со следующими параметрами:"
echo "  REALITY TCP : ${DOMAIN_TCP}:443 -> внутренний порт ${PORT_TCP}"
echo "  gRPC        : ${DOMAIN_GRPC}:443 -> внутренний порт ${PORT_GRPC}"
echo "  XHTTP       : ${DOMAIN_XHTTP}:443 -> внутренний порт ${PORT_XHTTP}"
echo "  Hysteria2   : ${DOMAIN_HY2}:443 (udp), cert=/etc/hysteria/fullchain.pem, key=/etc/hysteria/privkey.pem"
echo "============================================================"
