#!/bin/bash
set -euo pipefail

# ============================================================
#  DORIK — Server Toolkit CLI
#  Запуск:
#    curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh -o /tmp/menu.sh && chmod +x /tmp/menu.sh && bash /tmp/menu.sh
# ============================================================

VERSION="v2.0.0"

ORANGE='\033[38;5;209m'
ORANGE_BOLD='\033[1;38;5;209m'
DIM='\033[2m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[38;5;245m'
NC='\033[0m'

GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/scripts"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[x]${NC} Запускать нужно от root."
   exit 1
fi

ensure_toilet() {
    if command -v toilet >/dev/null 2>&1; then
        return 0
    fi
    apt update -qq >/dev/null 2>&1
    apt install -y toilet toilet-fonts >/dev/null 2>&1 || true
}
ensure_toilet

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
}

run_remote_script() {
    local script_name="$1"
    local url="${BASE_URL}/${script_name}"
    local tmpfile
    tmpfile=$(mktemp /tmp/dorik-XXXXXX.sh)

    echo -e "${BLUE}[i]${NC} Загружаем ${script_name}..."
    if ! curl -fsSL "$url" -o "$tmpfile"; then
        echo -e "${RED}[x]${NC} Не удалось скачать скрипт: ${url}"
        rm -f "$tmpfile"
        return 1
    fi
    chmod +x "$tmpfile"
    echo -e "${GREEN}[+]${NC} Запускаем ${script_name}..."
    echo
    bash "$tmpfile"
    local exit_code=$?
    rm -f "$tmpfile"
    return $exit_code
}

pause_return() {
    echo
    read -rp "Нажмите Enter, чтобы вернуться в меню..." _
}

# ------------------------------------------------------------
# Подменю: Защита сервера
# ------------------------------------------------------------
menu_security() {
    while true; do
        clear
        echo -e "${ORANGE_BOLD}── Защита сервера ──${NC}"
        echo
        echo -e "   ${ORANGE_BOLD}1${NC}  Harden SSH  ${DIM}(порт, ufw, fail2ban, таймзона, крон)${NC}"
        echo -e "   ${ORANGE_BOLD}2${NC}  Защита панели  ${DIM}(80/443/SSH, fail2ban, таймзона, крон)${NC}"
        echo -e "   ${ORANGE_BOLD}3${NC}  Восстановить SSH-доступ"
        echo -e "   ${ORANGE_BOLD}4${NC}  Статус ufw / fail2ban / cron"
        echo
        echo -e "   ${ORANGE_BOLD}9${NC}  Назад"
        echo
        read -rp "$(echo -e "${ORANGE_BOLD}❯${NC} Выберите пункт меню: ")" CHOICE
        case "$CHOICE" in
            1) run_remote_script "harden-ssh.sh"; pause_return ;;
            2) run_remote_script "panel-protect.sh"; pause_return ;;
            3) run_remote_script "fix-ssh-access.sh"; pause_return ;;
            4) show_status; pause_return ;;
            9) return ;;
            *) echo -e "${RED}[x]${NC} Некорректный выбор."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# Подменю: Установка ноды (в стиле скриншота)
# ------------------------------------------------------------
menu_node() {
    while true; do
        clear
        echo -e "${ORANGE_BOLD}── Установка ноды ──${NC}"
        echo
        echo -e "   ${ORANGE_BOLD}1${NC}  Полная установка  ${DIM}(Nginx self-steal + BBR + Remnanode)${NC}"
        echo -e "   ${ORANGE_BOLD}2${NC}  Только Remnanode"
        echo -e "   ${ORANGE_BOLD}3${NC}  Только Nginx + self-steal"
        echo -e "   ${ORANGE_BOLD}4${NC}  Только BBR"
        echo
        echo -e "   ${ORANGE_BOLD}9${NC}  Назад"
        echo
        read -rp "$(echo -e "${ORANGE_BOLD}❯${NC} Выберите пункт меню: ")" CHOICE
        case "$CHOICE" in
            1) run_remote_script "full-node-install.sh"; pause_return ;;
            2) run_remote_script "remnanode-setup.sh"; pause_return ;;
            3) run_remote_script "haproxy-setup.sh"; pause_return ;;
            4) run_remote_script "bbr-install.sh"; pause_return ;;
            9) return ;;
            *) echo -e "${RED}[x]${NC} Некорректный выбор."; sleep 1 ;;
        esac
    done
}

show_status() {
    echo
    echo -e "${ORANGE_BOLD}── Статус служб ──${NC}"
    for svc in ssh fail2ban ufw cron haproxy nginx docker; do
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
    echo -e "${ORANGE_BOLD}── BBR ──${NC}"
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "  неизвестно"
    echo
    echo -e "${ORANGE_BOLD}── crontab ──${NC}"
    crontab -l 2>/dev/null || echo "  (пусто)"
}

# ------------------------------------------------------------
# Главное меню
# ------------------------------------------------------------
main() {
    while true; do
        clear
        print_banner
        echo
        print_info_panel
        echo
        echo -e "${ORANGE}┌─ DORIK ${NC}"
        echo
        echo -e "   ${ORANGE_BOLD}1${NC}  Защита сервера"
        echo -e "   ${ORANGE_BOLD}2${NC}  Установка ноды"
        echo
        echo -e "   ${ORANGE_BOLD}0${NC}  ${RED}Выход${NC}"
        echo
        echo -e "${ORANGE}└${NC}"
        echo
        read -rp "$(echo -e "${ORANGE_BOLD}❯${NC} Выберите пункт меню: ")" CHOICE

        case "$CHOICE" in
            1) menu_security ;;
            2) menu_node ;;
            0) echo "Выход."; exit 0 ;;
            *) echo -e "${RED}[x]${NC} Некорректный выбор."; sleep 1 ;;
        esac
    done
}

main
