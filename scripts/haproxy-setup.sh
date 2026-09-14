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

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

echo "============================================================"
echo " Nginx (self-steal) + HAProxy + Certbot"
echo "============================================================"
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
# 7. Decoy-страница
# ------------------------------------------------------------
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
