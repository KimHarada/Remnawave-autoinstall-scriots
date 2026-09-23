#!/usr/bin/env bash
# Nginx self-steal decoy + HAProxy (SNI routing) + Certbot.
# Если NONINTERACTIVE=1 — домены и флаг Hysteria2 берутся из окружения
# (вызов из full-setup.sh), вопросов не задаём.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  RAW="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main"
  t=$(mktemp); curl -fsSL "${RAW}/scripts/lib.sh" -o "$t"; source "$t"
}
require_root

NONINTERACTIVE="${NONINTERACTIVE:-0}"

if [ "$NONINTERACTIVE" != "1" ]; then
  DOMAIN_TCP=$(ask_value "Домен для VLESS REALITY TCP" "")
  DOMAIN_GRPC=$(ask_value "Домен для VLESS gRPC" "")
  DOMAIN_XHTTP=$(ask_value "Домен для VLESS XHTTP" "")
  DOMAIN_HY2=$(ask_value "Домен для Hysteria2" "")
  if ask_yes_no "Использовать Hysteria2?" "1"; then USE_HY2=1; else USE_HY2=0; fi
fi

DECOY_ROOT="/var/www/decoy"

step "Установка Nginx / HAProxy / Certbot"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx haproxy certbot 2>&1 | tail -5 || true

confirm_overwrite() {
  local f="$1"
  if [ -f "$f" ]; then
    if [ "$NONINTERACTIVE" = "1" ]; then return 0; fi
    ask_yes_no "Файл $f уже существует, перезаписать?" "1"
    return $?
  fi
  return 0
}

# ---- decoy page -----------------------------------------------------------
step "Страница-заглушка"
mkdir -p "$DECOY_ROOT"
if [ ! -f "${DECOY_ROOT}/index.html" ] || confirm_overwrite "${DECOY_ROOT}/index.html"; then
  MANIFEST_URL="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/decoys/manifest.txt"
  PICK=""
  if curl -fsSL "$MANIFEST_URL" -o /tmp/decoy_manifest.txt 2>/dev/null && [ -s /tmp/decoy_manifest.txt ]; then
    PICK=$(head -1 /tmp/decoy_manifest.txt)
  fi
  if [ -n "$PICK" ]; then
    ZIP_URL="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/decoys/${PICK}"
    if curl -fsSL "$ZIP_URL" -o /tmp/decoy.zip 2>/dev/null; then
      rm -rf /tmp/decoy_unzip && mkdir -p /tmp/decoy_unzip
      unzip -oq /tmp/decoy.zip -d /tmp/decoy_unzip
      SRC_DIR="/tmp/decoy_unzip"
      # если внутри один каталог — используем его
      if [ "$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" = "1" ] && \
         [ "$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 | wc -l)" = "1" ]; then
        SRC_DIR="$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d)"
      fi
      cp -rf "$SRC_DIR"/* "$DECOY_ROOT"/
      ok "Заглушка установлена: ${PICK}"
    fi
  fi
  if [ ! -f "${DECOY_ROOT}/index.html" ]; then
    cat > "${DECOY_ROOT}/index.html" <<'HTML'
<!DOCTYPE html><html><head><title>It works</title></head>
<body><h1>It works!</h1></body></html>
HTML
    warn "Не удалось скачать заглушку из репозитория, поставлена базовая."
  fi
fi

# ---- certbot ---------------------------------------------------------------
step "Выпуск SSL сертификатов"
ufw allow 80/tcp &>/dev/null || true
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
  [ -z "$d" ] && continue
  if [ ! -d "/etc/letsencrypt/live/${d}" ]; then
    certbot certonly --standalone --non-interactive --agree-tos -m admin@"${d}" -d "$d" 2>&1 | tail -5 || warn "certbot: не удалось выпустить для $d"
  else
    ok "Сертификат для $d уже есть."
  fi
done

# ---- nginx (self-steal, локальный decoy на 8081) --------------------------
step "Настройка Nginx (self-steal)"
cat > /etc/nginx/sites-available/decoy <<EOF
server {
    listen 127.0.0.1:8081;
    server_name _;
    root ${DECOY_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/decoy /etc/nginx/sites-enabled/decoy
rm -f /etc/nginx/sites-enabled/default
sed -i 's/worker_connections .*/worker_connections 16384;/' /etc/nginx/nginx.conf || true
grep -q "large_client_header_buffers" /etc/nginx/nginx.conf || \
  sed -i '/http {/a \    large_client_header_buffers 8 64k;' /etc/nginx/nginx.conf
nginx -t 2>&1 || { err "Ошибка конфигурации nginx"; exit 1; }
systemctl restart nginx
ok "Nginx настроен."

# ---- haproxy (SNI passthrough) --------------------------------------------
step "Настройка HAProxy"
HY2_LINE=""
[ -n "$DOMAIN_HY2" ] && [ "$USE_HY2" = "1" ] && HY2_LINE="# Hysteria2 обслуживается напрямую Xray на 443/udp"

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 8192

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend fe_443
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend be_grpc if { req.ssl_sni -i ${DOMAIN_GRPC} }
    use_backend be_xhttp if { req.ssl_sni -i ${DOMAIN_XHTTP} }
    default_backend be_tcp

backend be_tcp
    server tcp1 127.0.0.1:56789

backend be_grpc
    server grpc1 127.0.0.1:56790

backend be_xhttp
    server xhttp1 127.0.0.1:56791
EOF

if haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null; then
  systemctl restart haproxy
  ok "HAProxy настроен и перезапущен."
else
  err "Ошибка конфигурации HAProxy, старая конфигурация сохранена."
fi

# ---- certbot автопродление --------------------------------------------------
systemctl enable --now certbot.timer &>/dev/null || true
( crontab -l 2>/dev/null | grep -v 'certbot renew' ; echo "0 3 * * * /usr/bin/certbot renew --quiet" ) | crontab -

ok "haproxy-setup.sh завершён."
