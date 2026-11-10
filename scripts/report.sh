#!/usr/bin/env bash
# DORIK toolkit — отчёт о сервере.
#
#   report.sh            — меню: новый отчёт, прошлые отчёты, журнал последней операции
#   report.sh new        — собрать отчёт, сохранить и показать
#   report.sh last       — показать последний сохранённый отчёт
#   report.sh log        — показать журнал последней операции
#   report.sh print      — напечатать отчёт в стандартный вывод (для пересылки/автоматизации)
#
# Отчёт — обычный текст без цветов: /var/log/dorik/report-ДАТА.txt. В нём нет ключей, токенов и
# секретных ссылок — его можно пересылать. Хранятся последние 20 отчётов.

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
  _dorik_source doctor.sh
  _dorik_source decoys.sh
  _dorik_source scanblock.sh
  _report_standalone=1
else
  _report_standalone=0
fi

REPORT_DIR=/var/log/dorik

_rp_plain() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }
_rp_h()     { printf '\n== %s ==\n' "$1"; }
# Колонки выравниваем через _tfit: printf '%-22s' считает байты, и кириллица съезжала бы.
_rp_kv()    { _tfit "$1" 26; printf '  %s %s\n' "$REPLY" "$2"; }

_rp_cert_days() {  # дней до конца сертификата certbot; пусто, если его нет
  local f="/etc/letsencrypt/live/$1/fullchain.pem" end d
  [ -f "$f" ] || return 0
  end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
  d="$(date -d "$end" +%s 2>/dev/null)" || return 0
  echo $(( (d - $(date +%s)) / 86400 ))
}

_rp_f2b() {  # _rp_f2b <jail> — «сейчас в бане N, всего M»
  local out
  out="$(fail2ban-client status "$1" 2>/dev/null)" || { echo "не работает"; return 0; }
  echo "в бане сейчас: $(awk '/Currently banned/{print $NF}' <<<"$out"), всего забанено: $(awk '/Total banned/{print $NF}' <<<"$out")"
}

# Печатает отчёт (обычный текст).
report_build() {
  local ip os i mark p d port zip days dns pk n f
  ip="$(get_public_ip)"
  # shellcheck disable=SC1091
  os="$([ -r /etc/os-release ] && . /etc/os-release && echo "${PRETTY_NAME:-}")"

  echo "DORIK ${DORIK_VERSION} — отчёт о сервере"
  echo "Собран: $(date '+%F %T %Z')"

  _rp_h "Сервер"
  _rp_kv "Имя" "$(hostname 2>/dev/null)"
  _rp_kv "Публичный IP" "${ip:-не определён}"
  _rp_kv "Система" "${os:-?} · ядро $(uname -r)"
  _rp_kv "Работает без перезагрузки" "$(uptime -p 2>/dev/null | sed 's/^up //')"
  _rp_kv "Процессор" "$(nproc 2>/dev/null) ядер · нагрузка $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  _rp_kv "Память" "$(free -m 2>/dev/null | awk '/^Mem:/{printf "занято %d из %d МБ", $2-$7, $2}')"
  _rp_kv "Диск /" "$(df -h / 2>/dev/null | awk 'NR==2{printf "занято %s из %s (%s)", $3, $2, $5}')"

  _rp_h "Состояние"
  [ "${#DASH_N[@]}" -gt 0 ] || dash_collect
  for i in "${!DASH_N[@]}"; do
    case "${DASH_L[$i]}" in ok) mark="[ OK ]" ;; warn) mark="[ !! ]" ;; bad) mark="[СБОЙ]" ;; *) mark="[ -- ]" ;; esac
    _tfit "${DASH_N[$i]}" 18
    printf '  %s %s %s\n' "$mark" "$REPLY" "${DASH_T[$i]}"
  done

  _rp_h "Протоколы и домены"
  if [ -s "$DECOY_CONF" ]; then
    _rp_kv "Веб-сервер заглушек" "$(ws_label)"
    while IFS='|' read -r p d port zip; do
      [ -n "$p" ] || continue
      days="$(_rp_cert_days "$d")"
      if [ -z "$ip" ]; then dns="DNS не проверен"
      elif dns_points_here "$d" "$ip"; then dns="DNS верный"
      else dns="DNS указывает НЕ на этот сервер"; fi
      _tfit "${DECOY_LABEL[$p]:-$p}" 12
      printf '  %s %s\n' "$REPLY" "$d"
      printf '  %12s сертификат: %s · %s · заглушка 127.0.0.1:%s (%s)\n' "" \
        "$([ -n "$days" ] && echo "ещё ${days} дн." || echo "НЕТ")" "$dns" "$port" "${zip%.zip}"
    done < "$DECOY_CONF"
  else
    echo "  Нода на этом сервере не настраивалась (нет ${DECOY_CONF})."
  fi
  if [ -s /etc/dorik/profile.json ]; then
    _rp_kv "Профиль на панели" "$(jq -r '.name // "?"' /etc/dorik/profile.json 2>/dev/null) · inbound'ов: $(jq -r '[.protocols[]?.tag] | length' /etc/dorik/profile.json 2>/dev/null)"
  fi

  _rp_h "Защита от сканеров"
  if have fail2ban-client && svc_active fail2ban; then
    _rp_kv "fail2ban: SSH" "$(_rp_f2b sshd)"
    _rp_kv "fail2ban: перебор портов" "$(_rp_f2b dorik-portscan)"
  else
    _rp_kv "fail2ban" "не работает"
  fi
  n="$(scanblock_count)"
  if [ "$n" -gt 0 ]; then
    pk="$(iptables -w -nvxL INPUT 2>/dev/null | awk '/dorik-scan4/{print $1; exit}')"
    _rp_kv "Блок-лист сетей" "${n} сетей · отброшено пакетов: ${pk:-0} · обновлён: $(cat "$SB_DIR/updated" 2>/dev/null || echo "?")"
  else
    _rp_kv "Блок-лист сетей" "выключен"
  fi
  if [ -f /etc/haproxy/haproxy.cfg ]; then
    if grep -q 'sc_conn_rate' /etc/haproxy/haproxy.cfg; then _rp_kv "HAProxy" "лимиты соединений с одного адреса включены"
    else _rp_kv "HAProxy" "лимитов соединений нет"; fi
  fi
  _rp_kv "Ответ на ping" "$([ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)" = "1" ] && echo "скрыт" || echo "отвечает")"
  _rp_kv "Вход в SSH по паролю" "$([ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')" = "no" ] && echo "выключен (только ключи)" || echo "разрешён")"

  _rp_h "Открытые порты"
  if declare -F scan_listeners &>/dev/null; then
    scan_listeners
    print_listeners 2>&1 | _rp_plain
  fi

  _rp_h "Найденные проблемы"
  if declare -F doctor_scan &>/dev/null; then
    doctor_scan
    if [ "${#ISSUE_IDS[@]}" -eq 0 ]; then echo "  Проблем не найдено."
    else for i in "${ISSUE_IDS[@]}"; do echo "  - ${ISSUE_TXT[$i]}"; done
         echo "  Исправить: меню → «Проверка и исправление проблем»."; fi
  fi

  _rp_h "Последняя полная настройка"
  if [ -s /var/lib/dorik/last-run.txt ]; then sed 's/^/  /' /var/lib/dorik/last-run.txt
  else echo "  Ещё не выполнялась."; fi

  _rp_h "Журналы"
  # shellcheck disable=SC2012
  ls -1t "$REPORT_DIR"/dorik-*.log 2>/dev/null | head -5 | sed 's/^/  /'
  return 0
}

_rp_view() {  # показать файл: постранично, если есть терминал
  local f="$1"
  [ -s "$f" ] || { warn "Файл пуст или не найден: ${f}"; return 1; }
  if [ "${UI_TTY:-0}" = "1" ] && [ "${ASSUME_YES:-0}" != "1" ] && have less; then
    info "Листать — стрелки и PgUp/PgDn, выход — q"
    less -R "$f"
  else
    cat "$f"
  fi
}

report_new() {
  local f
  mkdir -p "$REPORT_DIR"
  f="${REPORT_DIR}/report-$(date +%Y%m%d-%H%M%S).txt"
  DASH_N=()
  if spin_run "Сбор отчёта о сервере" _report_to_file "$f"; then :; else warn "Отчёт собран не полностью."; fi
  # shellcheck disable=SC2012
  ls -1t "$REPORT_DIR"/report-*.txt 2>/dev/null | tail -n +21 | xargs -r rm -f
  _rp_view "$f"
  ok "Отчёт сохранён: ${f}"
}
_report_to_file() { report_build 2>/dev/null | _rp_plain > "$1"; [ -s "$1" ]; }

report_last() {
  local f
  # shellcheck disable=SC2012
  f="$(ls -1t "$REPORT_DIR"/report-*.txt 2>/dev/null | head -1)"
  [ -n "$f" ] || { info "Сохранённых отчётов пока нет — соберите новый."; return 0; }
  _rp_view "$f"
}

report_log() {
  local f
  # shellcheck disable=SC2012
  # журнал текущего запуска (почти пустой) пропускаем — нужен предыдущий
  f="$(ls -1t "$REPORT_DIR"/dorik-*.log 2>/dev/null | grep -vxF "${DORIK_LOG:-}" | head -1)"
  [ -n "$f" ] || { info "Журналов пока нет."; return 0; }
  _rp_view "$f"
}

report_menu() {
  local nl=$'\n' cnt last l
  local -a RM_L=("Новый отчёт" "Последний отчёт" "Журнал последней операции" "Итог последней настройки")
  local -a RM_K=(1 2 3 4) RM_D
  TUI_SEL=0
  while true; do
    # shellcheck disable=SC2012
    cnt="$(ls -1 "$REPORT_DIR"/report-*.txt 2>/dev/null | wc -l)"
    # shellcheck disable=SC2012
    last="$(ls -1t "$REPORT_DIR"/report-*.txt 2>/dev/null | head -1)"
    RM_D=(
      "Собирает свежий отчёт: сервер, состояние всех компонентов, протоколы и домены со сроком сертификатов и проверкой DNS, защита от сканеров (сколько адресов забанено и пакетов отброшено), открытые порты, найденные проблемы.${nl}${nl}В отчёте нет ключей и токенов — его можно пересылать.${nl}${nl}@КУДА СОХРАНЯЕТСЯ${nl}${REPORT_DIR}/report-ДАТА.txt"
      "Открывает последний сохранённый отчёт без повторного сбора.${nl}${nl}@СОХРАНЕНО ОТЧЁТОВ${nl}${cnt}${nl}${nl}@ПОСЛЕДНИЙ${nl}${last:-ещё нет}"
      "Полный журнал предыдущего запуска: вывод apt, docker, certbot и остальных команд. Сюда смотреть, если этап установки завершился с ошибкой.${nl}${nl}@ГДЕ ЛЕЖАТ${nl}${REPORT_DIR}/dorik-ДАТА.log"
      "Короткий итог последней полной настройки: роль, протоколы, веб-сервер, сколько этапов выполнено и какие завершились с ошибкой."
    )
    tui_select "ОТЧЁТ" RM_L RM_D RM_K || return 0
    case "$TUI_SEL" in
      0) report_new ;;
      1) report_last ;;
      2) report_log ;;
      3) echo; if [ -s /var/lib/dorik/last-run.txt ]; then box_top "Последняя полная настройка"; while IFS= read -r l; do box_wrap "" "$l"; done < /var/lib/dorik/last-run.txt; box_bottom
         else info "Полная настройка ещё не выполнялась."; fi ;;
    esac
    [ "${ASSUME_YES:-0}" = "1" ] || { echo; read -r -p "$(echo -e "${C_DIM}Enter — вернуться в меню${C_RESET} ")" _ <"$(prompt_input)" || true; }
  done
}

if [ "$_report_standalone" = "1" ]; then
  require_root
  case "${1:-menu}" in
    new)   report_new ;;
    last)  report_last ;;
    log)   report_log ;;
    print) report_build 2>/dev/null | _rp_plain ;;
    menu)  ensure_tty; report_menu ;;
    *) echo "Использование: $0 [new|last|log|print]" >&2; exit 2 ;;
  esac
fi
