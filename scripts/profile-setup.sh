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
#
# Без вопросов (ASSUME_YES=1):
#   PANEL_URL        адрес панели; можно ссылку для входа с секретом (?ключ=значение) — он
#                    передаётся как cookie, иначе nginx-защита панели не пропустит API
#   PANEL_API_TOKEN  токен (панель → Настройки → API-токены)
#   PROFILE_PREFIX (NL) · PROFILE_NAME · COUNTRY_CODE · PSIPHON=1|0 · PROFILE_CREATE_NODE=1|0
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
  hdr="$(mktemp)"; chmod 600 "$hdr"
  {
    echo "Authorization: Bearer ${RW_TOKEN}"
    [ -n "$RW_COOKIE" ] && echo "Cookie: ${RW_COOKIE}"
    case "$RW_BASE" in http://*) echo 'X-Forwarded-For: 127.0.0.1'; echo 'X-Forwarded-Proto: https' ;; esac
  } > "$hdr"
  local -a args=(-sS --max-time 40 -X "$m" -H "@${hdr}" -H 'Content-Type: application/json')
  # shellcheck disable=SC2206
  [ -n "${RW_CURL_OPTS:-}" ] && args+=($RW_CURL_OPTS)
  [ -n "$body" ] && args+=(--data-binary "$body")
  out="$(curl "${args[@]}" -w $'\n%{http_code}' "${RW_BASE}${p}" 2>&1)"; rc=$?
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
    err "$1: панель недоступна по ${RW_BASE} (${RW_BODY:0:120})"
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
  local tmp; tmp="$(mktemp)"
  jq "$@" "$PROFILE_STATE" > "$tmp" && cat "$tmp" > "$PROFILE_STATE"; rm -f "$tmp"
}

# ---- сбор параметров --------------------------------------------------------------------------------
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
  local px="$1" name="$2" p fp key pair used
  mkdir -p "$(dirname "$PROFILE_STATE")"
  [ -s "$PROFILE_STATE" ] || echo '{"protocols":{}}' > "$PROFILE_STATE"
  chmod 600 "$PROFILE_STATE"
  st_set --arg px "$px" --arg name "$name" '.prefix=$px | .name=$name'

  used=" $(jq -r '[.protocols[]?.fingerprint // empty] | join(" ")' "$PROFILE_STATE") "
  local -a pool=()
  for fp in $(printf '%s\n' "${FINGERPRINTS[@]}" | shuf); do [[ "$used" == *" $fp "* ]] || pool+=("$fp"); done
  [ "${#pool[@]}" -gt 0 ] || pool=("${FINGERPRINTS[@]}")

  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    st_set --arg p "$p" --arg d "${PDOM[$p]}" --arg t "${P_TAG[$p]}" '.protocols[$p].domain=$d | .protocols[$p].tag=$t'
    [ "$p" = "hy2" ] && continue                                      # у Hysteria2 нет Reality-ключей
    if [ -z "$(st_get ".protocols.${p}.privateKey")" ]; then
      pair="$(gen_x25519)" || { err "Не удалось сгенерировать ключ x25519 (openssl)"; return 1; }
      st_set --arg p "$p" --arg k "${pair%% *}" --arg pub "${pair##* }" \
        --arg s1 "$(openssl rand -hex 8)" --arg s2 "$(openssl rand -hex 8)" \
        '.protocols[$p].privateKey=$k | .protocols[$p].publicKey=$pub | .protocols[$p].shortIds=[$s1,$s2]'
    fi
    local cur_fp bad
    cur_fp="$(st_get ".protocols.${p}.fingerprint")"
    for bad in "${BAD_FINGERPRINTS[@]}"; do [ "$cur_fp" = "$bad" ] && cur_fp=""; done
    if [ -z "$cur_fp" ]; then
      fp="${pool[0]}"; pool=("${pool[@]:1}"); [ "${#pool[@]}" -gt 0 ] || pool=("${FINGERPRINTS[@]}")
      st_set --arg p "$p" --arg f "$fp" '.protocols[$p].fingerprint=$f'
    fi
  done
  [ -n "$(st_get '.protocols.grpc.domain')" ] && [ -z "$(st_get '.protocols.grpc.serviceName')" ] && \
    st_set --arg v "$(openssl rand -hex 8)" '.protocols.grpc.serviceName=$v'
  [ -n "$(st_get '.protocols.xhttp.domain')" ] && [ -z "$(st_get '.protocols.xhttp.path')" ] && \
    st_set --arg v "/api/v2/sync-$(openssl rand -hex 6)" '.protocols.xhttp.path=$v'
  return 0
}

# ---- конфиг Xray ---------------------------------------------------------------------------------------
build_inbound() {  # build_inbound <proto> — JSON одного inbound'а
  local p="$1" d tag fp priv serv path
  d="${PDOM[$p]}"; tag="${P_TAG[$p]}"
  fp="$(st_get ".protocols.${p}.fingerprint")"; priv="$(st_get ".protocols.${p}.privateKey")"
  local sids; sids="$(jq -c ".protocols.${p}.shortIds // []" "$PROFILE_STATE")"
  case "$p" in
    hy2)
      jq -n --arg tag "$tag" --arg dir "$(decoy_root hy2)" '{
        tag:$tag, port:443, listen:"0.0.0.0", protocol:"hysteria",
        settings:{clients:[], version:2},
        sniffing:{enabled:true, routeOnly:true, destOverride:["http","tls","quic"]},
        streamSettings:{network:"hysteria", security:"tls",
          tlsSettings:{alpn:["h3"], certificates:[{keyFile:"/etc/hysteria/privkey.pem", certificateFile:"/etc/hysteria/fullchain.pem"}]},
          hysteriaSettings:{version:2, masquerade:{dir:$dir, type:"file"}}}}' ;;
    *)
      local net="raw" extra='{}' key=""
      if [ "$p" = "grpc" ]; then
        serv="$(st_get '.protocols.grpc.serviceName')"
        net="grpc"; key="grpcSettings"; extra="$(jq -n --arg s "$serv" '{multiMode:true, serviceName:$s}')"
      elif [ "$p" = "xhttp" ]; then
        path="$(st_get '.protocols.xhttp.path')"
        net="xhttp"; key="xhttpSettings"; extra="$(jq -n --arg h "$d" --arg pa "$path" '{host:$h, mode:"auto", path:$pa}')"
      fi
      jq -n --arg tag "$tag" --argjson port "${P_PORT[$p]}" --arg target "${P_TARGET[$p]}" --arg priv "$priv" \
            --arg fp "$fp" --arg sn "$d" --argjson sids "$sids" --arg net "$net" --arg key "$key" --argjson extra "$extra" '
        {tag:$tag, port:$port, listen:"127.0.0.1", protocol:"vless",
         settings:{clients:[], decryption:"none"},
         sniffing:{enabled:true, routeOnly:true, destOverride:["http","tls","quic"]},
         streamSettings: ({network:$net, security:"reality",
           realitySettings:{target:$target, spiderX:"/", shortIds:$sids, privateKey:$priv, fingerprint:$fp, serverNames:[$sn]}}
           + (if $key != "" then {($key): $extra} else {} end))}' ;;
  esac
}

build_config() {  # печатает полный конфиг Xray
  local p inbounds="[]" all_tags="[]" tg_tag="" tgdomains
  for p in "${PROTO_ORDER[@]}"; do
    [ -n "${PDOM[$p]:-}" ] || continue
    inbounds="$(jq -c --argjson ib "$(build_inbound "$p")" '. + [$ib]' <<<"$inbounds")"
    if [ "$p" = "tg" ]; then tg_tag="${P_TAG[tg]}"; else all_tags="$(jq -c --arg t "${P_TAG[$p]}" '. + [$t]' <<<"$all_tags")"; fi
  done
  # Что пропускает Telegram-хост: Telegram + ЮKassa/ЮMoney (+ свои домены). Всё остальное — в BLOCK.
  tgdomains="$(jq -nc --arg extra "${TG_EXTRA_DOMAINS:-}" '
    ["geosite:telegram","domain:telegram.org","domain:t.me","domain:telegra.ph","domain:yookassa.ru","domain:yoomoney.ru"]
    + ($extra | split(" ") | map(select(length>0) | "domain:" + .))')"
  jq -n --argjson inbounds "$inbounds" --argjson tags "$all_tags" --arg tg "$tg_tag" --argjson tgd "$tgdomains" \
        --arg psiphon "${PSIPHON:-1}" --arg ll "${XRAY_LOGLEVEL:-warning}" '
    {log:{loglevel:$ll},
     dns:{servers:["https+local://1.1.1.1/dns-query","https+local://8.8.8.8/dns-query","localhost"], queryStrategy:"UseIPv4"},
     inbounds:$inbounds,
     outbounds:([{tag:"DIRECT", protocol:"freedom", settings:{domainStrategy:"UseIP"}}, {tag:"BLOCK", protocol:"blackhole"}]
       + (if $psiphon=="1" then [{tag:"psiphon-out", protocol:"socks", settings:{port:1080, address:"172.17.0.1"}}] else [] end)),
     routing:{rules:(
       [{ip:["geoip:private"], outboundTag:"BLOCK"},
        {domain:["geosite:private"], outboundTag:"BLOCK"},
        {protocol:["bittorrent"], outboundTag:"BLOCK"},
        {port:"25", type:"field", network:"tcp", outboundTag:"BLOCK"}]
       + (if $tg != "" then
            [{type:"field", inboundTag:[$tg], domain:$tgd, outboundTag:"DIRECT"},
             {type:"field", inboundTag:[$tg], ip:["geoip:telegram"], outboundTag:"DIRECT"},
             {type:"field", inboundTag:[$tg], outboundTag:"BLOCK"}]
          else [] end)
       + (if $psiphon=="1" then
            [{type:"field", domain:["domain:gemini.google.com","domain:generativelanguage.googleapis.com","domain:ai.google.dev","domain:aistudio.google.com","domain:alkalimakersuite-pa.clients6.google.com","geosite:google-deepmind"], outboundTag:"psiphon-out"}]
          else [] end)
       + [{port:"443", type:"field", domain:["geosite:facebook","geosite:instagram","domain:fbcdn.net","domain:cdninstagram.com"], network:"udp", outboundTag:"BLOCK"},
          {inboundTag:$tags, outboundTag:"DIRECT"}])}}'
}

# ---- профиль, хосты, сквад, нода -------------------------------------------------------------------
upsert_profile() {  # upsert_profile <имя> <json-конфиг> → PROFILE_UUID
  local name="$1" cfg="$2" uuid
  uuid="$(st_get '.profileUuid')"
  if [ -n "$uuid" ] && rw_api GET "/api/config-profiles/${uuid}"; then :; else
    uuid=""
    rw_api GET /api/config-profiles || { rw_fail "Список профилей"; return 1; }
    uuid="$(jq -r --arg n "$name" '[.response.configProfiles[]? | select(.name==$n) | .uuid][0] // empty' <<<"$RW_BODY")"
  fi
  if [ -n "$uuid" ]; then
    info "Профиль «${name}» уже есть на панели — обновляю конфиг (ключи сохраняются)."
    rw_api PATCH /api/config-profiles "$(jq -nc --arg u "$uuid" --argjson c "$cfg" '{uuid:$u, config:$c}')" \
      || { rw_fail "Обновление профиля"; return 1; }
  else
    rw_api POST /api/config-profiles "$(jq -nc --arg n "$name" --argjson c "$cfg" '{name:$n, config:$c}')" \
      || { rw_fail "Создание профиля"; return 1; }
    uuid="$(jq -r '.response.uuid // empty' <<<"$RW_BODY")"
  fi
  [ -n "$uuid" ] || { err "Панель не вернула uuid профиля."; return 1; }
  PROFILE_UUID="$uuid"
  st_set --arg u "$uuid" '.profileUuid=$u'
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

host_body() {  # host_body <proto> — JSON хоста для API
  local p="$1" d fp tag
  d="${PDOM[$p]}"; tag="${P_TAG[$p]}"; fp="$(st_get ".protocols.${p}.fingerprint")"
  jq -nc --arg cp "$PROFILE_UUID" --arg ib "${IB_UUID[$tag]}" --arg remark "${P_REMARK[$p]}" --arg addr "$d" \
         --arg fp "$fp" --arg path "$(st_get '.protocols.xhttp.path')" --arg proto "$p" '
    {inbound:{configProfileUuid:$cp, configProfileInboundUuid:$ib}, remark:$remark, address:$addr, port:443, sni:$addr}
    + (if $proto=="hy2" then {alpn:"h3"} else {fingerprint:$fp} end)
    + (if $proto=="xhttp" then {host:$addr, path:$path} else {} end)'
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
  if [ -z "$sq" ]; then warn "Сквад не найден — inbound'ы не привязаны (создайте сквад в панели и добавьте их)."; return 0; fi
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
  box_top "Профиль «$(st_get '.name')» на панели"
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
  box_wrap "${C_DIM}•${C_RESET}" "У каждого протокола свои приватный ключ, shortId, fingerprint, SNI и заглушка. Секреты сохранены в ${PROFILE_STATE} (права 600)."
  box_bottom
}

# ---- запуск --------------------------------------------------------------------------------------------------------
profile_collect_params() {
  local px pname

  # адрес панели и токен
  RW_TOKEN="${PANEL_API_TOKEN:-${REMNAWAVE_API_TOKEN:-}}"
  local url="${PANEL_URL:-}"
  while true; do
    url=$(ask_valid "Адрес панели (ссылка для входа; с секретом ?ключ=значение, если включена защита)" "$url" is_valid_url) || return 1
    rw_parse_url "$url" || { err "Не удалось разобрать адрес панели."; [ "${ASSUME_YES:-0}" = "1" ] && return 1; url=""; continue; }
    if [ -z "$RW_TOKEN" ]; then
      info "Токен: панель → Настройки → API-токены → создать."
      RW_TOKEN=$(ask_value "API-токен панели" "")
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
    if ask_yes_no "Маршрут Gemini/AI Studio через psiphon (172.17.0.1:1080, как в вашем конфиге)?" "1"; then PSIPHON=1; else PSIPHON=0; fi
  fi
  if [ -z "${PROFILE_CREATE_NODE:-}" ]; then
    if ask_yes_no "Создать на панели ноду этого сервера и привязать профиль?" "1"; then PROFILE_CREATE_NODE=1; else PROFILE_CREATE_NODE=0; fi
  fi
  return 0
}

# Применяет профиль по уже собранным параметрам (profile_collect_params). В полной настройке
# параметры собираются на этапе вопросов, а применяется профиль отдельным этапом конвейера —
# когда заглушки и сертификаты уже готовы.
profile_apply() {
  step "Профиль и хосты на панели (API)"
  have jq || { apt_install jq || { err "jq нужен для работы с API."; return 1; }; }
  have openssl || { err "openssl не найден."; return 1; }
  load_domains || { err "Не найдены домены протоколов. Сначала настройте Nginx+HAProxy (пункт «Полная настройка») или задайте DOMAIN_TCP и др."; return 1; }
  [ -n "${PDOM[tcp]:-}" ] || { err "Нужен домен REALITY TCP."; return 1; }
  [ -n "$RW_BASE" ] && [ -n "$RW_TOKEN" ] || { err "Не заданы адрес панели и токен."; return 1; }
  define_protocols "${PROFILE_PREFIX:-NL}"

  state_prepare "$PROFILE_PREFIX" "$PROFILE_NAME" || return 1
  local cfg
  cfg="$(build_config)" || { err "Не удалось собрать конфиг Xray."; return 1; }
  jq -e . >/dev/null <<<"$cfg" || { err "Собранный конфиг не является валидным JSON."; return 1; }
  ok "Конфиг Xray собран: $(jq -r '[.inbounds[].tag] | join(", ")' <<<"$cfg")"

  upsert_profile "$PROFILE_NAME" "$cfg" || return 1
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
    nname="$(printf '%s' "${PROFILE_PREFIX}-${PDOM[tcp]%%.*}" | cut -c1-30)"
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
    "") ensure_tty; banner; ensure_base_packages || true; profile_run; exit $? ;;
    *) echo "Использование: $0 [--show]" >&2; exit 2 ;;
  esac
fi
