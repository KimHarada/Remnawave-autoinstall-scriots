#!/usr/bin/env bash
# DORIK toolkit — что уже установлено и в каком состоянии.
# Подключается после lib.sh. Даёт:
#   st_*            — определение состояния отдельных компонентов (ST_L уровень, ST_T текст)
#   show_dashboard  — рамка «Состояние сервера» для главного меню
#   verify_*        — проверки результата каждого этапа установки

NODE_DIR="${NODE_DIR:-/opt/remnanode}"
PANEL_DIR="${PANEL_DIR:-/opt/remnawave}"
SUB_DIR="${SUB_DIR:-/opt/remnawave/subscription}"

have()         { command -v "$1" &>/dev/null; }
svc_active()   { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_exists()   { [ "$(systemctl show -p LoadState --value "$1.service" 2>/dev/null)" = "loaded" ]; }

# Состояние контейнера: running / restarting / exited / ... ; пусто, если контейнера нет.
container_state() { have docker && docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true; }
container_running() { [ "$(container_state "$1")" = "running" ]; }
container_image()   { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || true; }
# Дата сборки образа, которым запущен контейнер (ГГГГ-ММ-ДД) — заменяет номер версии.
container_image_date() {
  local id
  id="$(docker inspect -f '{{.Image}}' "$1" 2>/dev/null)" || return 0
  docker image inspect -f '{{.Created}}' "$id" 2>/dev/null | cut -c1-10
}

env_get() {  # env_get <файл> <КЛЮЧ>
  [ -f "$1" ] && grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/^"//; s/"$//'
}

ST_L="off"; ST_T=""
_st() { ST_L="$1"; ST_T="$2"; }

st_system() {
  local name=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && name="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
  if [ -f /var/run/reboot-required ]; then _st warn "${name} · нужна перезагрузка"
  else _st ok "${name:-неизвестно}"; fi
}

st_ssh() {
  local port
  port="$(get_real_ssh_port)"
  if [ -z "$port" ]; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
      port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
      _st ok "порт ${port:-22} (через ssh.socket)"
    else
      _st bad "sshd не слушает порт"
    fi
  else
    _st ok "порт ${port}"
  fi
}

st_ufw() {
  if ! have ufw; then _st bad "не установлен"; return; fi
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then _st bad "выключен"; return; fi
  local n port
  n="$(ufw status 2>/dev/null | grep -c 'ALLOW')"
  port="$(get_real_ssh_port)"
  if [ -n "$port" ] && ! ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"; then
    _st warn "активен, но SSH-порт ${port} не разрешён!"
  else
    _st ok "активен · правил: ${n}"
  fi
}

st_f2b() {
  if ! have fail2ban-client; then _st warn "не установлен"; return; fi
  if ! svc_active fail2ban; then _st bad "не запущен"; return; fi
  local out
  out="$(fail2ban-client status sshd 2>/dev/null)" || { _st bad "jail sshd не работает"; return; }
  _st ok "jail sshd · заблокировано: $(echo "$out" | awk '/Currently banned/{print $NF}')"
}

st_bbr() {
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if [[ "$cc" == bbr* ]]; then _st ok "${cc} + ${qd}"; else _st warn "${cc:-?} (BBR не включён)"; fi
}

st_web() {
  local n=0 h=0
  svc_exists nginx && n=1
  svc_exists haproxy && h=1
  if [ "$n$h" = "00" ]; then _st off "не установлены"; return; fi
  if { [ "$n" = 0 ] || svc_active nginx; } && { [ "$h" = 0 ] || svc_active haproxy; }; then
    local decoy="" names="" total uniq
    [ "$n" = 1 ] && names="nginx"
    [ "$h" = 1 ] && names="${names:+$names + }haproxy"
    if [ -s /etc/dorik/decoys.conf ]; then
      total="$(wc -l < /etc/dorik/decoys.conf)"
      uniq="$(cut -d'|' -f4 /etc/dorik/decoys.conf | sort -u | wc -l)"
      if [ "$total" -gt 1 ] && [ "$uniq" -lt "$total" ]; then decoy=" · заглушки: есть одинаковые!"
      else decoy=" · заглушек: ${total}$([ "$total" -gt 1 ] && echo " (разные)")"; fi
    elif [ -f /var/www/decoy/.dorik-installed ]; then
      decoy=" · одна общая заглушка (старый формат)"
    fi
    _st ok "${names}${decoy}"
  else
    _st bad "служба остановлена (nginx/haproxy)"
  fi
}

st_certs() {
  local f d end days min=99999 cnt=0
  for f in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$f" ] || continue
    cnt=$((cnt+1))
    end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
    d="$(date -d "$end" +%s 2>/dev/null)" || continue
    days=$(( (d - $(date +%s)) / 86400 ))
    [ "$days" -lt "$min" ] && min=$days
  done
  if [ "$cnt" -eq 0 ]; then _st off "нет сертификатов"; return; fi
  if [ "$min" -lt 0 ]; then _st bad "${cnt} шт., есть просроченный"
  elif [ "$min" -lt 14 ]; then _st warn "${cnt} шт., ближайший истекает через ${min} дн."
  else _st ok "${cnt} шт., ближайший истекает через ${min} дн."; fi
}

st_docker() {
  if have docker; then _st ok "$(docker --version 2>/dev/null | sed -E 's/Docker version ([^,]+),.*/\1/')"
  else _st off "не установлен"; fi
}

st_node() {
  local s
  s="$(container_state remnanode)"
  case "$s" in
    running)
      local xv port
      xv="$(timeout 3 docker exec remnanode xray version 2>/dev/null | head -1 | awk '{print $1" "$2}')"
      port="$(env_get "$NODE_DIR/docker-compose.yml" NODE_PORT)"
      [ -z "$port" ] && port="$(grep -oE 'NODE_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d= -f2)"
      _st ok "работает${xv:+ · $xv}${port:+ · порт $port} · образ от $(container_image_date remnanode)" ;;
    restarting) _st bad "перезапускается — проверьте SECRET_KEY (docker logs remnanode)" ;;
    "")
      if [ -f "$NODE_DIR/docker-compose.yml" ]; then _st bad "настроена, но контейнера нет"
      else _st off "не установлена"; fi ;;
    *) _st bad "состояние: ${s}" ;;
  esac
}

st_panel() {
  local c ok_n=0 total=3 dom
  for c in remnawave remnawave-db remnawave-redis; do container_running "$c" && ok_n=$((ok_n+1)); done
  if [ "$ok_n" -eq "$total" ]; then
    dom="$(env_get "$PANEL_DIR/.env" PANEL_DOMAIN)"
    _st ok "работает · $(container_image remnawave | sed 's#.*/##')${dom:+ · $dom} · образ от $(container_image_date remnawave)"
  elif [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    _st bad "контейнеров запущено: ${ok_n} из ${total}"
  else
    _st off "не установлена"
  fi
}

st_sub() {
  if container_running remnawave-subscription-page; then
    local dom=""
    [ -f "$PANEL_DIR/.dorik-panel.conf" ] && dom="$(env_get "$PANEL_DIR/.dorik-panel.conf" SUB_DOMAIN)"
    _st ok "работает${dom:+ · $dom} · образ от $(container_image_date remnawave-subscription-page)"
  elif [ -f "$SUB_DIR/docker-compose.yml" ]; then _st bad "настроена, но не запущена"
  else _st off "не установлена"; fi
}

st_cron() {
  if [ -f /etc/cron.d/dorik-reboot ] || crontab -l 2>/dev/null | grep -q 'shutdown -r now'; then
    _st ok "ежедневная перезагрузка в 04:00 · $(timedatectl show -p Timezone --value 2>/dev/null)"
  else
    _st off "перезагрузка по расписанию выключена"
  fi
}

st_ports() {
  if ! declare -F scan_listeners &>/dev/null; then _st off "—"; return; fi
  scan_listeners
  local ex dk bl i open="" seen=" "
  ex="$(count_state exposed)"; dk="$(count_state docker)"; bl="$(count_state blocked)"
  for i in "${!L_STATE[@]}"; do
    [ "${L_STATE[$i]}" = "expected" ] || continue
    case "$seen" in *" ${L_PORT[$i]}/${L_PROTO[$i]} "*) continue ;; esac
    seen+="${L_PORT[$i]}/${L_PROTO[$i]} "
    open+="${open:+, }${L_PORT[$i]}/${L_PROTO[$i]}"
  done
  if [ "$ex" -gt 0 ]; then _st bad "лишних открытых портов: ${ex} — пункт «Укрепление сервера»"
  elif [ "$dk" -gt 0 ]; then _st bad "Docker открывает порты в обход ufw (${dk})"
  else _st ok "снаружи только нужное: ${open:-—}"; fi
}

st_profile() {
  local f=/etc/dorik/profile.json n
  if [ ! -s "$f" ]; then _st off "не создавался (пункт «Профиль и хосты на панели»)"; return; fi
  n="$(jq -r '[.protocols[]?.domain] | length' "$f" 2>/dev/null)"
  _st ok "$(jq -r '.name // "?"' "$f") · протоколов: ${n:-?}$(jq -e '.protocols.tg' "$f" &>/dev/null && echo " · есть Telegram-хост")"
}

st_webproxy() {
  local f=/etc/dorik/webproxy.json
  if [ ! -s "$f" ] || [ ! -x /usr/local/lib/mtproxy-web/telemt ]; then _st off "не установлен (пункт «WEB-прокси Telegram»)"; return; fi
  if svc_active mtproxy-web; then
    _st ok "$(jq -r '.domain' "$f" 2>/dev/null)$(jq -e '.adTag != ""' "$f" &>/dev/null && echo " · канал-спонсор подключён")"
  else
    _st bad "служба mtproxy-web остановлена"
  fi
}

st_issues() {
  if ! declare -F doctor_scan &>/dev/null; then _st off "—"; return; fi
  doctor_scan
  if [ "${#ISSUE_IDS[@]}" -eq 0 ]; then _st ok "проблем не найдено"
  else _st warn "найдено: ${#ISSUE_IDS[@]} — пункт «Проверка и исправление»"; fi
}

show_dashboard() {
  local entry label fn
  box_top "Состояние сервера"
  for entry in \
    "Система:st_system" "SSH:st_ssh" "Firewall (ufw):st_ufw" "fail2ban:st_f2b" \
    "Открытые порты:st_ports" "BBR:st_bbr" "Nginx/HAProxy:st_web" "Сертификаты:st_certs" "Docker:st_docker" \
    "Нода Remnanode:st_node" "Профиль панели:st_profile" "WEB-прокси TG:st_webproxy" "Панель Remnawave:st_panel" "Страница подп.:st_sub" \
    "Расписание:st_cron" "Проверка:st_issues"; do
    label="${entry%%:*}"; fn="${entry##*:}"
    "$fn"
    dot_row "$ST_L" "$label" "$ST_T"
  done
  box_bottom
}

# ---- проверки результата этапов ---------------------------------------------
# Каждая verify_* печатает галочки по пунктам и возвращает число провалов.
VERIFY_FAIL=0
_chk() {  # _chk <0|1 (0=ок)> <ok-текст> <fail-текст>
  if [ "$1" -eq 0 ]; then ok "$2"; else err "$3"; VERIFY_FAIL=$((VERIFY_FAIL+1)); fi
}
_ufw_allows() { ufw status 2>/dev/null | grep -qE "^$1[[:space:]]+ALLOW"; }
# Порт открыт для ВСЕХ (Anywhere), а не только для одного IP: правило «from 1.2.3.4»
# проходило бы за открытый порт, хотя SSH/HTTPS для остального мира закрыты.
_ufw_open()   { ufw status 2>/dev/null | grep -E "^$1[[:space:]]+ALLOW" | grep -q 'Anywhere'; }

verify_apt() {
  VERIFY_FAIL=0
  [ -z "$(dpkg --audit 2>/dev/null)" ]; _chk $? "dpkg: пакеты в целостном состоянии" "dpkg: есть недонастроенные пакеты (dpkg --configure -a)"
  apt-get check &>/dev/null;            _chk $? "apt: зависимости в порядке" "apt-get check сообщает о проблемах"
  return "$VERIFY_FAIL"
}

verify_ssh() {  # verify_ssh <порт>
  VERIFY_FAIL=0
  local port="$1" cfg
  cfg="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | tr '\n' ' ')"
  [ "${cfg% }" = "$port" ]; _chk $? "sshd настроен только на порт ${port}" "sshd -T показывает порты: ${cfg:-нет данных} (ожидался ${port})"
  ssh_is_really_up "$port" || ssh_ok_via_socket "$port"; _chk $? "sshd отвечает на порту ${port}" "sshd не обслуживает порт ${port}"
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    _ufw_allows "${port}(/tcp)?"; _chk $? "ufw: SSH-порт ${port} разрешён" "ufw: SSH-порт ${port} НЕ разрешён — доступ может пропасть!"
    # Ограничение SSH по IP — осознанный выбор администратора, поэтому лишь предупреждаем.
    _ufw_open "${port}(/tcp)?" || warn "ufw: SSH-порт ${port} открыт не для всех, а только для отдельного IP"
  fi
  return "$VERIFY_FAIL"
}

verify_firewall() {  # verify_firewall <ssh_port> <роль 1|2> <hy2 0|1> <node_port|""> <reboot 0|1>
  VERIFY_FAIL=0
  local ssh="$1" role="$2" hy2="$3" nport="$4" reboot="$5"
  ufw status 2>/dev/null | grep -q '^Status: active'; _chk $? "ufw: активен" "ufw: не активен"
  ufw status verbose 2>/dev/null | grep -q 'deny (incoming)'; _chk $? "ufw: входящие закрыты по умолчанию" "ufw: политика входящих не deny"
  _ufw_open "${ssh}/tcp"; _chk $? "ufw: SSH ${ssh}/tcp открыт для всех" "ufw: SSH ${ssh}/tcp не открыт для всех (нет правила или оно только для одного IP)"
  _ufw_open "443/tcp"; _chk $? "ufw: 443/tcp открыт" "ufw: нет правила для 443/tcp"
  _ufw_open "80/tcp"; _chk $? "ufw: 80/tcp открыт" "ufw: нет правила для 80/tcp"
  if [ "$role" = "1" ]; then
    [ "$hy2" != "1" ] || { _ufw_open "443/udp"; _chk $? "ufw: 443/udp открыт (Hysteria2)" "ufw: нет правила для 443/udp"; }
    [ -z "$nport" ] || { _ufw_allows "${nport}/tcp"; _chk $? "ufw: порт ноды ${nport} открыт" "ufw: нет правила для порта ноды ${nport}"; }
  fi
  fail2ban-client status sshd &>/dev/null; _chk $? "fail2ban: jail sshd работает" "fail2ban: jail sshd не работает"
  if [ "$reboot" = "1" ]; then
    [ -f /etc/cron.d/dorik-reboot ]; _chk $? "cron: перезагрузка в 04:00 настроена" "cron: файл /etc/cron.d/dorik-reboot отсутствует"
  fi
  [ "$(timedatectl show -p Timezone --value 2>/dev/null)" = "${DORIK_TZ}" ]; _chk $? "часовой пояс: ${DORIK_TZ}" "часовой пояс не ${DORIK_TZ}"
  return "$VERIFY_FAIL"
}

# Универсальное ожидание готовности контейнера: running (+healthy, если есть healthcheck).
wait_container_ready() {  # wait_container_ready <имя> [секунд]
  local name="$1" limit="${2:-120}" waited=0 st h
  while [ "$waited" -lt "$limit" ]; do
    st="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)"
    h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)"
    if [ "$st" = "running" ] && { [ -z "$h" ] || [ "$h" = "healthy" ]; }; then return 0; fi
    sleep 2; waited=$((waited+2))
  done
  return 1
}
