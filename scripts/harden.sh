#!/usr/bin/env bash
# DORIK toolkit — закрытие лишних портов и укрепление сервера.
#
#   harden.sh            — аудит портов + предложение закрыть лишнее и укрепить систему
#   harden.sh --audit    — только показать, что слушает снаружи; ничего не менять
#
# Что делает:
#   1. Определяет НУЖНЫЕ порты (SSH, 80/443, порт ноды, 443/udp для Hysteria2) и
#      показывает все слушающие сокеты: нужный / закрыт firewall'ом / ОТКРЫТ лишний.
#   2. Firewall: политика «входящие закрыты», IPv6, удаление всех лишних allow-правил.
#   3. Отключает известные ненужные службы, слушающие снаружи (rpcbind, avahi, cups, snmpd, smbd…).
#   4. Укрепляет ядро (sysctl), SSH, включает автообновления безопасности,
#      блокирует неиспользуемые модули ядра (dccp, sctp, rds, tipc).
#
# Ничего не закрывает «втёмную»: свои порты можно оставить так —
#   HARDEN_KEEP_PORTS="8443/tcp 9000"      (без /proto = tcp и udp)
# Вход по паролю SSH отключается только по явной просьбе и только при наличии ключей:
#   SSH_DISABLE_PASSWORD=1
# Без вопросов: ASSUME_YES=1. Явный список нужных портов: HARDEN_EXPECT="2200/tcp 80/tcp 443/tcp".

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
    t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
  } || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
  _dorik_source state.sh
  _harden_standalone=1
else
  _harden_standalone=0
fi

HARDEN_STATE_DIR=/var/lib/dorik

# Службы, которым нечего делать на публичном интерфейсе VPS с нодой/панелью.
# Отключаются ТОЛЬКО если реально слушают снаружи.
HARDEN_DISABLE_UNITS=" rpcbind avahi-daemon cups cups-browsed snmpd smbd nmbd nfs-server nfs-mountd
 vsftpd proftpd pure-ftpd telnetd inetd xinetd openbsd-inetd rsync tftpd-hpa isc-dhcp-server
 bind9 named dnsmasq apache2 lighttpd mosquitto memcached "

# Процессы, чьи публичные порты — часть работы системы или самой ноды.
HARDEN_SYSTEM_PROCS='systemd-network|dhclient|dhcpcd|NetworkManager|chronyd|systemd-timesyn|systemd-resolve'
HARDEN_NODE_PROCS='rw-node|xray|hysteria|sing-box'

declare -gA EXPECT=()
declare -ga L_PROTO=() L_ADDR=() L_PORT=() L_PROC=() L_PID=() L_STATE=() L_UNIT=()

# ---- ожидаемые порты -------------------------------------------------------
_add_expect() {  # _add_expect <порт[/proto]>
  local p="${1%%/*}" pr="${1#*/}"
  if [ "$pr" = "$1" ]; then EXPECT["$p/tcp"]=1; EXPECT["$p/udp"]=1; else EXPECT["$p/$pr"]=1; fi
}

build_expected() {
  EXPECT=()
  local e np p
  # SSH-порт нужен ВСЕГДА, что бы ни передал вызывающий: иначе чистка правил
  # удалила бы доступ по SSH.
  for p in $(sshd -T 2>/dev/null | awk '/^port /{print $2}'); do _add_expect "$p/tcp"; done
  # Автоопределение работает ВСЕГДА, а HARDEN_EXPECT только дополняет его: иначе запуск
  # в роли «панель» на сервере с нодой удалил бы правила ноды как «лишние».
  if svc_active nginx || svc_active haproxy || [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    _add_expect 80/tcp; _add_expect 443/tcp
  fi
  if [ -f "$NODE_DIR/docker-compose.yml" ]; then
    np="$(grep -oE 'NODE_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" | head -1 | cut -d= -f2)"
    [ -n "$np" ] && _add_expect "$np/tcp"
    grep -q '/etc/hysteria' "$NODE_DIR/docker-compose.yml" && _add_expect 443/udp
  fi
  for e in ${HARDEN_EXPECT:-}; do _add_expect "$e"; done
  for e in ${HARDEN_KEEP_PORTS:-}; do _add_expect "$e"; done
  return 0
}

# ---- сканирование слушающих сокетов -------------------------------------------
_is_loopback() { case "$1" in 127.*|::1|localhost) return 0 ;; esac; return 1; }

_unit_of_pid() {  # имя службы systemd, которой принадлежит процесс (без .service)
  [ -n "${1:-}" ] && [ -r "/proc/$1/cgroup" ] || return 0
  grep -oE '[^/]+\.(service|socket)' "/proc/$1/cgroup" 2>/dev/null | tail -1 | sed -E 's/\.(service|socket)$//'
}

# Закрывает ли firewall входящий порт: ufw активен, политика deny и нет allow-правила.
# Вывод ufw кэшируется один раз за сканирование (его вызов не бесплатен, а сокетов много).
_UFW_TXT=""; _UFW_VERB=""
_fw_blocks() {  # _fw_blocks <порт> <proto>
  grep -q '^Status: active' <<<"$_UFW_TXT" || return 1
  grep -q 'deny (incoming)' <<<"$_UFW_VERB" || return 1
  ! grep -E "^$1(/$2)?( \(v6\))?[[:space:]]+(ALLOW|LIMIT)" <<<"$_UFW_TXT" | grep -q .
}

scan_listeners() {
  L_PROTO=(); L_ADDR=(); L_PORT=(); L_PROC=(); L_PID=(); L_STATE=(); L_UNIT=()
  local line proto laddr procs port addr name pid state unit key
  declare -A seen=()
  build_expected
  if have ufw; then _UFW_TXT="$(ufw status 2>/dev/null)"; _UFW_VERB="$(ufw status verbose 2>/dev/null)"
  else _UFW_TXT=""; _UFW_VERB=""; fi
  while IFS= read -r line; do
    proto="$(awk '{print $1}' <<<"$line")"
    laddr="$(awk '{print $5}' <<<"$line")"
    procs="$(grep -oE 'users:\(\(.*\)\)' <<<"$line" | head -1)"
    port="${laddr##*:}"; addr="${laddr%:*}"; addr="${addr#[}"; addr="${addr%]}"; addr="${addr%%\%*}"
    name="$(grep -oE '\("[^"]+"' <<<"$procs" | head -1 | tr -d '("')"
    pid="$(grep -oE 'pid=[0-9]+' <<<"$procs" | head -1 | cut -d= -f2)"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    key="${proto}/${port}/${name}"
    [ -n "${seen[$key]:-}" ] && continue
    seen[$key]=1
    unit="$(_unit_of_pid "$pid")"

    if _is_loopback "$addr"; then state="local"
    elif [[ "$name" =~ ^(${HARDEN_SYSTEM_PROCS})$ ]]; then state="system"
    elif [ -n "${EXPECT[$port/$proto]:-}" ]; then state="expected"
    elif [[ "$name" =~ ^(${HARDEN_NODE_PROCS})$ ]]; then state="expected"   # inbound'ы ноды задаёт панель
    elif [ "$name" = "docker-proxy" ]; then state="docker"                  # публикация Docker обходит ufw
    elif _fw_blocks "$port" "$proto"; then state="blocked"
    else state="exposed"; fi

    L_PROTO+=("$proto"); L_ADDR+=("$addr"); L_PORT+=("$port"); L_PROC+=("${name:-?}"); L_PID+=("$pid")
    L_STATE+=("$state"); L_UNIT+=("$unit")
  done < <(ss -H -tulnp 2>/dev/null)
}

count_state() {  # count_state <state>
  local i n=0
  for i in "${!L_STATE[@]}"; do [ "${L_STATE[$i]}" = "$1" ] && n=$((n+1)); done
  echo "$n"
}

print_listeners() {
  local i shown=0 total=0 col lbl
  box_top "Слушающие порты"
  for i in "${!L_STATE[@]}"; do
    case "${L_STATE[$i]}" in local|system) continue ;; esac
    total=$((total+1))
    [ "$shown" -ge 14 ] && continue
    case "${L_STATE[$i]}" in
      expected) col="$C_G"; lbl="нужный" ;;
      blocked)  col="$C_Y"; lbl="закрыт firewall" ;;
      docker)   col="$C_R"; lbl="Docker: открыт мимо ufw" ;;
      *)        col="$C_R"; lbl="ОТКРЫТ, лишний" ;;
    esac
    box_row "${col}●${C_RESET} $(printf '%-9s' "${L_PORT[$i]}/${L_PROTO[$i]}") $(printf '%-14s' "${L_PROC[$i]}") ${col}${lbl}${C_RESET}"
    shown=$((shown+1))
  done
  [ "$total" -gt "$shown" ] && box_row "${C_DIM}…и ещё $((total-shown))${C_RESET}"
  [ "$total" -eq 0 ] && box_row "${C_DIM}публичных слушающих портов нет${C_RESET}"
  box_bottom
}

# ---- 1. firewall ------------------------------------------------------------------
# Разбор `ufw status numbered`: печатает «номер|куда|строка» для allow/limit-правил,
# которые не относятся к нужным портам.
_ufw_extra_rules() {
  local line num to key base proto rest
  while IFS= read -r line; do
    [[ "$line" =~ ^\[\ *([0-9]+)\]\ +(.+)$ ]] || continue
    num="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    [[ "$rest" =~ (ALLOW|LIMIT) ]] || continue
    to="$(sed -E 's/[[:space:]]+(ALLOW|LIMIT).*//; s/ \(v6\)//' <<<"$rest" | sed -E 's/[[:space:]]+$//')"
    case "$to" in
      OpenSSH)        key="22/tcp" ;;
      "Nginx HTTP")   key="80/tcp" ;;
      "Nginx HTTPS")  key="443/tcp" ;;
      "Nginx Full")   [ -n "${EXPECT[80/tcp]:-}" ] && [ -n "${EXPECT[443/tcp]:-}" ] && continue; key="80/tcp" ;;
      Anywhere)       key="" ;;                 # «разрешить всё с адреса X» — лишнее
      *)
        base="${to%%/*}"; proto="${to#*/}"; [ "$proto" = "$to" ] && proto=""
        if [[ "$base" =~ ^[0-9]+$ ]]; then
          if [ -n "$proto" ]; then key="$base/$proto"
          else [ -n "${EXPECT[$base/tcp]:-}" ] || [ -n "${EXPECT[$base/udp]:-}" ] && continue; key=""; fi
        else key=""; fi ;;
    esac
    [ -n "$key" ] && [ -n "${EXPECT[$key]:-}" ] && continue
    echo "${num}|${to}|$(sed -E 's/[[:space:]]+/ /g' <<<"$rest")"
  done < <(ufw status numbered 2>/dev/null)
}

harden_firewall() {
  local rc=0 p
  have ufw || { apt_install ufw || { err "ufw не установился — firewall не настроить."; return 1; }; }

  # SSH-порт должен быть открыт ДО любых действий: иначе включение/чистка отрежет доступ.
  for p in $(sshd -T 2>/dev/null | awk '/^port /{print $2}'); do
    ufw status 2>/dev/null | grep -qE "^${p}(/tcp)?[[:space:]]+ALLOW" || ufw allow "${p}/tcp" comment "SSH" &>/dev/null
  done

  # IPv6: при IPV6=no правила применяются только к IPv4, а IPv6 остаётся без фильтра.
  if grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; then
    sed -i -E 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
    info "ufw: включена фильтрация IPv6"
  fi
  ufw default deny incoming &>/dev/null
  ufw default allow outgoing &>/dev/null
  ufw status 2>/dev/null | grep -q '^Status: active' || ufw --force enable &>/dev/null
  ufw reload &>/dev/null || true

  # лишние allow-правила
  local extra nums=() lines=() n to txt
  build_expected
  extra="$(_ufw_extra_rules)"
  if [ -n "$extra" ]; then
    echo
    box_top "Лишние правила firewall"
    while IFS='|' read -r n to txt; do
      box_row "${C_Y}▲${C_RESET} ${txt:0:56}"
      nums+=("$n")
    done <<<"$extra"
    box_row "${C_DIM}Оставить: HARDEN_KEEP_PORTS=\"порт/proto …\"${C_RESET}"
    box_bottom
    if ask_yes_no "Удалить эти правила (порты будут закрыты)?" "1"; then
      # с конца: номера сдвигаются после каждого удаления
      for n in $(printf '%s\n' "${nums[@]}" | sort -rn); do ufw --force delete "$n" &>/dev/null || rc=1; done
      ok "Удалено лишних правил: ${#nums[@]}"
    else
      warn "Лишние правила оставлены по вашему выбору."
    fi
  else
    ok "Лишних правил firewall нет."
  fi
  return $rc
}

# ---- 2. службы ------------------------------------------------------------------------
harden_services() {
  scan_listeners
  local i unit todo=() picked=" " list
  list=" ${HARDEN_DISABLE_UNITS//$'\n'/ } "
  for i in "${!L_STATE[@]}"; do
    case "${L_STATE[$i]}" in exposed|blocked) ;; *) continue ;; esac
    unit="${L_UNIT[$i]}"; [ -z "$unit" ] && unit="${L_PROC[$i]}"
    [[ "$list" == *" $unit "* ]] || continue
    [[ "$picked" == *" $unit "* ]] && continue
    picked+="$unit "; todo+=("$unit")
  done
  if [ "${#todo[@]}" -eq 0 ]; then
    ok "Известных ненужных служб, слушающих снаружи, нет."
    return 0
  fi
  echo
  box_top "Ненужные службы на публичных портах"
  for unit in "${todo[@]}"; do box_row "${C_Y}▲${C_RESET} ${unit}"; done
  box_bottom
  if ask_yes_no "Остановить и отключить эти службы?" "1"; then
    mkdir -p "$HARDEN_STATE_DIR"
    for unit in "${todo[@]}"; do
      systemctl disable --now "${unit}.socket" &>/dev/null || true
      if systemctl disable --now "${unit}.service" &>/dev/null || systemctl disable --now "$unit" &>/dev/null; then
        ok "Отключена служба ${unit}  ${C_DIM}(вернуть: systemctl enable --now ${unit})${C_RESET}"
        echo "$(date '+%F %T') disabled ${unit}" >> "$HARDEN_STATE_DIR/hardening.log"
      else
        warn "Не удалось отключить ${unit} — проверьте вручную: systemctl status ${unit}"
      fi
    done
  else
    warn "Службы оставлены по вашему выбору."
  fi
  return 0
}

# ---- 3. ядро ----------------------------------------------------------------------------
harden_sysctl() {
  cat > /etc/sysctl.d/98-dorik-hardening.conf <<'EOF'
# DORIK toolkit — укрепление сетевого стека и ядра. Значения безопасны для прокси-нод и Docker.
# Фильтр обратного пути в «мягком» режиме (2): не ломает асимметричную маршрутизацию.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Не принимать и не слать ICMP-редиректы, не принимать source-routing
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Защита от SYN-флуда, smurf и «мусорных» ICMP-ответов
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
# Ядро: не раскрывать адреса, ограничить dmesg и unprivileged BPF
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF
  sysctl -p /etc/sysctl.d/98-dorik-hardening.conf &>/dev/null || true
  # Модули протоколов, которые на прокси-ноде не нужны и регулярно оказываются дырами.
  cat > /etc/modprobe.d/dorik-blacklist.conf <<'EOF'
# DORIK toolkit — неиспользуемые сетевые протоколы
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
  ok "Применено укрепление ядра (sysctl) и заблокированы неиспользуемые модули"
}

# ---- 4. SSH -----------------------------------------------------------------------------
_has_ssh_keys() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -s "$f" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && return 0
  done
  return 1
}

harden_ssh() {
  have sshd || { warn "sshd не найден — пропускаю укрепление SSH."; return 0; }
  local cfg=/etc/ssh/sshd_config dir=/etc/ssh/sshd_config.d drop=/etc/ssh/sshd_config.d/00-dorik-hardening.conf bak
  bak="${cfg}.bak.hard.$(date +%s)"
  mkdir -p "$dir" /run/sshd
  cp -f "$cfg" "$bak"
  # держим только три последние копии, чтобы они не копились при каждом запуске
  # shellcheck disable=SC2012
  ls -1t "${cfg}".bak.hard.* 2>/dev/null | tail -n +4 | xargs -r rm -f
  # Уже отключённый вход по паролю повторный запуск НЕ возвращает: укрепление не должно
  # само себя ослаблять. Вернуть пароль можно только явно: SSH_ENABLE_PASSWORD=1.
  local pw_off="${SSH_DISABLE_PASSWORD:-0}"
  if grep -q '^PasswordAuthentication no' "$drop" 2>/dev/null && [ "${SSH_ENABLE_PASSWORD:-0}" != "1" ]; then
    pw_off=1
  fi
  # Старые sshd не читают sshd_config.d без Include — добавляем его в начало файла.
  grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$cfg" || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$cfg"

  # Имя 00-… нарочно: в sshd побеждает ПЕРВОЕ значение, а cloud-init кладёт свой файл 50-….
  {
    echo "# DORIK toolkit — укрепление SSH"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "PermitEmptyPasswords no"
    echo "X11Forwarding no"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    echo "HostbasedAuthentication no"
    echo "IgnoreRhosts yes"
    if [ "$pw_off" = "1" ]; then
      if _has_ssh_keys; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "PubkeyAuthentication yes"
        echo "PermitRootLogin prohibit-password"
      else
        warn "Вход по паролю отключать нельзя: в authorized_keys нет ни одного ключа (иначе потеряете доступ)."
      fi
    fi
  } > "$drop"

  if ! sshd -t 2>/tmp/dorik_sshd_hard_err; then
    err "sshd -t отверг настройки: $(head -1 /tmp/dorik_sshd_hard_err) — откатываю."
    rm -f "$drop"; cp -f "$bak" "$cfg"
    return 1
  fi
  # Применяем без разрыва сессий (reload). Если служба сейчас не запущена (ssh.socket
  # поднимет её сам), конфиг прочитается при ближайшем старте.
  if systemctl is-active --quiet "$(detect_ssh_unit).service" 2>/dev/null; then
    systemctl reload "$(detect_ssh_unit)" &>/dev/null || restart_ssh_service >/dev/null || true
  fi
  ok "SSH укреплён: MaxAuthTries 3, LoginGraceTime 30, без X11 и пустых паролей"
  if grep -q '^PasswordAuthentication no' "$drop" 2>/dev/null; then
    ok "Вход по паролю отключён — только по SSH-ключу"
  fi
  return 0
}

# ---- 5. автообновления безопасности ------------------------------------------------------
harden_updates() {
  dpkg -s unattended-upgrades &>/dev/null || apt_install unattended-upgrades || { warn "unattended-upgrades не установился."; return 1; }
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer &>/dev/null || true
  ok "Автоматические обновления безопасности включены"
}

# ---- 6. щит от сканеров: молчим на ping, баним сканирующих порты ---------------------------------
# Сам открытый порт 443 скрыть нельзя, но сервер не должен отвечать на ping и должен банить тех,
# кто перебирает закрытые порты (в логе ядра — строки «[UFW BLOCK]»).
harden_shield() {
  # По умолчанию ping ОСТАВЛЕН: клиенты (Happ, Hiddify, v2rayN...) показывают «пинг» хоста через ICMP,
  # и сервер без ответа выглядит в списке как нерабочий. Скрыть ping: ALLOW_PING=0.
  if [ "${ALLOW_PING:-1}" = "1" ]; then
    rm -f /etc/sysctl.d/97-dorik-noping.conf
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 &>/dev/null || true
    info "Сервер отвечает на ping (скрыть: ALLOW_PING=0)"
  else
    echo 'net.ipv4.icmp_echo_ignore_all = 1' > /etc/sysctl.d/97-dorik-noping.conf
    sysctl -w net.ipv4.icmp_echo_ignore_all=1 &>/dev/null || warn "ping не отключён (ядро/контейнер не позволяет)"
  fi
  # ICMPv6 не трогаем: на нём держится работа IPv6 (соседи, маршрутизаторы).
  have ufw && ufw logging low &>/dev/null || true
  have fail2ban-client || install_fail2ban || { warn "fail2ban не установился — бан сканеров пропущен."; return 1; }
  mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d
  cat > /etc/fail2ban/filter.d/dorik-portscan.conf <<'EOF'
[Definition]
failregex = \[UFW BLOCK\] .*SRC=<HOST> DST=
ignoreregex =
journalmatch = _TRANSPORT=kernel
EOF
  local ign="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
  [ -n "${PANEL_IP:-}" ] && ign="$ign ${PANEL_IP}"
  cat > /etc/fail2ban/jail.d/dorik-portscan.conf <<EOF
[dorik-portscan]
enabled  = true
filter   = dorik-portscan
backend  = systemd
maxretry = ${PORTSCAN_MAXRETRY:-20}
findtime = 60
bantime  = 1d
ignoreip = ${ign}
EOF
  systemctl restart fail2ban &>/dev/null || { warn "fail2ban не перезапустился."; return 1; }
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do fail2ban-client status dorik-portscan &>/dev/null && break; sleep 1; done
  ok "Щит от сканеров: перебор закрытых портов банится на сутки$([ "${ALLOW_PING:-1}" = "1" ] || echo ", ping скрыт")"
}

# ---- Docker: публикации в обход ufw --------------------------------------------------------
docker_public_ports() {  # печатает «контейнер порт» для портов, опубликованных на все интерфейсы
  have docker && svc_active docker || return 0
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | while IFS=$'\t' read -r name ports; do
    echo "$ports" | tr ',' '\n' | grep -E '^\s*(0\.0\.0\.0|\[::\]|:::)' | grep -oE ':[0-9]+->' | tr -d ':>-' \
      | while read -r p; do echo "$name $p"; done
  done | sort -u
}

# ---- проверка результата -----------------------------------------------------------------------
verify_hardening() {
  VERIFY_FAIL=0
  local i exposed docker_n
  ufw status 2>/dev/null | grep -q '^Status: active'; _chk $? "ufw активен" "ufw не активен"
  ufw status verbose 2>/dev/null | grep -q 'deny (incoming)'; _chk $? "входящие соединения закрыты по умолчанию" "политика входящих не deny"
  ! grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; _chk $? "firewall фильтрует и IPv6" "IPv6 не фильтруется (IPV6=no в /etc/default/ufw)"
  build_expected
  [ -z "$(_ufw_extra_rules)" ]; _chk $? "в firewall нет лишних allow-правил" "в firewall остались лишние allow-правила"

  scan_listeners
  exposed="$(count_state exposed)"; docker_n="$(count_state docker)"
  [ "$exposed" -eq 0 ]; _chk $? "лишних открытых портов нет" "открытых лишних портов: ${exposed} (см. таблицу выше)"
  if [ "$docker_n" -gt 0 ]; then
    err "Docker публикует порты на все интерфейсы в обход ufw: $(docker_public_ports | tr '\n' ';')"; VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi

  local k v cur bad=0
  for k in net.ipv4.tcp_syncookies=1 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 \
           net.ipv4.conf.all.accept_source_route=0 net.ipv4.conf.all.rp_filter=2 kernel.kptr_restrict=2; do
    cur="$(sysctl -n "${k%%=*}" 2>/dev/null)"; v="${k##*=}"
    [ "$cur" = "$v" ] || bad=$((bad+1))
  done
  # В контейнерной виртуализации хостер может не разрешать менять часть параметров — это не провал.
  if [ "$bad" -eq 0 ]; then ok "параметры ядра применены"
  else warn "параметров ядра не применено: ${bad} (в контейнерах/OpenVZ часть недоступна)"; fi

  local ma
  ma="$(sshd -T 2>/dev/null | awk '/^maxauthtries /{print $2}')"
  [ "$ma" = "3" ]; _chk $? "SSH: MaxAuthTries 3 действует" "SSH: MaxAuthTries=${ma:-?} (ожидалось 3)"
  [ "$(sshd -T 2>/dev/null | awk '/^permitemptypasswords /{print $2}')" = "no" ]; _chk $? "SSH: пустые пароли запрещены" "SSH: пустые пароли разрешены"

  systemctl is-enabled apt-daily-upgrade.timer &>/dev/null && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
  _chk $? "автообновления безопасности включены" "автообновления безопасности не включены"
  [ -f /etc/modprobe.d/dorik-blacklist.conf ]; _chk $? "неиспользуемые модули ядра заблокированы" "файл блокировки модулей отсутствует"
  if [ "${SCAN_PROTECT:-1}" = "1" ]; then
    if [ "${ALLOW_PING:-1}" != "1" ]; then
      [ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" = "1" ]; _chk $? "сервер не отвечает на ping" "ping не отключён"
    fi
    fail2ban-client status dorik-portscan &>/dev/null; _chk $? "fail2ban: защита от сканирования портов активна" "fail2ban: jail dorik-portscan не работает"
  fi
  return "$VERIFY_FAIL"
}

# ---- запуск ------------------------------------------------------------------------------------------
harden_audit() {
  step "Аудит открытых портов"
  scan_listeners
  print_listeners
  local ex dk bl
  ex="$(count_state exposed)"; dk="$(count_state docker)"; bl="$(count_state blocked)"
  [ "$ex" -gt 0 ] && warn "Лишних открытых портов: ${ex} — их закроет «Укрепление сервера»."
  [ "$dk" -gt 0 ] && warn "Docker публикует порты на все интерфейсы (в обход ufw): $(docker_public_ports | tr '\n' ';') Перепубликуйте на 127.0.0.1."
  [ "$bl" -gt 0 ] && info "Ещё ${bl} порт(а) слушают, но закрыты firewall'ом — снаружи недоступны."
  [ "$ex" -eq 0 ] && [ "$dk" -eq 0 ] && ok "Снаружи доступны только нужные порты."
  return 0
}

harden_run() {
  local rc=0
  harden_audit
  step "Закрытие лишних портов"
  harden_firewall || rc=1
  harden_services || rc=1
  step "Укрепление системы"
  harden_sysctl || rc=1
  harden_ssh || rc=1
  harden_updates || rc=1
  [ "${SCAN_PROTECT:-1}" = "1" ] && { harden_shield || rc=1; }
  step "Проверка результата"
  verify_hardening || rc=1
  echo
  print_listeners
  return $rc
}

if [ "$_harden_standalone" = "1" ]; then
  require_root
  require_apt_os
  case "${1:-}" in
    --audit) banner; harden_audit; exit 0 ;;
    "") ensure_tty; banner; ensure_base_packages || true; harden_run; exit $? ;;
    *) echo "Использование: $0 [--audit]" >&2; exit 2 ;;
  esac
fi
