#!/usr/bin/env bash
# DORIK toolkit — блок-лист сетей сканеров.
#
# Сервер перестаёт отвечать адресам из публичного списка сетей, с которых ведётся активное
# зондирование (госсети РФ и связанные с ними подсети сканеров): пакеты от них отбрасываются
# ещё до HAProxy/Xray. Список — открытый проект C24Be/AS_Network_List, обновляется раз в сутки.
#
#   scanblock.sh on       — включить (ipset + iptables + ежедневное обновление)
#   scanblock.sh update   — обновить список сейчас
#   scanblock.sh status   — сколько сетей в списке и сколько пакетов отброшено
#   scanblock.sh off      — выключить и убрать правила
#
# Что важно знать:
#   - клиент, который сам сидит в сети из списка, не подключится; такие адреса добавляйте в
#     /etc/dorik/scanblock.allow (по одному IP или сети на строку) и выполните «update»;
#   - ваш текущий SSH-адрес и IP панели (PANEL_IP) попадают в исключения автоматически;
#   - правила ставятся в цепочку INPUT перед ufw и восстанавливаются после перезагрузки.
# Свой список: SCANBLOCK_URL4 / SCANBLOCK_URL6 (по одной сети CIDR на строку).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
    t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
  } || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
  _dorik_source state.sh
  _scanblock_standalone=1
else
  _scanblock_standalone=0
fi

SB_BIN=/usr/local/sbin/dorik-scanblock
SB_DIR=/var/lib/dorik/scanblock
SB_ALLOW=/etc/dorik/scanblock.allow
SB_URL4="${SCANBLOCK_URL4:-https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists/blacklist-v4.txt}"
SB_URL6="${SCANBLOCK_URL6:-https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists/blacklist-v6.txt}"

# Вся работа с ipset/iptables — в отдельном самостоятельном файле: его же запускают служба при
# загрузке и ежедневный таймер, когда тулкита может не быть под рукой.
_sb_write_bin() {
  mkdir -p "$(dirname "$SB_BIN")" "$SB_DIR" /etc/dorik
  cat > "$SB_BIN" <<EOF
#!/usr/bin/env bash
# DORIK toolkit — блок-лист сетей сканеров (ipset + iptables). Создан scanblock.sh.
set -u
DIR=${SB_DIR}
ALLOW=${SB_ALLOW}
URL4='${SB_URL4}'
URL6='${SB_URL6}'
EOF
  cat >> "$SB_BIN" <<'EOF'
mkdir -p "$DIR"

fetch() {  # fetch <4|6> <url> — скачивает и проверяет список; при сбое остаётся прежний
  local fam="$1" url="$2" raw="$DIR/$1.raw" new="$DIR/$1.new" min=20
  curl -fsSL --retry 3 --max-time 60 "$url" -o "$raw" || { rm -f "$raw"; return 1; }
  if [ "$fam" = "4" ]; then
    grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' "$raw" \
      | grep -vE '^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
      | awk -F/ '$2=="" || ($2>=8 && $2<=32)' | sort -u > "$new"
  else
    min=1
    grep -oiE '^[0-9a-f]{1,4}:[0-9a-f:]*(/[0-9]{1,3})?' "$raw" \
      | grep -viE '^(fe80|fc|fd|::1)' | awk -F/ '$2=="" || ($2>=16 && $2<=128)' | sort -u > "$new"
  fi
  rm -f "$raw"
  # Пустой или обрезанный ответ не должен обнулить защиту.
  [ "$(wc -l < "$new")" -ge "$min" ] || { rm -f "$new"; return 1; }
  mv -f "$new" "$DIR/$fam.list"
}

load() {  # load <4|6> — список в ipset, подмена набора без «окна» без защиты
  local fam="$1" set="dorik-scan$1" family=inet f="$DIR/$1.list"
  [ "$fam" = "6" ] && family=inet6
  [ -s "$f" ] || return 0
  {
    echo "create ${set}-new hash:net family ${family} hashsize 4096 maxelem 262144 -exist"
    echo "flush ${set}-new"
    sed "s/^/add ${set}-new /; s/\$/ -exist/" "$f"
  } | ipset restore || return 1
  ipset create "$set" hash:net family "$family" hashsize 4096 maxelem 262144 -exist
  ipset swap "${set}-new" "$set" && ipset destroy "${set}-new"
}

allow() {  # исключения: адреса, которым список не мешает
  local ip
  ipset create dorik-allow4 hash:net family inet -exist
  ipset create dorik-allow6 hash:net family inet6 -exist
  ipset flush dorik-allow4; ipset flush dorik-allow6
  [ -f "$ALLOW" ] || return 0
  while read -r ip _; do
    case "$ip" in
      ''|\#*) ;;
      *:*) ipset add dorik-allow6 "$ip" -exist 2>/dev/null ;;
      *)   ipset add dorik-allow4 "$ip" -exist 2>/dev/null ;;
    esac
  done < "$ALLOW"
  return 0
}

rules() {
  local fam ipt
  for fam in 4 6; do
    ipt=iptables; [ "$fam" = "6" ] && ipt=ip6tables
    command -v "$ipt" >/dev/null 2>&1 || continue
    ipset list -n "dorik-scan$fam" >/dev/null 2>&1 || continue
    "$ipt" -w -C INPUT -m set --match-set "dorik-scan$fam" src -m set ! --match-set "dorik-allow$fam" src -j DROP 2>/dev/null \
      || "$ipt" -w -I INPUT 1 -m set --match-set "dorik-scan$fam" src -m set ! --match-set "dorik-allow$fam" src -j DROP
  done
}

unrules() {
  local fam ipt
  for fam in 4 6; do
    ipt=iptables; [ "$fam" = "6" ] && ipt=ip6tables
    command -v "$ipt" >/dev/null 2>&1 || continue
    while "$ipt" -w -D INPUT -m set --match-set "dorik-scan$fam" src -m set ! --match-set "dorik-allow$fam" src -j DROP 2>/dev/null; do :; done
  done
}

case "${1:-apply}" in
  update)  # свежий список + применить
    fetch 4 "$URL4"; r4=$?
    fetch 6 "$URL6" || true
    allow; load 4; load 6; rules
    date '+%F %T' > "$DIR/updated"
    exit "$r4" ;;
  apply)   # при загрузке: из сохранённых списков, без сети
    allow; load 4; load 6; rules ;;
  remove)
    unrules
    for s in dorik-scan4 dorik-scan6 dorik-scan4-new dorik-scan6-new dorik-allow4 dorik-allow6; do ipset destroy "$s" 2>/dev/null; done
    exit 0 ;;
  *) echo "usage: $0 [update|apply|remove]" >&2; exit 2 ;;
esac
EOF
  chmod 755 "$SB_BIN"
}

_sb_write_units() {
  cat > /etc/systemd/system/dorik-scanblock.service <<EOF
[Unit]
Description=DORIK: блок-лист сетей сканеров (восстановление после загрузки)
After=network.target ufw.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=${SB_BIN} apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/dorik-scanblock-update.service <<EOF
[Unit]
Description=DORIK: обновление блок-листа сетей сканеров
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SB_BIN} update
EOF
  cat > /etc/systemd/system/dorik-scanblock-update.timer <<'EOF'
[Unit]
Description=DORIK: ежедневное обновление блок-листа сетей сканеров

[Timer]
OnBootSec=10min
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

# Адреса, которым список мешать не должен: текущая SSH-сессия, IP панели, заданные вручную.
_sb_allow_add() {  # _sb_allow_add <ip> <пояснение>
  local ip="${1:-}"
  [ -n "$ip" ] && is_valid_ip "$ip" || return 0
  mkdir -p /etc/dorik; touch "$SB_ALLOW"
  grep -qE "^${ip//./\\.}([[:space:]]|\$)" "$SB_ALLOW" 2>/dev/null || echo "${ip}  # ${2:-}" >> "$SB_ALLOW"
}

_sb_seed_allow() {
  local ip
  if [ ! -f "$SB_ALLOW" ]; then
    mkdir -p /etc/dorik
    printf '%s\n' "# DORIK: адреса и сети, на которые блок-лист сканеров не действует (IP или CIDR на строку)." > "$SB_ALLOW"
  fi
  local sc="${SSH_CLIENT:-}"
  _sb_allow_add "${sc%% *}" "SSH-сессия при установке"
  for ip in $(who 2>/dev/null | grep -oE '\(([0-9]{1,3}\.){3}[0-9]{1,3}\)' | tr -d '()' | sort -u); do
    _sb_allow_add "$ip" "SSH-сессия при установке"
  done
  _sb_allow_add "${PANEL_IP:-}" "панель Remnawave"
  for ip in ${SCANBLOCK_ALLOW:-}; do _sb_allow_add "$ip" "задано в SCANBLOCK_ALLOW"; done
  return 0
}

scanblock_count() {  # сколько сетей в наборе IPv4; 0 — выключено
  have ipset || { echo 0; return 0; }
  local n
  n="$(ipset list -t dorik-scan4 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')"
  echo "${n:-0}"
}

scanblock_on() {
  have ipset && have iptables || apt_install ipset iptables || { err "ipset/iptables не установились — блок-лист не включён."; return 1; }
  _sb_write_bin
  _sb_write_units
  _sb_seed_allow
  if ! spin_run "Загрузка блок-листа сетей сканеров" "$SB_BIN" update; then
    if [ -s "$SB_DIR/4.list" ]; then
      warn "Свежий список не скачался — применён сохранённый ранее."
    else
      err "Список сетей не скачался (${SB_URL4}) — блок-лист не включён. Повторите позже: «Защита и порты» → блок-лист."
      return 1
    fi
  fi
  systemctl enable dorik-scanblock.service &>/dev/null || true
  systemctl enable --now dorik-scanblock-update.timer &>/dev/null || true
  local n; n="$(scanblock_count)"
  if [ "$n" -gt 0 ] && iptables -w -S INPUT 2>/dev/null | grep -q 'dorik-scan4'; then
    ok "Блок-лист сканеров включён: ${n} сетей, обновление раз в сутки"
    info "Исключения (ваш SSH-адрес, IP панели): ${SB_ALLOW}"
    return 0
  fi
  err "Блок-лист не применился (ipset: ${n} сетей; правило iptables не найдено)."
  return 1
}

scanblock_update() {
  [ -x "$SB_BIN" ] || { err "Блок-лист не включён — сначала включите его."; return 1; }
  spin_run "Обновление блок-листа сетей сканеров" "$SB_BIN" update || { warn "Свежий список не скачался — остался прежний."; return 1; }
  ok "Блок-лист обновлён: $(scanblock_count) сетей"
}

scanblock_off() {
  systemctl disable --now dorik-scanblock-update.timer dorik-scanblock.service &>/dev/null || true
  [ -x "$SB_BIN" ] && "$SB_BIN" remove
  rm -f /etc/systemd/system/dorik-scanblock.service /etc/systemd/system/dorik-scanblock-update.service \
        /etc/systemd/system/dorik-scanblock-update.timer "$SB_BIN"
  systemctl daemon-reload
  ok "Блок-лист сканеров выключен (исключения сохранены в ${SB_ALLOW})."
}

scanblock_status() {
  local n pk upd
  n="$(scanblock_count)"
  if [ "$n" -eq 0 ]; then info "Блок-лист сканеров: выключен"; return 0; fi
  pk="$(iptables -w -nvxL INPUT 2>/dev/null | awk '/dorik-scan4/{print $1; exit}')"
  upd="$(cat "$SB_DIR/updated" 2>/dev/null)"
  ok "Блок-лист сканеров: ${n} сетей IPv4$(have ipset && ipset list -n dorik-scan6 &>/dev/null && echo ", IPv6: $(ipset list -t dorik-scan6 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')")"
  info "Отброшено пакетов с момента загрузки: ${pk:-0}"
  info "Список обновлён: ${upd:-неизвестно} · исключений: $(grep -cvE '^[[:space:]]*(#|$)' "$SB_ALLOW" 2>/dev/null || true)"
}

if [ "$_scanblock_standalone" = "1" ]; then
  require_root
  require_apt_os
  case "${1:-status}" in
    on)     scanblock_on ;;
    update) scanblock_update ;;
    off)    scanblock_off ;;
    status) scanblock_status ;;
    *) echo "Использование: $0 [on|update|status|off]" >&2; exit 2 ;;
  esac
fi
