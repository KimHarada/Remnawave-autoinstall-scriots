# Remnawave autoinstall

Автонастройка ноды Remnawave на **чистой Ubuntu/Debian**: обновление пакетов, SSH, firewall, fail2ban,
Nginx (self-steal) + HAProxy (SNI-маршрутизация) + Let's Encrypt, BBR и сетевая оптимизация, Remnanode в Docker.

## Запуск на пустом сервере

От root (`sudo -i`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh)
```

Скрипт сам скачает тулкит в `/opt/dorik-toolkit`, поставит недостающие пакеты
(`curl`, `ufw`, `dnsutils`, `cron`, …), обновит систему, зададёт вопросы **один раз** и дальше пройдёт все шаги без остановок.
Повторный запуск безопасен: уже сделанное пропускается.

Перед запуском направьте A-записи доменов на IP сервера — иначе сертификаты не выпустятся
(скрипт проверит DNS заранее и скажет, что не так).

## Что делает «Полная настройка»

| Шаг | Что происходит |
|---|---|
| Базовые пакеты | `apt update`, установка `curl ufw dnsutils cron psmisc …`; ждёт `unattended-upgrades`, чинит прерванный dpkg |
| Обновление | `apt full-upgrade` без интерактивных вопросов (конфиги не перезаписываются) |
| SSH | Смена порта с проверкой `sshd -t`, откат при неудаче, поддержка `ssh.socket` (Ubuntu 24.04), закрытие старого порта |
| Firewall | ufw: SSH, 80, 443/tcp, 443/udp (Hysteria2), порт ноды — опционально только для IP панели |
| fail2ban | Защита SSH (`backend = systemd`, бан на сутки после 3 попыток) |
| Nginx + HAProxy | Заглушка на `127.0.0.1:8081` с TLS, SNI-маршрутизация по доменам, Certbot с автопродлением и хуком перезапуска |
| BBR | BBR + `fq` и настройка сети под прокси-ноду (буферы для QUIC/Hysteria2, backlog, keepalive, лимиты файлов) |
| Remnanode | Docker, `docker-compose.yml` (права 600, ротация логов), привязка сертификата Hysteria2 |

Роль «только сервер панели» ставит firewall (SSH + 80 + 443) и fail2ban без ноды.

## Запуск без вопросов (cloud-init / автоматизация)

```bash
export ASSUME_YES=1 ROLE=1 NEW_SSH_PORT=22 \
       DOMAIN_TCP=tcp.example.com DOMAIN_GRPC=grpc.example.com DOMAIN_XHTTP=xhttp.example.com \
       DOMAIN_HY2=hy2.example.com NODE_PORT=3001 SECRET_KEY='...' PANEL_IP=203.0.113.10
bash <(curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh) --full
```

Ответы на «да/нет» в этом режиме берутся по умолчанию (всё включается). Необязательные переменные:
`LE_EMAIL` (почта для Let's Encrypt), `DORIK_TZ` (часовой пояс, по умолчанию `Asia/Irkutsk`).

## Отдельные операции

`menu.sh` → «Дополнительно», либо напрямую: `menu.sh --bbr`. Внутри: восстановление SSH
(`fix-ssh-access.sh`), только BBR, только Nginx+HAProxy, только Remnanode.

## Требования

Ubuntu 22.04 / 24.04 или Debian 11/12, root, доступ в интернет, порты 80/443 свободны на время выпуска сертификатов.
