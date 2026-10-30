#!/usr/bin/env bash
# DORIK toolkit — проверка сервера и исправление последствий старых версий
# скриптов (и ручных правок). Находит известные проблемы, показывает списком
# и по вашему согласию исправляет. Можно запускать сколько угодно раз.
#
# Запуск: напрямую (bash doctor.sh) или из меню. Без вопросов: ASSUME_YES=1.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
    t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
  } || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
  _dorik_source state.sh
  _dorik_source harden.sh
  _standalone=1
else
  _standalone=0
fi

declare -ga ISSUE_IDS=()
declare -gA ISSUE_TXT=()
# DORIK_IGNORE="time_sync,net_tuning" — не считать перечисленные замечания проблемами.
_issue() {
  case ",${DORIK_IGNORE:-}," in *",$1,"*) return 0 ;; esac
  [ -n "${ISSUE_TXT[$1]:-}" ] && return 0   # одно замечание — одна запись
  ISSUE_IDS+=("$1"); ISSUE_TXT["$1"]="$2"
}

# ---- поиск проблем -----------------------------------------------------------
doctor_scan() {
  ISSUE_IDS=(); ISSUE_TXT=()
  local sshp cfgp f

  # пакеты
  [ -n "$(dpkg --audit 2>/dev/null)" ] && _issue dpkg_audit "dpkg в незавершённом состоянии (прерванная установка пакетов)"

  # SSH
  if have sshd; then
    mkdir -p /run/sshd
    if ! sshd -t 2>/dev/null; then
      _issue sshd_cfg "sshd_config содержит ошибки — исправьте вручную: sshd -t"
    else
      cfgp="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
      if [ -n "$cfgp" ] && ! ssh_is_really_up "$cfgp" && ! ssh_ok_via_socket "$cfgp"; then
        _issue ssh_down "SSH не отвечает на настроенном порту ${cfgp}"
      fi
    fi
  fi
  sshp="$(get_real_ssh_port)"; sshp="${sshp:-${cfgp:-22}}"

  # firewall
  if ! have ufw; then
    _issue ufw_off "ufw не установлен — сервер без firewall"
  elif ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    _issue ufw_off "ufw выключен — сервер без firewall"
  else
    if ! ufw status 2>/dev/null | grep -qE "^${sshp}(/tcp)?[[:space:]]+ALLOW"; then
      _issue ufw_ssh "ufw: SSH-порт ${sshp} не разрешён (при перезагрузке/сбросе доступ пропадёт)"
    fi
    if ufw status numbered 2>/dev/null | grep -qE '\(temp\)|SSH (old|new|recovered|rollback)'; then
      _issue ufw_stale "ufw: остались временные/старые правила SSH от прежних версий скрипта"
    fi
  fi

  # fail2ban
  if ! have fail2ban-client; then
    _issue f2b "fail2ban не установлен — SSH не защищён от перебора паролей"
  elif ! fail2ban-client status sshd &>/dev/null; then
    _issue f2b "fail2ban: jail sshd не работает (нет backend=systemd или неверный порт)"
  elif [ -f /etc/fail2ban/jail.local ] && ! grep -q 'backend' /etc/fail2ban/jail.local; then
    _issue f2b "fail2ban: в jail.local нет backend=systemd (сломается на Ubuntu 24.04+ после обновления)"
  fi

  # старый crontab
  if have crontab; then
    crontab -l 2>/dev/null | grep -q 'shutdown -r now' && \
      _issue cron_legacy "перезагрузка по расписанию лежит в crontab root (прежний способ) — перенесу в /etc/cron.d"
    crontab -l 2>/dev/null | grep -q 'certbot renew' && \
      _issue cron_certbot "в crontab root дублируется certbot renew (его уже делает certbot.timer)"
  fi

  # сертификаты
  if compgen -G "/etc/letsencrypt/live/*/fullchain.pem" >/dev/null; then
    [ -x /etc/letsencrypt/renewal-hooks/deploy/dorik-reload.sh ] || \
      _issue renew_hook "нет хука продления сертификатов — после продления Hysteria2/nginx останутся на старом"
  fi

  # нода
  if [ -f "$NODE_DIR/docker-compose.yml" ]; then
    f="$NODE_DIR/docker-compose.yml"
    if ! grep -q 'cap_add' "$f" || ! grep -q 'logging' "$f" || \
       [ "$(stat -c '%a' "$f" 2>/dev/null)" != "600" ]; then
      _issue node_compose "compose ноды старого формата (нет NET_ADMIN/ulimits/ротации логов или права не 600)"
    fi
    [ "$(container_state remnanode)" = "restarting" ] && \
      _issue node_crash "контейнер remnanode перезапускается по кругу — проверьте SECRET_KEY: docker logs remnanode"
  fi

  # сеть
  if [ -f "$NODE_DIR/docker-compose.yml" ] || svc_exists haproxy; then
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr* ]] || [ ! -f /etc/sysctl.d/99-dorik-net.conf ]; then
      _issue net_tuning "не включены BBR и сетевая оптимизация ноды"
    fi
  fi

  # web
  if have haproxy && [ -f /etc/haproxy/haproxy.cfg ] && ! haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null; then
    _issue haproxy_cfg "конфиг HAProxy невалиден — перенастройте через «Только Nginx+HAProxy»"
  fi
  if [ -e /etc/nginx/sites-enabled/default ] && { [ -e /etc/nginx/sites-enabled/decoy ] || compgen -G "/etc/nginx/sites-enabled/decoy-*" >/dev/null; }; then
    _issue nginx_default "включён стандартный сайт nginx — занимает порт 80 и мешает выпуску сертификатов"
  fi
  # Старый формат: одна заглушка на все протоколы (чужой сертификат на gRPC/XHTTP-доменах, одинаковые страницы)
  if [ -e /etc/nginx/sites-enabled/decoy ] && [ ! -s /etc/dorik/decoys.conf ]; then
    _issue decoy_legacy "одна общая заглушка на все протоколы (старый формат) — нужна отдельная и разная для каждого"
  fi
  # Настроенные, но остановленные службы: нода/панель без них недоступны.
  if [ -e /etc/nginx/sites-enabled/decoy ] || compgen -G "/etc/nginx/sites-enabled/decoy-*" >/dev/null \
     || compgen -G "/etc/nginx/sites-enabled/remnawave-*" >/dev/null; then
    svc_active nginx || _issue web_down "nginx настроен, но остановлен"
  fi
  if svc_exists haproxy && [ -f /etc/haproxy/haproxy.cfg ] && grep -q 'fe_443' /etc/haproxy/haproxy.cfg; then
    svc_active haproxy || _issue web_down "HAProxy настроен, но остановлен — клиенты не подключатся"
  fi
  # WEB-прокси Telegram (Telemt): установлен, но служба не работает
  if [ -f /etc/dorik/webproxy.json ] && [ -f /etc/systemd/system/mtproxy-web.service ]; then
    svc_active mtproxy-web || _issue webproxy_down "WEB-прокси Telegram установлен, но служба mtproxy-web не работает"
  fi

  # панель
  if [ -f "$PANEL_DIR/.env" ]; then
    if [ "$(stat -c '%a' "$PANEL_DIR/.env" 2>/dev/null)" != "600" ]; then
      _issue panel_env "файл $PANEL_DIR/.env с секретами доступен не только root"
    fi
  fi

  # время: неверные часы ломают TLS, apt и продление сертификатов
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ]; then
    _issue time_sync "системное время не синхронизируется (NTP) — ломает TLS и сертификаты"
  fi

  # сертификаты, которым осталось меньше 14 дней (продление не сработало)
  local cf end d days
  for cf in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$cf" ] || continue
    end="$(openssl x509 -enddate -noout -in "$cf" 2>/dev/null | cut -d= -f2)"
    d="$(date -d "$end" +%s 2>/dev/null)" || continue
    days=$(( (d - $(date +%s)) / 86400 ))
    if [ "$days" -lt 14 ]; then
      _issue cert_expiring "сертификат $(basename "$(dirname "$cf")") истекает через ${days} дн. — автопродление не сработало"
      break
    fi
  done

  # Docker и контейнеры
  if [ -f "$NODE_DIR/docker-compose.yml" ] || [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    if ! have docker || ! svc_active docker; then
      _issue docker_down "Docker не установлен или не запущен, а нода/панель его используют"
    else
      if [ -f "$NODE_DIR/docker-compose.yml" ]; then
        local ns; ns="$(container_state remnanode)"
        if [ "$ns" != "running" ] && [ "$ns" != "restarting" ]; then
          _issue node_down "контейнер remnanode не запущен (состояние: ${ns:-нет})"
        fi
      fi
      if [ -f "$PANEL_DIR/docker-compose.yml" ]; then
        local c bad=0
        for c in remnawave remnawave-db remnawave-redis; do container_running "$c" || bad=1; done
        [ "$bad" = 1 ] && _issue panel_down "контейнеры панели Remnawave запущены не все"
      fi
      if [ -f "$SUB_DIR/docker-compose.yml" ] && ! container_running remnawave-subscription-page; then
        _issue sub_down "контейнер страницы подписки не запущен"
      fi
    fi
  fi

  # открытые порты и укрепление (модуль harden.sh)
  if declare -F scan_listeners &>/dev/null; then
    local ex dk
    scan_listeners
    ex="$(count_state exposed)"; dk="$(count_state docker)"
    [ "$ex" -gt 0 ] && _issue ports_exposed "наружу открыто лишних портов: ${ex} — их нужно закрыть"
    [ "$dk" -gt 0 ] && _issue docker_public "Docker публикует порты на все интерфейсы в обход ufw: $(docker_public_ports | head -3 | tr '\n' ';') — перепубликуйте на 127.0.0.1"
    if have ufw && grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; then
      _issue ufw_ipv6 "ufw не фильтрует IPv6 (IPV6=no) — по IPv6 сервер открыт целиком"
    fi
    if [ ! -f /etc/sysctl.d/98-dorik-hardening.conf ] || [ ! -f /etc/ssh/sshd_config.d/00-dorik-hardening.conf ] \
       || ! grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
      _issue hardening_missing "не применено укрепление системы (ядро, SSH, автообновления безопасности)"
    elif [ "${SCAN_PROTECT:-1}" = "1" ] && { [ ! -f /etc/fail2ban/jail.d/dorik-portscan.conf ] \
         || { [ "${ALLOW_PING:-1}" != "1" ] && [ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" != "1" ]; }; }; then
      _issue shield_missing "нет щита от сканеров (бан перебора портов; ping скрыт только при ALLOW_PING=0)"
    fi
  fi
  return 0
}

# ---- исправления -------------------------------------------------------------
fix_dpkg_audit() { dpkg --configure -a --force-confdef --force-confold; }

fix_ssh_down() {
  local p; p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  ssh_selfheal "${p:-22}"
}

fix_ufw_off() {
  have ufw || apt_install ufw || return 1
  local p; p="$(get_real_ssh_port)"; p="${p:-$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')}"; p="${p:-22}"
  ufw default deny incoming &>/dev/null; ufw default allow outgoing &>/dev/null
  ufw allow "${p}/tcp" comment "SSH" &>/dev/null; info "открыт SSH ${p}/tcp"
  if svc_active nginx || svc_active haproxy || [ -f "$PANEL_DIR/docker-compose.yml" ]; then
    ufw allow 80/tcp comment "HTTP" &>/dev/null; ufw allow 443/tcp comment "HTTPS" &>/dev/null
    info "открыты 80/tcp и 443/tcp (работают nginx/haproxy/панель)"
  fi
  if [ -f "$NODE_DIR/docker-compose.yml" ]; then
    local np; np="$(grep -oE 'NODE_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" | head -1 | cut -d= -f2)"
    ufw allow 443/udp comment "Hysteria2" &>/dev/null
    # Правило порта ноды уже могло быть (в т.ч. ограниченное IP панели) — при выключенном
    # ufw `status` его не показывает, а `show added` показывает. Не затираем его открытым.
    if [ -n "$np" ]; then
      if ufw show added 2>/dev/null | grep -qE "[ /]${np}(/tcp| proto|\$)"; then
        info "правило для порта ноды ${np} уже есть — оставляю как есть"
      else
        ufw allow "${np}/tcp" comment "Node panel" &>/dev/null && info "открыт порт ноды ${np}/tcp"
      fi
    fi
  fi
  ufw --force enable &>/dev/null
}

fix_ufw_ssh() {
  local p; p="$(get_real_ssh_port)"; p="${p:-22}"
  ufw allow "${p}/tcp" comment "SSH" &>/dev/null
}

fix_ufw_stale() {
  ufw_delete_matching '\(temp\)|SSH (old|new|recovered|rollback)'
}

fix_f2b() {
  install_fail2ban || return 1
  local p; p="$(get_real_ssh_port)"; p="${p:-$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')}"; p="${p:-22}"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${p}
backend  = systemd
maxretry = 3
findtime = 1h
bantime  = 1d
EOF
  systemctl enable fail2ban &>/dev/null
  systemctl restart fail2ban
}

fix_cron_legacy() {
  crontab -l 2>/dev/null | grep -v 'shutdown -r now' | crontab - || true
  echo "0 4 * * * root /sbin/shutdown -r now" > /etc/cron.d/dorik-reboot
  chmod 644 /etc/cron.d/dorik-reboot
}

fix_cron_certbot() { crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - || true; }

fix_renew_hook() { install_renew_hook; }

fix_node_compose() {
  # remnanode-setup подхватит SECRET_KEY/порт/сертификат Hysteria2 из текущего compose.
  local f="$NODE_DIR/docker-compose.yml" hy2 src
  hy2="$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain.pem:/etc/hysteria' "$f" | head -1 | sed -E 's#.*live/([^/]+)/fullchain.*#\1#')"
  src="$(get_script remnanode-setup.sh)" || return 1
  NONINTERACTIVE=1 USE_HY2="$([ -n "$hy2" ] && echo 1 || echo 0)" DOMAIN_HY2="$hy2" bash "$src"
}

fix_net_tuning() { local src; src="$(get_script bbr-install.sh)" || return 1; NONINTERACTIVE=1 bash "$src"; }

fix_nginx_default() { rm -f /etc/nginx/sites-enabled/default; nginx -t &>/dev/null && systemctl reload nginx; }

fix_panel_env() { chmod 600 "$PANEL_DIR/.env"; }

fix_time_sync() { timedatectl set-ntp true; }

# Исправления из harden.sh выполняются внутри спиннера без терминала — вопросы
# задавать некому, поэтому ASSUME_YES=1 (пользователь уже согласился на исправление).
fix_ports_exposed()     { ( ASSUME_YES=1; harden_firewall; harden_services ); }
fix_ufw_ipv6()          { sed -i -E 's/^IPV6=no/IPV6=yes/' /etc/default/ufw && ufw reload; }
fix_shield_missing()    { ( ASSUME_YES=1; harden_shield ); }
fix_hardening_missing() { ( ASSUME_YES=1; harden_sysctl; harden_ssh; harden_updates ); }

# Миграция со старого формата: домены восстанавливаем из того, что уже настроено (nginx-сайт
# старой заглушки, HAProxy, compose ноды), и перезапускаем haproxy-setup — он поставит разные заглушки.
fix_decoy_legacy() {
  local old=/etc/nginx/sites-available/decoy src dtcp dgrpc dxhttp dhy2 cfg=/etc/haproxy/haproxy.cfg
  # значение директивы server_name (работает и для сайта в одну строку, и для многострочного)
  dtcp="$(grep -oE 'server_name[[:space:]]+[^;[:space:]]+' "$old" 2>/dev/null | awk '$2!="_"{print $2; exit}')"
  dgrpc="$(grep -oE 'be_grpc if \{ req.ssl_sni -i [^ ]+' "$cfg" 2>/dev/null | awk '{print $NF}')"
  dxhttp="$(grep -oE 'be_xhttp if \{ req.ssl_sni -i [^ ]+' "$cfg" 2>/dev/null | awk '{print $NF}')"
  dhy2="$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain.pem:/etc/hysteria' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | sed -E 's#.*live/([^/]+)/fullchain.*#\1#')"
  [ -n "$dtcp" ] || { echo "Не удалось определить домен REALITY TCP из старой заглушки — запустите «Только Nginx+HAProxy» вручную."; return 1; }
  src="$(get_script haproxy-setup.sh)" || return 1
  NONINTERACTIVE=1 INSTALL_DECOY=1 DOMAIN_TCP="$dtcp" DOMAIN_GRPC="$dgrpc" DOMAIN_XHTTP="$dxhttp" \
    DOMAIN_HY2="$dhy2" USE_HY2="$([ -n "$dhy2" ] && echo 1 || echo 0)" bash "$src"
}

fix_webproxy_down() { systemctl restart mtproxy-web && sleep 3 && svc_active mtproxy-web; }

fix_web_down() {
  local rc=0
  if [ -e /etc/nginx/sites-enabled/decoy ] || compgen -G "/etc/nginx/sites-enabled/decoy-*" >/dev/null \
     || compgen -G "/etc/nginx/sites-enabled/remnawave-*" >/dev/null; then
    nginx -t &>/dev/null && systemctl restart nginx || rc=1
  fi
  if svc_exists haproxy && grep -q 'fe_443' /etc/haproxy/haproxy.cfg 2>/dev/null; then
    haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null && systemctl restart haproxy || rc=1
  fi
  return $rc
}

fix_cert_expiring() { certbot renew --no-random-sleep-on-renew; }

fix_docker_down() {
  if have docker; then systemctl enable --now docker; else ensure_docker; fi
}

fix_node_down()  { (cd "$NODE_DIR" && docker compose up -d); }
fix_panel_down() { (cd "$PANEL_DIR" && docker compose up -d); }
fix_sub_down()   { (cd "$SUB_DIR" && docker compose up -d); }

fix_haproxy_cfg() {
  if [ "${ASSUME_YES:-0}" = "1" ]; then warn "требуется ввод доменов — запустите вручную: «Только Nginx+HAProxy»"; return 1; fi
  local src; src="$(get_script haproxy-setup.sh)" || return 1
  bash "$src"
}

# ---- запуск ------------------------------------------------------------------
# doctor_run: показывает проблемы, спрашивает, исправляет, перепроверяет.
doctor_run() {
  local id n_before n_after fixed=0 failed=()
  step "Проверка сервера"
  doctor_scan
  if [ "${#ISSUE_IDS[@]}" -eq 0 ]; then
    ok "Известных проблем не найдено — всё в порядке."
    return 0
  fi
  n_before=${#ISSUE_IDS[@]}
  echo
  box_top "Найдено проблем: ${n_before}"
  for id in "${ISSUE_IDS[@]}"; do box_wrap "${C_Y}▲${C_RESET}" "${ISSUE_TXT[$id]}"; done
  box_bottom
  echo
  ask_yes_no "Исправить найденное автоматически?" "1" || { warn "Оставлено как есть."; return 1; }

  local -a todo=("${ISSUE_IDS[@]}")
  for id in "${todo[@]}"; do
    if ! declare -F "fix_${id}" &>/dev/null; then
      warn "${ISSUE_TXT[$id]} — автоисправления нет, нужно вручную."
      failed+=("$id"); continue
    fi
    if spin_run "Исправляю: ${ISSUE_TXT[$id]:0:44}…" "fix_${id}"; then fixed=$((fixed+1)); else failed+=("$id"); fi
  done

  doctor_scan
  n_after=${#ISSUE_IDS[@]}
  echo
  if [ "$n_after" -eq 0 ]; then
    ok "Перепроверка: все проблемы устранены (${fixed} исправлено)."
    return 0
  fi
  warn "Перепроверка: осталось проблем — ${n_after}:"
  for id in "${ISSUE_IDS[@]}"; do echo -e "      ${C_Y}•${C_RESET} ${ISSUE_TXT[$id]}" >&2; done
  return 1
}

if [ "$_standalone" = "1" ]; then
  require_root
  ensure_tty
  banner
  doctor_run
fi
