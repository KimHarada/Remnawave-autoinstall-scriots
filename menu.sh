#!/usr/bin/env bash
# DORIK — точка входа. Работает на чистой Ubuntu/Debian: сам скачивает
# тулкит, ставит нужные пакеты и запускает настройку.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh)
#
# Параметры:  --full  сразу полная настройка (без меню)
#             --bbr   только BBR + сетевая оптимизация
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

die() { echo -e "\e[31m[✗]\e[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo -i, затем повторите команду."
command -v apt-get >/dev/null 2>&1 || die "Нужна Ubuntu/Debian (apt-get не найден)."

# ---- где лежат скрипты ------------------------------------------------------
# Запуск из git-чекаута -> берём скрипты рядом. Запуск через curl/<(...) ->
# скачиваем репозиторий целиком ОДИН раз (а не по файлу на каждый шаг).
download_repo() {
  local tmp f
  tmp="$(mktemp -d)" || return 1
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "[i] Ставлю curl/tar..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 curl ca-certificates tar gzip >/dev/null 2>&1 || true
  fi
  echo "[i] Скачиваю тулкит (${GH_USER}/${GH_REPO}@${GH_BRANCH})..."
  if curl -fsSL --retry 3 --retry-delay 2 "$TARBALL_URL" \
     | tar -xz --strip-components=1 -C "$tmp" 2>/dev/null && [ -f "$tmp/scripts/lib.sh" ]; then
    :
  else
    # запасной путь: по одному файлу из raw
    echo "[!] Архив не скачался — пробую по файлам."
    rm -rf "$tmp"; tmp="$(mktemp -d)"; mkdir -p "$tmp/scripts"
    for f in lib.sh full-setup.sh bbr-install.sh haproxy-setup.sh remnanode-setup.sh fix-ssh-access.sh; do
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
ensure_tty

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

banner() {
  echo -e "${C_B}"
  cat <<'EOF'
 ____   ___  ____  ___ _  __
|  _ \ / _ \|  _ \|_ _| |/ /
| | | | | | | |_) || || ' /
| |_| | |_| |  _ < | || . \
|____/ \___/|_| \_\___|_|\_\
EOF
  echo -e "${C_RESET}"
}

case "${1:-}" in
  --full) run_script "full-setup.sh"; exit $? ;;
  --bbr)  run_script "bbr-install.sh"; exit $? ;;
esac

while true; do
  [ "${ASSUME_YES:-0}" = "1" ] || clear
  banner
  echo "  1) Полная настройка (нода + защита сервера, одним шагом)"
  echo "  2) Дополнительно (точечные операции)"
  echo "  0) Выход"
  echo
  read -r -p "Выбор: " CH <"$(prompt_input)" || exit 0

  case "$CH" in
    1)
      run_script "full-setup.sh"
      exit $?
      ;;
    2)
      clear
      echo "Дополнительно:"
      echo "  1) Восстановить SSH-доступ (экстренно)"
      echo "  2) Только BBR + сетевая оптимизация"
      echo "  3) Только Nginx+HAProxy (на уже настроенную ноду)"
      echo "  4) Только Remnanode"
      echo "  9) Назад"
      read -r -p "Выбор: " CH2 <"$(prompt_input)" || exit 0
      case "$CH2" in
        1) run_script "fix-ssh-access.sh"; exit $? ;;
        2) run_script "bbr-install.sh"; exit $? ;;
        3) run_script "haproxy-setup.sh"; exit $? ;;
        4) run_script "remnanode-setup.sh"; exit $? ;;
        *) continue ;;
      esac
      ;;
    0|*) exit 0 ;;
  esac
done
