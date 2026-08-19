#!/bin/bash
set -euo pipefail

# ============================================================
#  DORIK — Server Toolkit CLI
#  Запуск:
#    curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh -o /tmp/menu.sh && chmod +x /tmp/menu.sh && bash /tmp/menu.sh
#
#  ВАЖНО: не используйте 'sudo bash <(curl ...)' — современный sudo закрывает
#  файловые дескрипторы process substitution, скрипт упадёт с 'No such file
#  or directory'. Всегда сначала скачивайте в файл, потом запускайте.
# ============================================================

VERSION="v1.0.0"

# Цвета — приближены к тёплому оранжево-лососевому оттенку со скриншота
ORANGE='\033[38;5;209m'
ORANGE_BOLD='\033[1;38;5;209m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[38;5;245m'
NC='\033[0m'

# !!! ЗАМЕНИТЕ на свои реальные значения !!!
GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/scripts"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[x]${NC} Запускать нужно от root (sudo bash /tmp/menu.sh)."
   exit 1
fi

# ------------------------------------------------------------
# Автоустановка toilet при первом запуске — чтобы баннер сразу
# был красивым (блочный шрифт), а не запасным текстом.
# ------------------------------------------------------------
ensure_toilet() {
    if command -v toilet >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${BLUE}[i]${NC} toilet не найден — устанавливаем для красивого баннера (один раз)..."
    apt update -qq >/dev/null 2>&1
    apt install -y toilet toilet-fonts >/dev/null 2>&1 || true
    if command -v toilet >/dev/null 2>&1; then
        echo -e "${GREEN}[+]${NC} toilet установлен."
    else
        echo -e "${YELLOW}[!]${NC} Не удалось установить toilet — будет использован запасной баннер."
    fi
}
ensure_toilet

# ------------------------------------------------------------
# Баннер DORIK — через toilet (если есть), иначе через встроенный
# запасной вариант (обычный figlet, либо просто текст крупными буквами)
# ------------------------------------------------------------
print_banner() {
    echo -e "${ORANGE_BOLD}"
    if command -v toilet >/dev/null 2>&1; then
        toilet -f mono12 "DORIK" 2>/dev/null
    elif command -v figlet >/dev/null 2>&1; then
        figlet -f big DORIK 2>/dev/null || figlet DORIK 2>/dev/null
    else
        cat <<'EOF'
   _____   ____  _____  _____ _  __
  |  __ \ / __ \|  __ \|_   _| |/ /
  | |  | | |  | | |__) | | | | ' /
  | |  | | |  | |  _  /  | | |  <
  | |__| | |__| | | \ \ _| |_| . \
  |_____/ \____/|_|  \_\_____|_|\_\
EOF
    fi
    echo -e "${NC}"
    echo -e "${GRAY}                                   Dorik Server Toolkit ${VERSION}${NC}"
}

# ------------------------------------------------------------
# Информационная панель
# ------------------------------------------------------------
print_info_panel() {
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "неизвестно")
    local ssh_port="неизвестно"
    if command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | grep -i "^port" | awk '{print $2}' | head -n1) || true
        ssh_port=${ssh_port:-"неизвестно"}
    fi
    local tz_val
    tz_val=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "неизвестно")
    local now_val
    now_val=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "  ${GRAY}хост${NC}         •  ${hostname_val}"
    echo -e "  ${GRAY}ssh-порт${NC}     •  ${GREEN}${ssh_port}${NC}"
    echo -e "  ${GRAY}часовой пояс${NC} •  ${tz_val}"
    echo -e "  ${GRAY}время${NC}        •  ${now_val}"
    echo -e "  ${GRAY}вход выполнен${NC}•  $(whoami)@${hostname_val}"
}

# ------------------------------------------------------------
# Скачивание и запуск скрипта из репозитория
# ------------------------------------------------------------
run_remote_script() {
    local script_name="$1"
    local url="${BASE_URL}/${script_name}"
    local tmpfile
    tmpfile=$(mktemp /tmp/dorik-XXXXXX.sh)

    echo -e "${BLUE}[i]${NC} Загружаем ${script_name}..."
    if ! curl -fsSL "$url" -o "$tmpfile"; then
        echo -e "${RED}[x]${NC} Не удалось скачать скрипт: ${url}"
        rm -f "$tmpfile"
        exit 1
    fi

    chmod +x "$tmpfile"
    echo -e "${GREEN}[+]${NC} Запускаем ${script_name}..."
    echo
    bash "$tmpfile"
    local exit_code=$?
    rm -f "$tmpfile"
    return $exit_code
}

# ------------------------------------------------------------
# Меню
# ------------------------------------------------------------
print_menu() {
    local W=64
    local line
    line=$(printf '─%.0s' $(seq 1 $W))

    echo -e "${ORANGE}┌─ DORIK ${line:0:$((W-9))}${NC}"
    echo
    echo -e "  ${GRAY}Безопасность${NC}"
    echo -e "   ${ORANGE_BOLD}1${NC}  ${ORANGE}►${NC}  Harden SSH  ${DIM}(порт, ufw, fail2ban, таймзона, крон)${NC}"
    echo
    echo -e "  ${GRAY}Инфраструктура${NC}"
    echo -e "   ${ORANGE_BOLD}2${NC}  ${ORANGE}⚙${NC}  Установить/настроить remnanode  ${DIM}(docker + volumes автоматически)${NC}"
    echo -e "   ${ORANGE_BOLD}3${NC}  ${ORANGE}◈${NC}  HAProxy + Nginx + Certbot  ${DIM}(на уже установленную ноду)${NC}"
    echo
    echo -e "  ${GRAY}Наблюдение${NC}"
    echo -e "   ${ORANGE_BOLD}4${NC}  ${ORANGE}≡${NC}  Статус ufw / fail2ban / cron"
    echo
    echo -e "   ${ORANGE_BOLD}0${NC}  ${RED}✕${NC}  Выход"
    echo
    echo -e "${ORANGE}└${line}${NC}"
}

show_status() {
    echo
    echo -e "${ORANGE_BOLD}── Статус служб ──${NC}"
    for svc in ssh fail2ban ufw cron; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} ${svc}: активен"
        else
            echo -e "  ${RED}●${NC} ${svc}: неактивен"
        fi
    done
    echo
    echo -e "${ORANGE_BOLD}── ufw ──${NC}"
    ufw status verbose 2>/dev/null || echo "  ufw не установлен"
    echo
    echo -e "${ORANGE_BOLD}── crontab ──${NC}"
    crontab -l 2>/dev/null || echo "  (пусто)"
}

main() {
    clear
    print_banner
    echo
    print_info_panel
    echo
    print_menu
    echo
    read -rp "$(echo -e "${ORANGE_BOLD}❯${NC} Выберите пункт: ")" CHOICE

    case "$CHOICE" in
        1)
            run_remote_script "harden-ssh.sh"
            ;;
        2)
            run_remote_script "remnanode-setup.sh"
            ;;
        3)
            run_remote_script "haproxy-setup.sh"
            ;;
        4)
            show_status
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo -e "${RED}[x]${NC} Некорректный выбор."
            exit 1
            ;;
    esac
}

main
