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
  ws_ask node || exit 1
  info "Протокол без домена не настраивается. Нужен хотя бы один домен."
  DOMAIN_TCP=$(ask_valid "Домен для VLESS REALITY TCP (Enter — не использовать)" "${DOMAIN_TCP:-}" is_valid_domain 1) || exit 1
  DOMAIN_GRPC=$(ask_valid "Домен для VLESS gRPC (Enter — не использовать)" "${DOMAIN_GRPC:-}" is_valid_domain 1) || exit 1
  DOMAIN_XHTTP=$(ask_valid "Домен для VLESS XHTTP (Enter — не использовать)" "${DOMAIN_XHTTP:-}" is_valid_domain 1) || exit 1
  DOMAIN_HY2=$(ask_valid "Домен для Hysteria2 (Enter — не использовать)" "${DOMAIN_HY2:-}" is_valid_domain 1) || exit 1
  USE_HY2=0
  if [ -n "$DOMAIN_HY2" ] && ask_yes_no "Использовать Hysteria2?" "1"; then USE_HY2=1; fi
  USE_TG=0
  if ask_yes_no "Нужен отдельный хост только для Telegram и ЮKassa?" "2"; then
    USE_TG=1
    DOMAIN_TG=$(ask_valid "Домен для Telegram-хоста" "${DOMAIN_TG:-}" is_valid_domain) || exit 1
  fi
  USE_WEB=0
  if ask_yes_no "Нужен WEB-прокси Telegram (отдельный домен, реклама своего канала)?" "2"; then
    USE_WEB=1
    DOMAIN_WEB=$(ask_valid "Домен для WEB-прокси" "${DOMAIN_WEB:-}" is_valid_domain) || exit 1
  fi
  if ask_yes_no "Ставить красивые страницы-заглушки (своя, разная для каждого протокола)?" "1"; then INSTALL_DECOY=1; else INSTALL_DECOY=0; fi
else
  INSTALL_DECOY="${INSTALL_DECOY:-1}"
  DOMAIN_TCP="${DOMAIN_TCP:-}"; DOMAIN_GRPC="${DOMAIN_GRPC:-}"
  DOMAIN_XHTTP="${DOMAIN_XHTTP:-}"; DOMAIN_HY2="${DOMAIN_HY2:-}"
  USE_HY2="${USE_HY2:-0}"
  USE_TG="${USE_TG:-0}"; DOMAIN_TG="${DOMAIN_TG:-}"
  USE_WEB="${USE_WEB:-0}"; DOMAIN_WEB="${DOMAIN_WEB:-}"
fi
[ "$USE_TG" = "1" ] || DOMAIN_TG=""
[ "${USE_WEB:-0}" = "1" ] || DOMAIN_WEB=""
USE_WEB="${USE_WEB:-0}"
DOMAIN_TCP="${DOMAIN_TCP,,}"; DOMAIN_GRPC="${DOMAIN_GRPC,,}"; DOMAIN_XHTTP="${DOMAIN_XHTTP,,}"; DOMAIN_HY2="${DOMAIN_HY2,,}"; DOMAIN_TG="${DOMAIN_TG,,}"; DOMAIN_WEB="${DOMAIN_WEB,,}"
export USE_WEB DOMAIN_WEB

[ "$USE_HY2" = "1" ] || DOMAIN_HY2=""
if [ -z "${DOMAIN_TCP}${DOMAIN_GRPC}${DOMAIN_XHTTP}${DOMAIN_HY2}${DOMAIN_TG}${DOMAIN_WEB}" ]; then
  err "Не задан ни один домен — нечего настраивать (DOMAIN_TCP, DOMAIN_GRPC, DOMAIN_XHTTP, DOMAIN_HY2, DOMAIN_TG, DOMAIN_WEB)."
  exit 1
fi

# Основной протокол: к нему HAProxy отправляет всё, что пришло с неизвестным SNI или без него
# (заход по IP, сканер). Это первый из выбранных протоколов Xray, который слушает TCP 443.
declare -A XPORT=( [tcp]=56789 [grpc]=56790 [xhttp]=56791 [tg]=56792 )
declare -A XDOM=( [tcp]="$DOMAIN_TCP" [grpc]="$DOMAIN_GRPC" [xhttp]="$DOMAIN_XHTTP" [tg]="$DOMAIN_TG" )
PRIMARY=""; PRIMARY_DOMAIN=""
for p in tcp grpc xhttp tg; do
  [ -n "${XDOM[$p]}" ] && { PRIMARY="$p"; PRIMARY_DOMAIN="${XDOM[$p]}"; break; }
done
# Только Hysteria2 и/или WEB-прокси: на TCP 443 отвечает их собственная заглушка.
[ -z "$PRIMARY_DOMAIN" ] && PRIMARY_DOMAIN="${DOMAIN_HY2:-$DOMAIN_WEB}"

_dorik_source decoys.sh
WS="$(ws_current)"
ALL_DOMAINS=("$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2" "$DOMAIN_TG" "$DOMAIN_WEB")

step "Установка $(ws_label "$WS") / HAProxy / Certbot"
apt_update || warn "apt update не удался — ставлю из имеющихся списков."
apt_install haproxy certbot unzip dnsutils curl openssl
if [ "$WS" = "caddy" ]; then caddy_install; else apt_install nginx; fi
if ! command -v "$WS" &>/dev/null || ! command -v certbot &>/dev/null || ! command -v haproxy &>/dev/null; then
  err "${WS}/haproxy/certbot не установились — дальше этот шаг работать не будет. Проверьте: apt-get update; apt-get install ${WS} haproxy certbot unzip dnsutils"
  exit 1
fi
ws_save "$WS"

# ---- заглушки: по одной на КАЖДЫЙ протокол, все разные ---------------------------------
# (домен, сертификат, nginx-сайт, порт и страница — свои; подробности в decoys.sh)
step "Страницы-заглушки (по одной на протокол)"
mkdir -p "$DECOY_WEB"
decoys_install
decoys_write_conf

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
    RESOLVED="$(resolve_a "$d")"
    warn "${d}: DNS указывает на '${RESOLVED:-<нет ответа>}', а IP сервера — ${PUB_IP}. Сертификат для этого домена НЕ будет запрошен — сначала поправьте A-запись."
    DNS_OK["$d"]=0
  else
    DNS_OK["$d"]=1
  fi
done

# ---- certbot ---------------------------------------------------------------
step "Выпуск SSL сертификатов"
ufw allow 80/tcp &>/dev/null || true
# certbot --standalone сам слушает 80-й порт, поэтому веб-сервер на это время
# нужно остановить, иначе "port 80 already in use". Останавливаем оба: при смене
# nginx ↔ Caddy прежний сервер ещё может быть запущен.
systemctl stop nginx &>/dev/null || true
systemctl stop caddy &>/dev/null || true
# LE_EMAIL — необязательный адрес для уведомлений об истечении. Без него
# регистрируемся без email (раньше подставлялся несуществующий admin@домен).
if [ -n "${LE_EMAIL:-}" ]; then
  CERTBOT_ACCOUNT=(-m "$LE_EMAIL")
else
  CERTBOT_ACCOUNT=(--register-unsafely-without-email)
fi
declare -A SEEN
ISSUED=()
for d in "${ALL_DOMAINS[@]}"; do
  [ -z "$d" ] && continue
  [ -n "${SEEN[$d]:-}" ] && continue
  SEEN[$d]=1
  if cert_is_valid "$d"; then
    ok "Сертификат для $d уже есть и валиден — пропускаю."
  elif [ "${DNS_OK[$d]:-1}" = "0" ]; then
    warn "Пропускаю certbot для $d — DNS не указывает на этот сервер (см. выше)."
  else
    if spin_run "Выпуск сертификата для $d" certbot certonly --standalone --preferred-challenges http \
         --non-interactive --agree-tos "${CERTBOT_ACCOUNT[@]}" -d "$d"; then
      ISSUED+=("$d")
    else
      warn "certbot: сертификат для $d не выпущен (см. лог выше)."
    fi
  fi
done
[ "$WS" = "nginx" ] && { systemctl start nginx 2>&1 || true; }

# Хук продления (см. install_renew_hook в lib.sh): перезапуск веб-сервера и remnanode.
install_renew_hook

# ---- веб-сервер: отдельная заглушка (и сертификат) на каждый протокол -------------------
# Reality «ворует» сертификат у target-сервера реальным TLS-хендшейком, поэтому каждая
# заглушка слушает TLS с сертификатом СВОЕГО домена (см. decoys.sh).
step "Настройка $(ws_label "$WS") (self-steal: заглушка на каждый протокол)"
# Сайты тулкита у другого веб-сервера убираем: иначе оба слушали бы одни и те же порты.
ws_cleanup_other decoy
if [ "$WS" = "caddy" ]; then
  decoys_write_caddy || true   # код > 0 = часть заглушек пока без TLS; предупреждение уже выведено
  # При чужом/пустом SNI отдаём сертификат основного домена — как nginx с первым сайтом.
  CADDY_DEFAULT_SNI=""; cert_is_valid "$PRIMARY_DOMAIN" && CADDY_DEFAULT_SNI="$PRIMARY_DOMAIN"
  if ! caddy_apply node "$CADDY_DEFAULT_SNI"; then
    err "Ошибка конфигурации Caddy"
    exit 1
  fi
  ok "Caddy настроен."
else
  decoys_write_nginx || true
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
fi

# ---- haproxy (SNI passthrough) --------------------------------------------
# Конфиг пишем во временный файл, проверяем, и только потом ставим на место
# (со старой копией рядом) — раньше он перезаписывался ДО проверки.
# ACL и backend'ы создаются только для заданных доменов: пустой домен давал
# невалидное `req.ssl_sni -i ` и HAProxy не стартовал.
step "Настройка HAProxy"

# ---- защита от сканеров ------------------------------------------------------------------
# Любой заход (по IP, с чужим SNI) должен видеть обычный сайт-заглушку, как у настоящего сервера:
# мёртвый порт для проверяющего (ТСПУ) подозрительнее. Поэтому лишнее НЕ рвём, а отдаём REALITY TCP.
# SCAN_PROTECT=1 добавляет: лимит новых соединений и одновременных соединений с одного IP.
#   HAPROXY_RATE (300 новых за 10 с), HAPROXY_CONN_MAX (3000 одновременных) — под CGNAT/офисы
#   с тысячами клиентов за одним адресом при необходимости поднимите.
SCAN_PROTECT="${SCAN_PROTECT:-1}"
HAP_RATE="${HAPROXY_RATE:-300}"; HAP_CONN_MAX="${HAPROXY_CONN_MAX:-3000}"

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
EOF
if [ "$SCAN_PROTECT" = "1" ]; then
  cat <<EOF
    # лимиты на один адрес источника
    stick-table type ip size 200k expire 5m store conn_rate(10s),conn_cur
    tcp-request connection track-sc0 src
    tcp-request connection reject if { sc_conn_rate(0) gt ${HAP_RATE} }
    tcp-request connection reject if { sc_conn_cur(0) gt ${HAP_CONN_MAX} }
    # ждём ClientHello недолго: молчащий сканер не должен занимать сокет.
    # Неизвестный/пустой SNI и не-TLS НЕ отбрасываем: они уходят в REALITY TCP, а тот показывает
    # заглушку, как настоящий сайт (иначе проверка по IP/чужому SNI видела бы «мёртвый» порт).
    tcp-request inspect-delay 3s
    tcp-request content accept if { req.ssl_hello_type 1 }
EOF
else
  cat <<'EOF'
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
EOF
fi
# Какие backend'ы нужны. Протокол на том же домене, что и основной, отдельного маршрута
# не получает: HAProxy различает только SNI.
declare -A BE=()
for p in grpc xhttp tg; do
  [ "$p" = "$PRIMARY" ] && continue
  [ -n "${XDOM[$p]}" ] && [ "${XDOM[$p]}" != "$PRIMARY_DOMAIN" ] && BE[$p]=1
done
# Домен Hysteria2 по TCP — его собственная заглушка с его сертификатом (по UDP отвечает сам Hysteria2).
[ -n "$DOMAIN_HY2" ] && { [ -z "$PRIMARY" ] || [ "$DOMAIN_HY2" != "$PRIMARY_DOMAIN" ]; } && BE[hy2]=1
# WEB-прокси Telegram: веб-сервер (TLS своего домена) -> Telemt; страницу для обычных посетителей отдаёт Telemt.
[ -n "$DOMAIN_WEB" ] && { [ -z "$PRIMARY" ] || [ "$DOMAIN_WEB" != "$PRIMARY_DOMAIN" ]; } && BE[web]=1

# Куда уходит всё неизвестное: основной протокол Xray; без него — заглушка Hysteria2 или WEB-прокси.
if [ -n "$PRIMARY" ]; then DEFAULT_BE="be_${PRIMARY}"
elif [ -n "${BE[hy2]:-}" ]; then DEFAULT_BE="be_hy2"
else DEFAULT_BE="be_web"; fi

for p in grpc xhttp tg; do
  [ -n "${BE[$p]:-}" ] && echo "    use_backend be_${p} if { req.ssl_sni -i ${XDOM[$p]} }"
done
[ -n "${BE[hy2]:-}" ] && [ "$DEFAULT_BE" != "be_hy2" ] && echo "    use_backend be_hy2 if { req.ssl_sni -i ${DOMAIN_HY2} }"
[ -n "${BE[web]:-}" ] && [ "$DEFAULT_BE" != "be_web" ] && echo "    use_backend be_web if { req.ssl_sni -i ${DOMAIN_WEB} }"
echo "    default_backend ${DEFAULT_BE}"

if [ -n "$PRIMARY" ]; then
  printf '\nbackend be_%s\n    server %s1 127.0.0.1:%s\n' "$PRIMARY" "$PRIMARY" "${XPORT[$PRIMARY]}"
fi
for p in grpc xhttp tg; do
  [ -n "${BE[$p]:-}" ] && printf '\nbackend be_%s\n    server %s1 127.0.0.1:%s\n' "$p" "$p" "${XPORT[$p]}"
done
if [ -n "${BE[hy2]:-}" ]; then
  printf '\n# Hysteria2 по UDP 443 обслуживает Xray сам (masquerade); по TCP этот домен ведёт на свою заглушку\nbackend be_hy2\n    server hy2web 127.0.0.1:%s\n' "${DECOY_PORT[hy2]:-8084}"
fi
if [ -n "${BE[web]:-}" ]; then
  printf '\n# WEB-прокси Telegram (веб-сервер -> Telemt)\nbackend be_web\n    server web1 127.0.0.1:%s\n' "${DECOY_PORT[web]:-8086}"
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

if systemctl is-active --quiet "$WS"; then ok "${WS}: активен"; else err "${WS}: НЕ активен"; CHECK_FAIL=1; fi
if systemctl is-active --quiet haproxy; then ok "haproxy: активен"; else err "haproxy: НЕ активен"; CHECK_FAIL=1; fi

if ss -tlnp 2>/dev/null | grep -E '[:.]443[[:space:]]' | grep -q haproxy; then
  ok "haproxy: слушает 443/tcp"
else
  err "haproxy: НЕ слушает 443/tcp — клиенты не смогут подключиться"; CHECK_FAIL=1
fi
if haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null; then
  ok "haproxy: конфигурация валидна"
else
  err "haproxy: действующая конфигурация невалидна"; CHECK_FAIL=1
fi

# Автопродление: пробный прогон certbot (staging) для только что выпущенных
# сертификатов — убеждаемся, что продление через 60 дней сработает само.
# Все сертификаты выпущены одним способом (standalone, порт 80), поэтому достаточно пробного продления
# ОДНОГО из них: по умолчанию проверяется первый (CERT_DRYRUN=all — каждый, off — пропустить).
CERT_DRYRUN="${CERT_DRYRUN:-one}"
if [ "${#ISSUED[@]}" -gt 0 ] && [ "$CERT_DRYRUN" != "off" ]; then
  DRY_TARGETS=("${ISSUED[@]}")
  [ "$CERT_DRYRUN" = "all" ] || DRY_TARGETS=("${ISSUED[0]}")
  for d in "${DRY_TARGETS[@]}"; do
    if spin_run "Проверка автопродления для ${d} (dry-run)" certbot_dry_run "$d"; then :; else
      err "автопродление для ${d} не пройдёт — проверьте порт 80 и DNS"; CHECK_FAIL=1
    fi
  done
  [ "${#ISSUED[@]}" -gt "${#DRY_TARGETS[@]}" ] && \
    info "Остальные $(( ${#ISSUED[@]} - ${#DRY_TARGETS[@]} )) сертификата(ов) выпущены тем же способом — отдельная проверка не нужна (CERT_DRYRUN=all — проверить каждый)."
fi

# Заглушки: каждая отвечает 200, отдаёт сертификат своего домена, и все страницы разные.
decoys_verify || CHECK_FAIL=1

for d in "${ALL_DOMAINS[@]}"; do
  [ -z "$d" ] && continue
  if cert_is_valid "$d"; then
    ok "сертификат ${d}: валиден"
  else
    err "сертификат ${d}: ОТСУТСТВУЕТ или просрочен"
    CHECK_FAIL=1
  fi
done

echo
decoys_table

if [ "$CHECK_FAIL" = "1" ]; then
  warn "haproxy-setup.sh завершён С ПРЕДУПРЕЖДЕНИЯМИ — см. пункты выше с [✗]."
  exit 1
else
  ok "haproxy-setup.sh завершён, все проверки пройдены."
fi
