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
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx haproxy certbot unzip dnsutils 2>&1 | tail -5 || true

confirm_overwrite() {
  local f="${1:-}"
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
DECOY_MARKER="${DECOY_ROOT}/.dorik-installed"
if [ -f "$DECOY_MARKER" ] && [ -f "${DECOY_ROOT}/index.html" ] && [ "$NONINTERACTIVE" = "1" ]; then
  ok "Заглушка уже установлена ($(cat "$DECOY_MARKER")) — повторная загрузка не нужна, пропускаю."
elif [ ! -f "${DECOY_ROOT}/index.html" ] || confirm_overwrite "${DECOY_ROOT}/index.html"; then
  MANIFEST_URL="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/decoys/manifest.txt"
  PICK=""
  DECOY_INSTALLED=0
  if curl -fsSL "$MANIFEST_URL" -o /tmp/decoy_manifest.txt 2>/dev/null && [ -s /tmp/decoy_manifest.txt ]; then
    # tr убирает \r (Windows-перевод строки) и пробелы — иначе имя файла
    # получается с мусором на конце и curl за zip-архивом падает с 404.
    PICK=$(head -1 /tmp/decoy_manifest.txt | tr -d '\r' | xargs)
  fi
  if ! command -v unzip &>/dev/null; then
    warn "unzip не установлен — ставлю."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip 2>&1 | tail -3 || true
  fi
  if [ -n "$PICK" ]; then
    ZIP_URL="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/decoys/${PICK}"
    if curl -fsSL "$ZIP_URL" -o /tmp/decoy.zip 2>/dev/null && [ -s /tmp/decoy.zip ]; then
      rm -rf /tmp/decoy_unzip && mkdir -p /tmp/decoy_unzip
      if unzip -oq /tmp/decoy.zip -d /tmp/decoy_unzip 2>/tmp/decoy_unzip_err.log; then
        SRC_DIR="/tmp/decoy_unzip"
        # если внутри один каталог — используем его
        if [ "$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" = "1" ] && \
           [ "$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 | wc -l)" = "1" ]; then
          SRC_DIR="$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d)"
        fi
        if [ -n "$(find "$SRC_DIR" -mindepth 1 -maxdepth 1)" ]; then
          cp -rf "$SRC_DIR"/. "$DECOY_ROOT"/
          echo "$PICK" > "$DECOY_MARKER"
          DECOY_INSTALLED=1
          ok "Заглушка установлена: ${PICK}"
        else
          warn "Архив ${PICK} распаковался пустым."
        fi
      else
        warn "Не удалось распаковать ${PICK}: $(cat /tmp/decoy_unzip_err.log 2>/dev/null | head -1)"
      fi
    else
      warn "Не удалось скачать ${ZIP_URL} (проверьте, что файл ещё есть в decoys/ репозитория)."
    fi
  else
    warn "manifest.txt пуст или недоступен — decoys/ в репозитории может быть пустой."
  fi
  if [ "$DECOY_INSTALLED" != "1" ] && [ ! -f "${DECOY_ROOT}/index.html" ]; then
    cat > "${DECOY_ROOT}/index.html" <<'HTML'
<!DOCTYPE html><html><head><title>It works</title></head>
<body><h1>It works!</h1></body></html>
HTML
    warn "Не удалось скачать заглушку из репозитория, поставлена базовая."
  fi
fi

# ---- DNS preflight ---------------------------------------------------------
# Certbot проваливается с невнятной ошибкой, если домен ещё не смотрит на
# этот сервер. Проверяем заранее и явно говорим, если DNS не тот — иначе
# уходит попытка в лимит Let's Encrypt (5 неудач/час на домен) без пользы.
step "Проверка DNS перед выпуском сертификатов"
PUB_IP="$(get_public_ip)"
if [ -z "$PUB_IP" ]; then
  warn "Не удалось определить публичный IP сервера — DNS-проверку пропускаю."
fi
declare -A DNS_OK
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
  [ -z "$d" ] && continue
  if [ -n "$PUB_IP" ] && ! dns_points_here "$d" "$PUB_IP"; then
    RESOLVED=$(dig +short A "$d" 2>/dev/null | tail -1)
    warn "${d}: DNS указывает на '${RESOLVED:-<нет ответа>}', а IP сервера — ${PUB_IP}. Сертификат для этого домена НЕ будет запрошен — сначала поправьте A-запись."
    DNS_OK["$d"]=0
  else
    DNS_OK["$d"]=1
  fi
done

# ---- certbot ---------------------------------------------------------------
step "Выпуск SSL сертификатов"
ufw allow 80/tcp &>/dev/null || true
# certbot --standalone сам слушает 80-й порт, поэтому nginx на это время
# нужно остановить, иначе "port 80 already in use".
systemctl stop nginx 2>&1 || true
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
  [ -z "$d" ] && continue
  if cert_is_valid "$d"; then
    ok "Сертификат для $d уже есть и валиден — пропускаю."
  elif [ "${DNS_OK[$d]:-1}" = "0" ]; then
    warn "Пропускаю certbot для $d — DNS не указывает на этот сервер (см. выше)."
  else
    certbot certonly --standalone --non-interactive --agree-tos -m admin@"${d}" -d "$d" 2>&1 | tail -5 || warn "certbot: не удалось выпустить для $d"
  fi
done
systemctl start nginx 2>&1 || true

# ---- nginx (self-steal, локальный decoy на 8081) --------------------------
# ВАЖНО: Reality "ворует" сертификат у target-сервера через реальный TLS-
# хендшейк. Если target отдаёт голый HTTP без TLS, хендшейк не проходит и
# весь self-steal fallback ломается (клиент получает TLS-ошибку/пустой ответ).
# Поэтому decoy ОБЯЗАН слушать SSL с реальным сертификатом одного из доменов.
step "Настройка Nginx (self-steal)"
STEAL_CERT_DOMAIN=""
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP"; do
  [ -z "$d" ] && continue
  if [ -d "/etc/letsencrypt/live/${d}" ]; then STEAL_CERT_DOMAIN="$d"; break; fi
done

if [ -z "$STEAL_CERT_DOMAIN" ]; then
  err "Нет ни одного выпущенного сертификата — decoy НЕ сможет работать как TLS self-steal target (Reality не получит сертификат для подмены). Проверьте certbot выше."
  cat > /etc/nginx/sites-available/decoy <<EOF
server {
    listen 127.0.0.1:8081;
    server_name _;
    root ${DECOY_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
else
  ok "Decoy будет отдавать TLS с сертификатом ${STEAL_CERT_DOMAIN}."
  cat > /etc/nginx/sites-available/decoy <<EOF
server {
    listen 127.0.0.1:8081 ssl;
    server_name ${STEAL_CERT_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${STEAL_CERT_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${STEAL_CERT_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${DECOY_ROOT};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
fi
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

# ---- итоговая самопроверка -------------------------------------------------
# Именно эти три вещи ломались раньше молча — теперь явно печатаем pass/fail,
# чтобы при повторном запуске сразу было видно, что реально не работает.
step "Итоговая проверка"
CHECK_FAIL=0

if systemctl is-active --quiet nginx; then ok "nginx: активен"; else err "nginx: НЕ активен"; CHECK_FAIL=1; fi
if systemctl is-active --quiet haproxy; then ok "haproxy: активен"; else err "haproxy: НЕ активен"; CHECK_FAIL=1; fi

DECOY_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://127.0.0.1:8081" 2>/dev/null || echo "000")
if [ "$DECOY_CODE" = "200" ]; then
  ok "decoy (TLS self-steal, 127.0.0.1:8081): отвечает 200"
else
  err "decoy (TLS self-steal, 127.0.0.1:8081): код ${DECOY_CODE} (ожидался 200) — Reality fallback не будет работать корректно"
  CHECK_FAIL=1
fi

for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2"; do
  [ -z "$d" ] && continue
  if cert_is_valid "$d"; then
    ok "сертификат ${d}: валиден"
  else
    err "сертификат ${d}: ОТСУТСТВУЕТ или просрочен"
    CHECK_FAIL=1
  fi
done

if [ "$CHECK_FAIL" = "1" ]; then
  warn "haproxy-setup.sh завершён С ПРЕДУПРЕЖДЕНИЯМИ — см. пункты выше с [✗]."
else
  ok "haproxy-setup.sh завершён, все проверки пройдены."
fi
