#!/usr/bin/env bash
# DORIK toolkit — заглушки (decoy): по одной на КАЖДЫЙ протокол, и все разные.
#
# Раньше на всех протоколах стояла одна заглушка с сертификатом первого домена: сканер,
# заходя на gRPC- или XHTTP-домен, получал чужой сертификат, а одинаковая страница на
# всех доменах сразу выдавала связь между ними. Теперь у каждого протокола:
#   - свой домен, свой сертификат и свой nginx-сайт на 127.0.0.1;
#   - своя страница из decoys/manifest.txt (без повторов между протоколами);
#   - свой порт: REALITY TCP -> 8081, gRPC -> 8082, XHTTP -> 8083, Hysteria2 -> 8084.
#
# Порт заглушки — это значение `dest` (target) REALITY в профиле Xray на панели
# (для Hysteria2 — адрес masquerade, если он используется в вашем профиле).
#
# Подключается из haproxy-setup.sh. Домены берутся из DOMAIN_TCP / DOMAIN_GRPC /
# DOMAIN_XHTTP / DOMAIN_HY2 (+ USE_HY2). Принудительный выбор страницы:
#   DECOY_NAME_TCP / _GRPC / _XHTTP / _HY2 = имя.zip   (DECOY_NAME — для TCP)

DECOY_CONF=/etc/dorik/decoys.conf
DECOY_WEB=/var/www
DECOY_ORDER=(tcp grpc xhttp hy2)
declare -gA DECOY_PORT=( [tcp]=8081 [grpc]=8082 [xhttp]=8083 [hy2]=8084 )
declare -gA DECOY_LABEL=( [tcp]="REALITY TCP" [grpc]="gRPC" [xhttp]="XHTTP" [hy2]="Hysteria2" )

decoy_root() { echo "${DECOY_WEB}/decoy-$1"; }

# Домен протокола; пусто — протокол не используется (или делит домен с TCP: HAProxy
# различает их по SNI, поэтому отдельной заглушки такому протоколу не нужно).
decoy_domain() {
  case "$1" in
    tcp)   echo "${DOMAIN_TCP:-}" ;;
    grpc)  [ -n "${DOMAIN_GRPC:-}" ]  && [ "$DOMAIN_GRPC"  != "${DOMAIN_TCP:-}" ] && echo "$DOMAIN_GRPC" ;;
    xhttp) [ -n "${DOMAIN_XHTTP:-}" ] && [ "$DOMAIN_XHTTP" != "${DOMAIN_TCP:-}" ] && echo "$DOMAIN_XHTTP" ;;
    hy2)   [ -n "${DOMAIN_HY2:-}" ]   && [ "${USE_HY2:-0}" = "1" ] && echo "$DOMAIN_HY2" ;;
  esac
  return 0
}

decoy_protos() {
  local p
  for p in "${DECOY_ORDER[@]}"; do [ -n "$(decoy_domain "$p")" ] && echo "$p"; done
  return 0
}

decoy_forced_name() {  # принудительно заданная страница для протокола
  local up="${1^^}" var
  var="DECOY_NAME_${up}"
  if [ -n "${!var:-}" ]; then echo "${!var}"
  elif [ "$1" = "tcp" ] && [ -n "${DECOY_NAME:-}" ]; then echo "$DECOY_NAME"; fi
  return 0
}

# Простая страница-заглушка, РАЗНАЯ у каждого протокола (на случай, когда архивы недоступны
# или установка страниц отключена): иначе «заглушки» на разных доменах были бы близнецами.
decoy_write_basic() {  # decoy_write_basic <proto> <root>
  local title text
  case "$1" in
    tcp)   title="Welcome";                 text="Welcome. This site is being prepared." ;;
    grpc)  title="Scheduled maintenance";   text="We are performing scheduled maintenance. Please check back later." ;;
    xhttp) title="Coming soon";             text="A new website is on its way." ;;
    hy2)   title="Service status";          text="All systems operational." ;;
    *)     title="Hello";                   text="Hello." ;;
  esac
  mkdir -p "$2"
  cat > "$2/index.html" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>${title}</title></head>
<body style="font-family:sans-serif;margin:12vh auto;max-width:36rem;color:#333"><h1>${title}</h1><p>${text}</p></body></html>
HTML
  echo "basic-$1" > "$2/.dorik-installed"
}

# Скачивает и распаковывает архив заглушки в каталог протокола (каталог предварительно очищается,
# чтобы файлы разных страниц не смешивались).
decoy_install_zip() {  # decoy_install_zip <архив.zip> <root> <рабочий каталог>
  local zip="$1" root="$2" work="$3" src
  rm -rf "$work/unzip" "$work/d.zip"
  if ! { curl -fsSL --retry 3 "${RAW:-$DORIK_RAW}/decoys/${zip}" -o "$work/d.zip" 2>/dev/null && [ -s "$work/d.zip" ]; }; then
    warn "Не удалось скачать ${zip} — пробую другую."; return 1
  fi
  mkdir -p "$work/unzip"
  if ! unzip -oq "$work/d.zip" -d "$work/unzip" 2>"$work/unzip_err.log"; then
    warn "Не удалось распаковать ${zip}: $(head -1 "$work/unzip_err.log" 2>/dev/null)"; return 1
  fi
  src="$work/unzip"
  # если внутри один каталог — используем его
  if [ "$(find "$src" -mindepth 1 -maxdepth 1 -type d | wc -l)" = "1" ] && \
     [ "$(find "$src" -mindepth 1 -maxdepth 1 | wc -l)" = "1" ]; then
    src="$(find "$src" -mindepth 1 -maxdepth 1 -type d)"
  fi
  if [ -z "$(find "$src" -mindepth 1 -maxdepth 1)" ]; then warn "Архив ${zip} распаковался пустым."; return 1; fi
  if [ ! -f "$src/index.html" ]; then warn "В архиве ${zip} нет index.html."; return 1; fi
  rm -rf "$root"; mkdir -p "$root"
  cp -rf "$src"/. "$root"/
  echo "$zip" > "$root/.dorik-installed"
  return 0
}

# ---- установка -------------------------------------------------------------------------
decoys_install() {
  local p root marker d zip work forced i
  local -a protos candidates=()
  declare -A used=() keep=()
  mapfile -t protos < <(decoy_protos)

  # Миграция со старого формата (одна заглушка /var/www/decoy на все протоколы): TCP сохраняет
  # свою страницу и порт 8081, остальные получат другие.
  if [ -f "${DECOY_WEB}/decoy/.dorik-installed" ] && [ ! -d "$(decoy_root tcp)" ]; then
    cp -a "${DECOY_WEB}/decoy" "$(decoy_root tcp)"
    info "Прежняя общая заглушка ($(cat "${DECOY_WEB}/decoy/.dorik-installed")) оставлена для REALITY TCP."
  fi

  # Уже установленные страницы (при повторном запуске) не меняем — иначе «лицо» домена
  # менялось бы при каждом запуске. В интерактивном режиме спрашиваем один раз.
  local have_any=0
  for p in "${protos[@]}"; do
    root="$(decoy_root "$p")"; marker="$root/.dorik-installed"
    [ -f "$marker" ] && [ -f "$root/index.html" ] && have_any=1
  done
  local replace=0
  if [ "$have_any" = "1" ] && [ "${NONINTERACTIVE:-0}" != "1" ] && [ "${INSTALL_DECOY:-1}" = "1" ]; then
    ask_yes_no "Заглушки уже установлены — заменить на новые?" "2" && replace=1
  fi

  if [ "${INSTALL_DECOY:-1}" != "1" ]; then
    warn "Установка страниц-заглушек отключена по выбору — каждому протоколу ставится своя простая страница."
    for p in "${protos[@]}"; do
      root="$(decoy_root "$p")"
      [ -f "$root/index.html" ] || decoy_write_basic "$p" "$root"
      ok "${DECOY_LABEL[$p]}: простая заглушка"
    done
    return 0
  fi

  for p in "${protos[@]}"; do
    root="$(decoy_root "$p")"; marker="$root/.dorik-installed"
    forced="$(decoy_forced_name "$p")"
    if [ "$replace" = "0" ] && [ -f "$marker" ] && [ -f "$root/index.html" ] && [ -z "$forced" ]; then
      keep[$p]=1
      zip="$(cat "$marker")"; used["$zip"]=1
      ok "${DECOY_LABEL[$p]}: заглушка уже установлена (${zip%.zip}) — оставляю."
    fi
  done

  work="$(mktemp -d)"
  if curl -fsSL --retry 3 "${RAW:-$DORIK_RAW}/decoys/manifest.txt" -o "$work/manifest.txt" 2>/dev/null && [ -s "$work/manifest.txt" ]; then
    # tr убирает \r (Windows-перевод строки) и пробелы — иначе имя файла получается с мусором
    # на конце и за архивом приходит 404. shuf: на каждом сервере порядок свой.
    mapfile -t candidates < <(tr -d '\r' < "$work/manifest.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '\.zip$' | shuf)
  else
    warn "manifest.txt недоступен — страницы возьму из встроенных простых."
  fi

  for p in "${protos[@]}"; do
    [ -n "${keep[$p]:-}" ] && continue
    root="$(decoy_root "$p")"
    forced="$(decoy_forced_name "$p")"
    local done_ok=0
    if [ -n "$forced" ]; then
      decoy_install_zip "$forced" "$root" "$work" && { used["$forced"]=1; done_ok=1; }
    else
      for zip in "${candidates[@]}"; do
        [ -n "${used[$zip]:-}" ] && continue          # ни одна страница не повторяется между протоколами
        if decoy_install_zip "$zip" "$root" "$work"; then used["$zip"]=1; done_ok=1; break; fi
      done
    fi
    if [ "$done_ok" = "1" ]; then
      ok "${DECOY_LABEL[$p]}: заглушка «$(sed 's/\.zip$//' "$root/.dorik-installed")»"
    else
      decoy_write_basic "$p" "$root"
      warn "${DECOY_LABEL[$p]}: свободных страниц не хватило/не скачались — поставлена своя простая заглушка."
    fi
  done
  rm -rf "$work"
  return 0
}

# ---- состояние ----------------------------------------------------------------------------
decoys_write_conf() {
  local p
  mkdir -p "$(dirname "$DECOY_CONF")"
  : > "$DECOY_CONF"
  for p in $(decoy_protos); do
    echo "${p}|$(decoy_domain "$p")|${DECOY_PORT[$p]}|$(cat "$(decoy_root "$p")/.dorik-installed" 2>/dev/null)" >> "$DECOY_CONF"
  done
  chmod 644 "$DECOY_CONF"
}

# ---- nginx -------------------------------------------------------------------------------------
# ВАЖНО: Reality «ворует» сертификат у target-сервера реальным TLS-хендшейком. Если target
# отдаёт голый HTTP или сертификат ДРУГОГО домена, self-steal ломается или выдаёт себя.
# Поэтому каждая заглушка слушает TLS с сертификатом СВОЕГО домена.
# Возвращает число заглушек, оставшихся без TLS (нет сертификата своего домена).
decoys_write_nginx() {
  local p d port root no_tls=0 keep=" "
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/decoy /etc/nginx/sites-available/decoy   # прежняя единая заглушка
  for p in $(decoy_protos); do
    d="$(decoy_domain "$p")"; port="${DECOY_PORT[$p]}"; root="$(decoy_root "$p")"
    keep+="decoy-$p "
    if cert_is_valid "$d"; then
      cat > "/etc/nginx/sites-available/decoy-$p" <<EOF
# DORIK toolkit — заглушка протокола ${DECOY_LABEL[$p]} (${d})
server {
    listen 127.0.0.1:${port} ssl;
    server_name ${d};
    server_tokens off;
    ssl_certificate /etc/letsencrypt/live/${d}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${d}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${root};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    else
      no_tls=$((no_tls+1))
      warn "${DECOY_LABEL[$p]}: нет сертификата для ${d} — заглушка пока без TLS (self-steal не заработает, пока не выпущен сертификат; перезапустите скрипт)."
      cat > "/etc/nginx/sites-available/decoy-$p" <<EOF
# DORIK toolkit — заглушка протокола ${DECOY_LABEL[$p]} (${d}) БЕЗ TLS: нет сертификата
server {
    listen 127.0.0.1:${port};
    server_name _;
    server_tokens off;
    root ${root};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    fi
    ln -sf "/etc/nginx/sites-available/decoy-$p" "/etc/nginx/sites-enabled/decoy-$p"
  done
  # заглушки протоколов, которые больше не используются
  local f b
  for f in /etc/nginx/sites-enabled/decoy-*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    b="$(basename "$f")"
    [[ "$keep" == *" $b "* ]] || { rm -f "$f" "/etc/nginx/sites-available/$b"; }
  done
  return "$no_tls"
}

# ---- проверка -------------------------------------------------------------------------------------
# Для каждого протокола: отвечает 200, отдаёт сертификат СВОЕГО домена; страницы всех протоколов
# различаются. Возвращает число провалов.
decoys_verify() {
  local p d port code body hash fails=0 tls other
  declare -A hash_of=()
  body="$(mktemp)"
  for p in $(decoy_protos); do
    d="$(decoy_domain "$p")"; port="${DECOY_PORT[$p]}"
    if cert_is_valid "$d"; then
      code="$(curl -sk -o "$body" -w '%{http_code}' --max-time 5 --resolve "${d}:${port}:127.0.0.1" "https://${d}:${port}/" 2>/dev/null || echo 000)"
      if echo | openssl s_client -connect "127.0.0.1:${port}" -servername "$d" 2>/dev/null | openssl x509 -noout -checkhost "$d" 2>/dev/null | grep -q 'does match'; then
        tls="ok"
      else
        tls="bad"
      fi
    else
      code="$(curl -s -o "$body" -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
      tls="none"
    fi
    if [ "$code" = "200" ] && [ "$tls" = "ok" ]; then
      ok "заглушка ${DECOY_LABEL[$p]} (127.0.0.1:${port}): 200, сертификат ${d} верный"
    elif [ "$code" = "200" ] && [ "$tls" = "none" ]; then
      err "заглушка ${DECOY_LABEL[$p]} (127.0.0.1:${port}): отвечает без TLS — нет сертификата ${d}"; fails=$((fails+1))
    elif [ "$code" = "200" ]; then
      err "заглушка ${DECOY_LABEL[$p]} (127.0.0.1:${port}): сертификат не подходит к ${d}"; fails=$((fails+1))
    else
      err "заглушка ${DECOY_LABEL[$p]} (127.0.0.1:${port}): код ${code} (ожидался 200)"; fails=$((fails+1))
    fi
    hash="$(md5sum < "$body" | cut -d' ' -f1)"
    if [ -n "${hash_of[$hash]:-}" ]; then
      other="${hash_of[$hash]}"
      err "заглушки ${DECOY_LABEL[$other]} и ${DECOY_LABEL[$p]} одинаковы — у каждого протокола должна быть своя"; fails=$((fails+1))
    else
      hash_of[$hash]="$p"
    fi
  done
  rm -f "$body"
  [ "${#hash_of[@]}" -gt 1 ] && [ "$fails" -eq 0 ] && ok "заглушки всех протоколов (${#hash_of[@]}) различаются"
  return "$fails"
}

# Таблица «протокол → домен → адрес заглушки» для настройки профиля на панели.
decoys_table() {
  [ -f "$DECOY_CONF" ] || return 0
  local p d port zip
  box_top "Заглушки по протоколам"
  while IFS='|' read -r p d port zip; do
    [ -n "$p" ] || continue
    box_row "${C_B}${DECOY_LABEL[$p]:-$p}${C_RESET}  ${d}"
    box_row "  dest → ${C_BOLD}127.0.0.1:${port}${C_RESET}  ${C_DIM}(${zip%.zip})${C_RESET}"
  done < "$DECOY_CONF"
  box_sep
  box_wrap "${C_DIM}→${C_RESET}" "В профиле Xray на панели укажите этот адрес как dest (target) для REALITY нужного протокола; для Hysteria2 — как адрес masquerade, если он у вас включён."
  box_bottom
}
