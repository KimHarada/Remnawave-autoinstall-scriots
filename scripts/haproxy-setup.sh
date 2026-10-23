#!/usr/bin/env bash
# Nginx self-steal decoy + HAProxy (SNI routing) + Certbot.
# Если NONINTERACTIVE=1 — домены и флаг Hysteria2 берутся из окружения
# (вызов из full-setup.sh), вопросов не задаём.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
require_root
require_apt_os

NONINTERACTIVE="${NONINTERACTIVE:-${ASSUME_YES:-0}}"

if [ "$NONINTERACTIVE" != "1" ]; then
  ensure_tty
  DOMAIN_TCP=$(ask_valid "Домен для VLESS REALITY TCP (обязателен)" "${DOMAIN_TCP:-}" is_valid_domain) || exit 1
  DOMAIN_GRPC=$(ask_valid "Домен для VLESS gRPC (Enter — не использовать)" "${DOMAIN_GRPC:-}" is_valid_domain 1) || exit 1
  DOMAIN_XHTTP=$(ask_valid "Домен для VLESS XHTTP (Enter — не использовать)" "${DOMAIN_XHTTP:-}" is_valid_domain 1) || exit 1
  DOMAIN_HY2=$(ask_valid "Домен для Hysteria2 (Enter — не использовать)" "${DOMAIN_HY2:-}" is_valid_domain 1) || exit 1
  USE_HY2=0
  if [ -n "$DOMAIN_HY2" ] && ask_yes_no "Использовать Hysteria2?" "1"; then USE_HY2=1; fi
  if ask_yes_no "Ставить страницу-заглушку (decoy) для self-steal?" "1"; then INSTALL_DECOY=1; else INSTALL_DECOY=0; fi
else
  INSTALL_DECOY="${INSTALL_DECOY:-1}"
  DOMAIN_TCP="${DOMAIN_TCP:-}"; DOMAIN_GRPC="${DOMAIN_GRPC:-}"
  DOMAIN_XHTTP="${DOMAIN_XHTTP:-}"; DOMAIN_HY2="${DOMAIN_HY2:-}"
  USE_HY2="${USE_HY2:-0}"
fi
DOMAIN_TCP="${DOMAIN_TCP,,}"; DOMAIN_GRPC="${DOMAIN_GRPC,,}"; DOMAIN_XHTTP="${DOMAIN_XHTTP,,}"; DOMAIN_HY2="${DOMAIN_HY2,,}"

if [ -z "$DOMAIN_TCP" ]; then
  err "DOMAIN_TCP не задан — это домен по умолчанию для HAProxy (REALITY TCP)."
  exit 1
fi

DECOY_ROOT="/var/www/decoy"
ALL_DOMAINS=("$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2")

step "Установка Nginx / HAProxy / Certbot"
apt_update || warn "apt update не удался — ставлю из имеющихся списков."
apt_install nginx haproxy certbot unzip dnsutils curl openssl
if ! command -v nginx &>/dev/null || ! command -v certbot &>/dev/null || ! command -v haproxy &>/dev/null; then
  err "nginx/haproxy/certbot не установились — дальше этот шаг работать не будет. Проверьте: apt-get update; apt-get install nginx haproxy certbot unzip dnsutils"
  exit 1
fi

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
write_basic_decoy() {
  cat > "${DECOY_ROOT}/index.html" <<'HTML'
<!DOCTYPE html><html><head><title>It works</title></head>
<body><h1>It works!</h1></body></html>
HTML
}
if [ "${INSTALL_DECOY:-1}" != "1" ]; then
  warn "Установка decoy-страницы отключена по выбору — self-steal будет отдавать только базовую пустую страницу."
  [ -f "${DECOY_ROOT}/index.html" ] || write_basic_decoy
elif [ -f "$DECOY_MARKER" ] && [ -f "${DECOY_ROOT}/index.html" ] && [ "$NONINTERACTIVE" = "1" ]; then
  ok "Заглушка уже установлена ($(cat "$DECOY_MARKER")) — повторная загрузка не нужна, пропускаю."
elif [ ! -f "${DECOY_ROOT}/index.html" ] || confirm_overwrite "${DECOY_ROOT}/index.html"; then
  WORK="$(mktemp -d)"
  PICK=""
  DECOY_INSTALLED=0
  CANDIDATES=()
  if curl -fsSL --retry 3 "${RAW}/decoys/manifest.txt" -o "$WORK/manifest.txt" 2>/dev/null && [ -s "$WORK/manifest.txt" ]; then
    # tr убирает \r (Windows-перевод строки) и пробелы — иначе имя файла
    # получается с мусором на конце и curl за zip-архивом падает с 404.
    # shuf: на каждом сервере заглушка своя случайная, а не одна и та же везде.
    mapfile -t CANDIDATES < <(tr -d '\r' < "$WORK/manifest.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '\.zip$' | shuf)
  fi
  # DECOY_NAME=имя.zip — принудительно выбрать конкретную заглушку
  [ -n "${DECOY_NAME:-}" ] && CANDIDATES=("$DECOY_NAME")
  # Берём первую в случайном порядке, которая реально скачалась и распаковалась.
  for PICK in "${CANDIDATES[@]}"; do
    ZIP_URL="${RAW}/decoys/${PICK}"
    rm -rf "$WORK/unzip" "$WORK/decoy.zip"
    if curl -fsSL --retry 3 "$ZIP_URL" -o "$WORK/decoy.zip" 2>/dev/null && [ -s "$WORK/decoy.zip" ]; then
      mkdir -p "$WORK/unzip"
      if unzip -oq "$WORK/decoy.zip" -d "$WORK/unzip" 2>"$WORK/unzip_err.log"; then
        SRC_DIR="$WORK/unzip"
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
        warn "Не удалось распаковать ${PICK}: $(head -1 "$WORK/unzip_err.log" 2>/dev/null)"
      fi
    else
      warn "Не удалось скачать ${ZIP_URL} — пробую другую заглушку."
    fi
    [ "$DECOY_INSTALLED" = "1" ] && break
  done
  [ "${#CANDIDATES[@]}" -eq 0 ] && warn "manifest.txt пуст или недоступен — decoys/ в репозитории может быть пустой."
  rm -rf "$WORK"
  if [ "$DECOY_INSTALLED" != "1" ] && [ ! -f "${DECOY_ROOT}/index.html" ]; then
    write_basic_decoy
    warn "Не удалось скачать заглушку из репозитория, поставлена базовая."
  fi
fi

# ---- DNS preflight ---------------------------------------------------------
# Certbot проваливается с невнятной ошибкой, если домен ещё не смотрит на
# этот сервер. Проверяем заранее — иначе попытка уходит в лимит Let's Encrypt
# (5 неудач/час на домен) без пользы.
step "Проверка DNS перед выпуском сертификатов"
PUB_IP="$(get_public_ip)"
if [ -z "$PUB_IP" ]; then
  warn "Не удалось определить публичный IP сервера — DNS-проверку пропускаю."
fi
declare -A DNS_OK
for d in "${ALL_DOMAINS[@]}"; do
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
# LE_EMAIL — необязательный адрес для уведомлений об истечении. Без него
# регистрируемся без email (раньше подставлялся несуществующий admin@домен).
if [ -n "${LE_EMAIL:-}" ]; then
  CERTBOT_ACCOUNT=(-m "$LE_EMAIL")
else
  CERTBOT_ACCOUNT=(--register-unsafely-without-email)
fi
CERT_LOG="$(mktemp)"
declare -A SEEN
for d in "${ALL_DOMAINS[@]}"; do
  [ -z "$d" ] && continue
  [ -n "${SEEN[$d]:-}" ] && continue
  SEEN[$d]=1
  if cert_is_valid "$d"; then
    ok "Сертификат для $d уже есть и валиден — пропускаю."
  elif [ "${DNS_OK[$d]:-1}" = "0" ]; then
    warn "Пропускаю certbot для $d — DNS не указывает на этот сервер (см. выше)."
  else
    if certbot certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
         "${CERTBOT_ACCOUNT[@]}" -d "$d" >"$CERT_LOG" 2>&1; then
      ok "Сертификат для $d выпущен."
    else
      warn "certbot: не удалось выпустить для $d:"
      tail -n 6 "$CERT_LOG" >&2
    fi
  fi
done
rm -f "$CERT_LOG"
systemctl start nginx 2>&1 || true

# Хук продления. Сертификаты Hysteria2/Xray монтируются в контейнер как
# symlink'и на конкретный файл в archive/ — после продления контейнер видит
# старый файл, пока его не пересоздать. Без этого через ~60 дней TLS протухает.
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/dorik-reload.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
if [ -f /opt/remnanode/docker-compose.yml ] && grep -q '/etc/letsencrypt/live' /opt/remnanode/docker-compose.yml \
   && command -v docker >/dev/null 2>&1; then
  (cd /opt/remnanode && docker compose up -d --force-recreate) >/dev/null 2>&1 || true
fi
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/dorik-reload.sh

# ---- nginx (self-steal, локальный decoy на 8081) --------------------------
# ВАЖНО: Reality "ворует" сертификат у target-сервера через реальный TLS-
# хендшейк. Если target отдаёт голый HTTP без TLS, хендшейк не проходит и
# весь self-steal fallback ломается (клиент получает TLS-ошибку/пустой ответ).
# Поэтому decoy ОБЯЗАН слушать SSL с реальным сертификатом одного из доменов.
step "Настройка Nginx (self-steal)"
STEAL_CERT_DOMAIN=""
for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP"; do
  [ -z "$d" ] && continue
  if cert_is_valid "$d"; then STEAL_CERT_DOMAIN="$d"; break; fi
done

if [ -z "$STEAL_CERT_DOMAIN" ]; then
  err "Нет ни одного выпущенного сертификата — decoy НЕ сможет работать как TLS self-steal target (Reality не получит сертификат для подмены). Проверьте certbot выше."
  cat > /etc/nginx/sites-available/decoy <<EOF
server {
    listen 127.0.0.1:8081;
    server_name _;
    server_tokens off;
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
    server_tokens off;
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
if ! nginx -t 2>&1; then
  err "Ошибка конфигурации nginx"
  exit 1
fi
systemctl enable nginx &>/dev/null || true
systemctl restart nginx
ok "Nginx настроен."

# ---- haproxy (SNI passthrough) --------------------------------------------
# Конфиг пишем во временный файл, проверяем, и только потом ставим на место
# (со старой копией рядом) — раньше он перезаписывался ДО проверки.
# ACL и backend'ы создаются только для заданных доменов: пустой домен давал
# невалидное `req.ssl_sni -i ` и HAProxy не стартовал.
step "Настройка HAProxy"
HAP_NEW="$(mktemp)"
{
cat <<'EOF'
global
    log /dev/log local0
    maxconn 16384

defaults
    log global
    mode tcp
    option clitcpka
    option srvtcpka
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend fe_443
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
EOF
[ -n "$DOMAIN_GRPC" ]  && [ "$DOMAIN_GRPC"  != "$DOMAIN_TCP" ] && echo "    use_backend be_grpc if { req.ssl_sni -i ${DOMAIN_GRPC} }"
[ -n "$DOMAIN_XHTTP" ] && [ "$DOMAIN_XHTTP" != "$DOMAIN_TCP" ] && echo "    use_backend be_xhttp if { req.ssl_sni -i ${DOMAIN_XHTTP} }"
cat <<'EOF'
    default_backend be_tcp

backend be_tcp
    server tcp1 127.0.0.1:56789
EOF
if [ -n "$DOMAIN_GRPC" ] && [ "$DOMAIN_GRPC" != "$DOMAIN_TCP" ]; then
  printf '\nbackend be_grpc\n    server grpc1 127.0.0.1:56790\n'
fi
if [ -n "$DOMAIN_XHTTP" ] && [ "$DOMAIN_XHTTP" != "$DOMAIN_TCP" ]; then
  printf '\nbackend be_xhttp\n    server xhttp1 127.0.0.1:56791\n'
fi
if [ -n "$DOMAIN_HY2" ] && [ "$USE_HY2" = "1" ]; then
  printf '\n# Hysteria2 обслуживается напрямую Xray на 443/udp, HAProxy его не касается\n'
fi
} > "$HAP_NEW"

if haproxy -c -f "$HAP_NEW" >/tmp/dorik_haproxy_check 2>&1; then
  [ -f /etc/haproxy/haproxy.cfg ] && cp -f /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%s)"
  install -m 644 "$HAP_NEW" /etc/haproxy/haproxy.cfg
  systemctl enable haproxy &>/dev/null || true
  systemctl restart haproxy
  ok "HAProxy настроен и перезапущен."
else
  err "Новый конфиг HAProxy не прошёл проверку, старый оставлен без изменений:"
  head -n 10 /tmp/dorik_haproxy_check >&2
fi
rm -f "$HAP_NEW"

# ---- certbot автопродление --------------------------------------------------
# Пакет certbot уже приносит certbot.timer; отдельная запись в crontab root
# (как делали раньше) только дублировала его — убираем.
systemctl enable --now certbot.timer &>/dev/null || true
if command -v crontab &>/dev/null && crontab -l 2>/dev/null | grep -q 'certbot renew'; then
  crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - || true
fi
if ! systemctl is-enabled --quiet certbot.timer 2>/dev/null && [ ! -f /etc/cron.d/certbot ]; then
  echo "0 3 * * * root /usr/bin/certbot renew --quiet" > /etc/cron.d/dorik-certbot
  chmod 644 /etc/cron.d/dorik-certbot
fi

# ---- итоговая самопроверка -------------------------------------------------
# Явно печатаем pass/fail, чтобы при повторном запуске сразу было видно,
# что реально не работает.
step "Итоговая проверка"
CHECK_FAIL=0

if systemctl is-active --quiet nginx; then ok "nginx: активен"; else err "nginx: НЕ активен"; CHECK_FAIL=1; fi
if systemctl is-active --quiet haproxy; then ok "haproxy: активен"; else err "haproxy: НЕ активен"; CHECK_FAIL=1; fi

DECOY_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://127.0.0.1:8081" 2>/dev/null || echo "000")
if [ -z "$STEAL_CERT_DOMAIN" ]; then
  DECOY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8081" 2>/dev/null || echo "000")
fi
if [ "$DECOY_CODE" = "200" ]; then
  ok "decoy (self-steal, 127.0.0.1:8081): отвечает 200"
else
  err "decoy (self-steal, 127.0.0.1:8081): код ${DECOY_CODE} (ожидался 200) — Reality fallback не будет работать корректно"
  CHECK_FAIL=1
fi

for d in "${ALL_DOMAINS[@]}"; do
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
  exit 1
else
  ok "haproxy-setup.sh завершён, все проверки пройдены."
fi
