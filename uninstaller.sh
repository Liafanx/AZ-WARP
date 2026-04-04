#!/bin/bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}================================================${NC}"
echo -e " 🗑️ УДАЛЕНИЕ WARPER И SING-BOX"
echo -e "${RED}================================================${NC}"
echo -e "Эта команда полностью удалит службу туннеля, очистит настройки DNS и маршруты."

remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

load_config_value() {
    local key="$1"
    local file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]'
}

while true; do
    read -r -p "Вы уверены, что хотите полностью удалить warper? (N/y): " conf < /dev/tty
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
    read -r -p "Оставить список доменов и настройки в папке /root/warper? (Y/n): " keep_dom < /dev/tty
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
SUBNET="198.18.0.0/24"
if [ -f "$CONF_FILE" ]; then
    loaded_subnet=$(load_config_value "SUBNET" "$CONF_FILE")
    if [ -n "$loaded_subnet" ]; then
        SUBNET="$loaded_subnet"
    fi
fi

echo -e "\n${YELLOW}1. Остановка и удаление служб...${NC}"
echo -e " - ${CYAN}Остановка демона sing-box...${NC}"
systemctl stop sing-box 2>/dev/null
systemctl stop warper-autopatch 2>/dev/null
echo -e " - ${CYAN}Удаление из автозагрузки...${NC}"
systemctl disable sing-box 2>/dev/null
systemctl disable warper-autopatch 2>/dev/null
echo -e " - ${CYAN}Удаление файлов служб...${NC}"
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/warper-autopatch.service
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
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"

if [ -f "$KRESD_BACKUP" ]; then
    echo -e " - ${CYAN}Восстановление kresd.conf из резервной копии...${NC}"
    cp -a "$KRESD_BACKUP" "$KRESD_CONF"
    chmod 644 "$KRESD_CONF" 2>/dev/null || true
    systemctl restart kresd@1 kresd@2 2>/dev/null
    rm -f "$KRESD_BACKUP"
elif grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
    echo -e " - ${CYAN}Очистка кода WARPER из конфигурации DNS...${NC}"
    sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
    echo -e " - ${CYAN}Перезапуск служб kresd...${NC}"
    systemctl restart kresd@1 kresd@2 2>/dev/null
else
    echo -e " - ${GREEN}kresd.conf уже чист.${NC}"
fi

echo -e "\n${YELLOW}4. Восстановление маршрутов AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"

if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then
    echo -e " - ${CYAN}Удаление подсети $SUBNET из $AZ_INC...${NC}"
    sed -i "\|$SUBNET|d" "$AZ_INC"

    echo -e " - ${CYAN}Запуск doall.sh (обновление конфигурации AntiZapret, подождите)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1

    echo -e " - ${GREEN}Конфигурация маршрутов успешно восстановлена!${NC}"
else
    echo -e " - ${GREEN}Подсеть $SUBNET отсутствует, изменения маршрутов не требуются.${NC}"
fi

echo -e "\n${YELLOW}5. Удаление правил firewall...${NC}"
remove_iptables_rule FORWARD -o singbox-tun
remove_iptables_rule FORWARD -i singbox-tun

echo -e "\n${YELLOW}6. Удаление утилиты WARPER...${NC}"
echo -e " - ${CYAN}Удаление системного ярлыка утилиты...${NC}"
rm -f /usr/local/bin/warper
rm -f /etc/knot-resolver/warper-domains.txt

if [ "$KEEP_DOMAINS" = true ]; then
    echo -e " - ${CYAN}Очистка папки /root/warper (с сохранением настроек, доменов и ключей WARP)...${NC}"
    find /root/warper -type f -not -name 'domains.txt' -not -name 'warper.conf' -not -path '*/wgcf/*' -delete 2>/dev/null
    rm -rf /root/warper/download 2>/dev/null
    echo -e " - ${GREEN}Настройки сохранены!${NC}"
else
    echo -e " - ${CYAN}Полное удаление папки /root/warper...${NC}"
    rm -rf /root/warper
fi

echo -e "\n${GREEN}✅ WARPER успешно удален из системы! Сервер возвращен в исходное состояние.${NC}"