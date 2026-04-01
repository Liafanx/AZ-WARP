#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}================================================${NC}"
echo -e " 🗑️ УДАЛЕНИЕ WARPER И SING-BOX"
echo -e "${RED}================================================${NC}"
echo -e "Эта команда удалит службу туннеля, очистит настройки DNS и маршруты."

read -p "Вы уверены, что хотите полностью удалить warper? (N/y): " conf < /dev/tty
if [[ ! "$conf" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Отмена. Ничего не изменено.${NC}"
    exit 0
fi

read -p "Оставить список доменов в папке /root/warper? (Y/n): " keep_dom < /dev/tty
if [[ -z "$keep_dom" || "$keep_dom" =~ ^[Yy]$ ]]; then
    KEEP_DOMAINS=true
else
    KEEP_DOMAINS=false
fi

echo -e "\n${YELLOW}1. Остановка и удаление службы sing-box...${NC}"
systemctl stop sing-box 2>/dev/null
systemctl disable sing-box 2>/dev/null
rm -f /usr/lib/systemd/system/sing-box.service
systemctl daemon-reload

echo -e "${YELLOW}2. Удаление ядра sing-box и конфигов...${NC}"
rm -f /usr/bin/sing-box /usr/local/bin/sing-box
rm -rf /etc/sing-box

echo -e "${YELLOW}3. Восстановление исходного kresd.conf...${NC}"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
    sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2 2>/dev/null
fi

echo -e "${YELLOW}4. Восстановление маршрутов AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if grep -q "198.18.0.0/24" "$AZ_INC" 2>/dev/null; then
    sed -i '/198.18.0.0\/24/d' "$AZ_INC"
    /root/antizapret/doall.sh >/dev/null 2>&1
fi

echo -e "${YELLOW}5. Удаление утилиты WARPER...${NC}"
rm -f /usr/local/bin/warper
rm -f /etc/knot-resolver/warper-domains.txt

if [ "$KEEP_DOMAINS" = true ]; then
    find /root/warper -type f -not -name 'domains.txt' -delete 2>/dev/null
    echo -e "${GREEN}Файл доменов /root/warper/domains.txt сохранен!${NC}"
else
    rm -rf /root/warper
fi

echo -e "\n${GREEN}✅ WARPER успешно удален из системы! Сервер возвращен в исходное состояние.${NC}"
