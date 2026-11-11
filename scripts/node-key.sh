#!/usr/bin/env bash
# DORIK toolkit — смена SECRET_KEY ноды Remnawave (Remnanode).
#
#   node-key.sh            — ввести новый ключ (ввод скрыт) и применить
#   node-key.sh api        — взять ключ у панели по API (нужны адрес панели и токен)
#   node-key.sh show       — показать состояние: порт, контейнер, ключ в сокращённом виде
#
# Когда нужно: нода в панели «offline» с ошибкой «Client network socket disconnected before secure TLS
# connection was established» — нода закрывает соединение, если её ключ не совпадает с ключом панели.
# Новый ключ берут в панели: Ноды → ваша нода → «Скопировать docker-compose.yml» (или при создании ноды).
#
# Что делает: сохраняет копию docker-compose.yml, заменяет в нём только строку SECRET_KEY (порт, тома и
# остальное не трогает), пересоздаёт контейнер, ждёт порт ноды и проверяет логи. Если нода после замены не
# поднялась — возвращает прежний файл. Ключ не печатается и не попадает в журнал.
# Без вопросов: NODE_SECRET_KEY=... ASSUME_YES=1 bash node-key.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh

# ---- помощники (без побочных эффектов — их проверяют отдельно) ---------------------------------
# Чистит ключ: убирает кавычки, пробелы и переводы строк (частая причина «Invalid SECRET_KEY payload»).
# Если вставили строку «- SECRET_KEY=…» или «SECRET_KEY=…» целиком, берёт только значение.
nk_clean() {
  printf '%s' "$1" | tr -d '\r\n\t ' | sed -E 's/^-?SECRET_KEY=//; s/^"+//; s/"+$//; s/^'"'"'+//; s/'"'"'+$//'
}

# Ключ панели — base64 от JSON. 0 — похож, 1 — нет.
nk_looks_valid() {
  [ "${#1}" -ge 40 ] || return 1
  printf '%s' "$1" | base64 -d 2>/dev/null | head -c 1 | grep -q '{'
}

# Сокращённый вид для экрана: первые 6 и последние 4 символа, длина.
nk_mask() {
  local k="$1"
  [ -n "$k" ] || { echo "(не задан)"; return 0; }
  if [ "${#k}" -le 14 ]; then echo "(слишком короткий: ${#k} симв.)"; return 0; fi
  echo "${k:0:6}…${k: -4}  (${#k} симв.)"
}

# Заменяет значение SECRET_KEY в compose, больше ничего не трогая. Возвращает 1, если строки с ключом нет.
nk_apply_key() {  # nk_apply_key <файл> <ключ>
  local f="$1" k="$2" tmp
  grep -qE '^[[:space:]]*-[[:space:]]*SECRET_KEY=' "$f" || return 1
  tmp="$(mktemp)"
  awk -v k="$k" '/^[[:space:]]*-[[:space:]]*SECRET_KEY=/ { sub(/SECRET_KEY=.*/, "SECRET_KEY=" k) } { print }' "$f" > "$tmp" \
    && cat "$tmp" > "$f"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

nk_current_key() { grep -oE 'SECRET_KEY=[^[:space:]]+' "$1" 2>/dev/null | head -1 | sed 's/SECRET_KEY=//; s/^"//; s/"$//'; }
nk_node_port()   { grep -oE 'NODE_PORT=[0-9]+' "$1" 2>/dev/null | head -1 | cut -d= -f2; }

# Логи с признаками неверного ключа или конфигурации.
nk_log_problem() {
  docker logs remnanode --tail 40 2>&1 | grep -iE 'invalid secret_key|secret_key contains|Environment Configuration Errors|invalid json' | head -3
}

nk_wait_port() {  # порт держит процесс ноды, а не sshd/nginx/haproxy; до 30 с
  local port="$1" i
  for i in $(seq 1 15); do
    ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -vqE 'sshd|nginx|haproxy' && return 0
    sleep 2
  done
  return 1
}

# Если файл подключён как библиотека (source) — только функции выше, без запуска.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

require_root
COMPOSE="${NODE_DIR}/docker-compose.yml"

node_show() {
  local key port state
  [ -f "$COMPOSE" ] || { warn "Нода не настроена: нет ${COMPOSE}."; return 1; }
  key="$(nk_current_key "$COMPOSE")"; port="$(nk_node_port "$COMPOSE")"
  state="$(container_state remnanode)"
  box_top "Нода Remnanode"
  box_row "Порт ноды:     ${port:-?}"
  box_row "Контейнер:     ${state:-нет}"
  box_row "SECRET_KEY:    $(nk_mask "$key")"
  box_row "$(nk_looks_valid "$key" && echo "${C_G}✔${C_RESET} формат ключа верный" || echo "${C_R}✖${C_RESET} ключ не похож на ключ из панели")"
  box_bottom
  local prob; prob="$(nk_log_problem)"
  [ -n "$prob" ] && { warn "В логах ноды есть признаки неверного ключа/конфигурации:"; echo "$prob" | sed 's/^/      /' >&2; }
  return 0
}

# Где взять ключ: ввод вручную (скрытый) либо по API панели.
nk_read_key() {
  local raw=""
  if [ -n "${NODE_SECRET_KEY:-}" ]; then printf '%s' "$NODE_SECRET_KEY"; return 0; fi
  [ "${ASSUME_YES:-0}" = "1" ] && return 1
  info "Ключ берут в панели: Ноды → ваша нода → «Скопировать docker-compose.yml» (или ключ при создании ноды)." >&2
  info "Вставьте SECRET_KEY или строку «- SECRET_KEY=…» целиком — ввод не отображается, затем Enter." >&2
  read -r -s -p "$(echo -e "${C_Y}?${C_RESET} SECRET_KEY: ")" raw <"$(prompt_input)" || return 1
  echo >&2
  printf '%s' "$raw"
}

nk_key_from_api() {
  _dorik_source profile-setup.sh
  have jq || apt_install jq || { err "jq нужен для работы с API."; return 1; }
  local url="${PANEL_URL:-}" k
  RW_TOKEN="${PANEL_API_TOKEN:-${REMNAWAVE_API_TOKEN:-}}"
  info "Адрес панели: домен или ссылка для входа (https:// можно не писать)." >&2
  url=$(ask_valid "Адрес панели" "$url" _is_panel_addr) || return 1
  [[ "$url" =~ ^https?:// ]] || url="https://${url}"
  rw_parse_url "$url" || { err "Не удалось разобрать адрес панели."; return 1; }
  if [ -z "$RW_TOKEN" ]; then
    info "Токен: панель → Настройки → API-токены (в чат и в журнал он не попадает)." >&2
    read -r -s -p "$(echo -e "${C_Y}?${C_RESET} API-токен панели: ")" RW_TOKEN <"$(prompt_input)" || return 1
    echo >&2
    RW_TOKEN="$(printf '%s' "$RW_TOKEN" | tr -d ' \r\n"')"
  fi
  rw_check >&2 || return 1
  k="$(fetch_secret_key)" || return 1
  [ -n "$k" ] || { err "Панель не вернула ключ."; return 1; }
  printf '%s' "$k"
}

node_change_key() {
  local mode="${1:-manual}" raw key old port ts bak
  [ -f "$COMPOSE" ] || { err "Нода не настроена: нет ${COMPOSE}. Сначала установите её («Только Remnanode»)."; return 1; }
  ensure_docker || return 1
  old="$(nk_current_key "$COMPOSE")"; port="$(nk_node_port "$COMPOSE")"
  info "Сейчас в compose: SECRET_KEY $(nk_mask "$old"), порт ${port:-?}"

  if [ "$mode" = "api" ]; then raw="$(nk_key_from_api)" || return 1
  else raw="$(nk_read_key)" || { err "Ключ не задан (NODE_SECRET_KEY для запуска без вопросов)."; return 1; }; fi
  key="$(nk_clean "$raw")"
  [ -n "$key" ] || { err "Ключ пуст."; return 1; }

  if ! nk_looks_valid "$key"; then
    warn "Ключ не похож на ключ из панели (ожидается длинная base64-строка от JSON). Скопируйте его целиком."
    if [ "${ASSUME_YES:-0}" = "1" ] || ! ask_yes_no "Всё равно использовать этот ключ?" "2"; then
      err "Отменено: проверьте ключ."; return 1
    fi
  fi
  if [ "$key" = "$old" ]; then
    ok "Этот ключ уже стоит на ноде — менять нечего. Если нода всё равно offline, причина в другом: docker logs remnanode --tail 30; порт ${port:-3001}."
    return 0
  fi

  ts="$(date +%Y%m%d-%H%M%S)"; bak="${COMPOSE}.bak.${ts}"
  ( umask 077; cp -f "$COMPOSE" "$bak" ) || { err "Не удалось сохранить копию compose."; return 1; }
  nk_apply_key "$COMPOSE" "$key" || { err "В ${COMPOSE} не нашлась строка SECRET_KEY — файл не менялся."; rm -f "$bak"; return 1; }
  chmod 600 "$COMPOSE"
  ok "Ключ заменён в ${COMPOSE} (копия: ${bak})"

  if ! (cd "$NODE_DIR" && docker compose config &>/dev/null); then
    err "docker-compose.yml после замены не валиден — возвращаю прежний."
    cp -f "$bak" "$COMPOSE"; return 1
  fi
  if ! spin_run "Пересоздание контейнера remnanode" bash -c "cd '$NODE_DIR' && docker compose up -d --force-recreate"; then
    err "Не удалось пересоздать контейнер — возвращаю прежний файл."
    cp -f "$bak" "$COMPOSE"; (cd "$NODE_DIR" && docker compose up -d --force-recreate &>/dev/null) || true
    return 1
  fi

  sleep 3
  local problem=0
  container_running remnanode || { err "Контейнер не запустился."; problem=1; }
  if [ -n "$port" ] && ! spin_run "Ожидание порта ноды ${port}" nk_wait_port "$port" 2>/dev/null; then
    err "Порт ноды ${port} не слушает."; problem=1
  fi
  if [ -n "$(nk_log_problem)" ]; then err "В логах ноды ошибка ключа/конфигурации:"; nk_log_problem | sed 's/^/      /' >&2; problem=1; fi

  if [ "$problem" = "1" ]; then
    warn "Нода с новым ключом не поднялась — возвращаю прежний compose."
    cp -f "$bak" "$COMPOSE"; chmod 600 "$COMPOSE"
    (cd "$NODE_DIR" && docker compose up -d --force-recreate &>/dev/null) || true
    err "Прежний ключ восстановлен. Проверьте, что ключ скопирован целиком из панели, и повторите."
    return 1
  fi
  ok "Нода работает с новым ключом, порт ${port:-?} слушает."
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && [ -n "$port" ] && ! _ufw_allows "${port}(/tcp)?"; then
    warn "Порт ${port} в firewall не разрешён для панели — откройте его: ufw allow from IP_ПАНЕЛИ to any port ${port} proto tcp"
  fi
  echo
  box_top "Готово"
  box_row "Откройте ноду в панели: через 1–2 минуты она должна стать онлайн"
  box_row "${C_DIM}Прежний compose: ${bak}${C_RESET}"
  box_bottom
  return 0
}

case "${1:-change}" in
  change|"")  ensure_tty; banner; node_change_key manual ;;
  api)        ensure_tty; banner; node_change_key api ;;
  show|status) node_show ;;
  *) echo "Использование: $0 [change|api|show]" >&2; exit 2 ;;
esac
