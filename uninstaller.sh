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

remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

load_config_value() {
    local key="$1" file="$2"
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
        echo -e "${RED}Ошибка: Пожалуйста, введите y или N.${NC}"
    fi
done

while true; do
    read -r -p "Оставить список доменов, исключения и настройки в /root/warper? (Y/n): " keep_dom < /dev/tty
    if [[ -z "$keep_dom" || "$keep_dom" =~ ^[Yy]$ ]]; then
        KEEP_DOMAINS=true
        break
    elif [[ "$keep_dom" =~ ^[Nn]$ ]]; then
        KEEP_DOMAINS=false
        break
    else
        echo -e "${RED}Ошибка: Пожалуйста, введите Y или n.${NC}"
    fi
done

CONF_FILE="/root/warper/warper.conf"
SUBNET="198.18.0.0/24"
if [ -f "$CONF_FILE" ]; then
    loaded_subnet=$(load_config_value "SUBNET" "$CONF_FILE")
    [ -n "$loaded_subnet" ] && SUBNET="$loaded_subnet"
fi

systemctl stop sing-box 2>/dev/null
systemctl stop warper-autopatch 2>/dev/null
systemctl disable sing-box 2>/dev/null
systemctl disable warper-autopatch 2>/dev/null

rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/warper-autopatch.service
rm -f /usr/lib/systemd/system/sing-box.service
rm -f /usr/lib/systemd/system/warper-autopatch.service
systemctl daemon-reload

rm -f /usr/bin/sing-box /usr/local/bin/sing-box
rm -rf /etc/sing-box

KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"

if [ -f "$KRESD_BACKUP" ]; then
    cp -a "$KRESD_BACKUP" "$KRESD_CONF"
    chmod 644 "$KRESD_CONF" 2>/dev/null || true
    systemctl restart kresd@1 kresd@2 2>/dev/null || true
    rm -f "$KRESD_BACKUP"
elif grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
    sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2 2>/dev/null || true
fi

AZ_INC="/root/antizapret/config/include-ips.txt"
if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then
    sed -i "\|$SUBNET|d" "$AZ_INC"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
fi

remove_iptables_rule FORWARD -o singbox-tun
remove_iptables_rule FORWARD -i singbox-tun

rm -f /usr/local/bin/warper
rm -f /etc/knot-resolver/warper-domains.txt
rm -f /etc/knot-resolver/warper-exclude-domains.txt

if [ "$KEEP_DOMAINS" = true ]; then
    find /root/warper -type f \
        -not -name 'domains.txt' \
        -not -name 'exclude_domains.txt' \
        -not -name 'warper.conf' \
        -not -path '*/wgcf/*' \
        -delete 2>/dev/null
    rm -rf /root/warper/download 2>/dev/null
else
    rm -rf /root/warper
fi

echo -e "\n${GREEN}✅ WARPER успешно удален.${NC}"
