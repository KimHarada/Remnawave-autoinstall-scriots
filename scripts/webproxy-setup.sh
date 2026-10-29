#!/usr/bin/env bash
# DORIK toolkit — WEB-прокси Telegram (тип «WEB» в настройках прокси Telegram Desktop/Android).
#
# Схема (порт 443 общий с протоколами Xray, конфликта нет):
#   клиент --TLS 443--> HAProxy (SNI) --> nginx 127.0.0.1:8086 (сертификат домена WEB-прокси)
#                                     --> Telemt 127.0.0.1:18080 (transport = "web")
# Посетитель без ключа получает страницу-заглушку (её отдаёт Telemt из /var/www/decoy-web),
# приложение с ключом — проксируется в Telegram. Канал-спонсор показывается, если указан
# рекламный тег из @MTProxybot (use_middle_proxy + ad_tag).
#
# Используется Telemt (https://github.com/telemt/telemt), версия и SHA-256 закреплены ниже.
# Бинарник Telemt закрытый по содержимому для этого скрипта: проверяется только его хеш.
#
#   webproxy-setup.sh [install]     установить / обновить (по умолчанию)
#   webproxy-setup.sh status        состояние и ссылка
#   webproxy-setup.sh link          только ссылка для клиентов
#   webproxy-setup.sh secret [домен]  заранее создать ключ и показать данные для @MTProxybot
#   webproxy-setup.sh tag <32hex>   сменить рекламный тег (пусто/off — убрать)
#   webproxy-setup.sh remove        удалить WEB-прокси (домен и сертификат остаются)
# Без вопросов: ASSUME_YES=1 DOMAIN_WEB=web.example.com [WEB_SECRET=32hex] [WEB_AD_TAG=32hex]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh
_dorik_source decoys.sh

[ "${BASH_SOURCE[0]}" = "$0" ] && _wp_standalone=1 || _wp_standalone=0

TELEMT_VERSION="3.5.14"
declare -A TELEMT_SHA256=(
  [x86_64]="b10f86c6851f5c422a49d98deea55e8ef4aea7879605e59c1d4aa43c8f4c70ce"
  [aarch64]="d2e3ca6a3f407aecb190c4a73db74ec581d56b5dd6ab469cb0e1d0f2c3d31c57"
)
WP_SERVICE=mtproxy-web
WP_CONF_DIR=/etc/mtproxy-web
WP_LIB_DIR=/usr/local/lib/mtproxy-web
WP_DATA_DIR=/var/lib/mtproxy-web
WP_STATE=/etc/dorik/webproxy.json
WP_API="127.0.0.1:18082"
WP_PORT_BACKEND=18080

wp_get() { [ -s "$WP_STATE" ] && jq -r "$1 // empty" "$WP_STATE" 2>/dev/null; return 0; }
wp_save() {  # wp_save <домен> <секрет> <тег>
  # umask только внутри подоболочки: иначе он остался бы 077 до конца скрипта и каталоги Telemt
  # создавались бы недоступными для его пользователя (status=203/EXEC, «Permission denied»).
  (
    umask 077
    mkdir -p "$(dirname "$WP_STATE")"
    jq -n --arg d "$1" --arg s "$2" --arg t "$3" --arg v "$TELEMT_VERSION" \
      '{domain:$d, secret:$s, adTag:$t, telemt:$v}' > "$WP_STATE"
    chmod 600 "$WP_STATE"
  )
}
wp_installed() { [ -s "$WP_STATE" ] && [ -x "$WP_LIB_DIR/telemt" ]; }
wp_link() { printf 'tg://webproxy?server=%s&secret=dd%s' "$1" "$2"; }

# Данные для регистрации прокси в @MTProxybot (бот просит адрес и ключ, потом выдаёт рекламный тег).
wp_bot_info() {  # wp_bot_info <домен> <секрет 32hex>
  box_top "Регистрация в @MTProxybot (для рекламы канала)"
  box_row "Бот: ${C_BOLD}https://t.me/MTProxybot${C_RESET}"
  box_row "1. Отправьте боту: /newproxy"
  box_row "2. Адрес:  ${C_BOLD}$1:443${C_RESET}"
  box_row "3. Ключ:   ${C_BOLD}$2${C_RESET}  ${C_DIM}(без dd)${C_RESET}"
  box_row "4. Бот выдаст тег (32 символа) — его укажите скрипту"
  box_row "5. В боте: /myproxies → прокси → Set promotion → ваш канал"
  box_bottom
}

# ---- параметры ------------------------------------------------------------------------------
wp_collect() {
  local d s t
  d="${DOMAIN_WEB:-$(wp_get .domain)}"
  s="${WEB_SECRET:-$(wp_get .secret)}"
  t="${WEB_AD_TAG-$(wp_get .adTag)}"
  if [ "${ASSUME_YES:-0}" != "1" ] && [ "${WEB_NONINTERACTIVE:-0}" != "1" ]; then
    ensure_tty
    d="$(ask_valid "Домен для WEB-прокси (A-запись на этот сервер, отдельный от доменов протоколов)" "$d" is_valid_domain)" || return 1
    if [ -z "$s" ]; then s="$(openssl rand -hex 16)"; wp_save "${d,,}" "$s" "${t:-}"; fi   # ключ нужен боту ДО тега
    wp_bot_info "${d,,}" "${s#dd}"
    t="$(ask_value "Рекламный тег (Enter — без рекламы канала)" "$t")"
    t="$(printf '%s' "$t" | tr -d ' \r\n"' | tr 'A-F' 'a-f')"
  fi
  [ -n "$d" ] && is_valid_domain "$d" || { err "Нужен корректный домен WEB-прокси (DOMAIN_WEB)."; return 1; }
  d="${d,,}"
  if [ -n "$s" ]; then s="${s#dd}"; is_hex32 "$s" || { err "WEB_SECRET должен быть 32 hex-символа."; return 1; }
  else s="$(openssl rand -hex 16)"; fi
  s="$(printf '%s' "$s" | tr 'A-F' 'a-f')"
  t="$(printf '%s' "$t" | tr 'A-F' 'a-f')"
  if [ -n "$t" ] && [ "$t" != "off" ]; then is_hex32 "$t" || { err "Рекламный тег должен быть 32 hex-символа."; return 1; }; else t=""; fi
  WEB_DOMAIN="$d"; WEB_SECRET_VAL="$s"; WEB_TAG_VAL="$t"
  return 0
}

# ---- домен, сертификат, nginx и HAProxy -------------------------------------------------------
# Если домен уже подключён (в составе полной настройки) — ничего не делаем. Иначе перезапускаем
# haproxy-setup.sh со всеми уже настроенными доменами + доменом WEB-прокси: он выпустит
# сертификат, поставит заглушку, nginx-сайт и маршрут HAProxy по SNI.
wp_front() {
  local p d port zip have=0
  if [ -f "$DECOY_CONF" ]; then
    while IFS='|' read -r p d port zip; do [ "$p" = "web" ] && [ "$d" = "$WEB_DOMAIN" ] && have=1; done < "$DECOY_CONF"
  fi
  if [ "$have" = "1" ] && grep -q 'backend be_web' /etc/haproxy/haproxy.cfg 2>/dev/null \
     && cert_is_valid "$WEB_DOMAIN" && [ -f /etc/nginx/sites-enabled/decoy-web ]; then
    ok "Домен ${WEB_DOMAIN}: сертификат, nginx и маршрут HAProxy уже настроены."
    return 0
  fi
  if [ ! -f "$DECOY_CONF" ] || ! grep -q '^tcp|' "$DECOY_CONF"; then
    err "Сначала нужна база: Nginx + HAProxy + сертификаты («Полная настройка» или «Только Nginx + HAProxy»)."
    err "WEB-прокси подключается к ним по SNI — отдельного порта 443 он не занимает."
    return 1
  fi
  local envs=() USE_HY2_=0 USE_TG_=0
  while IFS='|' read -r p d port zip; do
    case "$p" in
      tcp)   envs+=("DOMAIN_TCP=$d") ;;
      grpc)  envs+=("DOMAIN_GRPC=$d") ;;
      xhttp) envs+=("DOMAIN_XHTTP=$d") ;;
      hy2)   envs+=("DOMAIN_HY2=$d"); USE_HY2_=1 ;;
      tg)    envs+=("DOMAIN_TG=$d"); USE_TG_=1 ;;
    esac
  done < "$DECOY_CONF"
  step "Домен WEB-прокси: сертификат, заглушка, nginx, HAProxy"
  env "${envs[@]}" USE_HY2="$USE_HY2_" USE_TG="$USE_TG_" DOMAIN_WEB="$WEB_DOMAIN" USE_WEB=1 \
      NONINTERACTIVE=1 INSTALL_DECOY="${INSTALL_DECOY:-1}" DORIK_NESTED=1 \
      bash "${SCRIPT_DIR}/haproxy-setup.sh" </dev/null
  # код возврата haproxy-setup ненулевой и при мелких предупреждениях — решает проверка ниже
  cert_is_valid "$WEB_DOMAIN" || { err "Сертификат для ${WEB_DOMAIN} не выпущен: проверьте A-запись домена на этот сервер и порт 80."; return 1; }
  return 0
}

# ---- Telemt ------------------------------------------------------------------------------------
wp_install_binary() {
  local arch work url sum
  arch="$(uname -m)"
  [ -n "${TELEMT_SHA256[$arch]:-}" ] || { err "Архитектура ${arch} не поддерживается (нужен x86_64 или aarch64)."; return 1; }
  if [ -x "$WP_LIB_DIR/telemt" ] && [ "$(cat "$WP_LIB_DIR/.version" 2>/dev/null)" = "$TELEMT_VERSION" ]; then
    chmod 755 "$WP_LIB_DIR" 2>/dev/null || true     # чинит каталог, созданный прежней версией скрипта с правами 700
    ok "Telemt ${TELEMT_VERSION} уже установлен."; return 0
  fi
  work="$(mktemp -d)"
  for url in "https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/telemt-${arch}-linux-gnu.tar.gz" \
             "https://github.com/telemt/telemt/releases/download/v${TELEMT_VERSION}/telemt-${arch}-linux-gnu.tar.gz"; do
    spin_run "Загрузка Telemt ${TELEMT_VERSION}" curl -fsSL --retry 3 -o "$work/t.tgz" "$url" && break
    rm -f "$work/t.tgz"
  done
  [ -s "$work/t.tgz" ] || { err "Не удалось скачать Telemt с github.com."; rm -rf "$work"; return 1; }
  sum="$(sha256sum "$work/t.tgz" | cut -d' ' -f1)"
  if [ "$sum" != "${TELEMT_SHA256[$arch]}" ]; then
    err "SHA-256 архива Telemt не совпал (получено ${sum:0:16}…) — установка остановлена."; rm -rf "$work"; return 1
  fi
  ok "SHA-256 Telemt совпадает с закреплённым."
  mkdir -p "$work/x"
  tar -xzf "$work/t.tgz" -C "$work/x" || { err "Не удалось распаковать Telemt."; rm -rf "$work"; return 1; }
  local bin; bin="$(find "$work/x" -type f -name telemt | head -1)"
  [ -n "$bin" ] || { err "В архиве нет файла telemt."; rm -rf "$work"; return 1; }
  mkdir -p "$WP_LIB_DIR"
  chmod 755 "$WP_LIB_DIR"            # каталог должен быть доступен пользователю службы независимо от umask
  install -m 755 "$bin" "$WP_LIB_DIR/telemt"
  echo "$TELEMT_VERSION" > "$WP_LIB_DIR/.version"
  rm -rf "$work"
  ok "Telemt ${TELEMT_VERSION} установлен в ${WP_LIB_DIR}."
}

wp_write_config() {  # wp_write_config <домен> <секрет> <тег>
  local d="$1" s="$2" t="$3" ip
  ip="$(get_public_ip)"
  [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2)"
  [ -n "$ip" ] || { err "Не удалось определить IP сервера."; return 1; }
  getent group mtproxy-web >/dev/null || groupadd --system mtproxy-web
  id mtproxy-web &>/dev/null || useradd --system --gid mtproxy-web --home-dir "$WP_DATA_DIR" --shell /usr/sbin/nologin mtproxy-web
  mkdir -p "$WP_CONF_DIR" "$WP_DATA_DIR"
  chown mtproxy-web:mtproxy-web "$WP_DATA_DIR"; chmod 750 "$WP_DATA_DIR"
  chown root:mtproxy-web "$WP_CONF_DIR"; chmod 750 "$WP_CONF_DIR"
  [ -f "$(decoy_root web)/index.html" ] || decoy_write_basic web "$(decoy_root web)"
  chmod -R a+rX "$(decoy_root web)"
  {
    echo "# DORIK toolkit — Telemt (WEB-прокси Telegram). Не редактируйте вручную: файл пересоздаётся скриптом."
    echo "[general]"
    if [ -n "$t" ]; then echo "use_middle_proxy = true"; echo "ad_tag = \"${t}\""; else echo "use_middle_proxy = false"; fi
    cat <<EOF
log_level = "normal"
prefer_ipv6 = false

[general.modes]
classic = false
secure = true
tls = false

[general.links]
show = []

[network]
ipv4 = true
prefer = 4

[access.users]
default = "${s}"

[server.api]
enabled = true
listen = "${WP_API}"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "127.0.0.1"
port = ${WP_PORT_BACKEND}
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https"
carriers = ["websocket-lanes", "websocket", "https-lanes", "https"]
decoy_fasttrack_mode = "off"

[[web.vhosts]]
host = "${d}"
public_addr = "${ip}:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "$(decoy_root web)"
index = "index.html"

[[web.vhosts.profiles]]
user = "default"
secret_mode = "dd"
max_sessions = 128
max_streams = 4096
max_streams_per_session = 64
EOF
  } > "$WP_CONF_DIR/telemt.toml"
  chown root:mtproxy-web "$WP_CONF_DIR/telemt.toml"; chmod 640 "$WP_CONF_DIR/telemt.toml"
}

wp_write_unit() {
  cat > /etc/systemd/system/${WP_SERVICE}.service <<EOF
[Unit]
Description=Telegram WEB proxy (Telemt) — DORIK toolkit
After=network-online.target
Wants=network-online.target

[Service]
User=mtproxy-web
Group=mtproxy-web
WorkingDirectory=${WP_DATA_DIR}
ExecStart=${WP_LIB_DIR}/telemt ${WP_CONF_DIR}/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${WP_DATA_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

wp_wait_ready() {
  local i out
  for i in $(seq 1 45); do
    out="$(curl -s --max-time 2 "http://${WP_API}/v1/runtime/web/status" 2>/dev/null)"
    if [ -n "$out" ] && echo "$out" | jq -e '(.data // .) | .ingress.accepting_connections == true' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# ---- проверка результата -------------------------------------------------------------------------
wp_verify() {  # wp_verify <домен>
  local d="$1" code body h_dom
  VERIFY_FAIL=0
  systemctl is-active --quiet "$WP_SERVICE"; _chk $? "Telemt запущен (служба ${WP_SERVICE})" "служба ${WP_SERVICE} не запущена: journalctl -u ${WP_SERVICE} -n 30"
  ss -tln 2>/dev/null | grep -qE "127\.0\.0\.1:${WP_PORT_BACKEND}[[:space:]]"; _chk $? "Telemt слушает 127.0.0.1:${WP_PORT_BACKEND}" "Telemt не слушает 127.0.0.1:${WP_PORT_BACKEND}"
  ss -tlnp 2>/dev/null | grep -E '[:.]443[[:space:]]' | grep -q haproxy; _chk $? "порт 443 держит HAProxy (общий с протоколами Xray)" "HAProxy не слушает 443"
  grep -q 'use_backend be_web' /etc/haproxy/haproxy.cfg 2>/dev/null; _chk $? "HAProxy направляет ${d} (по SNI) на WEB-прокси" "в HAProxy нет маршрута для ${d}"
  body="$(mktemp)"
  code="$(curl -sk -o "$body" -w '%{http_code}' --max-time 8 --resolve "${d}:443:127.0.0.1" "https://${d}/" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]; _chk $? "https://${d}/ без ключа отдаёт страницу-заглушку (код 200)" "https://${d}/ вернул код ${code} (ожидался 200 — заглушку отдаёт Telemt)"
  rm -f "$body"
  h_dom="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$d" 2>/dev/null | openssl x509 -noout -checkhost "$d" 2>/dev/null)"
  echo "$h_dom" | grep -q 'does match'; _chk $? "по 443 с SNI ${d} отдаётся сертификат этого домена" "по 443 с SNI ${d} отдаётся чужой сертификат"
  return "$VERIFY_FAIL"
}

wp_print_link() {  # wp_print_link <домен> <секрет> <тег>
  echo
  box_top "WEB-прокси Telegram"
  box_row "Домен:   ${C_BOLD}$1${C_RESET}"
  box_row "Ключ:    ${C_BOLD}dd$2${C_RESET}"
  box_row "Реклама: $([ -n "$3" ] && echo "канал-спонсор подключён (тег ${3:0:6}…)" || echo "не задана (тег из @MTProxybot не указан)")"
  box_sep
  box_wrap "${C_DIM}→${C_RESET}" "Работает в Telegram Desktop и Android (iOS тип WEB не поддерживает)."
  box_wrap "${C_DIM}→${C_RESET}" "Вручную: Настройки → Данные и память → Прокси → Добавить → WEB; сервер ${1}, ключ — значение выше (с dd)."
  [ -z "$3" ] && box_wrap "${C_DIM}→${C_RESET}" "Реклама своего канала: @MTProxybot → зарегистрировать прокси → тег → «webproxy-setup.sh tag <тег>» (меню → WEB-прокси → тег)."
  box_bottom
  echo
  echo -e "  Ссылка для клиентов (откройте в Telegram):"
  echo -e "  ${C_B}$(wp_link "$1" "$2")${C_RESET}"
}

# ---- команды ------------------------------------------------------------------------------------------
wp_install() {
  step "WEB-прокси Telegram"
  wp_collect || return 1
  ensure_base_packages 2>/dev/null || true
  command -v jq &>/dev/null || apt_install jq || { err "Не удалось установить jq."; return 1; }
  [ "${WEB_FRONT_DONE:-0}" = "1" ] || wp_front || return 1
  step "Telemt ${TELEMT_VERSION}"
  wp_install_binary || return 1
  wp_write_config "$WEB_DOMAIN" "$WEB_SECRET_VAL" "$WEB_TAG_VAL" || return 1
  wp_write_unit
  runuser -u mtproxy-web -- test -x "$WP_LIB_DIR/telemt" \
    || { err "Пользователь mtproxy-web не может запустить ${WP_LIB_DIR}/telemt (проверьте права каталога: ls -ld ${WP_LIB_DIR})."; return 1; }
  systemctl enable "$WP_SERVICE" &>/dev/null || true
  systemctl restart "$WP_SERVICE"
  spin_run "Запуск Telemt" wp_wait_ready || { err "Telemt не стал принимать соединения:"; journalctl -u "$WP_SERVICE" -n 30 --no-pager >&2; return 1; }
  wp_save "$WEB_DOMAIN" "$WEB_SECRET_VAL" "$WEB_TAG_VAL"
  step "Проверка WEB-прокси"
  wp_verify "$WEB_DOMAIN" || { warn "WEB-прокси установлен, но часть проверок не прошла — см. пункты выше."; wp_print_link "$WEB_DOMAIN" "$WEB_SECRET_VAL" "$WEB_TAG_VAL"; return 1; }
  ok "WEB-прокси работает."
  wp_print_link "$WEB_DOMAIN" "$WEB_SECRET_VAL" "$WEB_TAG_VAL"
}

# Сгенерировать ключ заранее и показать данные для бота (установка потом использует тот же ключ).
wp_secret() {  # wp_secret [домен]
  command -v jq &>/dev/null || apt_install jq || { err "Не удалось установить jq."; return 1; }
  local d s t
  d="${1:-${DOMAIN_WEB:-$(wp_get .domain)}}"
  if [ -z "$d" ] && [ "${ASSUME_YES:-0}" != "1" ]; then
    ensure_tty; d="$(ask_valid "Домен для WEB-прокси" "" is_valid_domain)" || return 1
  fi
  is_valid_domain "$d" || { err "Укажите домен: webproxy-setup.sh secret <домен> (или DOMAIN_WEB=...)."; return 1; }
  d="${d,,}"
  s="${WEB_SECRET:-$(wp_get .secret)}"; s="${s#dd}"
  if [ -n "$s" ]; then is_hex32 "$s" || { err "WEB_SECRET должен быть 32 hex-символа."; return 1; }
  else s="$(openssl rand -hex 16)"; fi
  s="$(printf '%s' "$s" | tr 'A-F' 'a-f')"
  t="$(wp_get .adTag)"
  wp_save "$d" "$s" "$t"
  wp_bot_info "$d" "$s"
  echo
  info "Ключ сохранён: установка WEB-прокси использует именно его (тег можно указать при установке или потом: --web tag <тег>)."
  echo "$s"
}

wp_status() {
  wp_installed || { info "WEB-прокси не установлен."; return 0; }
  local d s t; d="$(wp_get .domain)"; s="$(wp_get .secret)"; t="$(wp_get .adTag)"
  wp_verify "$d" || true
  wp_print_link "$d" "$s" "$t"
}

wp_tag() {
  wp_installed || { err "WEB-прокси не установлен."; return 1; }
  local t="${1:-}"; t="$(printf '%s' "$t" | tr -d ' \r\n"' | tr 'A-F' 'a-f')"
  [ "$t" = "off" ] && t=""
  if [ -n "$t" ] && ! is_hex32 "$t"; then err "Тег — 32 hex-символа из @MTProxybot."; return 1; fi
  local d s; d="$(wp_get .domain)"; s="$(wp_get .secret)"
  wp_write_config "$d" "$s" "$t" || return 1
  systemctl restart "$WP_SERVICE"
  wp_wait_ready || { err "Telemt не поднялся после смены тега."; return 1; }
  wp_save "$d" "$s" "$t"
  ok "Рекламный тег $([ -n "$t" ] && echo "обновлён" || echo "убран")."
  wp_print_link "$d" "$s" "$t"
}

wp_remove() {
  wp_installed || [ -f /etc/systemd/system/${WP_SERVICE}.service ] || { info "WEB-прокси не установлен."; return 0; }
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    ensure_tty
    ask_yes_no "Удалить WEB-прокси (Telemt, конфиг и ключ)? Домен и сертификат останутся" "2" || { info "Отменено."; return 0; }
  fi
  systemctl disable --now "$WP_SERVICE" &>/dev/null || true
  rm -f /etc/systemd/system/${WP_SERVICE}.service; systemctl daemon-reload
  rm -rf "$WP_LIB_DIR" "$WP_CONF_DIR" "$WP_DATA_DIR" "$WP_STATE" /etc/nginx/sites-enabled/decoy-web /etc/nginx/sites-available/decoy-web /etc/nginx/conf.d/dorik-web-upgrade.conf
  # убираем домен из списка заглушек и маршрут из HAProxy: пересобирать всё не нужно, достаточно
  # убрать be_web — иначе HAProxy отправлял бы SNI удалённого домена на несуществующий nginx-сайт.
  [ -f "$DECOY_CONF" ] && sed -i '/^web|/d' "$DECOY_CONF"
  if [ -f /etc/haproxy/haproxy.cfg ] && grep -q 'be_web' /etc/haproxy/haproxy.cfg; then
    cp -f /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%s)"
    sed -i '/use_backend be_web/d; /# WEB-прокси Telegram/,/server web1/d' /etc/haproxy/haproxy.cfg
    if haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null; then systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
    else warn "HAProxy: после удаления маршрута конфиг невалиден — восстановите копию /etc/haproxy/haproxy.cfg.bak.*"; fi
  fi
  nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
  rm -rf "$(decoy_root web)"
  ok "WEB-прокси удалён."
}

if [ "$_wp_standalone" = "1" ]; then
  require_root
  require_apt_os
  case "${1:-install}" in
    install|"") banner; wp_install; exit $? ;;
    status)     banner; wp_status; exit $? ;;
    link)       wp_installed || { echo "WEB-прокси не установлен." >&2; exit 1; }
                wp_link "$(wp_get .domain)" "$(wp_get .secret)"; echo; exit 0 ;;
    tag)        wp_tag "${2:-}"; exit $? ;;
    secret)     banner; wp_secret "${2:-}"; exit $? ;;
    remove)     banner; wp_remove; exit $? ;;
    *) echo "Использование: $0 [install|status|link|secret [домен]|tag <32hex|off>|remove]" >&2; exit 2 ;;
  esac
fi
