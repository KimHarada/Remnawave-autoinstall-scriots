#!/usr/bin/env bash
# DORIK toolkit — двухпанельный интерфейс: слева список, справа описание выбранного пункта.
# Подключается из lib.sh после ui.sh. Даёт:
#   tui_select     — меню: стрелки + Enter, либо сразу клавиша пункта
#   tui_checklist  — список с отметками: Пробел отмечает, Enter продолжает
#   ask_choice     — короткий вопрос «один из вариантов» в том же оформлении
#   tui_splash     — заставка с логотипом и ходом проверки сервера
# Без терминала, в узком окне, при ASSUME_YES=1 или DORIK_PLAIN=1 всё это превращается
# в обычные нумерованные вопросы — автоматический запуск (cloud-init) не ломается.

if [ "${UI_TTY:-0}" = "1" ]; then
  T_FR=$'\e[38;5;26m';  T_TI=$'\e[1;38;5;221m'; T_KEY=$'\e[38;5;81m'; T_PINK=$'\e[1;38;5;205m'
  T_SEL=$'\e[48;5;25m\e[1;38;5;231m'; T_ORG=$'\e[38;5;215m'; T_MUT=$'\e[38;5;60m'; T_LBL=$'\e[38;5;110m'
else
  T_FR=""; T_TI=""; T_KEY=""; T_PINK=""; T_SEL=""; T_ORG=""; T_MUT=""; T_LBL=""
fi

_T_ANSI_RE=$'\e\\[[0-9;?]*[A-Za-z]'
_TUI_EMPTY=()
TUI_SEL=0; TUI_KEY=""; TUI_COLS=80; TUI_ROWS=24; TUI_SYS=""; CHOICE=1
TUI_W=80; TUI_LW=32; TUI_RW=43
declare -ga TW=()

# ---- размеры и возможности терминала ------------------------------------------------------
tui_size() {
  local sz=""
  sz="$(stty size <"$(prompt_input)" 2>/dev/null)" || sz=""
  TUI_ROWS="${sz%% *}"; TUI_COLS="${sz##* }"
  [[ "$TUI_ROWS" =~ ^[0-9]+$ ]] && [ "$TUI_ROWS" -gt 0 ] || TUI_ROWS="${LINES:-24}"
  [[ "$TUI_COLS" =~ ^[0-9]+$ ]] && [ "$TUI_COLS" -gt 0 ] || TUI_COLS="${COLUMNS:-80}"
}

tui_ok() {
  [ "${UI_TTY:-0}" = "1" ] || return 1
  [ "${ASSUME_YES:-0}" = "1" ] && return 1
  [ "${DORIK_PLAIN:-0}" = "1" ] && return 1
  { [ -t 0 ] || tty_available; } || return 1
  tui_size
  [ "$TUI_COLS" -ge 78 ] && [ "$TUI_ROWS" -ge 20 ]
}

# ---- строки -------------------------------------------------------------------------------
_tstrip() {  # REPLY = строка без ANSI-кодов
  REPLY="$1"
  while [[ "$REPLY" =~ $_T_ANSI_RE ]]; do REPLY="${REPLY//"${BASH_REMATCH[0]}"/}"; done
}

_tfit() {  # _tfit <строка> <ширина> — REPLY ровно заданной видимой ширины (дополнить или обрезать)
  local s="$1" w="$2" plain n
  _tstrip "$s"; plain="$REPLY"; n=${#plain}
  if [ "$n" -gt "$w" ]; then
    REPLY="${plain:0:$((w-1))}…"
  else
    printf -v REPLY '%s%*s' "$s" $((w-n)) ''
  fi
}

# _twrap <текст> <ширина> — перенос по словам в массив TW. Строка с «@» в начале — подзаголовок,
# с \x01 — готовая строка (с цветами), её не переносим.
_twrap() {
  TW=()
  local para word line w="$2"
  local -a words
  while IFS= read -r para || [ -n "$para" ]; do
    if [ -z "$para" ]; then TW+=(""); continue; fi
    case "$para" in
      $'\x01'*) TW+=("${para:1}"); continue ;;
      @*)       TW+=("${T_LBL}${para:1}${C_RESET}"); continue ;;
    esac
    read -ra words <<<"$para"; line=""
    for word in "${words[@]}"; do
      if [ -z "$line" ]; then line="$word"
      elif [ $(( ${#line} + 1 + ${#word} )) -le "$w" ]; then line+=" $word"
      else TW+=("$line"); line="$word"; fi
    done
    [ -n "$line" ] && TW+=("$line")
  done <<<"$1"
  return 0
}

# ---- шапка: диск, память, нагрузка --------------------------------------------------------
_tui_meter() {  # шкала из 6 делений и процент
  local p="${1:-0}" n i out="" col="$C_G"
  [[ "$p" =~ ^[0-9]+$ ]] || p=0
  [ "$p" -ge 70 ] && col="$C_Y"
  [ "$p" -ge 90 ] && col="$C_R"
  n=$(( (p*6 + 99) / 100 )); [ "$n" -gt 6 ] && n=6
  for ((i=0; i<6; i++)); do
    if [ "$i" -lt "$n" ]; then out+="${col}▮"; else out+="${T_MUT}▮"; fi
  done
  printf '%s%s %s%3d %%%s' "$out" "$C_RESET" "$C_W" "$p" "$C_RESET"
}

tui_sysinfo() {
  local d m l
  d="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  m="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%d", (t-a)*100/t}' /proc/meminfo 2>/dev/null)"
  l="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
  TUI_SYS="${T_LBL}диск${C_RESET} $(_tui_meter "$d")  ${T_LBL}озу${C_RESET} $(_tui_meter "$m")  ${T_LBL}нагр${C_RESET} ${C_W}${l:-?}${C_RESET} "
}

# Ширины панелей под текущий терминал: TUI_W — весь экран, TUI_LW — список, TUI_RW — описание.
tui_dims() {
  tui_size
  TUI_W=$TUI_COLS; [ "$TUI_W" -gt 104 ] && TUI_W=104
  TUI_LW=$(( TUI_W * 38 / 100 )); [ "$TUI_LW" -lt 32 ] && TUI_LW=32; [ "$TUI_LW" -gt 42 ] && TUI_LW=42
  TUI_RW=$(( TUI_W - TUI_LW - 5 ))
  return 0
}

# Строка состояния для правой панели: цветная точка, название, текст (обрезан под ширину панели).
# tui_status_row <уровень> <название> <текст> — готовая строка в REPLY (с признаком «не переносить»).
tui_status_row() {
  local dot name txt="$3" max
  case "$1" in
    ok)   dot="${C_G}●${C_RESET}" ;;
    warn) dot="${C_Y}●${C_RESET}" ;;
    bad)  dot="${C_R}●${C_RESET}" ;;
    *)    dot="${C_DIM}○${C_RESET}" ;;
  esac
  _tfit "$2" 17; name="$REPLY"
  max=$(( ${TUI_RW:-50} - 22 )); [ "$max" -lt 10 ] && max=10
  [ "${#txt}" -gt "$max" ] && txt="${txt:0:$((max-1))}…"
  REPLY=$'\x01'"${dot} ${name}${C_DIM}${txt}${C_RESET}"
}

_tui_top() {  # _tui_top <заголовок> <внутренняя ширина> — верх рамки с заголовком
  local t="$1" w="$2" fill
  [ "${#t}" -gt $((w-5)) ] && t="${t:0:$((w-6))}…"
  fill=$(( w - ${#t} - 3 ))
  REPLY="${T_FR}╔═${C_RESET} ${T_TI}${t}${C_RESET} ${T_FR}$(_rep "$fill" ═)╗${C_RESET}"
}

# ---- клавиши ------------------------------------------------------------------------------
_tui_key() {  # TUI_KEY = up|down|enter|space|esc|<символ>
  local k="" rest="" in
  in="$(prompt_input)"
  IFS= read -rsn1 k <"$in" || { TUI_KEY=esc; return 0; }
  case "$k" in
    $'\e')
      # хвост последовательности стрелки приходит следом; 0.15 с хватает и на медленном SSH
      IFS= read -rsn2 -t 0.15 rest <"$in" || rest=""
      case "$rest" in
        '[A'|'OA') TUI_KEY=up ;;
        '[B'|'OB') TUI_KEY=down ;;
        '')        TUI_KEY=esc ;;
        *)         # прочие последовательности (PgUp, Home, F-клавиши) дочитываем и пропускаем
                   IFS= read -rsn4 -t 0.02 rest <"$in" || true; TUI_KEY=none ;;
      esac ;;
    '')  TUI_KEY=enter ;;
    ' ') TUI_KEY=space ;;
    *)   TUI_KEY="$k" ;;
  esac
  return 0
}

# ---- основной экран -----------------------------------------------------------------------
# tui_run <menu|check> <заголовок> <имя массива пунктов> <имя массива описаний> <имя массива клавиш>
#         [имя массива: пометки справа (menu) | состояния 0/1 (check)] [имя массива «заблокировано» (check)]
# menu:  выбранный пункт — в TUI_SEL, код 0; «назад» — код 1.
# check: состояния меняются прямо в переданном массиве; Enter — код 0, отмена — код 1.
tui_run() {
  local mode="$1" title="$2"
  local -n _tl="$3" _td="$4" _tk="$5"
  local -n _tm="${6:-_TUI_EMPTY}" _tx="${7:-_TUI_EMPTY}"
  local n=${#_tl[@]} sel="${TUI_SEL:-0}" W LW RW H i buf cell rr key box mark syslen first=1 hit nl=$'\n'
  local -a R
  [ "$n" -gt 0 ] || return 1
  [ "$sel" -lt "$n" ] || sel=0
  tui_dims; W=$TUI_W; LW=$TUI_LW; RW=$TUI_RW
  tui_sysinfo
  _tstrip "$TUI_SYS"; syslen=${#REPLY}
  printf '\e[?25l'
  while true; do
    _twrap "${_td[$sel]:-}" "$((RW-2))"
    R=("${TW[@]}")
    H=$n; [ "${#R[@]}" -gt "$H" ] && H=${#R[@]}; [ "$H" -lt 10 ] && H=10
    [ "$H" -gt $((TUI_ROWS-6)) ] && H=$((TUI_ROWS-6))
    [ "$H" -lt "$n" ] && H=$n

    _tfit " ${T_TI}dorik${C_RESET} ${C_DIM}${DORIK_VERSION:-}${C_RESET} ${T_MUT}·${C_RESET} ${C_W}${HOSTNAME:-server}${C_RESET}" $((W - syslen))
    buf="${REPLY}${TUI_SYS}"$'\e[K'"${nl}"
    _tui_top "$title" "$LW"; buf+="$REPLY "
    _tstrip "${_tl[$sel]}"; _tui_top "$REPLY" "$RW"; buf+="${REPLY}"$'\e[K'"${nl}"

    for ((i=0; i<H; i++)); do
      if [ "$i" -lt "$n" ]; then
        key="${_tk[$i]:- }"; box=""; mark=" "
        if [ "$mode" = "check" ]; then
          if [ "${_tx[$i]:-0}" = "1" ]; then box="[■] "
          elif [ "${_tm[$i]:-0}" = "1" ]; then box="[✓] "
          else box="[ ] "; fi
        else
          mark="${_tm[$i]:- }"
        fi
        if [ "$i" -eq "$sel" ]; then
          _tstrip "${_tl[$i]}"; _tfit " ▸ ${key} ${box}${REPLY}" $((LW-3)); cell="$REPLY"
          _tstrip "$mark"; cell="${T_SEL}${cell} ${REPLY:- } ${C_RESET}"
        else
          if [ "$mode" = "check" ] && [ "${box:1:1}" != " " ]; then box="${C_G}${box}${C_RESET}"; fi
          _tfit "   ${T_KEY}${key}${C_RESET} ${box}${_tl[$i]}" $((LW-3)); cell="${REPLY} ${mark} "
        fi
      else
        printf -v cell '%*s' "$LW" ''
      fi
      rr="${R[$i]:-}"
      _tfit " ${rr}" "$RW"
      buf+="${T_FR}║${C_RESET}${cell}${T_FR}║${C_RESET} ${T_FR}║${C_RESET}${REPLY}${T_FR}║${C_RESET}"$'\e[K'"${nl}"
    done
    buf+="${T_FR}╚$(_rep "$LW" ═)╝ ╚$(_rep "$RW" ═)╝${C_RESET}"$'\e[K'"${nl}"
    if [ "$mode" = "check" ]; then
      buf+=" ${T_KEY}↑↓${C_RESET} выбор  ${T_KEY}Пробел${C_RESET} отметить  ${T_KEY}a${C_RESET} все  ${T_KEY}n${C_RESET} снять  ${T_KEY}Enter${C_RESET} продолжить  ${T_KEY}0${C_RESET} отмена"
    else
      buf+=" ${T_KEY}↑↓${C_RESET} выбор  ${T_KEY}Enter${C_RESET} открыть  ${C_DIM}или сразу клавиша пункта${C_RESET}  ${T_KEY}0${C_RESET} назад"
    fi
    buf+=$'\e[K'

    if [ "$first" = "1" ]; then printf '\e[2J'; first=0; fi
    printf '\e[H%s\e[J' "$buf"

    _tui_key
    hit=-1
    for ((i=0; i<n; i++)); do
      [ -n "${_tk[$i]:-}" ] && [ "${_tk[$i]}" = "$TUI_KEY" ] && { hit=$i; break; }
    done
    if [ "$hit" -ge 0 ]; then
      sel=$hit
      if [ "$mode" = "menu" ]; then TUI_SEL=$sel; break; fi
      [ "${_tx[$sel]:-0}" = "1" ] || _tm[$sel]=$(( 1 - ${_tm[$sel]:-0} ))
      continue
    fi
    case "$TUI_KEY" in
      up)    sel=$(( (sel - 1 + n) % n )) ;;
      down)  sel=$(( (sel + 1) % n )) ;;
      enter) TUI_SEL=$sel; break ;;
      space)
        if [ "$mode" = "menu" ]; then TUI_SEL=$sel; break; fi
        [ "${_tx[$sel]:-0}" = "1" ] || _tm[$sel]=$(( 1 - ${_tm[$sel]:-0} )) ;;
      a) [ "$mode" = "check" ] && for ((i=0; i<n; i++)); do [ "${_tx[$i]:-0}" = "1" ] || _tm[$i]=1; done ;;
      n) [ "$mode" = "check" ] && for ((i=0; i<n; i++)); do [ "${_tx[$i]:-0}" = "1" ] || _tm[$i]=0; done ;;
      esc|0|q) TUI_SEL=$sel; printf '\e[2J\e[H\e[?25h'; return 1 ;;
    esac
  done
  printf '\e[2J\e[H\e[?25h'
  return 0
}

# ---- запасной вид: нумерованный список ----------------------------------------------------
_tui_plain() {
  local mode="$1" title="$2"
  local -n _pl="$3" _pk="$5"
  local -n _pm="${6:-_TUI_EMPTY}" _px="${7:-_TUI_EMPTY}"
  local n=${#_pl[@]} i ans tok
  [ "${ASSUME_YES:-0}" = "1" ] && return 0     # без вопросов: остаётся значение по умолчанию
  while true; do
    echo
    box_top "$title"
    for ((i=0; i<n; i++)); do
      if [ "$mode" = "check" ]; then
        box_row "${C_B}${_pk[$i]:- }${C_RESET}  $([ "${_pm[$i]:-0}" = "1" ] && echo "[x]" || echo "[ ]") ${_pl[$i]}"
      else
        box_row "${C_B}${_pk[$i]:- }${C_RESET}  ${_pl[$i]}"
      fi
    done
    box_row "${C_B}0${C_RESET}  $([ "$mode" = "check" ] && echo "Отмена" || echo "Назад")"
    box_bottom
    if [ "$mode" = "check" ]; then
      read -r -p "$(echo -e "${C_Y}›${C_RESET} Клавиши пунктов через пробел — переключить; Enter — продолжить: ")" ans <"$(prompt_input)" || return 1
      [ -z "$ans" ] && return 0
      [ "$ans" = "0" ] && return 1
      for tok in $ans; do
        for ((i=0; i<n; i++)); do
          [ "${_pk[$i]:-}" = "$tok" ] && [ "${_px[$i]:-0}" != "1" ] && _pm[$i]=$(( 1 - ${_pm[$i]:-0} ))
        done
      done
    else
      read -r -p "$(echo -e "${C_Y}›${C_RESET} Выбор: ")" ans <"$(prompt_input)" || return 1
      case "$ans" in 0|q|Q) return 1 ;; esac
      for ((i=0; i<n; i++)); do
        [ -n "$ans" ] && [ "${_pk[$i]:-}" = "$ans" ] && { TUI_SEL=$i; return 0; }
      done
    fi
  done
}

tui_select()    { if tui_ok; then tui_run menu "$@";  else _tui_plain menu "$@";  fi; }
tui_checklist() { if tui_ok; then tui_run check "$@"; else _tui_plain check "$@"; fi; }

# ask_choice <заголовок> <номер по умолчанию> "Название|Описание" ... — номер выбранного (с 1) в CHOICE.
# Вызывать напрямую, не через $(...): экран рисуется в стандартный вывод. Код 1 — отказ (Esc/0).
ask_choice() {
  local title="$1" def="${2:-1}"; shift 2
  local -a _acl=() _acd=() _ack=()
  local o i=0
  for o in "$@"; do
    i=$((i+1))
    _acl+=("${o%%|*}"); _ack+=("$i")
    if [ "${o#*|}" != "$o" ]; then _acd+=("${o#*|}"); else _acd+=(""); fi
  done
  [[ "$def" =~ ^[0-9]+$ ]] && [ "$def" -ge 1 ] && [ "$def" -le "$i" ] || def=1
  CHOICE="$def"
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  TUI_SEL=$((def-1))
  tui_select "$title" _acl _acd _ack || return 1
  CHOICE=$((TUI_SEL+1))
  return 0
}

# ---- логотип и заставка -------------------------------------------------------------------
tui_logo() {
  local -a art=(
'██████   ██████  ██████  ██ ██   ██'
'██   ██ ██    ██ ██   ██ ██ ██  ██ '
'██   ██ ██    ██ ██████  ██ █████  '
'██   ██ ██    ██ ██   ██ ██ ██  ██ '
'██████   ██████  ██   ██ ██ ██   ██'
  )
  local -a col=(221 215 209 204 162) side=("" "" "" "" "")
  local os="" i
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && os="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
  side[1]="${T_TI}dorik${C_RESET} ${C_DIM}${DORIK_VERSION:-}${C_RESET}"
  side[2]="${C_DIM}установщик Remnawave: нода · панель · защита${C_RESET}"
  side[3]="${C_DIM}${HOSTNAME:-server}${os:+ · ${os}}${C_RESET}"
  echo
  for i in "${!art[@]}"; do
    if [ "${UI_TTY:-0}" = "1" ]; then
      printf '  \e[38;5;%sm%s\e[0m   %s\n' "${col[$i]}" "${art[$i]}" "${side[$i]}"
    else
      printf '  %s   %s\n' "${art[$i]}" "${side[$i]}"
    fi
  done
  echo
}

_tui_bar() {  # _tui_bar <сделано> <всего> — шкала хода как в заставке
  local cur="$1" total="$2" w=30 f i out=""
  [ "$total" -lt 1 ] && total=1
  f=$(( cur * w / total ))
  for ((i=0; i<w; i++)); do
    if [ "$i" -lt "$f" ]; then out+="${T_KEY}█"; else out+="${T_FR}▒"; fi
  done
  printf '%s%s  %s%d из %d%s' "$out" "$C_RESET" "$C_DIM" "$cur" "$total" "$C_RESET"
}

_tui_splash_row() {  # _tui_splash_row <уровень|wait> <название> <текст>
  local dot name
  case "$1" in
    ok)   dot="${C_G}✓${C_RESET}" ;;
    warn) dot="${C_Y}▲${C_RESET}" ;;
    bad)  dot="${C_R}✖${C_RESET}" ;;
    wait) dot="${T_FR}⠿${C_RESET}" ;;
    *)    dot="${T_MUT}·${C_RESET}" ;;
  esac
  _tfit "$2" 19; name="$REPLY"
  _tfit "$3" $(( TUI_COLS - 26 ))
  if [ "$1" = "bad" ] || [ "$1" = "warn" ]; then printf ' %s %s %s%s%s' "$dot" "$name" "$T_ORG" "$REPLY" "$C_RESET"
  else printf ' %s %s %s%s%s' "$dot" "$name" "$C_DIM" "$REPLY" "$C_RESET"; fi
}

_tui_splash_tick() {  # обратный вызов dash_collect: <номер пункта> <всего>
  local i="$1" total="$2" up
  up=$(( total - i + 1 ))
  printf '\e[%dA\r\e[2K' "$up"
  _tui_splash_row "${DASH_L[$((i-1))]}" "${DASH_N[$((i-1))]}" "${DASH_T[$((i-1))]}"
  printf '\e[%dB\r' "$up"
  up=$(( total + 2 ))
  printf '\e[%dA\r\e[2K %sПроверка сервера%s  %s\e[%dB\r' "$up" "$C_BOLD" "$C_RESET" "$(_tui_bar "$i" "$total")" "$up"
}

# Собирает состояние сервера (DASH_*) и показывает ход проверки. В запасном виде — молча.
tui_splash() {
  local total=${#DASH_ENTRIES[@]} entry
  if ! tui_ok || [ "$TUI_ROWS" -lt $(( total + 13 )) ]; then
    dash_collect
    return 0
  fi
  printf '\e[2J\e[H\e[?25l'
  tui_logo
  printf ' %sПроверка сервера%s  %s\n\n' "$C_BOLD" "$C_RESET" "$(_tui_bar 0 "$total")"
  for entry in "${DASH_ENTRIES[@]}"; do
    _tui_splash_row wait "${entry%%:*}" "проверяю…"; printf '\n'
  done
  dash_collect _tui_splash_tick
  printf '\e[?25h'
  sleep 0.4
  return 0
}
