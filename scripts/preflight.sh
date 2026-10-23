#!/usr/bin/env bash
# DORIK toolkit — предполётная проверка окружения.
# Ловит проблемы ДО установки, а не на середине: нет сети, мало места, нет systemd,
# порты 80/443 заняты чужим процессом, часы убежали (ломают TLS и apt) и т.п.
# Подключается после lib.sh и state.sh.
#
#   preflight_run [--docker] [--certs] [--ports "80 443"] [--ram-mb 1024] [--disk-gb 5]
#
# Возвращает число ФАТАЛЬНЫХ проблем (0 = можно продолжать). Предупреждения не
# останавливают установку. PREFLIGHT_SKIP=1 пропускает проверку целиком.

_pf_fatal=0
_pf_warn=0
_pf_ok()    { ok "$1"; }
_pf_fail()  { err "$1"; _pf_fatal=$((_pf_fatal+1)); }
_pf_note()  { warn "$1"; _pf_warn=$((_pf_warn+1)); }

# Достижимость хоста по HTTPS (любой HTTP-ответ, в т.ч. 401/404, = достижим).
_pf_reach() {  # _pf_reach <url>
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null)" || true
  [ -n "$code" ] && [ "$code" != "000" ]
}

preflight_run() {
  local need_docker=0 need_certs=0 ports="" ram_min=1024 disk_min=5 allow='nginx|haproxy'
  while [ $# -gt 0 ]; do
    case "$1" in
      --docker)  need_docker=1 ;;
      --certs)   need_certs=1 ;;
      --ports)   ports="$2"; shift ;;
      --allow)   allow="$2"; shift ;;   # какие процессы вправе держать порты (regex)
      --ram-mb)  ram_min="$2"; shift ;;
      --disk-gb) disk_min="$2"; shift ;;
    esac
    shift
  done
  _pf_fatal=0; _pf_warn=0

  if [ "${PREFLIGHT_SKIP:-0}" = "1" ]; then
    warn "Предполётная проверка отключена (PREFLIGHT_SKIP=1)."
    return 0
  fi

  step "Проверка окружения"

  # ---- система --------------------------------------------------------------
  local id="" ver="" arch
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release; echo "${ID:-}")"; ver="$(. /etc/os-release; echo "${VERSION_ID:-}")"
  fi
  case "$id:$ver" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) _pf_ok "ОС: ${id} ${ver} (проверена)" ;;
    ubuntu:*|debian:*) _pf_note "ОС: ${id} ${ver} — не из проверенных (Ubuntu 22.04/24.04/26.04); обычно работает, но без гарантий" ;;
    *) _pf_note "ОС: '${id:-неизвестна}' — скрипты рассчитаны на Ubuntu/Debian" ;;
  esac

  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) _pf_ok "Архитектура: ${arch}" ;;
    *) _pf_note "Архитектура ${arch}: образы Remnawave собираются только под x86_64/aarch64" ;;
  esac

  if [ -d /run/systemd/system ]; then _pf_ok "systemd: работает"
  else _pf_fail "systemd не запущен как init (контейнер/chroot?) — службы управлять нечем"; fi

  local virt
  virt="$(systemd-detect-virt -c 2>/dev/null || true)"
  case "$virt" in
    ""|none) ;;
    openvz|lxc|lxc-libvirt) _pf_note "Контейнерная виртуализация (${virt}): BBR и sysctl могут быть недоступны, зависит от хостера" ;;
    docker|podman) _pf_note "Скрипт запущен внутри контейнера (${virt}) — firewall, sysctl и службы работать не будут" ;;
  esac

  # ---- ресурсы --------------------------------------------------------------
  local ram free_gb
  ram="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  if [ -n "$ram" ] && [ "$ram" -ge "$ram_min" ]; then _pf_ok "Память: ${ram} МБ"
  else _pf_note "Памяти ${ram:-?} МБ, рекомендуется от ${ram_min} МБ — возможны тормоза и OOM"; fi

  free_gb="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -z "$free_gb" ]; then _pf_note "Не удалось определить свободное место на /"
  elif [ "$free_gb" -lt 2 ]; then _pf_fail "Свободно ${free_gb} ГБ на / — этого не хватит даже на обновления (нужно хотя бы 2, лучше ${disk_min})"
  elif [ "$free_gb" -lt "$disk_min" ]; then _pf_note "Свободно ${free_gb} ГБ на /, рекомендуется от ${disk_min} ГБ"
  else _pf_ok "Диск: свободно ${free_gb} ГБ"; fi

  # ---- время ----------------------------------------------------------------
  local ntp
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [ "$ntp" = "yes" ]; then _pf_ok "Время синхронизировано (NTP)"
  elif [ "$ntp" = "no" ]; then _pf_note "Время не синхронизировано — сертификаты и apt могут ругаться на неверную дату (timedatectl set-ntp true)"
  fi

  # ---- сеть -----------------------------------------------------------------
  if getent hosts github.com &>/dev/null; then _pf_ok "DNS: github.com разрешается"
  else _pf_fail "DNS не работает (github.com не разрешается) — проверьте /etc/resolv.conf и сеть"; fi

  if _pf_reach https://github.com; then _pf_ok "HTTPS: github.com доступен"
  else _pf_fail "github.com по HTTPS недоступен — тулкит и файлы Remnawave не скачать"; fi

  if [ "$need_docker" = 1 ]; then
    if _pf_reach https://registry-1.docker.io/v2/; then _pf_ok "Docker Hub доступен"
    else _pf_fail "Docker Hub (registry-1.docker.io) недоступен — образы не скачать"; fi
    if command -v docker &>/dev/null || _pf_reach https://download.docker.com/; then _pf_ok "Docker: установка возможна"
    else _pf_fail "download.docker.com недоступен — Docker не установить"; fi
  fi

  if [ "$need_certs" = 1 ]; then
    if _pf_reach https://acme-v02.api.letsencrypt.org/directory; then _pf_ok "Let's Encrypt доступен"
    else _pf_note "Let's Encrypt (acme-v02.api.letsencrypt.org) недоступен — сертификаты не выпустятся"; fi
  fi

  local pub
  pub="$(get_public_ip)"
  if [ -n "$pub" ]; then _pf_ok "Публичный IPv4: ${pub}"
  else _pf_note "Публичный IPv4 не определён — проверка DNS доменов будет пропущена"; fi

  # ---- порты ----------------------------------------------------------------
  # Свободны или заняты нашими же nginx/haproxy (повторный запуск — норма).
  local p busy
  for p in $ports; do
    busy="$(ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -vE "$allow" || true)"
    if [ -z "$busy" ]; then _pf_ok "Порт ${p}/tcp доступен (свободен или занят ${allow//|/\/})"
    else
      _pf_fail "Порт ${p}/tcp занят чужим процессом: $(echo "$busy" | head -1 | grep -oE 'users:\(\("[^"]+"' | head -1 | sed 's/users:((//; s/"//g')"
    fi
  done

  echo
  if [ "$_pf_fatal" -gt 0 ]; then
    err "Проверка окружения: критичных проблем — ${_pf_fatal}, предупреждений — ${_pf_warn}. Установка остановлена."
    err "Исправьте причины выше. Если уверены, что всё в порядке: PREFLIGHT_SKIP=1."
  elif [ "$_pf_warn" -gt 0 ]; then
    warn "Проверка окружения: предупреждений — ${_pf_warn}, критичных нет. Продолжаю."
  else
    ok "Проверка окружения: всё в порядке."
  fi
  return "$_pf_fatal"
}
