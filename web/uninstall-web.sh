#!/bin/bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

read -r -p "Удалить веб-панель WARPER? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Отменено"
    exit 0
fi

systemctl stop warper-web 2>/dev/null
systemctl disable warper-web 2>/dev/null
rm -f /etc/systemd/system/warper-web.service
systemctl daemon-reload

rm -f /etc/nginx/sites-enabled/warper-web
rm -f /etc/nginx/sites-available/warper-web
rm -rf /etc/nginx/ssl/warper-web.*
systemctl reload nginx 2>/dev/null

rm -rf /root/warper/web
rm -f /root/warper/web_admin_pass.txt

echo -e "${GREEN}✓ Веб-панель удалена${NC}"
