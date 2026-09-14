#!/bin/bash
set -euo pipefail

# ============================================================
#  haproxy-setup — Nginx (self-steal decoy) + HAProxy + Certbot
#  Для уже установленной ноды: настраивает инфраструктуру перед
#  ней, не трогает сам remnanode.
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

GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
DECOY_BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/decoys"

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

# Распаковывает zip во временную папку и, если внутри одна корневая папка
# без файлов рядом с ней, спускается внутрь — чтобы не получить лишний
# уровень вложенности при установке в /var/www/decoy.
unpack_to_content_dir() {
    local zip_path="$1"
    local extract_dir="$2"
    if ! unzip -q "$zip_path" -d "$extract_dir" 2>/tmp/unzip_err; then
        err "Не удалось распаковать архив:"
        cat /tmp/unzip_err
        return 1
    fi
    local content_dir="$extract_dir"
    local subdirs files_in_root
    subdirs=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)
    files_in_root=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type f | wc -l)
    if (( subdirs == 1 && files_in_root == 0 )); then
        content_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)
    fi
    echo "$content_dir"
}

# Поднимает временный HTTP-сервер на распакованной заглушке, печатает
# ссылку, ждёт Enter, затем сам всё убирает за собой (сервер, ufw-правило).
preview_decoy() {
    local zip_path="$1"
    local preview_root
    preview_root=$(mktemp -d)

    local content_dir
    content_dir=$(unpack_to_content_dir "$zip_path" "$preview_root") || { rm -rf "$preview_root"; return 1; }

    local preview_port=8899
    while ss -tln 2>/dev/null | grep -q ":${preview_port} "; do
        ((preview_port++))
    done

    local opened_ufw_rule=false
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${preview_port}/tcp" comment 'decoy preview (temp)' >/dev/null 2>&1
        opened_ufw_rule=true
    fi

    ( cd "$content_dir" && python3 -m http.server "$preview_port" --bind 0.0.0.0 >/dev/null 2>&1 ) &
    local server_pid=$!
    sleep 1

    local server_ip
    server_ip=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "ВАШ_IP")

    echo
    info "Заглушка доступна для просмотра: http://${server_ip}:${preview_port}/"
    warn "Ссылка временная, доступна только сейчас, для просмотра."
    read -rp "Откройте ссылку в браузере, затем нажмите Enter чтобы продолжить..." _

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    if [[ "$opened_ufw_rule" == "true" ]]; then
        ufw delete allow "${preview_port}/tcp" >/dev/null 2>&1 || true
    fi
    rm -rf "$preview_root"
}

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " Nginx (self-steal) + HAProxy + Certbot"
echo "============================================================"
echo

# ------------------------------------------------------------
# 0. Полное обновление системы (Ubuntu/Debian)
# ------------------------------------------------------------
log "Проверяем обновления системы..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
UPGRADABLE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
if (( UPGRADABLE_COUNT == 0 )); then
    info "Система уже полностью обновлена — пропускаем apt upgrade."
else
    info "Найдено пакетов для обновления: ${UPGRADABLE_COUNT}. Обновляем..."
    apt upgrade -y -qq
    apt full-upgrade -y -qq
    apt autoremove -y -qq
    apt autoclean -qq
    log "Система обновлена."
fi

if [[ -f /var/run/reboot-required ]]; then
    warn "Обновление ядра/системы требует перезагрузки. Продолжаем установку, но"
    warn "рекомендуем перезагрузить сервер после завершения всех шагов."
fi
echo

# ------------------------------------------------------------
# 1. Домены
# ------------------------------------------------------------
read -rp "Домен для REALITY TCP: " DOMAIN_TCP
read -rp "Домен для gRPC: " DOMAIN_GRPC
read -rp "Домен для XHTTP: " DOMAIN_XHTTP
read -rp "Домен для Hysteria2 (Enter — пропустить, если не используете): " DOMAIN_HY2
read -rp "Email для Let's Encrypt: " LE_EMAIL

echo
read -rp "Порт REALITY TCP (внутренний, дефолт 56789): " PORT_TCP
PORT_TCP=${PORT_TCP:-56789}
read -rp "Порт gRPC (внутренний, дефолт 56790): " PORT_GRPC
PORT_GRPC=${PORT_GRPC:-56790}
read -rp "Порт XHTTP (внутренний, дефолт 56791): " PORT_XHTTP
PORT_XHTTP=${PORT_XHTTP:-56791}

ALL_DOMAINS="$DOMAIN_TCP $DOMAIN_GRPC $DOMAIN_XHTTP"
[[ -n "$DOMAIN_HY2" ]] && ALL_DOMAINS="$ALL_DOMAINS $DOMAIN_HY2"

echo
log "Проверьте введённые данные:"
echo "  REALITY TCP : $DOMAIN_TCP -> 127.0.0.1:$PORT_TCP"
echo "  gRPC        : $DOMAIN_GRPC -> 127.0.0.1:$PORT_GRPC"
echo "  XHTTP       : $DOMAIN_XHTTP -> 127.0.0.1:$PORT_XHTTP"
[[ -n "$DOMAIN_HY2" ]] && echo "  Hysteria2   : $DOMAIN_HY2 (443/udp)"
echo "  Email       : $LE_EMAIL"
echo
if ! ask_yes_no "Всё верно? Продолжить установку?" "no"; then
    warn "Отменено."
    exit 0
fi

# ------------------------------------------------------------
# 2. Пакеты
# ------------------------------------------------------------
log "Устанавливаем пакеты..."
apt update -qq
apt install -y nginx haproxy certbot python3-certbot-nginx ufw dnsutils curl >/dev/null

# ------------------------------------------------------------
# 3. DNS-проверка
# ------------------------------------------------------------
echo
log "Проверяем DNS..."
SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || true)
if [[ -n "$SERVER_IP" ]]; then
    info "Внешний IP сервера: $SERVER_IP"
    DNS_OK=true
    for DOMAIN in $ALL_DOMAINS; do
        RESOLVED_IP=$(dig +short A "$DOMAIN" | tail -n1)
        if [[ -z "$RESOLVED_IP" ]]; then
            err "  $DOMAIN -> DNS не резолвится"
            DNS_OK=false
        elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
            err "  $DOMAIN -> указывает на $RESOLVED_IP, а не $SERVER_IP"
            DNS_OK=false
        else
            log "  $DOMAIN -> $RESOLVED_IP (OK)"
        fi
    done
    if [[ "$DNS_OK" != "true" ]]; then
        err "Не все домены указывают на этот сервер."
        if ! ask_yes_no "Продолжить всё равно?" "no"; then
            exit 1
        fi
    fi
fi

# ------------------------------------------------------------
# 4. Firewall (базово)
# ------------------------------------------------------------
ufw allow 80/tcp >/dev/null || true
ufw allow 443/tcp >/dev/null || true
[[ -n "$DOMAIN_HY2" ]] && ufw allow 443/udp >/dev/null || true

# ------------------------------------------------------------
# 5. Временный HTTP vhost для certbot
# ------------------------------------------------------------
log "Готовим временный HTTP vhost для certbot..."
mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/decoy-http.conf
rm -f /etc/nginx/sites-enabled/decoy-tls.conf

if confirm_overwrite "/etc/nginx/sites-available/decoy-http.conf" "HTTP-vhost для certbot"; then
cat > /etc/nginx/sites-available/decoy-http.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_DOMAINS};
    root /var/www/html;
    location /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF
fi
ln -sf /etc/nginx/sites-available/decoy-http.conf /etc/nginx/sites-enabled/decoy-http.conf

if ! nginx -t 2>/tmp/nginx_err; then
    err "Ошибка nginx:"
    cat /tmp/nginx_err
    exit 1
fi
systemctl restart nginx

# ------------------------------------------------------------
# 6. Сертификат
# ------------------------------------------------------------
CERT_DIR="/etc/letsencrypt/live/${DOMAIN_TCP}"
CERTBOT_DOMAINS=""
for d in $ALL_DOMAINS; do CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $d"; done

if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    info "Сертификат уже существует, проверяем покрытие доменов..."
    EXISTING_SANS=$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)
    MISSING=false
    for d in $ALL_DOMAINS; do
        echo "$EXISTING_SANS" | grep -q "$d" || MISSING=true
    done
    if [[ "$MISSING" == "true" ]]; then
        log "Расширяем сертификат..."
        certbot certonly --nginx $CERTBOT_DOMAINS --agree-tos -m "$LE_EMAIL" --no-eff-email --expand --non-interactive
    else
        log "Сертификат уже покрывает все домены."
    fi
else
    log "Выпускаем сертификат..."
    certbot certonly --nginx $CERTBOT_DOMAINS --agree-tos -m "$LE_EMAIL" --no-eff-email --non-interactive
fi

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
    err "Сертификат не найден после выпуска."
    exit 1
fi
log "Сертификат готов: ${CERT_DIR}/fullchain.pem"

# ------------------------------------------------------------
# 7. Decoy-страница — своя библиотека заглушек или стандартная
# ------------------------------------------------------------
mkdir -p /var/www/decoy
DECOY_LIBRARY_DIR="/opt/decoy-library"
mkdir -p "$DECOY_LIBRARY_DIR"

install_default_decoy() {
    rm -rf /var/www/decoy
    mkdir -p /var/www/decoy
    cat > /var/www/decoy/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Site</title>
<style>body{font-family:Arial,sans-serif;background:#f4f4f4;display:flex;height:100vh;align-items:center;justify-content:center;margin:0;color:#333}.box{text-align:center}</style>
</head>
<body><div class="box"><h1>It works</h1><p>Nothing to see here.</p></div></body>
</html>
EOF
    log "Установлена стандартная заглушка."
}

echo
log "Скачиваем каталог доступных заглушек..."
MANIFEST_TMP=$(mktemp)
if curl -fsSL "${DECOY_BASE_URL}/manifest.txt" -o "$MANIFEST_TMP" 2>/dev/null && [[ -s "$MANIFEST_TMP" ]]; then
    while IFS= read -r decoy_name; do
        [[ -z "$decoy_name" ]] && continue
        if [[ -f "${DECOY_LIBRARY_DIR}/${decoy_name}" ]]; then
            continue
        fi
        info "Скачиваем заглушку: ${decoy_name}"
        if ! curl -fsSL "${DECOY_BASE_URL}/${decoy_name}" -o "${DECOY_LIBRARY_DIR}/${decoy_name}"; then
            warn "Не удалось скачать ${decoy_name} — пропускаем."
            rm -f "${DECOY_LIBRARY_DIR}/${decoy_name}"
        fi
    done < "$MANIFEST_TMP"
else
    warn "Не удалось скачать каталог заглушек (нет сети или манифест недоступен) — используем то, что уже есть локально."
fi
rm -f "$MANIFEST_TMP"

log "Ищем заглушки в ${DECOY_LIBRARY_DIR}..."
mapfile -t DECOY_ZIPS < <(find "$DECOY_LIBRARY_DIR" -maxdepth 1 -iname "*.zip" -printf '%f\n' 2>/dev/null | sort)

if (( ${#DECOY_ZIPS[@]} == 0 )); then
    info "Заглушек не найдено (ни скачать не удалось, ни локально нет) — используем стандартную."
    install_default_decoy
else
    # unzip/python3 нужны для распаковки и предпросмотра
    command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null
    command -v python3 >/dev/null 2>&1 || apt install -y python3 >/dev/null

    echo
    echo "Доступные заглушки:"
    idx=1
    for z in "${DECOY_ZIPS[@]}"; do
        echo "  ${idx}) ${z}"
        ((idx++))
    done
    echo "  0) Использовать стандартную заглушку"
    echo

    SELECTED_DECOY=""
    while true; do
        read -rp "Выберите номер: " DECOY_CHOICE
        if [[ "$DECOY_CHOICE" == "0" ]]; then
            install_default_decoy
            break
        elif [[ "$DECOY_CHOICE" =~ ^[0-9]+$ ]] && (( DECOY_CHOICE >= 1 && DECOY_CHOICE <= ${#DECOY_ZIPS[@]} )); then
            CANDIDATE="${DECOY_ZIPS[$((DECOY_CHOICE-1))]}"
            if ask_yes_no "Открыть предпросмотр по HTTP перед установкой '${CANDIDATE}'?" "yes"; then
                preview_decoy "${DECOY_LIBRARY_DIR}/${CANDIDATE}"
                if ! ask_yes_no "Устанавливаем именно эту заглушку ('${CANDIDATE}')?" "yes"; then
                    echo
                    info "Возвращаемся к выбору."
                    continue
                fi
            fi
            SELECTED_DECOY="$CANDIDATE"
            break
        else
            err "Некорректный выбор, попробуйте снова."
        fi
    done

    if [[ -n "$SELECTED_DECOY" ]]; then
        log "Устанавливаем заглушку: ${SELECTED_DECOY}"
        INSTALL_TMP=$(mktemp -d)
        CONTENT_DIR=$(unpack_to_content_dir "${DECOY_LIBRARY_DIR}/${SELECTED_DECOY}" "$INSTALL_TMP")
        if [[ -z "$CONTENT_DIR" ]]; then
            err "Не удалось распаковать заглушку — используем стандартную."
            install_default_decoy
        else
            rm -rf /var/www/decoy
            mkdir -p /var/www/decoy
            cp -r "${CONTENT_DIR}/." /var/www/decoy/
            rm -rf "$INSTALL_TMP"
            rm -f "${DECOY_LIBRARY_DIR}/${SELECTED_DECOY}"
            log "Заглушка установлена в /var/www/decoy."
            log "Архив '${SELECTED_DECOY}' удалён из библиотеки (использован)."
        fi
    fi
fi

# ------------------------------------------------------------
# 8. Nginx self-steal (decoy на 127.0.0.1:8081, цель для Reality)
# ------------------------------------------------------------
log "Настраиваем self-steal vhosts на 127.0.0.1:8081..."

if confirm_overwrite "/etc/nginx/sites-available/decoy-tls.conf" "Self-steal TLS vhosts"; then
{
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP"; do
cat <<EOF
server {
    listen 127.0.0.1:8081 ssl http2;
    server_name ${d};
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    root /var/www/decoy;
    index index.html;
    access_log /var/log/nginx/decoy-${d}.log;
}
EOF
done
} > /etc/nginx/sites-available/decoy-tls.conf
fi
ln -sf /etc/nginx/sites-available/decoy-tls.conf /etc/nginx/sites-enabled/decoy-tls.conf

if ! nginx -t 2>/tmp/nginx_err2; then
    err "Ошибка nginx (decoy-tls):"
    cat /tmp/nginx_err2
    exit 1
fi
systemctl reload nginx
log "Nginx self-steal настроен."

# ------------------------------------------------------------
# 9. HAProxy
# ------------------------------------------------------------
log "Настраиваем HAProxy..."

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

if ! haproxy -c -f /etc/haproxy/haproxy.cfg 2>/tmp/haproxy_err; then
    err "Ошибка haproxy.cfg:"
    cat /tmp/haproxy_err
    exit 1
fi
systemctl enable haproxy >/dev/null
systemctl restart haproxy
log "HAProxy настроен и перезапущен."

# ------------------------------------------------------------
# 10. Автопродление
# ------------------------------------------------------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
    docker restart remnanode
fi
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
log "Автопродление через certbot.timer настроено."

# Дублируем через cron — подстраховка на случай, если systemd-таймер
# по какой-то причине не сработает.
if ! command -v crontab >/dev/null 2>&1; then
    apt install -y cron >/dev/null 2>&1 || true
fi

CERT_CRON_JOB="0 3 * * * /usr/bin/certbot renew --quiet"
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
if echo "$EXISTING_CRON" | grep -qF "certbot renew"; then
    info "Cron-задача на обновление сертификатов уже есть."
else
    ( echo "$EXISTING_CRON"; echo "$CERT_CRON_JOB" ) | grep -v '^$' | crontab -
    log "Добавлена cron-задача: обновление сертификатов ежедневно в 03:00."
fi

if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "certbot renew"; then
    log "Cron-задача подтверждена в crontab root."
else
    err "Не удалось подтвердить cron-задачу автопродления! Проверьте вручную: crontab -l"
fi

# ------------------------------------------------------------
# 11. Итог
# ------------------------------------------------------------
echo
echo "============================================================"
log "Готово!"
echo "  Сертификат: ${CERT_DIR}/fullchain.pem"
echo "  Домены: ${ALL_DOMAINS}"
if [[ -n "$DOMAIN_HY2" ]]; then
echo
echo "  Для Hysteria2 добавьте volumes в docker-compose.yml ноды:"
echo "    - ${CERT_DIR}/fullchain.pem:/etc/hysteria/fullchain.pem:ro"
echo "    - ${CERT_DIR}/privkey.pem:/etc/hysteria/privkey.pem:ro"
echo "  (или используйте пункт 'Только Remnanode' — сделает это автоматически)"
fi
echo "============================================================"
