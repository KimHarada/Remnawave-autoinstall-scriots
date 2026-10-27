#!/usr/bin/env bash
# DORIK — точка входа. Работает на чистой Ubuntu/Debian: сам скачивает
# тулкит, ставит нужные пакеты и запускает настройку.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh)
#
# Параметры (запуск без меню):
#   --full           полная настройка сервера (нода или панель)
#   --doctor         проверка и исправление последствий старых версий
#   --harden         закрыть лишние порты и укрепить сервер (--ports — только показать порты)
#   --update-node    обновить ноду          --bbr   BBR + сетевая оптимизация
#   --panel-install  установить панель      --panel-update  обновить панель
#   --sub            страница подписки      --sub-update    обновить страницу
#   --status         показать состояние сервера
# Без вопросов (cloud-init):  ASSUME_YES=1 DOMAIN_TCP=... SECRET_KEY=... bash menu.sh --full
set -uo pipefail

# Переменные можно переопределить — для форка или проверки другой ветки.
GH_USER="${GH_USER:-KimHarada}"
GH_REPO="${GH_REPO:-Remnawave-autoinstall-scriots}"
GH_BRANCH="${GH_BRANCH:-main}"
INSTALL_DIR="${DORIK_DIR:-/opt/dorik-toolkit}"
DORIK_RAW="${DORIK_RAW:-https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}}"
TARBALL_URL="${DORIK_TARBALL_URL:-https://github.com/${GH_USER}/${GH_REPO}/archive/refs/heads/${GH_BRANCH}.tar.gz}"
export DORIK_RAW

die() { echo -e "\e[31m✖\e[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo -i, затем повторите команду."
command -v apt-get >/dev/null 2>&1 || die "Нужна Ubuntu/Debian (apt-get не найден)."

# ---- где лежат скрипты ------------------------------------------------------
# Запуск из git-чекаута -> берём скрипты рядом. Запуск через curl/<(...) ->
# скачиваем репозиторий целиком ОДИН раз (а не по файлу на каждый шаг).
download_repo() {
  local tmp f
  tmp="$(mktemp -d)" || return 1
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "• Ставлю curl/tar..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 curl ca-certificates tar gzip >/dev/null 2>&1 || true
  fi
  echo "• Скачиваю тулкит (${GH_USER}/${GH_REPO}@${GH_BRANCH})..."
  if curl -fsSL --retry 3 --retry-delay 2 "$TARBALL_URL" \
     | tar -xz --strip-components=1 -C "$tmp" 2>/dev/null && [ -f "$tmp/scripts/lib.sh" ]; then
    :
  else
    # запасной путь: по одному файлу из raw
    echo "▲ Архив не скачался — пробую по файлам."
    rm -rf "$tmp"; tmp="$(mktemp -d)"; mkdir -p "$tmp/scripts"
    for f in lib.sh ui.sh state.sh harden.sh decoys.sh doctor.sh preflight.sh full-setup.sh bbr-install.sh haproxy-setup.sh \
             remnanode-setup.sh node-update.sh panel-install.sh fix-ssh-access.sh; do
      curl -fsSL --retry 3 "${DORIK_RAW}/scripts/${f}" -o "$tmp/scripts/${f}" || { rm -rf "$tmp"; return 1; }
    done
  fi
  chmod 755 "$tmp"
  find "$tmp" -name '*.sh' -exec chmod 755 {} +
  rm -rf "${INSTALL_DIR}.old"
  [ -d "$INSTALL_DIR" ] && mv "$INSTALL_DIR" "${INSTALL_DIR}.old"
  mv "$tmp" "$INSTALL_DIR" || return 1
  rm -rf "${INSTALL_DIR}.old"
}

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SELF_DIR" ] && [ -f "${SELF_DIR}/scripts/lib.sh" ]; then
  SCRIPTS_DIR="${SELF_DIR}/scripts"
else
  download_repo || die "Не удалось скачать тулкит с GitHub. Проверьте сеть и доступ к github.com."
  SCRIPTS_DIR="${INSTALL_DIR}/scripts"
fi

SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/lib.sh" || die "Не удалось загрузить lib.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/state.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/harden.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/doctor.sh"

run_script() {
  local name="${1:?script name}"; shift
  if [ -t 0 ]; then
    bash "${SCRIPTS_DIR}/${name}" "$@"
  else
    # stdin — pipe (curl | bash): дочерний скрипт не должен читать из него, иначе
    # съест оставшийся текст родителя. Вопросы он задаёт через /dev/tty.
    bash "${SCRIPTS_DIR}/${name}" "$@" </dev/null
  fi
}

pause() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  echo
  read -r -p "$(echo -e "${C_DIM}Enter — вернуться в меню${C_RESET} ")" _ <"$(prompt_input)" || true
}

# ---- запуск без меню ----------------------------------------------------------
case "${1:-}" in
  --full)          run_script full-setup.sh; exit $? ;;
  --bbr)           run_script bbr-install.sh; exit $? ;;
  --doctor)        run_script doctor.sh; exit $? ;;
  --harden)        run_script harden.sh; exit $? ;;
  --ports)         run_script harden.sh --audit; exit $? ;;
  --update-node)   run_script node-update.sh; exit $? ;;
  --panel-install) run_script panel-install.sh install; exit $? ;;
  --panel-update)  run_script panel-install.sh update; exit $? ;;
  --sub)           run_script panel-install.sh sub; exit $? ;;
  --sub-update)    run_script panel-install.sh sub-update; exit $? ;;
  --status)        banner; show_dashboard; exit 0 ;;
  "") ;;
  *) die "Неизвестный параметр: $1 (см. заголовок menu.sh)" ;;
esac

ensure_tty

main_menu() {
  local ch
  while true; do
    [ "$UI_TTY" = "1" ] && clear
    banner
    show_dashboard
    echo
    box_top "Главное меню"
    box_row "${C_B}1${C_RESET}  Полная настройка сервера ${C_DIM}(нода или панель)${C_RESET}"
    box_row "${C_B}2${C_RESET}  Панель Remnawave ${C_DIM}· подписка · обновление${C_RESET}"
    box_row "${C_B}3${C_RESET}  Обновить ноду"
    box_row "${C_B}4${C_RESET}  Закрыть лишние порты и укрепить сервер"
    box_row "${C_B}5${C_RESET}  Проверка и исправление проблем"
    box_row "${C_B}6${C_RESET}  Дополнительно"
    box_row "${C_B}0${C_RESET}  Выход"
    box_bottom
    read -r -p "$(echo -e "${C_Y}›${C_RESET} Выбор: ")" ch <"$(prompt_input)" || exit 0
    case "$ch" in
      1) run_script full-setup.sh; pause ;;
      2) run_script panel-install.sh ;;
      3) run_script node-update.sh; pause ;;
      4) run_script harden.sh; pause ;;
      5) run_script doctor.sh; pause ;;
      6) advanced_menu ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

advanced_menu() {
  local ch
  while true; do
    echo
    box_top "Дополнительно"
    box_row "${C_B}1${C_RESET}  Восстановить SSH-доступ ${C_DIM}(экстренно)${C_RESET}"
    box_row "${C_B}2${C_RESET}  Только BBR + сетевая оптимизация"
    box_row "${C_B}3${C_RESET}  Только Nginx + HAProxy ${C_DIM}(на готовую ноду)${C_RESET}"
    box_row "${C_B}4${C_RESET}  Только Remnanode"
    box_row "${C_B}9${C_RESET}  Назад"
    box_bottom
    read -r -p "$(echo -e "${C_Y}›${C_RESET} Выбор: ")" ch <"$(prompt_input)" || return 0
    case "$ch" in
      1) run_script fix-ssh-access.sh; pause ;;
      2) run_script bbr-install.sh; pause ;;
      3) run_script haproxy-setup.sh; pause ;;
      4) run_script remnanode-setup.sh; pause ;;
      *) return 0 ;;
    esac
  done
}

main_menu
