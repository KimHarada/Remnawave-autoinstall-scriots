#!/usr/bin/env bash
# DORIK toolkit — оформление: цвета, рамки, баннер, спиннер, прогресс-бар.
# Подключается из lib.sh. Если вывод не в терминале (лог, cloud-init, pipe) —
# цвета и анимация отключаются автоматически, остаётся чистый текст.

# Рамки и спиннер — это UTF-8; без нужной локали bash считает длину строк по байтам.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*) ;;
  *) export LC_CTYPE=C.UTF-8 ;;
esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  UI_TTY=1
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[38;5;245m'
  C_G=$'\e[38;5;78m'; C_Y=$'\e[38;5;221m'; C_R=$'\e[38;5;203m'
  C_B=$'\e[38;5;75m'; C_M=$'\e[38;5;141m'; C_W=$'\e[38;5;255m'
else
  UI_TTY=0
  C_RESET=""; C_BOLD=""; C_DIM=""; C_G=""; C_Y=""; C_R=""; C_B=""; C_M=""; C_W=""
fi

UI_W=64
SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# Курсор мог остаться скрытым, если спиннер прервали Ctrl+C.
ui_restore_cursor() { [ "$UI_TTY" = "1" ] && printf '\e[?25h' 2>/dev/null; return 0; }
trap ui_restore_cursor EXIT

# ---- журнал -----------------------------------------------------------------
# Весь вывод тяжёлых команд (apt, docker, certbot) идёт в лог, а на экране —
# только спиннер и итог. При ошибке показываем хвост лога и путь к файлу.
if [ -z "${DORIK_LOG:-}" ]; then
  if mkdir -p /var/log/dorik 2>/dev/null && [ -w /var/log/dorik ]; then
    DORIK_LOG="/var/log/dorik/dorik-$(date +%Y%m%d-%H%M%S).log"
  else
    DORIK_LOG="/tmp/dorik-$(date +%Y%m%d-%H%M%S).log"
  fi
  export DORIK_LOG
fi

# ---- сообщения --------------------------------------------------------------
info() { echo -e "  ${C_B}•${C_RESET} $*"; }
ok()   { echo -e "  ${C_G}✔${C_RESET} $*"; }
# warn/err — в stderr, чтобы не попадали в результат $(...) вызывающего кода.
warn() { echo -e "  ${C_Y}▲${C_RESET} $*" >&2; }
err()  { echo -e "  ${C_R}✖${C_RESET} $*" >&2; }
# DORIK_NESTED=1 выставляет full-setup на время этапа: подзаголовки внутри этапа
# рисуются мельче, чтобы главные «[3/6] …» оставались заметнее.
step() {
  if [ "${DORIK_NESTED:-0}" = "1" ]; then
    echo -e "  ${C_DIM}›${C_RESET} ${C_BOLD}$*${C_RESET}"
  else
    echo; echo -e "${C_M}▌${C_RESET} ${C_BOLD}${C_W}$*${C_RESET}"
  fi
}

# vlen <строка> — видимая длина без ANSI-кодов (для выравнивания рамок).
vlen() {
  local s
  s="$(printf '%b' "$1" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
  echo "${#s}"
}

# ---- прогресс ----------------------------------------------------------------
progress_bar() {  # progress_bar <сделано> <всего> [ширина]
  local cur="${1:-0}" total="${2:-1}" w="${3:-26}" filled i bar=""
  [ "$total" -lt 1 ] && total=1
  filled=$(( cur * w / total ))
  for ((i=0; i<w; i++)); do
    if [ "$i" -lt "$filled" ]; then bar+="━"; else bar+="╌"; fi
  done
  printf '%s%s%s %s%3d%%%s' "$C_B" "$bar" "$C_RESET" "$C_BOLD" $(( cur * 100 / total )) "$C_RESET"
}

# step_n <номер> <всего> <название> — заголовок этапа с общим прогрессом.
step_n() {
  local cur="$1" total="$2"; shift 2
  echo
  echo -e "${C_M}▌${C_RESET} ${C_DIM}[${cur}/${total}]${C_RESET} ${C_BOLD}${C_W}$*${C_RESET}"
  echo -e "  $(progress_bar $((cur-1)) "$total")"
}

# ---- спиннер ----------------------------------------------------------------
# spin_run "Описание" команда args...  — выполняет команду (или функцию) в
# фоне, пока крутится спиннер с таймером; вывод пишется в лог. Возвращает код
# команды. Внимание: команда идёт в подоболочке, изменения переменных не видны.
spin_run() {
  local title="$1"; shift
  local tmp pid rc start el i=0
  tmp="$(mktemp)"
  start=$SECONDS
  printf '\n### %s  %s :: %s\n' "$(date '+%F %T')" "$title" "$*" >>"$DORIK_LOG" 2>/dev/null
  if [ "$UI_TTY" != "1" ]; then
    echo "  … $title"
    "$@" >"$tmp" 2>&1 </dev/null; rc=$?
  else
    # UI_TTY=0 внутри: вложенные spin_run не рисуют анимацию в лог-файл.
    ( UI_TTY=0; "$@" ) >"$tmp" 2>&1 </dev/null &
    pid=$!
    printf '\e[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      el=$((SECONDS-start))
      printf '\r\e[2K  %s%s%s %s %s(%dс)%s' "$C_B" "${SPIN_FRAMES[i % ${#SPIN_FRAMES[@]}]}" "$C_RESET" "$title" "$C_DIM" "$el" "$C_RESET"
      i=$((i+1)); sleep 0.1
    done
    wait "$pid"; rc=$?
    printf '\r\e[2K\e[?25h'
  fi
  cat "$tmp" >>"$DORIK_LOG" 2>/dev/null
  el=$((SECONDS-start))
  if [ "$rc" -eq 0 ]; then
    echo -e "  ${C_G}✔${C_RESET} ${title} ${C_DIM}(${el}с)${C_RESET}"
  else
    echo -e "  ${C_R}✖${C_RESET} ${title} ${C_DIM}(${el}с)${C_RESET}" >&2
    tail -n 12 "$tmp" | sed 's/^/      /' >&2
    echo -e "      ${C_DIM}полный лог: ${DORIK_LOG}${C_RESET}" >&2
  fi
  rm -f "$tmp"
  return "$rc"
}

# ---- рамки -------------------------------------------------------------------
_rep() { local n="$1" ch="$2" out="" i; for ((i=0; i<n; i++)); do out+="$ch"; done; printf '%s' "$out"; }

box_top() {  # box_top [заголовок]
  local t="${1:-}" fill
  if [ -n "$t" ]; then
    fill=$(( UI_W - 5 - $(vlen "$t") ))
    echo -e "${C_DIM}╭─${C_RESET} ${C_BOLD}${C_W}${t}${C_RESET} ${C_DIM}$(_rep "$fill" ─)╮${C_RESET}"
  else
    echo -e "${C_DIM}╭$(_rep $((UI_W-2)) ─)╮${C_RESET}"
  fi
}
box_sep()    { echo -e "${C_DIM}├$(_rep $((UI_W-2)) ─)┤${C_RESET}"; }
box_bottom() { echo -e "${C_DIM}╰$(_rep $((UI_W-2)) ─)╯${C_RESET}"; }
box_row() {  # box_row <текст>
  local t="${1:-}" pad
  pad=$(( UI_W - 4 - $(vlen "$t") ))
  [ "$pad" -lt 0 ] && pad=0
  echo -e "${C_DIM}│${C_RESET} ${t}$(_rep "$pad" ' ') ${C_DIM}│${C_RESET}"
}

# box_wrap <маркер> <текст> — длинный текст с переносом по словам внутри рамки.
box_wrap() {
  local mark="$1" text="$2" line first=1
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then box_row "${mark} ${line}"; first=0; else box_row "  ${line}"; fi
  done < <(printf '%s\n' "$text" | fold -s -w $((UI_W - 8)))
}

# Строка состояния: dot_row <ok|warn|bad|off> <название> <детали>
dot_row() {
  local lvl="$1" name="$2" det="${3:-}" dot pad
  # printf '%-16s' считает байты, а не символы — для кириллицы колонки поплывут.
  pad=$(( 17 - $(vlen "$name") )); [ "$pad" -lt 1 ] && pad=1
  name="${name}$(_rep "$pad" ' ')"
  # деталь должна влезать в рамку: UI_W - 4 (поля) - 2 (точка) - 17 (название)
  local max=$(( UI_W - 4 - 2 - 17 ))
  [ "${#det}" -gt "$max" ] && det="${det:0:$((max-1))}…"
  case "$lvl" in
    ok)   dot="${C_G}●${C_RESET}" ;;
    warn) dot="${C_Y}●${C_RESET}" ;;
    bad)  dot="${C_R}●${C_RESET}" ;;
    *)    dot="${C_DIM}○${C_RESET}" ;;
  esac
  box_row "${dot} ${name}${C_DIM}${det}${C_RESET}"
}

# ---- баннер -------------------------------------------------------------------
banner() {
  local -a art=(
'  ____   ___  ____  ___ _  __'
' |  _ \ / _ \|  _ \|_ _| |/ /'
' | | | | | | | |_) || || '"'"' / '
' | |_| | |_| |  _ < | || . \ '
' |____/ \___/|_| \_\___|_|\_\'
  )
  local -a col=(39 45 81 111 141)
  local i
  echo
  for i in "${!art[@]}"; do
    if [ "$UI_TTY" = "1" ]; then
      printf '\e[38;5;%sm%s\e[0m\n' "${col[$i]}" "${art[$i]}"
    else
      printf '%s\n' "${art[$i]}"
    fi
  done
  echo -e "  ${C_DIM}Remnawave toolkit · v${DORIK_VERSION:-2.0}${C_RESET}"
  echo
}
