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

normalize_include_ips() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk 'NF && !seen[$0]++' "$file" > "$tmp" && mv "$tmp" "$file"
}

strip_warper_blocks_from_kresd() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || return 1

    sed \
        -e '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' \
        -e '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' \
        "$src" | awk '
        BEGIN {
            seen_nonblank = 0
            prev_blank = 0
        }
        /^[[:space:]]*$/ {
            if (seen_nonblank && !prev_blank) {
                print ""
            }
            prev_blank = 1
            next
        }
        {
            print
            seen_nonblank = 1
            prev_blank = 0
        }
    ' > "$dst"
}

restore_or_clean_kresd() {
    local conf="$1"
    local backup="$2"
    local clean_tmp

    clean_tmp=$(mktemp) || return 1

    if strip_warper_blocks_from_kresd "$conf" "$clean_tmp"; then
        if [ -f "$backup" ] && cmp -s "$clean_tmp" "$backup"; then
            cp -a "$backup" "$conf" || {
                rm -f "$clean_tmp"
                return 1
            }
        else
            cp -a "$clean_tmp" "$conf" || {
                rm -f "$clean_tmp"
                return 1
            }
            cp -a "$clean_tmp" "$backup" 2>/dev/null || true
            chmod 644 "$backup" 2>/dev/null || true
        fi
    elif [ -f "$backup" ]; then
        cp -a "$backup" "$conf" || {
            rm -f "$clean_tmp"
            return 1
        }
    else
        rm -f "$clean_tmp"
        return 1
    fi

    chmod 644 "$conf" 2>/dev/null || true
    rm -f "$clean_tmp"
    return 0
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
SUBNET="198.20.0.0/24"
if [ -f "$CONF_FILE" ]; then
    loaded_subnet=$(load_config_value "SUBNET" "$CONF_FILE")
    if [ -n "$loaded_subnet" ]; then
        SUBNET="$loaded_subnet"
    fi
fi

# ============================================================
# 0. Удаление веб-панели (если установлена)
# ============================================================
WEB_DIR="/root/warper/web"
WEB_SERVICE="warper-web"

if [ -d "$WEB_DIR" ] || [ -f "/etc/systemd/system/${WEB_SERVICE}.service" ]; then
    echo -e "\n${YELLOW}0. Удаление веб-панели WARPER...${NC}"

    echo -e " - ${CYAN}Остановка сервиса warper-web...${NC}"
    systemctl stop "$WEB_SERVICE" 2>/dev/null || true
    systemctl disable "$WEB_SERVICE" 2>/dev/null || true

    echo -e " - ${CYAN}Удаление systemd-юнита...${NC}"
    rm -f "/etc/systemd/system/${WEB_SERVICE}.service"
    systemctl daemon-reload

    echo -e " - ${CYAN}Удаление конфигурации nginx...${NC}"
    rm -f /etc/nginx/sites-enabled/warper-web
    rm -f /etc/nginx/sites-available/warper-web
    rm -f /etc/nginx/ssl/warper-web.crt
    rm -f /etc/nginx/ssl/warper-web.key

    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    fi

    # Удаляем hooks автопродления сертификата если создавались
    rm -f /etc/letsencrypt/renewal-hooks/pre/warper-stop-openvpn80.sh
    rm -f /etc/letsencrypt/renewal-hooks/post/warper-start-openvpn80.sh

    echo -e " - ${CYAN}Удаление файлов веб-панели...${NC}"
    rm -rf "$WEB_DIR"
    rm -f "/root/warper/web_admin_pass.txt"

    echo -e " - ${GREEN}✓ Веб-панель удалена.${NC}"
else
    echo -e "\n${CYAN}Веб-панель не установлена — пропускаем.${NC}"
fi

echo -e "\n${YELLOW}1. Остановка и удаление служб...${NC}"
echo -e " - ${CYAN}Остановка демона sing-box...${NC}"
systemctl stop sing-box 2>/dev/null
systemctl stop warper-autopatch 2>/dev/null
systemctl stop warper-traffic-snapshot.timer 2>/dev/null
systemctl disable warper-traffic-snapshot.timer 2>/dev/null
echo -e " - ${CYAN}Удаление из автозагрузки...${NC}"
systemctl disable sing-box 2>/dev/null
systemctl disable warper-autopatch 2>/dev/null
echo -e " - ${CYAN}Удаление файлов служб...${NC}"
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/warper-autopatch.service
rm -f /usr/lib/systemd/system/sing-box.service
rm -f /usr/lib/systemd/system/warper-autopatch.service
rm -f /etc/systemd/system/warper-traffic-snapshot.service
rm -f /etc/systemd/system/warper-traffic-snapshot.timer
systemctl daemon-reload

echo -e "\n${YELLOW}2. Удаление ядра sing-box и конфигов...${NC}"
echo -e " - ${CYAN}Удаление папки с конфигурацией /etc/sing-box...${NC}"
rm -rf /etc/sing-box

# Проверяем используется ли sing-box службой warperslave
if systemctl is-active --quiet sing-box-slave 2>/dev/null; then
    echo -e " - ${YELLOW}sing-box используется sing-box-slave (warperslave). Бинарник не удаляем.${NC}"
elif systemctl is-enabled --quiet sing-box-slave 2>/dev/null; then
    echo -e " - ${YELLOW}sing-box-slave в автозагрузке (warperslave). Бинарник не удаляем.${NC}"
else
    echo -e " - ${CYAN}Удаление бинарных файлов sing-box...${NC}"
    rm -f /usr/bin/sing-box /usr/local/bin/sing-box
    echo -e " - ${GREEN}Бинарник sing-box удалён.${NC}"
fi

echo -e "\n${YELLOW}3. Восстановление исходного kresd.conf...${NC}"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"

if [ -f "$KRESD_BACKUP" ] || grep -qE "WARP-MOD-START|FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
    echo -e " - ${CYAN}Безопасное восстановление kresd.conf...${NC}"
    if restore_or_clean_kresd "$KRESD_CONF" "$KRESD_BACKUP"; then
        echo -e " - ${CYAN}Перезапуск служб kresd...${NC}"
        systemctl restart kresd@1 kresd@2 2>/dev/null || true
        rm -f "$KRESD_BACKUP"
    else
        echo -e " - ${YELLOW}Предупреждение: не удалось безопасно восстановить kresd.conf${NC}"
    fi
else
    echo -e " - ${GREEN}kresd.conf уже чист.${NC}"
fi

echo -e "\n${YELLOW}4. Восстановление маршрутов и очистка...${NC}"

NEED_DOALL=false

# Удаление fake-подсети из include-ips
AZ_INC="/root/antizapret/config/include-ips.txt"
if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then
    echo -e " - ${CYAN}Удаление подсети $SUBNET из $AZ_INC...${NC}"
    sed -i "\|$SUBNET|d" "$AZ_INC"
    normalize_include_ips "$AZ_INC"
    NEED_DOALL=true
fi

# Удаление пользовательских IP-маршрутов
echo -e " - ${CYAN}Удаление пользовательских IP-маршрутов...${NC}"
if [ -f "/root/warper/ip-ranges.applied" ]; then
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        ip route del "$cidr" dev singbox-tun table 100 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
    done < "/root/warper/ip-ranges.applied"
    rm -f "/root/warper/ip-ranges.applied"
fi
for prefix in 10 172; do
    while ip rule show 2>/dev/null | grep -q "from ${prefix}.29.0.0/16 lookup 100"; do
        ip rule del from "${prefix}.29.0.0/16" lookup 100 priority 500 2>/dev/null || break
    done
    while ip rule show 2>/dev/null | grep -q "from ${prefix}.28.0.0/15 lookup 100"; do
        ip rule del from "${prefix}.28.0.0/15" lookup 100 priority 500 2>/dev/null || break
    done
done
echo -e " - ${GREEN}IP-маршруты и правила маршрутизации удалены.${NC}"

# Удаление экспорта WARPER в AntiZapret
if [ -f "/root/antizapret/config/warper-include-ips.txt" ]; then
    echo -e " - ${CYAN}Удаление warper-include-ips.txt...${NC}"
    rm -f "/root/antizapret/config/warper-include-ips.txt"
    NEED_DOALL=true
fi

# Один вызов doall.sh ip если что-то изменилось
if [ "$NEED_DOALL" = true ]; then
    echo -e " - ${CYAN}Обновление маршрутов AntiZapret (doall.sh ip)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1
    echo -e " - ${GREEN}Маршруты AntiZapret обновлены.${NC}"
else
    echo -e " - ${GREEN}Изменения маршрутов AntiZapret не требуются.${NC}"
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
    find /root/warper -type f \
        -not -name 'domains.txt' \
        -not -name 'warper.conf' \
        -not -name 'ip-ranges.txt' \
        -not -name 'slave_mode.conf' \
        -not -name 'wg_mode.conf' \
        -not -name 'traffic.json' \
        -not -name 'catalog.json' \
        -not -name 'catalog-cache.json' \
        -not -path '*/wgcf/*' \
        -delete 2>/dev/null
    rm -rf /root/warper/download 2>/dev/null
    echo -e " - ${GREEN}Настройки сохранены!${NC}"
else
    echo -e " - ${CYAN}Полное удаление папки /root/warper...${NC}"
    rm -rf /root/warper
fi

echo -e "\n${GREEN}✅ WARPER успешно удален из системы! Сервер возвращен в исходное состояние.${NC}"
