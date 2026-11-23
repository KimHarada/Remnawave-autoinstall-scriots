#!/usr/bin/env bash
# DORIK toolkit — профиль Xray и хосты на панели Remnawave ПО API.
#
# Вы указываете адрес панели и API-токен (+ домены протоколов) — скрипт сам:
#   1. генерирует конфиг Xray для всех протоколов: REALITY TCP, gRPC, XHTTP, Hysteria2
#      и (по желанию) отдельный Telegram-хост. У КАЖДОГО протокола свои приватный ключ x25519,
#      shortId, fingerprint, SNI (= домен протокола) и своя заглушка (target = decoys.sh);
#   2. создаёт на панели профиль с этим конфигом (или обновляет прежний — ключи сохраняются);
#   3. создаёт хосты (по одному на протокол) с нужными sni / fingerprint / path / alpn;
#   4. добавляет inbound'ы в сквад, чтобы они попали в подписки пользователей;
#   5. (по желанию) создаёт на панели ноду этого сервера и привязывает профиль.
#
#   profile-setup.sh          — интерактивно (домены берутся из /etc/dorik/decoys.conf)
#   profile-setup.sh --show   — показать сохранённые параметры профиля
#   profile-setup.sh --exit-file — собрать параметры каскада на выходной ноде
#
# Без вопросов (ASSUME_YES=1):
#   PANEL_URL        адрес панели; можно ссылку для входа с секретом (?ключ=значение) — он
#                    передаётся как cookie, иначе nginx-защита панели не пропустит API
#   PANEL_API_TOKEN  токен (панель → Настройки → API-токены)
#   PROFILE_PREFIX (NL) · PROFILE_NAME · COUNTRY_CODE · PSIPHON=1|0 · PROFILE_CREATE_NODE=1|0
#   FINAL_MASK=1|0 (фрагментация ClientHello на TCP-хостах; своя маска: FINAL_MASK_JSON)
#   PROFILE_ROUTE=direct|vless|hysteria2 · PROFILE_EXIT_FILE=/etc/dorik/exit.json
#   NODE_ADDRESS (по умолчанию публичный IP) · TG_EXTRA_DOMAINS="a.com b.com"
#   RW_CURL_OPTS — доп. параметры curl (например -k для самоподписанного сертификата)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
    t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
  } || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
  _dorik_source state.sh
  _dorik_source decoys.sh
  _profile_standalone=1
else
  _profile_standalone=0
fi

PROFILE_STATE=/etc/dorik/profile.json
# Только отпечатки, проверенные с REALITY на реальном Xray 26.x. Отпечатки «360» и «android»
# в тесте НЕ проходят рукопожатие REALITY (соединение зависает), хотя Xray их принимает в конфиге —
# поэтому их в пуле нет, а у ранее сохранённых они заменяются (см. state_prepare).
FINGERPRINTS=(chrome firefox safari ios edge qq)
BAD_FINGERPRINTS=(360 android random randomized)
declare -gA PDOM=()      # протокол -> домен
PROTO_ORDER=(tcp grpc xhttp hy2 tg)
RW_BASE=""; RW_TOKEN=""; RW_COOKIE=""; RW_BODY=""; RW_LAST_CODE=0

# ---- клиент API ----------------------------------------------------------------------------
# Разбирает адрес панели. Секретная ссылка (?ключ=значение) превращается в cookie: именно её
# ждёт nginx-защита панели, созданная установщиком.
rw_parse_url() {
  local u="$1" base q
  base="$(sed -E 's#^(https?://[^/?\#]+).*#\1#' <<<"$u")"
  q="$(sed -nE 's#^[^?]*\?([^\#]*).*#\1#p' <<<"$u")"
  [[ "$base" =~ ^https?://[^/]+$ ]] || return 1
  RW_BASE="$base"; RW_COOKIE=""
  [ -n "$q" ] && RW_COOKIE="${q%%&*}"
  return 0
}

rw_api() {  # rw_api <METHOD> <path> [json-тело] — тело ответа в RW_BODY, код в RW_LAST_CODE
  local m="$1" p="$2" body="${3:-}" out hdr rc
  # Токен и секретный cookie передаём через файл заголовков (права 600), а не аргументами:
  # аргументы curl видны любому пользователю сервера в `ps`.
  hdr="$(mktemp)" || return 1
  {
    echo "Authorization: Bearer ${RW_TOKEN}"
    [ -n "$RW_COOKIE" ] && echo "Cookie: ${RW_COOKIE}"
    case "$RW_BASE" in http://*) echo 'X-Forwarded-For: 127.0.0.1'; echo 'X-Forwarded-Proto: https' ;; esac
  } > "$hdr"
  # --connect-timeout 10: недоступная панель определяется за 10 секунд, а не за 40.
  local -a args=(-sS --connect-timeout 10 --max-time 40 -X "$m" -H "@${hdr}" -H 'Content-Type: application/json')
  # shellcheck disable=SC2206
  [ -n "${RW_CURL_OPTS:-}" ] && args+=($RW_CURL_OPTS)
  [ "${PROFILE_ROUTE:-direct}" != direct ] && args+=(--no-insecure)
  # В конфиге могут быть ключи REALITY и пароль выходной ноды. Передаём тело по stdin.
  [ -n "$body" ] && args+=(--data-binary @-)
  [ "${RW_FORCE4:-0}" = "1" ] && args+=(-4)
  out="$(curl "${args[@]}" -w $'\n%{http_code}' "${RW_BASE}${p}" 2>&1 <<<"$body")"; rc=$?
  # Повторяем GET после таймаута, но для записи результат уже мог примениться на панели.
  # При отказе соединения (код 7) запрос не дошёл до сервера, повтор безопасен.
  # Повторяем до двух раз по IPv4 с паузой — сбой установки
  # соединения часто разовый (так и бывает с панелью за защитой хостера: первая попытка зависает,
  # вторая проходит сразу). Если у домена есть IPv6-адрес, а он не отвечает, дальше ходим только по IPv4.
  local attempt=1 host has6=0
  while { [ "$rc" -eq 7 ] || { [ "$m" = GET ] && [ "$rc" -eq 28 ]; }; } && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt+1))
    sleep 2
    out="$(curl "${args[@]}" -4 -w $'\n%{http_code}' "${RW_BASE}${p}" 2>&1 <<<"$body")"; rc=$?
    if [ "$rc" -eq 0 ]; then
      host="${RW_BASE#*://}"; host="${host%%[:/]*}"
      getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | grep -q ':' && has6=1
      if [ "$has6" = "1" ]; then
        RW_FORCE4=1
        warn "У домена панели есть IPv6-адрес, но он не отвечает — дальше работаю по IPv4 (проверьте IPv6 на сервере или уберите AAAA-запись домена)."
      elif [ "${RW_RETRY_NOTED:-0}" != "1" ]; then
        RW_RETRY_NOTED=1
        info "Первое соединение с панелью не удалось, со второй попытки прошло — это разовые сбои сети или защиты хостера."
      fi
    fi
  done
  rm -f "$hdr"
  if [ "$rc" -ne 0 ]; then
    RW_LAST_CODE=000; RW_BODY="$out"; return 1
  fi
  RW_LAST_CODE="${out##*$'\n'}"; RW_BODY="${out%$'\n'*}"
  [[ "$RW_LAST_CODE" =~ ^2 ]]
}

rw_fail() {  # rw_fail <что делали> — понятное сообщение об ошибке API
  local msg
  if [ "$RW_LAST_CODE" = "000" ]; then
    local host ips
    host="${RW_BASE#*://}"; host="${host%%[:/]*}"
    ips="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    err "$1: панель недоступна по ${RW_BASE} (${RW_BODY:0:120})"
    if [ -z "$ips" ]; then
      err "Имя ${host} не разрешается в IP: проверьте DNS-запись домена панели."
    else
      err "${host} → ${ips}"
      err "С ЭТОГО сервера до панели нет соединения: панель должна быть доступна с IP ноды (firewall панели или хостера, Cloudflare, блокировка по IP/стране, блок-лист сетей на сервере панели)."
      err "Проверка вручную:  curl -4 -vI --max-time 10 ${RW_BASE}    и    curl -6 -vI --max-time 10 ${RW_BASE}"
    fi
    return 1
  fi
  msg="$(jq -r '[.message // empty, (.errors[]? | "\(.path|join(".")): \(.message)")] | map(select(. != null)) | .[0:3] | join("; ")' <<<"$RW_BODY" 2>/dev/null)"
  err "$1: HTTP ${RW_LAST_CODE}${msg:+ — ${msg}}"
  case "$RW_LAST_CODE" in
    401) err "Токен отклонён: создайте новый в панели (Настройки → API-токены)." ;;
    403) err "Доступ запрещён: проверьте токен и секретную ссылку панели (?ключ=значение)." ;;
  esac
  return 1
}

rw_check() {  # проверка адреса и токена
  rw_api GET /api/config-profiles || { rw_fail "Проверка доступа к API"; return 1; }
  ok "API панели доступен, токен принят"
}

# ---- секреты ------------------------------------------------------------------------------------
gen_x25519() {  # печатает «приватный публичный» в base64url без padding — формат Xray
  local pem priv pub
  pem="$(openssl genpkey -algorithm x25519 2>/dev/null)" || return 1
  priv="$(printf '%s' "$pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  pub="$(printf '%s' "$pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  [ "${#priv}" -eq 43 ] && [ "${#pub}" -eq 43 ] || return 1
  echo "$priv $pub"
}

st_get() { jq -r "$1 // empty" "$PROFILE_STATE" 2>/dev/null; }
st_set() {  # st_set <jq-фильтр с --arg/--argjson через переменные окружения не нужен: передаём готовый фильтр>
  local tmp
  tmp="$(mktemp "${PROFILE_STATE}.XXXXXX")" || return 1
  if jq "$@" "$PROFILE_STATE" > "$tmp" && mv -f -- "$tmp" "$PROFILE_STATE"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

# ---- сбор параметров --------------------------------------------------------------------------------
profile_exit_config() {
  local mode="${PROFILE_ROUTE:-direct}" file="${PROFILE_EXIT_FILE:-/etc/dorik/exit.json}" meta
  case "$mode" in
    direct) printf 'null\n'; return 0 ;;
    vless|hysteria2) ;;
    *) err "Неизвестный режим маршрутизации. Допустимы direct, vless и hysteria2."; return 1 ;;
  esac

  if [ ! -f "$file" ] || [ -L "$file" ]; then
    err "Для каскада укажите обычный JSON-файл с параметрами выхода: $file"
    return 1
  fi
  meta="$(stat -c '%u:%a' -- "$file" 2>/dev/null)" || return 1
  if [ "$meta" != "$EUID:600" ] && [ "$meta" != "$EUID:400" ]; then
    err "Файл выхода должен принадлежать пользователю, запустившему скрипт, и иметь права 600 или 400."
    return 1
  fi

  jq -cse --arg mode "$mode" --arg self "${NODE_ADDRESS:-}" '
    def dnsname: type=="string" and length<=253 and
      test("^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z][a-zA-Z0-9-]{0,62}$");
    def ipv4: type=="string" and test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") and
      (split(".") | all(.[]; tostring == (tonumber|tostring) and tonumber<=255)) and
      (split(".")[0] | tonumber | .>0 and .!=127 and .<224);
    def port: type=="number" and floor==. and .>=1 and .<=65535;
    def uuid: type=="string" and
      test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
    def short_id: type=="string" and test("^([0-9a-f]{2}){1,8}$");

    if length!=1 then error("expected one object") else .[0] end
    | select(type=="object" and .protocol==$mode and
      (.address | dnsname or ipv4) and (.serverName | dnsname) and
      (.port | port) and (.address|ascii_downcase)!=($self|ascii_downcase))
    | if $mode=="vless" then
        select((.uuid|uuid) and (.publicKey|type=="string" and test("^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$")) and
          (.shortId|short_id))
        | select((has("vision")|not) or (.vision|type=="boolean"))
        | {tag:"EXIT", protocol:"vless",
           settings:{vnext:[{address, port, users:[{id:.uuid, encryption:"none"}
             + (if .vision then {flow:"xtls-rprx-vision"} else {} end)]}]},
           streamSettings:{network:"raw", security:"reality",
             realitySettings:{serverName, fingerprint:"chrome", password:.publicKey, shortId}}}
      else
        select(.auth|type=="string" and length>0 and length<=1024 and (test("[[:cntrl:]]")|not))
        | {tag:"EXIT", protocol:"hysteria", settings:{address, port, version:2},
           streamSettings:{network:"hysteria", security:"tls",
             tlsSettings:{serverName, alpn:["h3"], minVersion:"1.3"},
             hysteriaSettings:{version:2, auth}}}
      end' 2>/dev/null <"$file" || {
    err "Проверьте протокол, адрес, SNI, порт и данные доступа выходной ноды в $file."
    return 1
  }
}

profile_route_label() {
  case "${PROFILE_ROUTE:-direct}" in
    vless) printf 'Клиент → вход → выход по VLESS Reality\n' ;;
    hysteria2) printf 'Клиент → вход → выход по Hysteria2\n' ;;
    *) printf 'Клиент → нода → интернет\n' ;;
  esac
}

profile_check_exit_address() {
  local address local_address domain ip own_ips exit_ips
  address="$(jq -r '.settings.address // .settings.vnext[0].address // empty')"
  [ -n "$address" ] || return 0
  local_address="${SELF_IP:-${NODE_ADDRESS:-}}"
  for domain in "${PDOM[@]}" "$local_address"; do
    if [ "${address,,}" = "${domain,,}" ]; then
      err "Адрес выхода совпадает с адресом входной ноды: $address"
      return 1
    fi
  done
  exit_ips="$(getent ahosts "$address" | awk '{print $1}' | sort -u)"
  own_ips="$(ip -o addr show | awk '{split($4, address, "/"); print address[1]}')"
  own_ips+=$'\n'"${local_address:-$(get_public_ip)}"
  while IFS= read -r ip; do
    if [ -n "$ip" ] && [[ $'\n'"${own_ips}"$'\n' == *$'\n'"${ip}"$'\n'* ]]; then
      err "Выходная нода разрешается в IP входной ноды: $ip"
      return 1
    fi
  done <<<"$exit_ips"
}

profile_collect_route() {
  local mode="${PROFILE_ROUTE:-$(st_get '.route.mode')}" def=1
  if [ "${ASSUME_YES:-0}" != "1" ] && [ "${1:-}" != resume ]; then
    case "$mode" in vless) def=2 ;; hysteria2) def=3 ;; esac
    ask_choice "Маршрут трафика" "$def" \
      "Одна нода|Этот сервер принимает подключения клиентов и выходит в интернет." \
      "Каскад · VLESS Reality|Эта нода принимает подключения. До отдельной выходной ноды трафик идёт по TCP через VLESS Reality." \
      "Каскад · Hysteria2|Эта нода принимает подключения. До отдельной выходной ноды трафик идёт по QUIC через Hysteria2." || return 1
    case "$CHOICE" in 1) mode=direct ;; 2) mode=vless ;; 3) mode=hysteria2 ;; esac
  fi
  PROFILE_ROUTE="${mode:-direct}"
  if [ "$PROFILE_ROUTE" != direct ]; then
    PROFILE_EXIT_FILE="${PROFILE_EXIT_FILE:-$(st_get '.route.file')}"
    PROFILE_EXIT_FILE="${PROFILE_EXIT_FILE:-/etc/dorik/exit.json}"
    if [ "${1:-}" != resume ]; then
      PROFILE_EXIT_FILE="$(ask_value "JSON-файл с параметрами выходной ноды" "$PROFILE_EXIT_FILE")" || return 1
    fi
    [[ "$PROFILE_EXIT_FILE" = /* ]] || { err "Укажите абсолютный путь к файлу выходной ноды."; return 1; }
  fi
  profile_exit_config >/dev/null
}

profile_export_exit() {
  local p mode domain address port public_key="" sid="" credential vision=false file tmp
  have jq || { err "Для экспорта нужен jq."; return 1; }
  [ "${ASSUME_YES:-0}" != "1" ] || { err "Для экспорта данных сервисного пользователя нужен терминал."; return 1; }
  [ -s "$PROFILE_STATE" ] || { err "Сначала настройте профиль на выходной ноде."; return 1; }
  case "$(st_get '.route.mode')" in
    vless|hysteria2) err "Выберите «Одна нода» в профиле сервера, который будет выходить в интернет."; return 1 ;;
  esac
  ask_choice "Выходная нода" 1 \
    "VLESS Reality|Экспорт данных настроенного входа VLESS Reality TCP и UUID сервисного пользователя." \
    "Hysteria2|Экспорт настроенного порта, имени сертификата и пароля сервисного пользователя." || return 1
  case "$CHOICE" in
    1) p=tcp; mode=vless; port=443 ;;
    2) p=hy2; mode=hysteria2; port="$(hy2_port)" ;;
  esac
  load_domains && domain="${PDOM[$p]:-}"
  [ -n "${domain:-}" ] && [ "$domain" = "$(st_get ".protocols.$p.domain")" ] || {
    err "Выбранный протокол отсутствует в текущем профиле этой ноды."
    return 1
  }
  address="$(ask_value "Адрес выходной ноды (домен или IPv4)" "$domain")" || return 1
  port="$(ask_valid "Внешний порт выходной ноды" "$port" is_valid_port)" || return 1
  if [ "$mode" = vless ]; then
    public_key="$(st_get '.protocols.tcp.publicKey')"
    sid="$(st_get '.protocols.tcp.shortIds[0]')"
    if ask_yes_no "У сервисного пользователя на выходе включён XTLS Vision?" 2; then vision=true; fi
    read -rs -p "  VLESS UUID сервисного пользователя: " credential <"$(prompt_input)" || return 1
  else
    read -rs -p "  Пароль Hysteria2 сервисного пользователя: " credential <"$(prompt_input)" || return 1
  fi
  printf '\n' >&2
  file="$(ask_value "Куда записать параметры выхода" /etc/dorik/exit.json)" || return 1
  [[ "$file" == /* ]] || { err "Укажите абсолютный путь для файла."; return 1; }
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if printf '%s\n' "$credential" |
      jq -R --arg protocol "$mode" --arg address "$address" --arg sni "$domain" --arg port "$port" \
        --arg key "$public_key" --arg sid "$sid" --argjson vision "$vision" '
          . as $credential | {protocol:$protocol, address:$address, port:($port|tonumber), serverName:$sni}
          + (if $protocol=="vless" then {uuid:$credential, publicKey:$key, shortId:$sid, vision:$vision}
             else {auth:$credential} end)' > "$tmp" &&
      PROFILE_ROUTE="$mode" PROFILE_EXIT_FILE="$tmp" NODE_ADDRESS= profile_exit_config >/dev/null &&
      ln -T -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    ok "Файл создан с правами 600: $file"
    info "Передайте его по SSH на входную ноду и укажите путь в меню маршрутизации."
    return 0
  fi
  rm -f -- "$tmp"
  err "Файл выхода не создан. Проверьте параметры и укажите свободный путь."
  return 1
}

# Домены протоколов: из /etc/dorik/decoys.conf (их уже настроил haproxy-setup) либо из DOMAIN_*.
load_domains() {
  PDOM=()
  local p d
  if [ -s "${DECOY_CONF:-/etc/dorik/decoys.conf}" ]; then
    while IFS='|' read -r p d _; do [ -n "$p" ] && PDOM[$p]="$d"; done < "${DECOY_CONF:-/etc/dorik/decoys.conf}"
  else
    [ -n "${DOMAIN_TCP:-}" ]   && PDOM[tcp]="$DOMAIN_TCP"
    [ -n "${DOMAIN_GRPC:-}" ]  && PDOM[grpc]="$DOMAIN_GRPC"
    [ -n "${DOMAIN_XHTTP:-}" ] && PDOM[xhttp]="$DOMAIN_XHTTP"
    [ -n "${DOMAIN_HY2:-}" ] && [ "${USE_HY2:-0}" = "1" ] && PDOM[hy2]="$DOMAIN_HY2"
    [ -n "${DOMAIN_TG:-}" ]  && [ "${USE_TG:-0}" = "1" ]  && PDOM[tg]="$DOMAIN_TG"
  fi
  [ "${#PDOM[@]}" -gt 0 ]
}

declare -gA P_TAG=() P_PORT=() P_TARGET=() P_REMARK=()
define_protocols() {
  local px="$1"
  P_TAG=( [tcp]="${px}VLESS_REALITY_TCP" [grpc]="${px}VLESS_GRPC" [xhttp]="${px}VLESS_XHTTP" [hy2]="${px}HYSTERIA2_MAIN" [tg]="${px}VLESS_TELEGRAM" )
  P_PORT=( [tcp]=56789 [grpc]=56790 [xhttp]=56791 [tg]=56792 [hy2]=443 )         # где слушает Xray (HAProxy -> 127.0.0.1:порт)
  P_TARGET=( [tcp]="127.0.0.1:${DECOY_PORT[tcp]:-8081}" [grpc]="127.0.0.1:${DECOY_PORT[grpc]:-8082}" \
             [xhttp]="127.0.0.1:${DECOY_PORT[xhttp]:-8083}" [tg]="127.0.0.1:${DECOY_PORT[tg]:-8085}" )
  P_REMARK=( [tcp]="${px} REALITY TCP" [grpc]="${px} gRPC" [xhttp]="${px} XHTTP" [hy2]="${px} Hysteria2" [tg]="${px} Telegram" )
}

# Создаёт состояние (если нет) и доводит его до полного: недостающим протоколам — свои ключи,
# shortId, fingerprint. Уже сохранённое НЕ меняется: ключи привязаны к выданным клиентам.
state_prepare() {
  local px="$1" name="$2" p fp pair used s1 s2 s3
  [ -s "$PROFILE_STATE" ] || (umask 077; printf '%s\n' '{"protocols":{}}' > "$PROFILE_STATE") || return 1
  chmod 600 "$PROFILE_STATE" || return 1
  st_set --arg px "$px" --arg name "$name" '.prefix=$px | .name=$name' || return 1

  used=" $(jq -r '[.protocols[]?.fingerprint // empty] | join(" ")' "$PROFILE_STATE") "
  local -a pool=()
  for fp in $(printf '%s\n' "${FINGERPRINTS[@]}" | shuf); do [[ "$used" == *" $fp "* ]] || pool+=("$fp"); done
  [ "${#pool[@]}" -gt 0 ] || pool=("${FINGERPRINTS[@]}")

  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    st_set --arg p "$p" --arg d "${PDOM[$p]}" --arg t "${P_TAG[$p]}" '.protocols[$p].domain=$d | .protocols[$p].tag=$t' || return 1
    [ "$p" = "hy2" ] && continue                                      # у Hysteria2 нет Reality-ключей
    if [ -z "$(st_get ".protocols.${p}.privateKey")" ]; then
      pair="$(gen_x25519)" || { err "Не удалось сгенерировать ключ x25519 (openssl)"; return 1; }
      s1="$(openssl rand -hex 8)" && s2="$(openssl rand -hex 4)" && s3="$(openssl rand -hex 6)" || return 1
      st_set --arg p "$p" --rawfile pair /dev/stdin --arg s1 "$s1" --arg s2 "$s2" --arg s3 "$s3" '
        ($pair | rtrimstr("\n") | split(" ")) as [$private, $public]
        | .protocols[$p] += {privateKey:$private, publicKey:$public, shortIds:[$s1,$s2,$s3]}' <<<"$pair" || return 1
    fi
    local cur_fp bad
    cur_fp="$(st_get ".protocols.${p}.fingerprint")"
    for bad in "${BAD_FINGERPRINTS[@]}"; do [ "$cur_fp" = "$bad" ] && cur_fp=""; done
    if [ -z "$cur_fp" ]; then
      fp="${pool[0]}"; pool=("${pool[@]:1}"); [ "${#pool[@]}" -gt 0 ] || pool=("${FINGERPRINTS[@]}")
      st_set --arg p "$p" --arg f "$fp" '.protocols[$p].fingerprint=$f' || return 1
    fi
  done
  if [ -n "${PDOM[grpc]:-}" ] && [ -z "$(st_get '.protocols.grpc.serviceName')" ]; then
    st_set --arg v "$(openssl rand -hex 8)" '.protocols.grpc.serviceName=$v' || return 1
  fi
  if [ -n "${PDOM[xhttp]:-}" ] && [ -z "$(st_get '.protocols.xhttp.path')" ]; then
    st_set --arg v "/api/v2/sync-$(openssl rand -hex 6)" '.protocols.xhttp.path=$v' || return 1
  fi
  return 0
}

# ---- конфиг Xray ---------------------------------------------------------------------------------------
build_inbound() {  # build_inbound <proto> — JSON одного inbound'а
  local p="$1" d tag fp priv serv path
  d="${PDOM[$p]}"; tag="${P_TAG[$p]}"
  case "$p" in
    hy2)
      jq -n --arg tag "$tag" --arg dir "$(decoy_root hy2)" --argjson port "$(hy2_port)" '{
        tag:$tag, port:$port, listen:"0.0.0.0", protocol:"hysteria",
        settings:{clients:[], version:2},
        sniffing:{enabled:true, routeOnly:true, destOverride:["http","tls","quic"]},
        streamSettings:{network:"hysteria", security:"tls",
          tlsSettings:{minVersion:"1.3", alpn:["h3"], certificates:[{keyFile:"/etc/hysteria/privkey.pem", certificateFile:"/etc/hysteria/fullchain.pem"}]},
          hysteriaSettings:{version:2, masquerade:{dir:$dir, type:"file"}}}}' ;;
    *)
      local net="raw" extra='{}' key="" hard='{}' settings
      settings="$(jq -ce --arg p "$p" '.protocols[$p] | select(.privateKey and (.shortIds|length>0))' "$PROFILE_STATE")" || return 1
      # Защита от активного зондирования (SCAN_PROTECT=1):
      #  - maxTimeDiff (по умолчанию ВЫКЛЮЧЕН): отбрасывает рукопожатие, если часы клиента расходятся с
      #    сервером больше заданного (мс). Защищает от повтора перехваченного ClientHello, но у части
      #    клиентов часы уходят и подключение «молча» ломается — включайте REALITY_MAXTIMEDIFF=90000 осознанно;
      #  - limitFallback*: канал «запасного» сайта (при неверном ключе) ограничен по скорости,
      #    чтобы сервер нельзя было использовать как ретранслятор.
      if [ "${SCAN_PROTECT:-1}" = "1" ]; then
        hard="$(jq -nc --argjson t "${REALITY_MAXTIMEDIFF:-0}" '
          (if $t > 0 then {maxTimeDiff:$t} else {} end)
          + {limitFallbackUpload:{afterBytes:65536, bytesPerSec:16384, burstBytesPerSec:65536},
             limitFallbackDownload:{afterBytes:65536, bytesPerSec:16384, burstBytesPerSec:65536}}')" || return 1
      fi
      if [ "$p" = "grpc" ]; then
        serv="$(jq -er '.serviceName | select(length>0)' <<<"$settings")" || return 1
        net="grpc"; key="grpcSettings"; extra="$(jq -n --arg s "$serv" '{multiMode:true, serviceName:$s}')"
      elif [ "$p" = "xhttp" ]; then
        path="$(jq -er '.path | select(length>0)' <<<"$settings")" || return 1
        net="xhttp"; key="xhttpSettings"; extra="$(jq -n --arg h "$d" --arg pa "$path" '{host:$h, mode:"auto", path:$pa}')"
      fi
      jq --arg tag "$tag" --argjson port "${P_PORT[$p]}" --arg target "${P_TARGET[$p]}" \
            --arg sn "$d" --arg net "$net" --arg key "$key" --argjson extra "$extra" --argjson hard "$hard" '
        {tag:$tag, port:$port, listen:"127.0.0.1", protocol:"vless",
         settings:{clients:[], decryption:"none"},
         sniffing:{enabled:true, routeOnly:true, destOverride:["http","tls","quic"]},
         streamSettings: ({network:$net, security:"reality",
           realitySettings:({target:$target, spiderX:(.spiderX // "/"), shortIds, privateKey, fingerprint, serverNames:[$sn]} + $hard)}
           + (if $key != "" then {($key): $extra} else {} end))}' <<<"$settings" ;;
  esac
}

_self_ip() {  # публичный IPv4 ноды для правила «на сам сервер не ходить»; пусто, если неизвестен
  local ip="${SELF_IP:-${NODE_ADDRESS:-}}"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$ip"
  return 0
}

build_config() {  # stdin: объект выхода или null; stdout: конфиг Xray
  local p inbound exit_config tg_tag=""
  local -a inbounds=()
  IFS= read -r exit_config || return 1
  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    inbound="$(build_inbound "$p")" || return 1
    inbounds+=("$inbound")
    [ "$p" = "tg" ] && tg_tag="${P_TAG[tg]}"
  done
  [ "${#inbounds[@]}" -gt 0 ] || return 1
  printf '%s\n' "$exit_config" "${inbounds[@]}" |
  jq -s --arg tg "$tg_tag" --arg extra "${TG_EXTRA_DOMAINS:-}" \
        --arg psiphon "${PSIPHON:-1}" --arg ll "${XRAY_LOGLEVEL:-warning}" \
        --arg self "$(_self_ip)" --arg prot "${SCAN_PROTECT:-1}" \
        --arg opt "${XRAY_OPTIMIZE:-1}" --arg ads "${BLOCK_ADS:-0}" '
    # XRAY_OPTIMIZE=1 (по умолчанию):
    #  - IPOnDemand проверяет IP домена до завершающего правила по тегу входа.
    #  - DNS: ответы кэшируются, просроченный ответ отдаётся сразу и обновляется в фоне (serveStale) —
    #    повторные подключения не ждут резолвера;
    #  - исходящие соединения: keepalive (зависшие соединения закрываются, а не копятся) и TCP Fast Open.
    # BLOCK_ADS=1 — рекламные и трекерные домены в BLOCK (geosite:category-ads-all).
    .[0] as $exit | .[1:] as $inbounds
    | [$inbounds[] | .tag | select(.!=$tg)] as $tags
    | (if $exit then "EXIT" else "DIRECT" end) as $out
    | ($exit==null and $psiphon=="1") as $use_psiphon
    | (["geosite:telegram","domain:telegram.org","domain:t.me","domain:telegra.ph","domain:yookassa.ru","domain:yoomoney.ru",
        "full:cp.cloudflare.com","full:www.gstatic.com","full:connectivitycheck.gstatic.com","full:clients3.google.com","full:www.google.com"]
        + ($extra | split(" ") | map(select(length>0) | "domain:" + .))) as $tgd
    | {log:{loglevel:$ll},
     dns:({servers:["https+local://1.1.1.1/dns-query","https+local://8.8.8.8/dns-query","localhost"]}
       + (if $opt=="1" then {serveStale:true, serveExpiredTTL:3600} else {} end)),
     inbounds:$inbounds,
     outbounds:(if $exit then [{tag:"BLOCK", protocol:"blackhole"}, $exit]
       else [({tag:"DIRECT", protocol:"freedom", settings:{domainStrategy:"UseIP"}}
          + (if $opt=="1" then {streamSettings:{sockopt:{tcpFastOpen:true, tcpKeepAliveIdle:120, tcpKeepAliveInterval:30}}} else {} end)),
        {tag:"BLOCK", protocol:"blackhole"}]
       + (if $use_psiphon then [{tag:"psiphon-out", protocol:"socks", settings:{port:1080, address:"172.17.0.1"}}] else [] end)
       end),
     routing:((if $opt=="1" or $exit then {domainStrategy:"IPOnDemand"} else {} end) + {rules:(
       [{type:"field", domain:["geosite:private"], outboundTag:"BLOCK"},
        {type:"field", ip:["geoip:private"], outboundTag:"BLOCK"},
        {type:"field", protocol:["bittorrent"], outboundTag:"BLOCK"},
        {port:"25", type:"field", network:"tcp", outboundTag:"BLOCK"}]
       + (if $ads=="1" then [{type:"field", domain:["geosite:category-ads-all"], outboundTag:"BLOCK"}] else [] end)
       # Через прокси нельзя ходить на сам сервер (SSH/панель/внутренние сервисы по публичному IP)
       # и на порты, которые чаще всего используют для сканирования и брутфорса (telnet, NetBIOS/SMB, RDP).
       + (if $prot == "1" and $self != "" then [{type:"field", ip:[$self], outboundTag:"BLOCK"}] else [] end)
       + (if $prot == "1" then [{type:"field", port:"23,135-139,445,3389", outboundTag:"BLOCK"}] else [] end)
       + (if $tg != "" then
            [{type:"field", inboundTag:[$tg], domain:$tgd, outboundTag:$out},
             {type:"field", inboundTag:[$tg], ip:["geoip:telegram"], outboundTag:$out},
             {type:"field", inboundTag:[$tg], outboundTag:"BLOCK"}]
          else [] end)
       + (if $use_psiphon then
            [{type:"field", domain:["domain:gemini.google.com","domain:generativelanguage.googleapis.com","domain:ai.google.dev","domain:aistudio.google.com","domain:alkalimakersuite-pa.clients6.google.com","geosite:google-deepmind"], outboundTag:"psiphon-out"}]
          else [] end)
       + [{port:"443", type:"field", domain:["geosite:facebook","geosite:instagram","domain:fbcdn.net","domain:cdninstagram.com"], network:"udp", outboundTag:"BLOCK"}]
       + (if $tags!=[] then [{type:"field", inboundTag:$tags, outboundTag:$out}] else [] end))})}'
}

# ---- профиль, хосты, сквад, нода -------------------------------------------------------------------
upsert_profile() {  # upsert_profile <имя> <json-конфиг> → PROFILE_UUID
  local name="$1" cfg="$2" uuid payload
  uuid="$(st_get '.profileUuid')"
  if [ -n "$uuid" ] && rw_api GET "/api/config-profiles/${uuid}"; then :; else
    uuid=""
    rw_api GET /api/config-profiles || { rw_fail "Список профилей"; return 1; }
    uuid="$(jq -r --arg n "$name" '[.response.configProfiles[]? | select(.name==$n) | .uuid][0] // empty' <<<"$RW_BODY")"
  fi
  if [ -n "$uuid" ]; then
    info "Профиль «${name}» уже есть на панели — обновляю конфиг (ключи сохраняются)."
    payload="$(jq -c --arg u "$uuid" '{uuid:$u, config:.}' <<<"$cfg")" || return 1
    rw_api PATCH /api/config-profiles "$payload" \
      || { err "Не удалось обновить профиль (HTTP ${RW_LAST_CODE}). Проверьте профиль на панели и версию Xray ноды."; return 1; }
  else
    payload="$(jq -c --arg n "$name" '{name:$n, config:.}' <<<"$cfg")" || return 1
    rw_api POST /api/config-profiles "$payload" \
      || { err "Не удалось создать профиль (HTTP ${RW_LAST_CODE}). Проверьте список профилей на панели и версию Xray ноды."; return 1; }
    uuid="$(jq -r '.response.uuid // empty' <<<"$RW_BODY")"
  fi
  [ -n "$uuid" ] || { err "Панель не вернула uuid профиля."; return 1; }
  PROFILE_UUID="$uuid"
  st_set --arg u "$uuid" '.profileUuid=$u' || return 1
  ok "Профиль «${name}» готов (${uuid:0:8}…)"
}

load_inbounds() {  # заполняет IB_UUID[tag] из профиля
  declare -gA IB_UUID=()
  rw_api GET "/api/config-profiles/${PROFILE_UUID}" || { rw_fail "Чтение профиля"; return 1; }
  local tag uuid
  while IFS=$'\t' read -r tag uuid; do [ -n "$tag" ] && IB_UUID[$tag]="$uuid"; done \
    < <(jq -r '.response.inbounds[]? | [.tag, .uuid] | @tsv' <<<"$RW_BODY")
  [ "${#IB_UUID[@]}" -gt 0 ] || { err "В профиле не нашлось ни одного inbound'а — панель отклонила конфиг?"; return 1; }
}

# Final Mask — последний слой маскировки на клиенте (поле хоста «Final Mask» в панели). Здесь —
# фрагментация TLS ClientHello: рукопожатие уходит несколькими мелкими пакетами, и DPI, который
# ищет SNI в первом пакете, его не видит. Только для TCP-хостов (у Hysteria2 нет ClientHello по TCP).
# Включить: FINAL_MASK=1. Свой JSON: FINAL_MASK_JSON='{"tcp":[...]}'.
# В текущих версиях Xray поля называются lengths/delays/maxSplit (xtls.github.io → FinalMask),
# а в совете из Telegram — length/interval: какой вариант примет ядро клиента, зависит от его версии.
FINAL_MASK_DEFAULT='{"tcp":[{"type":"fragment","settings":{"length":"10-20","packets":"tlshello","interval":"10-20"}}]}'

host_body() {  # host_body <proto> — JSON хоста для API
  local p="$1" d fp tag fm=""
  d="${PDOM[$p]}"; tag="${P_TAG[$p]}"; fp="$(st_get ".protocols.${p}.fingerprint")"
  if [ "$p" != "hy2" ] && [ "${FINAL_MASK:-0}" = "1" ]; then
    fm="${FINAL_MASK_JSON:-$FINAL_MASK_DEFAULT}"
    jq -e . >/dev/null 2>&1 <<<"$fm" || { warn "FINAL_MASK_JSON — невалидный JSON, беру значение по умолчанию."; fm="$FINAL_MASK_DEFAULT"; }
  fi
  # Если фрагментация выключена, поле finalMask НЕ отправляем: так не затираем маску, заданную в панели вручную.
  jq -nc --arg cp "$PROFILE_UUID" --arg ib "${IB_UUID[$tag]}" --arg remark "${P_REMARK[$p]}" --arg addr "$d" \
         --arg fp "$fp" --arg path "$(st_get '.protocols.xhttp.path')" --arg proto "$p" --arg fm "$fm" \
         --argjson port "$([ "$p" = "hy2" ] && hy2_port || echo 443)" '
    {inbound:{configProfileUuid:$cp, configProfileInboundUuid:$ib}, remark:$remark, address:$addr, port:$port, sni:$addr}
    + (if $proto=="hy2" then {alpn:"h3"} else {fingerprint:$fp} end)
    + (if $proto=="xhttp" then {host:$addr, path:$path} else {} end)
    + (if $fm != "" then {finalMask:($fm | fromjson)} else {} end)'
}

upsert_hosts() {
  local p tag huuid body
  rw_api GET /api/hosts || { rw_fail "Список хостов"; return 1; }
  local existing="$RW_BODY"
  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    tag="${P_TAG[$p]}"
    [ -n "${IB_UUID[$tag]:-}" ] || { err "Нет inbound'а ${tag} в профиле — хост ${P_REMARK[$p]} не создать."; return 1; }
    huuid="$(jq -r --arg r "${P_REMARK[$p]}" --arg cp "$PROFILE_UUID" \
      '[.response[]? | select(.remark==$r and .inbound.configProfileUuid==$cp) | .uuid][0] // empty' <<<"$existing")"
    body="$(host_body "$p")"
    if [ -n "$huuid" ]; then
      rw_api PATCH /api/hosts "$(jq -c --arg u "$huuid" '. + {uuid:$u}' <<<"$body")" || { rw_fail "Обновление хоста ${P_REMARK[$p]}"; return 1; }
      ok "Хост «${P_REMARK[$p]}» обновлён  ${C_DIM}${PDOM[$p]}${C_RESET}"
    else
      rw_api POST /api/hosts "$body" || { rw_fail "Создание хоста ${P_REMARK[$p]}"; return 1; }
      ok "Хост «${P_REMARK[$p]}» создан  ${C_DIM}${PDOM[$p]}${C_RESET}"
    fi
  done
}

attach_squad() {  # добавляет inbound'ы профиля в сквад (по умолчанию — первый), не удаляя прежние
  local sq name want current merged
  rw_api GET /api/internal-squads || { rw_fail "Список сквадов"; return 1; }
  if [ -n "${SQUAD_NAME:-}" ]; then
    sq="$(jq -r --arg n "$SQUAD_NAME" '[.response.internalSquads[]? | select(.name==$n) | .uuid][0] // empty' <<<"$RW_BODY")"
  else
    sq="$(jq -r '[.response.internalSquads[]? | .uuid][0] // empty' <<<"$RW_BODY")"
  fi
  if [ -z "$sq" ]; then
    if [ -n "${SQUAD_NAME:-}" ]; then err "Сквад «${SQUAD_NAME}» не найден."; return 1; fi
    warn "Сквад не найден — inbound'ы не привязаны (создайте сквад в панели и добавьте их)."
    return 0
  fi
  name="$(jq -r --arg u "$sq" '.response.internalSquads[] | select(.uuid==$u) | .name' <<<"$RW_BODY")"
  current="$(jq -c --arg u "$sq" '[.response.internalSquads[] | select(.uuid==$u) | .info.inbounds[]? // .inbounds[]? | (.uuid // .)] | unique' <<<"$RW_BODY")"
  want="$(printf '%s\n' "${IB_UUID[@]}" | jq -R . | jq -sc .)"
  merged="$(jq -c -n --argjson a "$current" --argjson b "$want" '$a + $b | unique')"
  rw_api PATCH /api/internal-squads "$(jq -nc --arg u "$sq" --argjson i "$merged" '{uuid:$u, inbounds:$i}')" \
    || { rw_fail "Привязка inbound'ов к скваду"; return 1; }
  ok "Inbound'ы добавлены в сквад «${name}» — они попадут в подписки пользователей"
}

upsert_node() {  # создаёт (или обновляет) ноду этого сервера на панели
  local nname="$1" addr="$2" port="$3" cc="$4" nuuid body ids
  ids="$(printf '%s\n' "${IB_UUID[@]}" | jq -R . | jq -sc .)"
  body="$(jq -nc --arg n "$nname" --arg a "$addr" --argjson port "$port" --arg cc "$cc" --arg cp "$PROFILE_UUID" --argjson ids "$ids" \
    '{name:$n, address:$a, port:$port, countryCode:$cc, configProfile:{activeConfigProfileUuid:$cp, activeInbounds:$ids}}')"
  rw_api GET /api/nodes || { rw_fail "Список нод"; return 1; }
  nuuid="$(jq -r --arg n "$nname" --arg a "$addr" '[.response[]? | select(.name==$n or .address==$a) | .uuid][0] // empty' <<<"$RW_BODY")"
  if [ -n "$nuuid" ]; then
    rw_api PATCH /api/nodes "$(jq -c --arg u "$nuuid" '. + {uuid:$u}' <<<"$body")" || { rw_fail "Обновление ноды"; return 1; }
    ok "Нода «${nname}» обновлена на панели  ${C_DIM}${addr}:${port}${C_RESET}"
  else
    rw_api POST /api/nodes "$body" || { rw_fail "Создание ноды"; return 1; }
    nuuid="$(jq -r '.response.uuid // empty' <<<"$RW_BODY")"
    ok "Нода «${nname}» создана на панели  ${C_DIM}${addr}:${port}${C_RESET}"
  fi
  st_set --arg u "$nuuid" '.nodeUuid=$u'
}

# SECRET_KEY ноды — общий для панели, берётся по API (не нужно копировать вручную).
fetch_secret_key() {
  rw_api GET /api/keygen || { rw_fail "Получение SECRET_KEY"; return 1; }
  jq -r '.response.secretKey // .response.pubKey // empty' <<<"$RW_BODY"
}

# Ждёт, пока панель увидит ноду подключённой (вызывается ПОСЛЕ установки remnanode).
wait_node_connected() {  # wait_node_connected [секунд]
  local limit="${1:-120}" waited=0 nuuid st
  nuuid="$(st_get '.nodeUuid')"; [ -n "$nuuid" ] || return 2
  while [ "$waited" -lt "$limit" ]; do
    if rw_api GET "/api/nodes/${nuuid}"; then
      # подключена и Xray запущен: isXrayRunning в этой версии панели пустое, надёжный признак — xrayUptime
      st="$(jq -r '[.response.isConnected, ((.response.xrayUptime // 0) > 0 or .response.isXrayRunning == true)] | @tsv' <<<"$RW_BODY")"
      [ "$st" = $'true\ttrue' ] && return 0
    fi
    sleep 4; waited=$((waited+4))
  done
  return 1
}

# ---- вывод ---------------------------------------------------------------------------------------------------
print_summary() {
  local p
  echo
  box_top "Профиль Xray"
  box_wrap "Имя" "$(st_get '.name')"
  box_wrap "Маршрут" "$(profile_route_label)"
  box_sep
  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    box_row "${C_B}${P_REMARK[$p]}${C_RESET}"
    box_row "  ${PDOM[$p]}"
    if [ "$p" = "hy2" ]; then
      box_row "  ${C_DIM}masquerade: файлы ${DECOY_WEB:-/var/www}/decoy-hy2 · alpn h3${C_RESET}"
    else
      box_row "  ${C_DIM}fp ${C_RESET}$(st_get ".protocols.${p}.fingerprint")${C_DIM} · target ${P_TARGET[$p]}${C_RESET}"
    fi
  done
  box_sep
  box_wrap "${C_DIM}•${C_RESET}" "Ключи REALITY сохранены в ${PROFILE_STATE} (права 600)."
  box_bottom
}

# ---- запуск --------------------------------------------------------------------------------------------------------
_is_panel_addr() {  # домен/IP[:порт][/путь?запрос] с http(s):// или без него
  local a="${1:-}"
  [[ "$a" =~ ^https?:// ]] || a="https://${a}"
  is_valid_url "$a"
}

profile_check_panel_transport() {
  [ "${PROFILE_ROUTE:-direct}" = direct ] && return 0
  case "$RW_BASE" in https://*|http://127.0.0.1|http://127.0.0.1:*) return 0 ;; esac
  err "В режиме каскада укажите HTTPS-адрес панели. Локальная панель может использовать HTTP на 127.0.0.1."
  return 1
}

profile_collect_params() {
  local px pname

  profile_collect_route "${1:-}" || return 1
  # адрес панели и токен
  RW_TOKEN="${PANEL_API_TOKEN:-${REMNAWAVE_API_TOKEN:-}}"
  local url="${PANEL_URL:-}"
  while true; do
    info "Пример: panel.example.com   или с секретом: https://panel.example.com/auth/login?ключ=значение"
    url=$(ask_valid "Адрес панели (домен или ссылка для входа; https:// можно не писать)" "$url" _is_panel_addr) || return 1
    [[ "$url" =~ ^https?:// ]] || url="https://${url}"
    rw_parse_url "$url" || { err "Не удалось разобрать адрес панели."; [ "${ASSUME_YES:-0}" = "1" ] && return 1; url=""; continue; }
    profile_check_panel_transport || { [ "${ASSUME_YES:-0}" = "1" ] && return 1; url=""; continue; }
    if [ -z "$RW_TOKEN" ]; then
      if [ "${ASSUME_YES:-0}" = "1" ]; then err "Задайте PANEL_API_TOKEN."; return 1; fi
      info "Токен: панель → Настройки → API-токены → создать."
      read -rs -p "  API-токен панели: " RW_TOKEN <"$(prompt_input)" || return 1
      printf '\n' >&2
      RW_TOKEN="$(printf '%s' "$RW_TOKEN" | tr -d ' \r\n"')"
    fi
    if rw_check; then break; fi
    [ "${ASSUME_YES:-0}" = "1" ] && return 1
    RW_TOKEN=""; warn "Повторите ввод (Ctrl+C — отмена)."
  done

  px=$(ask_value "Короткий префикс имён (например NL — страна/сервер)" "${PROFILE_PREFIX:-NL}")
  px="$(printf '%s' "$px" | tr -cd 'A-Za-z0-9')"; [ -n "$px" ] || px="NL"
  pname=$(ask_value "Имя профиля на панели" "${PROFILE_NAME:-${px}-DORIK}")
  PROFILE_PREFIX="$px"; PROFILE_NAME="$pname"
  COUNTRY_CODE=$(ask_value "Код страны ноды (2 буквы, как в панели)" "${COUNTRY_CODE:-$([ "${#px}" -eq 2 ] && echo "${px^^}" || echo XX)}")
  if [ -z "${PSIPHON:-}" ]; then
    if [ "${PROFILE_ROUTE:-direct}" = direct ] && ask_yes_no "Маршрут Gemini/AI Studio через psiphon (172.17.0.1:1080, как в вашем конфиге)?" "1"; then PSIPHON=1; else PSIPHON=0; fi
  fi
  if [ -z "${FINAL_MASK:-}" ]; then
    # Без вопросов (cloud-init) по умолчанию выключено: не меняем поведение уже настроенных серверов.
    if ask_yes_no "Фрагментация ClientHello (Final Mask) на TCP-хостах? Мешает DPI видеть SNI; клиенты с очень старым ядром Xray могут её не понять" "$([ "${ASSUME_YES:-0}" = "1" ] && echo 2 || echo 1)"; then FINAL_MASK=1; else FINAL_MASK=0; fi
  fi
  export FINAL_MASK
  # Нода создаётся на панели сама (SECRET_KEY панель выдаёт по API — вручную ничего копировать не нужно).
  # Не создавать: PROFILE_CREATE_NODE=0.
  PROFILE_CREATE_NODE="${PROFILE_CREATE_NODE:-1}"
  [ "$PROFILE_CREATE_NODE" = "1" ] && info "Нода этого сервера будет создана на панели автоматически, SECRET_KEY получим по API."
  return 0
}

# Применяет профиль по уже собранным параметрам (profile_collect_params). В полной настройке
# параметры собираются на этапе вопросов, а применяется профиль отдельным этапом конвейера —
# когда заглушки и сертификаты уже готовы.
profile_apply() {
  mkdir -p -- "$(dirname "$PROFILE_STATE")" || return 1
  {
    flock -n 9 || { err "На этом сервере профиль уже настраивается другим процессом."; return 1; }
    profile_apply_locked
  } 9>"${PROFILE_STATE}.lock"
}

profile_apply_locked() {
  step "Профиль и хосты на панели (API)"
  have jq || { apt_install jq || { err "jq нужен для работы с API."; return 1; }; }
  have openssl || { err "openssl не найден."; return 1; }
  load_domains || { err "Не найдены домены протоколов. Сначала настройте Nginx+HAProxy (пункт «Полная настройка») или задайте DOMAIN_TCP и др."; return 1; }
  # Нужен хотя бы один протокол Xray (WEB-прокси Telegram к профилю не относится).
  local _p _first=""
  for _p in "${PROTO_ORDER[@]}"; do [ -n "${PDOM[$_p]:-}" ] && { _first="$_p"; break; }; done
  [ -n "$_first" ] || { err "Не выбран ни один протокол Xray (REALITY TCP, gRPC, XHTTP, Hysteria2, Telegram) — профиль создавать не из чего."; return 1; }
  [ -n "$RW_BASE" ] && [ -n "$RW_TOKEN" ] || { err "Не заданы адрес панели и токен."; return 1; }
  profile_check_panel_transport || return 1
  define_protocols "${PROFILE_PREFIX:-NL}"

  state_prepare "$PROFILE_PREFIX" "$PROFILE_NAME" || return 1
  local cfg exit_config
  exit_config="$(profile_exit_config)" || return 1
  profile_check_exit_address <<<"$exit_config" || return 1
  cfg="$(build_config <<<"$exit_config")" || { err "Не удалось собрать конфиг Xray."; return 1; }
  jq -e . >/dev/null <<<"$cfg" || { err "Собранный конфиг не является валидным JSON."; return 1; }
  ok "Конфиг Xray собран: $(jq -r '[.inbounds[].tag] | join(", ")' <<<"$cfg")"

  upsert_profile "$PROFILE_NAME" "$cfg" || return 1
  st_set --arg mode "${PROFILE_ROUTE:-direct}" --arg file "${PROFILE_EXIT_FILE:-}" '.route={mode:$mode, file:$file}' || return 1
  load_inbounds || return 1
  upsert_hosts || return 1
  attach_squad || return 1

  if [ "${PROFILE_CREATE_NODE:-0}" = "1" ]; then
    local addr="${NODE_ADDRESS:-$(get_public_ip)}" nport nname
    nport="${NODE_PORT:-}"
    [ -z "$nport" ] && [ -f "${NODE_DIR:-/opt/remnanode}/docker-compose.yml" ] && \
      nport="$(grep -oE 'NODE_PORT=[0-9]+' "${NODE_DIR:-/opt/remnanode}/docker-compose.yml" | head -1 | cut -d= -f2)"
    nport="${nport:-$DEFAULT_NODE_PORT}"
    [ -n "$addr" ] || { err "Не удалось определить адрес сервера — задайте NODE_ADDRESS."; return 1; }
    nname="$(printf '%s' "${PROFILE_PREFIX}-${PDOM[$_first]%%.*}" | cut -c1-30)"
    upsert_node "$nname" "$addr" "$nport" "$COUNTRY_CODE" || return 1
  fi
  print_summary
  return 0
}

# Автономный запуск: сначала проверяем, что есть что настраивать, потом спрашиваем параметры.
profile_run() {
  have jq || { apt_install jq || { err "jq нужен для работы с API."; return 1; }; }
  load_domains || { err "Не найдены домены протоколов. Сначала настройте Nginx+HAProxy (пункт «Полная настройка») или задайте DOMAIN_TCP и др."; return 1; }
  profile_collect_params || return 1
  profile_apply
}

if [ "$_profile_standalone" = "1" ]; then
  require_root
  case "${1:-}" in
    --show) [ -s "$PROFILE_STATE" ] && jq 'del(.protocols[]?.privateKey)' "$PROFILE_STATE" || echo "Профиль ещё не создавался."; exit 0 ;;
    --exit-file) ensure_tty; banner; profile_export_exit; exit $? ;;
    "") ensure_tty; banner; ensure_base_packages || true; profile_run; exit $? ;;
    *) echo "Использование: $0 [--show | --exit-file]" >&2; exit 2 ;;
  esac
fi
