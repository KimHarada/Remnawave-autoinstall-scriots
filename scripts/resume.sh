#!/usr/bin/env bash
# DORIK toolkit — запоминание ответов и этапов полной настройки: можно продолжить с того места,
# где остановились, и поменять то, в чём ошиблись (например, домен).
# Подключается из full-setup.sh после lib.sh.
#
#   /etc/dorik/setup.env        — ответы на вопросы (без паролей, токенов и ключей), права 600
#   /var/lib/dorik/steps.state  — этапы: «id|отпечаток параметров|время|ok или fail»
#
# Этап пропускается при повторном запуске, только если: он раньше завершился успешно, параметры,
# от которых он зависит, не менялись (совпал отпечаток) и он реально работает сейчас (проверка
# на живой системе). Поменяли домен — отпечаток другой, и перезапустятся только этапы, зависящие от домена.

SETUP_ENV="${SETUP_ENV:-/etc/dorik/setup.env}"
STEPS_STATE="${STEPS_STATE:-/var/lib/dorik/steps.state}"

# Что сохраняем из ответов. Секретов здесь нет намеренно: ключ ноды, токен панели и ссылка панели
# при продолжении спрашиваются заново, только если этап, которому они нужны, ещё не выполнен.
SETUP_VARS=(ROLE NEW_SSH_PORT PROTO_SELECTED DOMAIN_MODE BASE_DOMAIN
  DOMAIN_TCP DOMAIN_GRPC DOMAIN_XHTTP DOMAIN_HY2 DOMAIN_TG DOMAIN_WEB
  USE_HY2 USE_TG USE_WEB HAS_XRAY WEB_SERVER HY2_PORT INSTALL_DECOY USE_BBR
  USE_API PROFILE_PREFIX PROFILE_NAME COUNTRY_CODE PSIPHON FINAL_MASK PROFILE_CREATE_NODE
  NODE_PORT OPEN_NODE_PORT PANEL_IP ENABLE_REBOOT DO_HARDEN SSH_PW_OFF
  SCAN_PROTECT SCAN_BLOCKLIST WEB_AD_TAG)

# id этапа -> название для сводки
declare -gA STEP_TITLE=( [apt]="Обновление пакетов" [ssh]="SSH, firewall, fail2ban" [web]="Веб-сервер + HAProxy + сертификаты"
  [bbr]="BBR" [profile]="Профиль и хосты на панели" [node]="Remnanode" [nodelink]="Нода подключена к панели"
  [webproxy]="WEB-прокси Telegram" [harden]="Закрытие портов и укрепление" [scanblock]="Блок-лист сканеров" )
STEP_ORDER=(apt ssh web bbr profile node nodelink webproxy harden scanblock)

# ---- отпечаток параметров --------------------------------------------------------------------
fp_make() { printf '%s|' "$@" | md5sum | cut -c1-12; }

# ---- ответы ------------------------------------------------------------------------------------
setup_exists() { [ -s "$SETUP_ENV" ]; }

setup_save() {
  local v tmp="${SETUP_ENV}.tmp" old
  mkdir -p "$(dirname "$SETUP_ENV")" || return 1
  old="$(umask)"; umask 077
  {
    echo "# DORIK: ответы полной настройки (без паролей, токенов и ключей)."
    echo "SETUP_SAVED_AT=$(date +%s)"
    for v in "${SETUP_VARS[@]}"; do
      # if, а не «[ ] && printf»: иначе код возврата блока равен коду последней проверки (ложь для
      # незаданной переменной), и файл не переименовывался бы.
      if [ -n "${!v+x}" ]; then printf '%s=%q\n' "$v" "${!v}"; fi
    done
  } > "$tmp" && mv -f "$tmp" "$SETUP_ENV"
  umask "$old"
  chmod 600 "$SETUP_ENV" 2>/dev/null || true
}

# Загружает сохранённые ответы в переменные (они же экспортируются: вопросы берут их как значения по умолчанию).
setup_load() {
  local v
  [ -r "$SETUP_ENV" ] || return 1
  set -a
  # shellcheck disable=SC1090
  . "$SETUP_ENV"
  set +a
  # Чего нет в файле (версия старше), задаём пустым: иначе set -u остановит скрипт на первом обращении.
  for v in "${SETUP_VARS[@]}"; do [ -n "${!v+x}" ] || printf -v "$v" '%s' ""; done
  return 0
}

# ---- этапы -----------------------------------------------------------------------------------
steps_clear() { rm -f "$STEPS_STATE"; }

step_record() {  # step_record <id> <отпечаток> <ok|fail>
  local id="$1" fp="$2" res="$3" tmp
  mkdir -p "$(dirname "$STEPS_STATE")" || return 0
  tmp="$(mktemp)"
  { [ -f "$STEPS_STATE" ] && grep -v "^${id}|" "$STEPS_STATE"; printf '%s|%s|%s|%s\n' "$id" "$fp" "$(date +%s)" "$res"; } > "$tmp" 2>/dev/null
  cat "$tmp" > "$STEPS_STATE"; rm -f "$tmp"
}

step_result() {  # step_result <id> — «ok», «fail» или пусто
  [ -f "$STEPS_STATE" ] && awk -F'|' -v id="$1" '$1==id{r=$4} END{print r}' "$STEPS_STATE"
}

step_done() {  # step_done <id> <отпечаток> — этап был выполнен успешно с теми же параметрами
  [ -f "$STEPS_STATE" ] || return 1
  awk -F'|' -v id="$1" -v fp="$2" '$1==id && $2==fp && $4=="ok"{f=1} END{exit f?0:1}' "$STEPS_STATE"
}

# ---- протоколы <-> строка --------------------------------------------------------------------
# PROTO_SELECTED = «tcp grpc xhttp» (ключи отмеченных протоколов); восстанавливает PROTO_STATE/SEL.
proto_pack() {  # из PROTO_STATE
  local i out=""
  for i in "${!PROTO_KEYS[@]}"; do [ "${PROTO_STATE[$i]:-0}" = "1" ] && out+="${out:+ }${PROTO_KEYS[$i]}"; done
  PROTO_SELECTED="$out"
}
proto_unpack() {  # в PROTO_STATE, SEL, HAS_XRAY, USE_HY2/TG/WEB
  local k p
  PROTO_STATE=(); SEL=()
  for k in "${PROTO_KEYS[@]}"; do
    case " ${PROTO_SELECTED:-} " in *" $k "*) PROTO_STATE+=(1); SEL[$k]=1 ;; *) PROTO_STATE+=(0) ;; esac
  done
  HAS_XRAY=0
  for p in tcp grpc xhttp hy2 tg; do [ -n "${SEL[$p]:-}" ] && HAS_XRAY=1; done
  USE_HY2="${SEL[hy2]:-0}"; USE_TG="${SEL[tg]:-0}"; USE_WEB="${SEL[web]:-0}"
}

# ---- сводка прошлого запуска -------------------------------------------------------------------
setup_summary() {
  local id res when proto="" i d v n=0 bad=0
  box_top "Прошлый запуск"
  when="$(date -d "@${SETUP_SAVED_AT:-0}" '+%F %T' 2>/dev/null)"
  box_row "${C_DIM}ответы сохранены: ${when:-неизвестно}${C_RESET}"
  box_row "Роль: $([ "${ROLE:-1}" = "2" ] && echo "сервер панели" || echo "нода")    SSH-порт: ${NEW_SSH_PORT:-?}"
  if [ "${ROLE:-1}" = "1" ]; then
    for i in "${!PROTO_KEYS[@]}"; do
      case " ${PROTO_SELECTED:-} " in *" ${PROTO_KEYS[$i]} "*)
        v="${PROTO_VAR[${PROTO_KEYS[$i]}]}"; d="${!v:-}"
        box_row "  ${PROTO_LABELS[$i]}: ${C_B}${d:-—}${C_RESET}" ;; esac
    done
    [ "${USE_HY2:-0}" = "1" ] && box_row "  Hysteria2 UDP-порт: ${HY2_PORT:-443}    Веб-сервер: $(ws_label "${WEB_SERVER:-nginx}")"
  fi
  box_sep
  for id in "${STEP_ORDER[@]}"; do
    res="$(step_result "$id")"
    [ -n "$res" ] || continue
    n=$((n+1))
    if [ "$res" = "ok" ]; then box_row "${C_G}✔${C_RESET} ${STEP_TITLE[$id]}"
    else box_row "${C_R}✖${C_RESET} ${STEP_TITLE[$id]} ${C_DIM}(не завершён)${C_RESET}"; bad=$((bad+1)); fi
  done
  [ "$n" -eq 0 ] && box_row "${C_DIM}этапы ещё не выполнялись${C_RESET}"
  box_bottom
  RESUME_BAD="$bad"
}
