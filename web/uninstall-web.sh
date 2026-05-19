#!/bin/bash
set -uo pipefail

# Если запущено через "curl ... | bash" — переключаем stdin на терминал
if [ ! -t 0 ]; then
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        exec </dev/tty
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

echo -e "${YELLOW}=================================================${NC}"
echo -e "${YELLOW}  Удаление веб-панели WARPER${NC}"
echo -e "${YELLOW}=================================================${NC}"
echo ""
echo -e "Будут удалены:"
echo -e "  • Сервис warper-web и его конфигурация systemd"
echo -e "  • Конфиг nginx для warper-web"
echo -e "  • Самоподписанные SSL-сертификаты (если были)"
echo -e "  • Папка /root/warper/web/ (включая БД пользователей)"
echo ""
echo -e "${CYAN}Не будут затронуты:${NC}"
echo -e "  • WARPER (warper.sh, конфиги в /root/warper/)"
echo -e "  • sing-box и его настройки"
echo -e "  • Сертификаты Let's Encrypt в /etc/letsencrypt/"
echo ""

read -r -p "Продолжить удаление? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Отменено${NC}"
    exit 0
fi

echo ""
echo -e "${CYAN}Останавливаю сервис...${NC}"
systemctl stop warper-web 2>/dev/null || true
systemctl disable warper-web 2>/dev/null || true

echo -e "${CYAN}Удаляю systemd-юнит...${NC}"
rm -f /etc/systemd/system/warper-web.service
systemctl daemon-reload

echo -e "${CYAN}Удаляю nginx-конфиг...${NC}"
rm -f /etc/nginx/sites-enabled/warper-web
rm -f /etc/nginx/sites-available/warper-web
rm -f /etc/nginx/ssl/warper-web.crt
rm -f /etc/nginx/ssl/warper-web.key

if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
fi

echo -e "${CYAN}Удаляю файлы веб-панели...${NC}"
rm -rf /root/warper/web

# Удаляем старый файл с паролем если остался от прошлых версий
rm -f /root/warper/web_admin_pass.txt

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   ✓ Веб-панель удалена${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
echo -e "${CYAN}Установить заново:${NC}"
echo -e "  ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.2/web/install-web.sh)${NC}"
echo -e "  или через ${CYAN}warper${NC} → ${CYAN}W${NC} → ${CYAN}1${NC}"
echo ""
