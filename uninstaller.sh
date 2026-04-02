#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}================================================${NC}"
echo -e " 🗑️ УДАЛЕНИЕ WARPER И SING-BOX"
echo -e "${RED}================================================${NC}"
echo -e "Эта команда полностью удалит службу туннеля, очистит настройки DNS и маршруты."

while true; do
    read -p "Вы уверены, что хотите полностью удалить warper? (N/y): " conf < /dev/tty
    if [[ -z "$conf" || "$conf" =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Отмена. Ничего не изменено.${NC}"
        exit 0
    elif [[ "$conf" =~ ^[Yy]$ ]]; then
        break
    else
        echo -e "${RED}Ошибка: Пожалуйста, введите y (да) или N (нет).${NC}"
    fi
done

while true; do
    read -p "Оставить список доменов в папке /root/warper? (Y/n): " keep_dom < /dev/tty
    if [[ -z "$keep_dom" || "$keep_dom" =~ ^[Yy]$ ]]; then
        KEEP_DOMAINS=true
        break
    elif [[ "$keep_dom" =~ ^[Nn]$ ]]; then
        KEEP_DOMAINS=false
        break
    else
        echo -e "${RED}Ошибка: Пожалуйста, введите Y (да) или n (нет).${NC}"
    fi
done

CONF_FILE="/root/warper/warper.conf"
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    SUBNET="198.18.0.0/24"
fi

echo -e "\n${YELLOW}1. Остановка и удаление служб...${NC}"
echo -e " - ${CYAN}Остановка демона sing-box...${NC}"
systemctl stop sing-box 2>/dev/null
systemctl stop warper-autopatch 2>/dev/null
echo -e " - ${CYAN}Удаление из автозагрузки...${NC}"
systemctl disable sing-box 2>/dev/null
systemctl disable warper-autopatch 2>/dev/null
echo -e " - ${CYAN}Удаление файлов служб...${NC}"
rm -f /usr/lib/systemd/system/sing-box.service
rm -f /usr/lib/systemd/system/warper-autopatch.service
systemctl daemon-reload

echo -e "\n${YELLOW}2. Удаление ядра sing-box и конфигов...${NC}"
echo -e " - ${CYAN}Удаление бинарных файлов...${NC}"
rm -f /usr/bin/sing-box /usr/local/bin/sing-box
echo -e " - ${CYAN}Удаление папки с конфигурацией /etc/sing-box...${NC}"
rm -rf /etc/sing-box

echo -e "\n${YELLOW}3. Восстановление исходного kresd.conf...${NC}"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
    echo -e " - ${CYAN}Очистка кода WARPER из конфигурации DNS...${NC}"
    sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
    echo -e " - ${CYAN}Перезапуск служб kresd...${NC}"
    systemctl restart kresd@1 kresd@2 2>/dev/null
else
    echo -e " - ${GREEN}kresd.conf уже чист.${NC}"
fi

echo -e "\n${YELLOW}4. Восстановление маршрутов AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
ESC_SUBNET=$(echo "$SUBNET" | sed 's/\//\\\//g')

if grep -q "$SUBNET" "$AZ_INC" 2>/dev/null; then
    echo -e " - ${CYAN}Удаление подсети $SUBNET из $AZ_INC...${NC}"
    sed -i "/$ESC_SUBNET/d" "$AZ_INC"
    
    echo -e " - ${CYAN}Запуск doall.sh (обновление конфигурации AntiZapret, подождите)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
    
    echo -e " - ${GREEN}Конфигурация маршрутов успешно восстановлена!${NC}"
else
    echo -e " - ${GREEN}Подсеть $SUBNET отсутствует, изменения маршрутов не требуются.${NC}"
fi

echo -e "\n${YELLOW}5. Удаление утилиты WARPER...${NC}"
echo -e " - ${CYAN}Удаление системного ярлыка утилиты...${NC}"
rm -f /usr/local/bin/warper
rm -f /etc/knot-resolver/warper-domains.txt

if [ "$KEEP_DOMAINS" = true ]; then
    echo -e " - ${CYAN}Очистка папки /root/warper (с сохранением domains.txt и warper.conf)...${NC}"
    find /root/warper -type f -not -name 'domains.txt' -not -name 'warper.conf' -delete 2>/dev/null
    rm -rf /root/warper/download 2>/dev/null
    echo -e " - ${GREEN}Настройки сохранены!${NC}"
else
    echo -e " - ${CYAN}Полное удаление папки /root/warper...${NC}"
    rm -rf /root/warper
fi

echo -e "\n${GREEN}✅ WARPER успешно удален из системы! Сервер возвращен в исходное состояние.${NC}"
