#!/usr/bin/env bash
# DORIK toolkit — выбор веб-сервера: nginx или Caddy.
#
# Веб-сервер нужен в двух местах:
#   - на ноде он отдаёт страницы-заглушки (self-steal для REALITY) на 127.0.0.1 и проксирует
#     WEB-прокси Telegram; сертификаты выпускает certbot (их же использует Hysteria2);
#   - на сервере панели он стоит перед панелью и страницей подписки на 80/443; Caddy в этой
#     роли выпускает и продлевает сертификаты сам, certbot не нужен.
#
# Выбор хранится в /etc/dorik/webserver; задать без вопросов: WEB_SERVER=nginx|caddy.
# Подключается из lib.sh.

WS_STATE=/etc/dorik/webserver
CADDY_DIR=/etc/caddy
CADDY_SITES=/etc/caddy/dorik
CADDY_CERTS=/etc/caddy/certs
CADDY_MARK="# DORIK toolkit — файл создаётся скриптом, правки будут перезаписаны"

ws_current() {
  local v="${WEB_SERVER:-}"
  [ -z "$v" ] && [ -s "$WS_STATE" ] && v="$(head -1 "$WS_STATE" 2>/dev/null | tr -d '[:space:]')"
  case "$v" in caddy|nginx) echo "$v" ;; *) echo nginx ;; esac
}
ws_save()  { mkdir -p "$(dirname "$WS_STATE")"; echo "$1" > "$WS_STATE"; chmod 644 "$WS_STATE"; }
ws_label() { case "${1:-$(ws_current)}" in caddy) echo "Caddy" ;; *) echo "Nginx" ;; esac; }

# Вопрос «какой веб-сервер» — в оформлении меню. Результат: WEB_SERVER (и сохраняется).
ws_ask() {  # ws_ask <контекст: node|panel>
  local def=1 cur extra nl=$'\n' now=""
  cur="$(ws_current)"; [ "$cur" = "caddy" ] && def=2
  [ -s "$WS_STATE" ] && now="${nl}${nl}@СЕЙЧАС НА СЕРВЕРЕ${nl}$(ws_label "$cur")"
  if [ "${1:-node}" = "panel" ]; then
    extra="Сертификаты выпускает и продлевает сам (certbot не нужен), конфиг в несколько строк."
  else
    extra="Отдаёт заглушки с сертификатами certbot; конфиг короче, HTTP/2 и TLS 1.3 без настройки."
  fi
  ask_choice "ВЕБ-СЕРВЕР" "$def" \
    "Nginx|Проверенный вариант по умолчанию: на нём тулкит работал всегда. Гибкая настройка, минимум памяти.${now}" \
    "Caddy|${extra} Новый вариант: на боевом сервере проверьте после установки пункт «Отчёт».${now}" || return 1
  if [ "$CHOICE" = "2" ]; then WEB_SERVER=caddy; else WEB_SERVER=nginx; fi
  export WEB_SERVER
  return 0
}

ws_stop()  { systemctl stop "$(ws_current)" &>/dev/null || true; }
ws_start() { systemctl start "$(ws_current)" &>/dev/null || true; }

# ---- Caddy: установка ----------------------------------------------------------------------
_caddy_add_repo() {  # официальный репозиторий Caddy (свежая версия)
  apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg curl &>/dev/null || true
  have gpg || return 1
  curl -1sLf --retry 3 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 1
  curl -1sLf --retry 3 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list || return 1
  [ -s /usr/share/keyrings/caddy-stable-archive-keyring.gpg ] && [ -s /etc/apt/sources.list.d/caddy-stable.list ] || return 1
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
}

caddy_install() {
  if have caddy; then return 0; fi
  if spin_run "Подключение репозитория Caddy" _caddy_add_repo && apt_update && apt_install caddy; then :; else
    # Репозиторий недоступен — берём пакет из дистрибутива (версия старее, но рабочая).
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    apt_update || true
    apt_install caddy || { err "Caddy не установился."; return 1; }
  fi
  have caddy || { err "Caddy не установился."; return 1; }
  # Пакет сразу запускает Caddy со стандартным сайтом на :80 — он мешал бы certbot. Останавливаем
  # до записи нашего конфига.
  systemctl stop caddy &>/dev/null || true
  return 0
}

# Главный Caddyfile. scope=node: сертификаты свои (certbot), порт 80 не занимаем;
# scope=panel: Caddy сам выпускает сертификаты и ведёт 80 → 443.
# default_sni/fallback_sni — какой сертификат отдавать при пустом или чужом SNI (как у nginx:
# зашедший по IP видит обычный сайт, а не обрыв рукопожатия).
caddy_write_main() {  # caddy_write_main <node|panel> [домен по умолчанию] [с fallback_sni: 1|0]
  local scope="$1" dsni="${2:-}" fb="${3:-1}" f="$CADDY_DIR/Caddyfile"
  mkdir -p "$CADDY_SITES"
  if [ -f "$f" ] && ! grep -qF "DORIK toolkit" "$f"; then
    cp -f "$f" "${f}.bak.$(date +%s)"
    info "Прежний Caddyfile сохранён рядом (${f}.bak.*)."
  fi
  {
    echo "$CADDY_MARK"
    echo "{"
    if [ "$scope" = "node" ]; then
      printf '\tauto_https disable_redirects\n'
      if [ -n "$dsni" ]; then
        printf '\tdefault_sni %s\n' "$dsni"
        [ "$fb" = "1" ] && printf '\tfallback_sni %s\n' "$dsni"
      fi
    else
      [ -n "${LE_EMAIL:-}" ] && printf '\temail %s\n' "$LE_EMAIL"
    fi
    printf '\tservers {\n\t\tprotocols h1 h2\n\t}\n'
    echo "}"
    echo
    echo "import ${CADDY_SITES}/*.caddy"
  } > "$f"
}

caddy_validate() { caddy validate --adapter caddyfile --config "$CADDY_DIR/Caddyfile" >/tmp/dorik_caddy_check 2>&1; }

# Проверяет конфиг и применяет его. Старые версии Caddy не знают fallback_sni — тогда
# пересобираем главный файл без него.
caddy_apply() {  # caddy_apply <node|panel> [домен по умолчанию]
  local scope="$1" dsni="${2:-}"
  caddy_write_main "$scope" "$dsni" 1
  if ! caddy_validate; then
    if grep -q 'fallback_sni' /tmp/dorik_caddy_check 2>/dev/null; then
      caddy_write_main "$scope" "$dsni" 0
      caddy_validate || { err "Конфиг Caddy не прошёл проверку: $(tail -n 3 /tmp/dorik_caddy_check | tr '\n' ' ')"; return 1; }
      warn "Эта версия Caddy не знает fallback_sni — при чужом SNI заглушка не ответит (обновите Caddy)."
    else
      err "Конфиг Caddy не прошёл проверку: $(tail -n 3 /tmp/dorik_caddy_check | tr '\n' ' ')"
      return 1
    fi
  fi
  systemctl enable caddy &>/dev/null || true
  systemctl restart caddy || { err "Caddy не запустился: journalctl -u caddy -n 30"; return 1; }
  return 0
}

# Caddy работает от пользователя caddy и не может читать /etc/letsencrypt (доступ только root).
# Поэтому сертификаты certbot копируются в /etc/caddy/certs/<домен>; после продления то же
# делает хук (install_renew_hook).
caddy_sync_cert() {  # caddy_sync_cert <домен>
  local d="$1" src="/etc/letsencrypt/live/$1" dst="$CADDY_CERTS/$1"
  [ -f "$src/fullchain.pem" ] && [ -f "$src/privkey.pem" ] || return 1
  mkdir -p "$dst"
  cp -fL "$src/fullchain.pem" "$dst/fullchain.pem"
  cp -fL "$src/privkey.pem" "$dst/privkey.pem"
  chown -R caddy:caddy "$CADDY_CERTS" 2>/dev/null || true
  chmod 750 "$CADDY_CERTS" "$dst"; chmod 640 "$dst"/*.pem
}

# Ждёт, пока Caddy выпустит сертификат и начнёт отвечать по HTTPS (роль «панель»).
caddy_wait_https() {  # caddy_wait_https <домен> [секунд]
  local d="$1" limit="${2:-120}" waited=0 out
  # Смотрим само TLS-рукопожатие, а не ответ сайта: закрытая секретной ссылкой панель рвёт
  # соединение без ответа, но сертификат при этом уже настоящий. Код 0 = цепочка доверенная
  # и сертификат подходит домену.
  while [ "$waited" -lt "$limit" ]; do
    out="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$d" -verify_hostname "$d" 2>/dev/null || true)"
    if grep -q 'Verify return code: 0 (ok)' <<<"$out"; then return 0; fi
    sleep 4; waited=$((waited+4))
  done
  return 1
}

# ---- переключение между серверами ------------------------------------------------------------
# Убирает сайты тулкита у ДРУГОГО веб-сервера, чтобы два сервера не слушали одни и те же порты.
# Чужие сайты не трогаем: nginx/Caddy отключаются, только если у них не осталось ничего своего.
ws_cleanup_other() {  # ws_cleanup_other <область: decoy|panel>
  local scope="$1" cur f left
  cur="$(ws_current)"
  if [ "$cur" = "caddy" ]; then
    [ -d /etc/nginx ] || return 0
    if [ "$scope" = "decoy" ]; then
      rm -f /etc/nginx/sites-enabled/decoy /etc/nginx/sites-available/decoy /etc/nginx/conf.d/dorik-web-upgrade.conf
      for f in /etc/nginx/sites-enabled/decoy-* /etc/nginx/sites-available/decoy-*; do [ -e "$f" ] || [ -L "$f" ] || continue; rm -f "$f"; done
    else
      rm -f /etc/nginx/sites-enabled/remnawave-panel /etc/nginx/sites-available/remnawave-panel \
            /etc/nginx/sites-enabled/remnawave-sub /etc/nginx/sites-available/remnawave-sub
    fi
    have nginx || return 0
    left="$(find /etc/nginx/sites-enabled -mindepth 1 2>/dev/null | grep -vc '/default$' || true)"
    if [ "${left:-0}" -eq 0 ]; then
      systemctl disable --now nginx &>/dev/null || true
      info "Nginx остановлен и отключён — его работу взял Caddy."
    else
      nginx -t &>/dev/null && systemctl restart nginx &>/dev/null || true
    fi
  else
    [ -d "$CADDY_SITES" ] || return 0
    if [ "$scope" = "decoy" ]; then
      for f in "$CADDY_SITES"/decoy-*.caddy; do [ -e "$f" ] && rm -f "$f"; done
    else
      rm -f "$CADDY_SITES/panel.caddy" "$CADDY_SITES/sub.caddy"
    fi
    have caddy || return 0
    if ! compgen -G "$CADDY_SITES/*.caddy" >/dev/null; then
      systemctl disable --now caddy &>/dev/null || true
      info "Caddy остановлен и отключён — его работу взял Nginx."
    else
      systemctl restart caddy &>/dev/null || true
    fi
  fi
  return 0
}
