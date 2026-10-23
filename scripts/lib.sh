#!/usr/bin/env bash
# DORIK toolkit — общие функции. Подключается (source) каждым скриптом.
# Безопасно использовать с `set -euo pipefail` в вызывающем скрипте: все
# рискованные пайплайны здесь защищены `|| true` там, где ненулевой код — норма.

# Никаких интерактивных вопросов от apt/dpkg.
export DEBIAN_FRONTEND=noninteractive
# needrestart НЕ должен сам решать перезапускать службы (в т.ч. sshd) в фоне
# после apt install/upgrade — экспортируем это сразу при подключении lib.sh,
# чтобы это действовало во ВСЕХ скриптах тулкита.
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1

DORIK_RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
DORIK_TZ="${DORIK_TZ:-Asia/Irkutsk}"
DEFAULT_NODE_PORT="3001"

DORIK_VERSION="2.0"

# Оформление (цвета, рамки, спиннер, прогресс) лежит рядом, в ui.sh.
_dorik_source() {  # _dorik_source <файл рядом с lib.sh>
  local d t
  d="$(dirname "${BASH_SOURCE[0]}")"
  if [ -f "${d}/$1" ]; then
    # shellcheck disable=SC1090
    . "${d}/$1"
  else
    t="$(mktemp)"
    curl -fsSL --retry 3 "${DORIK_RAW}/scripts/$1" -o "$t" && . "$t"
  fi
}
_dorik_source ui.sh

# ---- ввод ------------------------------------------------------------------
# ASSUME_YES=1 — режим без вопросов (cloud-init / автоматический запуск):
# каждый вопрос получает значение по умолчанию, а оно берётся из переменных
# окружения (DOMAIN_TCP, SECRET_KEY, NEW_SSH_PORT и т.д., см. README).

# Откуда читать ответы. Если скрипт запущен через `curl ... | bash`, stdin занят
# самим скриптом (bash читает его оттуда) — переназначать stdin нельзя, иначе
# выполнение зависнет. Поэтому читаем ответы напрямую из /dev/tty.
tty_available() { { : </dev/tty; } 2>/dev/null; }
prompt_input() {
  if [ -t 0 ]; then echo /dev/stdin
  elif tty_available; then echo /dev/tty
  else echo /dev/stdin; fi
}

ensure_tty() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] && return 0
  tty_available && return 0
  err "Нет интерактивного терминала. Для запуска без вопросов задайте ASSUME_YES=1 и параметры через переменные окружения (см. README)."
  exit 1
}

# Numbered yes/no prompt. Usage: if ask_yes_no "Продолжить?" "1"; then ...
# Second arg = default numeric choice (1=yes,2=no) used if ENTER pressed.
ask_yes_no() {
  local prompt="${1:-}" default="${2:-1}" ans in
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    [ "$default" = "1" ]; return
  fi
  in="$(prompt_input)"
  while true; do
    read -r -p "$(echo -e "${C_Y}?${C_RESET} ${prompt} [1-Да / 2-Нет] (по умолчанию ${default}): ")" ans <"$in" || ans=""
    ans="${ans:-$default}"
    case "$ans" in
      1) return 0 ;;
      2) return 1 ;;
      *) echo "Введите 1 или 2." ;;
    esac
  done
}

ask_value() {
  local prompt="${1:-}" default="${2:-}" ans in
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    echo "$default"; return 0
  fi
  in="$(prompt_input)"
  read -r -p "$(echo -e "${C_Y}?${C_RESET} ${prompt}$( [ -n "$default" ] && echo " [$default]" ): ")" ans <"$in" || ans=""
  echo "${ans:-$default}"
}

is_valid_port()   { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_valid_domain() { [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
is_valid_ip()     { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ "${1:-}" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]]; }
is_valid_choice12() { [ "${1:-}" = "1" ] || [ "${1:-}" = "2" ]; }

# ask_valid <prompt> <default> <validator> [optional=0]
# Спрашивает, пока validator не примет значение. optional=1 — пустой ответ
# допустим. В режиме ASSUME_YES невалидное значение — ошибка (return 1).
# Вызывать как:  X=$(ask_valid ...) || exit 1
ask_valid() {
  local prompt="$1" default="${2:-}" validator="$3" optional="${4:-0}" v
  while true; do
    v=$(ask_value "$prompt" "$default")
    if [ -z "$v" ] && [ "$optional" = "1" ]; then echo ""; return 0; fi
    if [ -n "$v" ] && "$validator" "$v"; then echo "$v"; return 0; fi
    err "Недопустимое значение для «${prompt}»: '${v}'"
    [ "${ASSUME_YES:-0}" = "1" ] && return 1
    default=""
  done
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запустите скрипт от root (sudo -i)."
    exit 1
  fi
}

require_apt_os() {
  if ! command -v apt-get &>/dev/null; then
    err "Скрипты рассчитаны на Ubuntu/Debian (нужен apt-get)."
    exit 1
  fi
  local id=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && id="$(. /etc/os-release; echo "${ID:-}")"
  case "$id" in
    ubuntu|debian) ;;
    *) warn "Система '${id:-неизвестна}' не Ubuntu/Debian — скрипты не тестировались на ней." ;;
  esac
}

# ---- apt: ожидание блокировки, ретраи, неинтерактивные опции ----------------
# На свежем VPS cloud-init запускает unattended-upgrades сразу после первого
# старта, и он держит dpkg lock несколько минут. Раньше apt-get падал с
# "Could not get lock", это глоталось (|| true) — и ничего не устанавливалось.
APT_OPTS=(-y -qq
  -o DPkg::Lock::Timeout=120
  -o Acquire::Retries=3
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold)

apt_busy() {
  if command -v fuser &>/dev/null; then
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock &>/dev/null
  else
    pgrep -x 'apt|apt-get|dpkg|aptitude|unattended-upgr' &>/dev/null
  fi
}

wait_for_apt_lock() {
  local waited=0 limit=600
  while apt_busy; do
    if [ "$waited" -eq 0 ]; then
      warn "apt занят другим процессом (обычно unattended-upgrades на свежем VPS) — жду освобождения..."
    fi
    sleep 3; waited=$((waited+3))
    if [ "$waited" -ge "$limit" ]; then
      # Штатная остановка: unattended-upgrades доделывает текущий шаг dpkg.
      # kill -9 здесь не используем — он оставляет dpkg в битом состоянии.
      warn "apt занят больше 10 минут — прошу unattended-upgrades остановиться штатно."
      systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
      break
    fi
  done
}

# Если прошлый запуск apt/dpkg был прерван — чиним до начала работы.
fix_dpkg_state() {
  wait_for_apt_lock
  if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
    warn "dpkg в незавершённом состоянии — выполняю dpkg --configure -a"
    dpkg --configure -a --force-confdef --force-confold &>/dev/null || true
  fi
}

# apt_run <apt-get args...> — apt-get с опциями выше, с повтором при
# временных ошибках (блокировка, сеть, зеркало). Вывод показываем только при провале.
apt_run() {
  local logf attempt rc=1
  logf="$(mktemp)"
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    wait_for_apt_lock
    apt-get "${APT_OPTS[@]}" "$@" >"$logf" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then rm -f "$logf"; return 0; fi
    if grep -qiE 'dpkg was interrupted|dpkg --configure -a' "$logf"; then
      dpkg --configure -a --force-confdef --force-confold &>/dev/null || true
    elif grep -qiE 'Could not get lock|Unable to acquire the dpkg|Temporary failure|Could not resolve|Connection (timed out|failed|reset)|Failed to fetch|Hash Sum mismatch|is not valid yet|Some index files failed' "$logf"; then
      :
    else
      break
    fi
    warn "apt: временная ошибка (попытка ${attempt}/12), повторяю через 10 с..."
    sleep 10
  done
  err "apt-get $* завершился с ошибкой (код ${rc}):"
  tail -n 15 "$logf" >&2
  rm -f "$logf"
  return "$rc"
}

apt_update()  { spin_run "Обновление списков пакетов" apt_run update --allow-releaseinfo-change; }
apt_install() { spin_run "Установка пакетов: $*" apt_run install "$@"; }

# Базовый набор для любого этапа: на минимальном образе Ubuntu часть этого нет
# (ufw, dnsutils, psmisc, cron) — и раньше шаги молча «ставились» впустую.
BASE_PACKAGES=(curl ca-certificates iproute2 dnsutils unzip ufw cron openssl psmisc procps)

ensure_base_packages() {
  step "Базовые пакеты"
  fix_dpkg_state
  apt_update || warn "apt update не удался — продолжаю с имеющимися списками пакетов."
  if ! apt_install "${BASE_PACKAGES[@]}"; then
    warn "Общая установка не прошла — ставлю по одному."
    local p failed=()
    for p in "${BASE_PACKAGES[@]}"; do
      apt_install "$p" || failed+=("$p")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      err "Не установились: ${failed[*]}"
      return 1
    fi
  fi
  systemctl enable --now cron &>/dev/null || true
  ok "Базовые пакеты на месте."
}

# ---- обновление пакетов -----------------------------------------------------
apt_upgrade_smart() {
  fix_dpkg_state
  apt_update || warn "apt update не удался — считаю обновления по старым спискам."
  local cnt
  cnt=$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst ' || true)
  if [ "${cnt:-0}" -eq 0 ]; then
    ok "Пакеты уже актуальны, апгрейд не требуется."
  else
    info "Найдено обновлений: ${cnt}. Это может занять несколько минут."
    spin_run "Обновление ${cnt} пакетов" apt_run full-upgrade || return 1
    spin_run "Очистка ненужных пакетов" apt_run autoremove --purge || true
  fi
  if [ -f /var/run/reboot-required ]; then
    warn "После обновления нужна перезагрузка (ядро/библиотеки) — см. итог в конце."
  fi
  return 0
}

# ---- ssh.socket vs ssh.service ---------------------------------------------
# LoadState-проверка надёжнее grep по list-unit-files: формат вывода
# list-unit-files отличается между версиями systemd и однажды дал ложный
# результат — "sshd" вместо реального "ssh".
detect_ssh_unit() {
  local u
  for u in ssh sshd; do
    if [ "$(systemctl show -p LoadState --value "${u}.service" 2>/dev/null)" = "loaded" ]; then
      echo "$u"
      return 0
    fi
  done
  echo "ssh"  # ssh.service — норма для Debian/Ubuntu, sshd.service — для RHEL/CentOS
}

# Перезапускает SSH-службу, определяя юнит заново и подстраховываясь
# альтернативным именем, если определение всё равно ошиблось.
restart_ssh_service() {
  local unit alt out
  unit="$(detect_ssh_unit)"
  if ! out=$(systemctl restart "${unit}.service" 2>&1); then
    warn "systemctl restart ${unit}.service не сработал (${out}), пробую альтернативное имя."
    alt="sshd"; [ "$unit" = "sshd" ] && alt="ssh"
    if systemctl restart "${alt}.service" 2>&1; then
      unit="$alt"
    else
      err "Не удалось перезапустить ни ${unit}.service, ни ${alt}.service."
      return 1
    fi
  fi
  echo "$unit"
  return 0
}

ensure_no_ssh_socket() {
  if systemctl is-active ssh.socket &>/dev/null; then
    warn "ssh.socket активен и переопределяет порт — отключаю."
    systemctl stop ssh.socket 2>&1 || true
  fi
  systemctl disable ssh.socket &>/dev/null || true
  local unit; unit="$(detect_ssh_unit)"
  systemctl enable "${unit}" &>/dev/null || true
}

wait_for_port() {
  local port="${1:-}" tries=0
  [ -z "$port" ] && return 1
  while [ $tries -lt 10 ]; do
    if ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
      return 0
    fi
    sleep 1; tries=$((tries+1))
  done
  return 1
}

get_real_ssh_port() {
  local p=""
  p=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)
  if [ -z "$p" ] && command -v sshd &>/dev/null; then
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  fi
  echo "$p"
}

# ---- настоящая проверка живого SSH -----------------------------------------
# wait_for_port проверяет только "что-то слушает порт" — этим "что-то" может
# быть ssh.socket, который слушает, но не гарантирует, что sshd реально
# поднят и обслуживает соединения. Здесь проверяем и юнит, и что порт слушает
# именно процесс sshd (а не socket-заглушка).
ssh_is_really_up() {
  local port="${1:-}" unit_ok=0 u
  [ -z "$port" ] && return 1
  for u in ssh sshd; do
    systemctl is-active --quiet "${u}.service" 2>/dev/null && unit_ok=1 && break
  done
  [ "$unit_ok" = "1" ] || return 1
  local lines
  lines=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep sshd) || return 1
  # Порт может быть занят чужим процессом по IPv4 — тогда sshd садится только
  # на IPv6 и «слушает», но по IPv4 недоступен. Если у хоста есть глобальный
  # IPv4, требуем IPv4-листенер sshd, иначе это потеря доступа.
  if ip -4 addr show scope global 2>/dev/null | grep -q inet; then
    echo "$lines" | grep -vE '\[[0-9A-Fa-f:]*\]:' | grep -q .
  fi
}

# Порт обслуживается штатной socket-активацией (Ubuntu 22.10+/24.04 по умолчанию)
# и sshd реально способен стартовать — это нормальное рабочее состояние.
ssh_ok_via_socket() {
  local port="${1:-}"
  systemctl is-active --quiet ssh.socket 2>/dev/null || return 1
  ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" || return 1
  # Пока ssh.service не запущен, каталога /run/sshd нет и sshd -t ругается на
  # него, а не на конфиг (юнит создаёт его сам при старте).
  mkdir -p /run/sshd
  sshd -t 2>/dev/null
}

# Самовосстановление: если SSH на порту не работает — убирает ssh.socket с
# дороги, стартует сервис явно и сообщает, если всё равно не поднялся.
ssh_selfheal() {
  local port="${1:-}" unit
  if [ -z "$port" ]; then
    port="$(get_real_ssh_port)"
    port="${port:-22}"
  fi
  unit="$(detect_ssh_unit)"
  if ssh_is_really_up "$port"; then
    ok "SSH (${unit}.service) на порту ${port}: реально работает."
    return 0
  fi
  if ssh_ok_via_socket "$port"; then
    ok "SSH на порту ${port}: работает через ssh.socket."
    return 0
  fi
  warn "SSH на порту ${port} не отвечает как положено — пробую поднять явно (systemctl start ${unit}.service)."
  ensure_no_ssh_socket
  systemctl start "${unit}.service" 2>&1 || true
  sleep 1
  if ssh_is_really_up "$port"; then
    ok "SSH (${unit}.service) поднят и работает на порту ${port}."
    return 0
  fi
  local alt="sshd"; [ "$unit" = "sshd" ] && alt="ssh"
  warn "${unit}.service не поднялся, пробую альтернативный юнит ${alt}.service."
  systemctl start "${alt}.service" 2>&1 || true
  sleep 1
  if ssh_is_really_up "$port"; then
    ok "SSH (${alt}.service) поднят и работает на порту ${port}."
    return 0
  fi
  err "SSH НЕ поднимается на порту ${port} ни под одним именем юнита. Требуется ручное вмешательство: journalctl -u ssh.service -n 50, sshd -t."
  return 1
}

# Переносит sshd на порт $1 безопасно: бэкап, правка sshd_config и drop-in'ов,
# sshd -t, отключение ssh.socket, рестарт, проверка что порт реально обслуживает
# sshd. При любой неудаче возвращает прежний конфиг. 0 = порт переехал.
ssh_apply_port() {
  local new="${1:?port}" ts f cfg="/etc/ssh/sshd_config"
  ts="$(date +%s)"
  cp -f "$cfg" "${cfg}.bak.${ts}"
  mkdir -p /run/sshd

  sed -i -E '/^[#[:space:]]*Port[[:space:]]+[0-9]+/d' "$cfg"
  # Port в drop-in'ах (sshd_config.d/*.conf) СКЛАДЫВАЕТСЯ с основным — sshd
  # слушал бы и старый порт. Гасим их, с бэкапом рядом.
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" || continue
    cp -f "$f" "${f}.bak.${ts}"
    sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/#\1/' "$f"
  done
  echo "Port ${new}" >> "$cfg"

  _ssh_port_rollback() {
    cp -f "${cfg}.bak.${ts}" "$cfg"
    for f in /etc/ssh/sshd_config.d/*.conf.bak."${ts}"; do
      [ -f "$f" ] && mv -f "$f" "${f%.bak.${ts}}"
    done
  }

  if ! sshd -t 2>/tmp/dorik_sshd_err; then
    err "sshd -t отверг новую конфигурацию: $(head -1 /tmp/dorik_sshd_err) — откатываю."
    _ssh_port_rollback
    return 1
  fi

  ensure_no_ssh_socket
  restart_ssh_service >/dev/null
  sleep 1
  if wait_for_port "$new" && ssh_is_really_up "$new"; then
    return 0
  fi

  err "Новый порт ${new} не поднялся — возвращаю прежний конфиг SSH."
  _ssh_port_rollback
  restart_ssh_service >/dev/null || true
  return 1
}

# ---- ufw helpers -------------------------------------------------------
# Delete every numbered ufw rule matching a grep pattern, highest number first
# (works only while ufw is active; for inactive ufw use ufw_close_port).
ufw_delete_matching() {
  local pattern="${1:-}" nums n
  [ -z "$pattern" ] && return 0
  nums=$(ufw status numbered 2>/dev/null | grep -E "$pattern" \
        | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/' | sort -rn || true)
  for n in $nums; do
    ufw --force delete "$n" &>/dev/null || true
  done
}

# Убирает allow-правило для порта (tcp), работает и при выключенном ufw.
ufw_close_port() {
  local port="${1:-}"
  [ -z "$port" ] && return 0
  ufw delete allow "${port}/tcp" &>/dev/null || true
  ufw delete allow "${port}" &>/dev/null || true
  [ "$port" = "22" ] && ufw delete allow OpenSSH &>/dev/null || true
  return 0
}

# ---- DNS preflight ---------------------------------------------------------
# Certbot fails ("challenge failed") if the domain doesn't point at this
# server yet. Checking this BEFORE calling certbot avoids burning Let's
# Encrypt's rate limit on doomed attempts and gives a clear reason.
get_public_ip() {
  curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null \
    || true
}

# Usage: dns_points_here <domain> <public_ip>  → 0 if match, 1 otherwise.
dns_points_here() {
  local domain="${1:-}" pubip="${2:-}" resolved
  [ -z "$domain" ] && return 1
  resolved=$(dig +short A "$domain" 2>/dev/null | tail -1)
  if [ -z "$resolved" ]; then
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
  fi
  [ -n "$resolved" ] && [ -n "$pubip" ] && [ "$resolved" = "$pubip" ]
}

# ---- сертификат существует и не протух -------------------------------------
cert_is_valid() {
  local domain="${1:-}" cert
  [ -z "$domain" ] && return 1
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  [ -f "$cert" ] && openssl x509 -checkend 86400 -noout -in "$cert" &>/dev/null
}

# ---- Docker -------------------------------------------------------------------
install_docker() { curl -fsSL --retry 3 https://get.docker.com | sh; }

# Ставит Docker (официальный get.docker.com) с повторами и проверяет compose-плагин.
ensure_docker() {
  local attempt
  if ! command -v docker &>/dev/null; then
    step "Установка Docker"
    apt_update || true
    apt_install curl ca-certificates || true
    for attempt in 1 2 3; do
      wait_for_apt_lock
      spin_run "Установка Docker (get.docker.com)" install_docker && break
      warn "Установка Docker не удалась (попытка ${attempt}/3), повторяю..."
      fix_dpkg_state
      sleep 10
    done
    if ! command -v docker &>/dev/null; then
      err "Docker не установился."
      return 1
    fi
  fi
  systemctl enable --now docker &>/dev/null || true
  if ! docker compose version &>/dev/null; then
    apt_install docker-compose-plugin || true
    if ! docker compose version &>/dev/null; then
      err "docker compose недоступен — установите docker-compose-plugin вручную."
      return 1
    fi
  fi
  return 0
}

# Хук продления. Сертификаты Hysteria2/Xray монтируются в контейнер как
# symlink'и на конкретный файл в archive/ — после продления контейнер видит
# старый файл, пока его не пересоздать. Без хука через ~60 дней TLS протухает.
install_renew_hook() {
  install -d /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/dorik-reload.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
if [ -f /opt/remnanode/docker-compose.yml ] && grep -q '/etc/letsencrypt/live' /opt/remnanode/docker-compose.yml \
   && command -v docker >/dev/null 2>&1; then
  (cd /opt/remnanode && docker compose up -d --force-recreate) >/dev/null 2>&1 || true
fi
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/dorik-reload.sh
}

# ---- доступ к соседним скриптам ----------------------------------------------
# get_script <name> → печатает путь к исполняемому скрипту: лежащему рядом
# (локальный чекаут / /opt/dorik-toolkit) или скачанному из репозитория.
get_script() {
  local name="${1:?name}" f
  f="${SCRIPT_DIR:-.}/${name}"
  if [ -f "$f" ]; then echo "$f"; return 0; fi
  f="$(mktemp)"
  if curl -fsSL --retry 3 "${DORIK_RAW}/scripts/${name}" -o "$f"; then
    echo "$f"; return 0
  fi
  rm -f "$f"
  return 1
}
