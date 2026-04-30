#!/bin/bash

set -uo pipefail

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"
AZ_INC="/root/antizapret/config/include-ips.txt"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"
SLAVE_TEMPLATE="$WARPER_DIR/config-slave-master.json.template"
SLAVE_MODE_FILE="$WARPER_DIR/slave_mode.conf"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.0beta"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"
WARP_SYSTEM_CONF="/etc/wireguard/warp.conf"
LOCK_FILE="/var/run/warper.lock"
# ===== WG mode конфигурация =====
WG_CONF_FILE=""
WG_ADDRESS=""
WG_PRIVATE_KEY=""
WG_PUBLIC_KEY=""
WG_PRESHARED_KEY=""
WG_ENDPOINT_HOST=""
WG_ENDPOINT_PORT=""
WG_KEEPALIVE="15"
WG_TEMPLATE="$WARPER_DIR/config-wg.json.template"
WG_MODE_FILE="$WARPER_DIR/wg_mode.conf"
# ===== IP-ranges маршрутизация =====
IP_RANGES_FILE="$WARPER_DIR/ip-ranges.txt"
IP_ROUTE_TABLE=100
IP_ROUTE_PRIO=500
IP_ROUTE_MODE="antizapret"
AZ_WARPER_INCLUDE_IPS="/root/antizapret/config/warper-include-ips.txt"
IP_EXPORT_TO_ANTIZAPRET="y"

# Динамические: определяются из AntiZapret setup
AZ_CLIENT_NET=""
FULLVPN_CLIENT_NET=""
ALL_CLIENT_NET=""

SUBNET="198.20.0.0/24"
TUN_IP="198.20.0.1/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

# ===== Lock-файл =====

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}Другой экземпляр warper уже запущен.${NC}" >&2
        exit 1
    fi
}

release_lock() {
    rm -f "$LOCK_FILE"
}

trap 'release_lock' EXIT
acquire_lock

# ===== Определение интерактивного режима =====

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# ===== Инициализация domains.txt =====

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF
fi

# ===== Инициализация ip-ranges.txt =====

if [ ! -f "$IP_RANGES_FILE" ]; then
cat << 'IPEOF' > "$IP_RANGES_FILE"
# Добавление IPv4-адресов для маршрутизации через Warper (Sing-box tun)
#
# Формат записи: A.B.C.D/M
# Где:
#   A.B.C.D - IPv4-адрес
#   M       - размер маски подсети (1-32)
#
# Примеры записи:
#   5.255.255.242/32  - один IPv4-адрес
#   66.22.192.0/18    - подсеть с маской 18 (16382 адреса)
#   104.24.0.0/14     - подсеть с маской 14 (262142 адреса)
#   34.3.3.0/24       - подсеть с маской 24 (254 адреса)
#
# Строки начинающиеся с # - комментарии, не обрабатываются.
# Пустые строки игнорируются.
#
# После изменения файла выполните: warper ipsync
# Или в меню: Управление IP-подсетями → Синхронизировать
IPEOF
fi

# ===== Загрузка конфигурации =====

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        return 0
    fi
    local value
    value=$(grep -E '^SUBNET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ] && validate_subnet "$value"; then
        SUBNET="$value"
    fi
    value=$(grep -E '^TUN_IP=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        TUN_IP="$value"
    else
        TUN_IP=$(calculate_tun_ip "$SUBNET")
    fi
    value=$(grep -E '^IP_ROUTE_MODE=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        IP_ROUTE_MODE="$value"
    fi
    value=$(grep -E '^IP_EXPORT_TO_ANTIZAPRET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        IP_EXPORT_TO_ANTIZAPRET="$value"
    fi    
}

# ===== Slave mode конфигурация =====

CURRENT_OUTBOUND_MODE="warp"
SLAVE_SERVER=""
SLAVE_PORT="8444"
SLAVE_PASSWORD=""

load_slave_config() {
    CURRENT_OUTBOUND_MODE="warp"
    SLAVE_SERVER=""
    SLAVE_PORT="8444"
    SLAVE_PASSWORD=""
    if [ -f "$SLAVE_MODE_FILE" ]; then
        local val
        val=$(grep -E '^OUTBOUND_MODE=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && CURRENT_OUTBOUND_MODE="$val"
        val=$(grep -E '^SLAVE_SERVER=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && SLAVE_SERVER="$val"
        val=$(grep -E '^SLAVE_PORT=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && SLAVE_PORT="$val"
        val=$(grep -E '^SLAVE_PASSWORD=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
        [ -n "$val" ] && SLAVE_PASSWORD="$val"
    fi
}

save_slave_config() {
    {
        echo "OUTBOUND_MODE=$CURRENT_OUTBOUND_MODE"
        echo "SLAVE_SERVER=$SLAVE_SERVER"
        echo "SLAVE_PORT=$SLAVE_PORT"
        echo "SLAVE_PASSWORD=$SLAVE_PASSWORD"
    } > "$SLAVE_MODE_FILE"
    chmod 600 "$SLAVE_MODE_FILE"
}

load_wg_config() {
    WG_CONF_FILE=""
    WG_ADDRESS=""
    WG_PRIVATE_KEY=""
    WG_PUBLIC_KEY=""
    WG_PRESHARED_KEY=""
    WG_ENDPOINT_HOST=""
    WG_ENDPOINT_PORT=""
    WG_KEEPALIVE="15"
    if [ -f "$WG_MODE_FILE" ]; then
        local val
        val=$(grep -E '^WG_CONF_FILE=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
        [ -n "$val" ] && WG_CONF_FILE="$val"
        val=$(grep -E '^WG_ADDRESS=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ADDRESS="$val"
        val=$(grep -E '^WG_PRIVATE_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PRIVATE_KEY="$val"
        val=$(grep -E '^WG_PUBLIC_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PUBLIC_KEY="$val"
        val=$(grep -E '^WG_PRESHARED_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PRESHARED_KEY="$val"
        val=$(grep -E '^WG_ENDPOINT_HOST=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ENDPOINT_HOST="$val"
        val=$(grep -E '^WG_ENDPOINT_PORT=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ENDPOINT_PORT="$val"
        val=$(grep -E '^WG_KEEPALIVE=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_KEEPALIVE="$val"
    fi
}

save_wg_config() {
    {
        echo "WG_CONF_FILE=$WG_CONF_FILE"
        echo "WG_ADDRESS=$WG_ADDRESS"
        echo "WG_PRIVATE_KEY=$WG_PRIVATE_KEY"
        echo "WG_PUBLIC_KEY=$WG_PUBLIC_KEY"
        echo "WG_PRESHARED_KEY=$WG_PRESHARED_KEY"
        echo "WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST"
        echo "WG_ENDPOINT_PORT=$WG_ENDPOINT_PORT"
        echo "WG_KEEPALIVE=$WG_KEEPALIVE"
    } > "$WG_MODE_FILE"
    chmod 600 "$WG_MODE_FILE"
}

# Проверка: файл WG-конфиг, НЕ Cloudflare WARP
is_valid_wg_conf() {
    local file="$1"
    [ -f "$file" ] || return 1
    # Должен содержать [Peer] с Endpoint
    grep -q '^\[Peer\]' "$file" || return 1
    grep -q '^Endpoint' "$file" || return 1
    grep -q '^PublicKey' "$file" || return 1
    # Исключаем Cloudflare WARP конфиги
    if grep -q 'engage.cloudflareclient.com' "$file" 2>/dev/null; then
        return 1
    fi
    if grep -q '162.159.192.1' "$file" 2>/dev/null; then
        return 1
    fi
    if grep -q '162.159.193.1' "$file" 2>/dev/null; then
        return 1
    fi
    return 0
}

parse_wg_conf() {
    local file="$1"
    WG_CONF_FILE="$file"
    WG_PRIVATE_KEY=$(grep -m 1 '^PrivateKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    WG_ADDRESS=$(grep -m 1 '^Address' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    WG_ADDRESS="${WG_ADDRESS%%,*}"
    WG_ADDRESS=$(echo "$WG_ADDRESS" | tr -d ' ')
    WG_PUBLIC_KEY=$(grep -m 1 '^PublicKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    WG_PRESHARED_KEY=$(grep -m 1 '^PresharedKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    local endpoint
    endpoint=$(grep -m 1 '^Endpoint' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    WG_ENDPOINT_HOST="${endpoint%:*}"
    WG_ENDPOINT_PORT="${endpoint##*:}"
    local keepalive
    keepalive=$(grep -m 1 '^PersistentKeepalive' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    WG_KEEPALIVE="${keepalive:-15}"

    # Валидация всех обязательных параметров
    local missing=()
    [ -z "$WG_ADDRESS" ]        && missing+=("Address")
    [ -z "$WG_PRIVATE_KEY" ]    && missing+=("PrivateKey")
    [ -z "$WG_PUBLIC_KEY" ]     && missing+=("PublicKey")
    [ -z "$WG_PRESHARED_KEY" ]  && missing+=("PresharedKey")
    [ -z "$WG_ENDPOINT_HOST" ]  && missing+=("Endpoint")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}В файле отсутствуют обязательные параметры: ${missing[*]}${NC}"
        return 1
    fi
    return 0
}

# Сканировать папки для WG-конфигов
scan_wg_configs() {
    local -a found_files=()
    local file
    for dir in /root /root/warper; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' file; do
                if is_valid_wg_conf "$file"; then
                    found_files+=("$file")
                fi
            done < <(find "$dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
        fi
    done

    if [ ${#found_files[@]} -gt 0 ]; then
        printf '%s\n' "${found_files[@]}"
    fi
}

# Интерактивный выбор WG-конфига
select_wg_config() {
    local -a configs
    local choice

    while true; do
        echo -e "\n${CYAN}Поиск WireGuard-конфигов в /root/ и /root/warper/...${NC}"

        mapfile -t configs < <(scan_wg_configs)
        local filtered_configs=()
        local cfg_item
        for cfg_item in "${configs[@]}"; do
            [[ -n "$cfg_item" ]] && filtered_configs+=("$cfg_item")
        done
        configs=("${filtered_configs[@]+"${filtered_configs[@]}"}")

        if [ ${#configs[@]} -gt 0 ]; then
            echo -e "${GREEN}Найдено конфигов: ${#configs[@]}${NC}"
            echo -e ""
            local i=1
            for f in "${configs[@]}"; do
                local ep
                ep=$(grep -m 1 '^Endpoint' "$f" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                echo -e " ${GREEN}${i}.${NC} ${YELLOW}${f}${NC} (${CYAN}${ep}${NC})"
                ((i++))
            done
            echo -e ""
            echo -e " ${CYAN}M.${NC} Ввести данные вручную"
            echo -e " ${CYAN}R.${NC} Обновить список"
            echo -e " ${CYAN}0.${NC} Отмена"
            echo -e ""
            read -r -p "Выбор: " choice

            case "$choice" in
                0)
                    return 1
                    ;;
                [0-9]*)
                    if (( choice >= 1 && choice <= ${#configs[@]} )); then
                        if parse_wg_conf "${configs[$((choice-1))]}"; then
                            save_wg_config
                            echo -e "${GREEN}Выбран: ${configs[$((choice-1))]}${NC}"
                            return 0
                        else
                            echo -e "${YELLOW}Выберите другой файл или введите данные вручную.${NC}"
                        fi
                    else
                        echo -e "${RED}Неверный номер.${NC}"
                    fi
                    ;;
                m|M)
                    input_wg_manually
                    return $?
                    ;;
                r|R)
                    echo -e "${CYAN}Повторный поиск...${NC}"
                    continue
                    ;;
                *)
                    echo -e "${RED}Неверный выбор.${NC}"
                    ;;
            esac
        else
            echo -e "${YELLOW}WireGuard-конфиги не найдены.${NC}"
            echo -e ""
            echo -e " ${GREEN}1.${NC} Ввести данные вручную"
            echo -e " ${CYAN}2.${NC} Положить .conf файл в /root/ или /root/warper/ и обновить"
            echo -e " ${CYAN}0.${NC} Отмена (выбрать другой режим)"
            echo -e ""
            read -r -p "Выбор: " choice

            case "$choice" in
                1) input_wg_manually; return $? ;;
                2)
                    echo -e "${YELLOW}Положите .conf файл и нажмите Enter...${NC}"
                    read -r -p ""
                    continue
                    ;;
                0) return 1 ;;
                *) echo -e "${RED}Неверный выбор.${NC}" ;;
            esac
        fi
    done
}

input_wg_manually() {
    echo -e "\n${CYAN}Ввод данных WireGuard вручную${NC}"

    while true; do
        read -r -p "Endpoint (IP:порт, например 1.2.3.4:51820): " ep_input
        if [[ "$ep_input" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
            WG_ENDPOINT_HOST="${ep_input%:*}"
            WG_ENDPOINT_PORT="${ep_input##*:}"
            break
        fi
        echo -e "${RED}Формат: IP:порт или домен:порт${NC}"
    done

    while true; do
        read -r -p "Address (например 172.28.8.3/32): " WG_ADDRESS
        [ -n "$WG_ADDRESS" ] && break
        echo -e "${RED}Address обязателен!${NC}"
    done

    while true; do
        read -r -p "PrivateKey: " WG_PRIVATE_KEY
        [ -n "$WG_PRIVATE_KEY" ] && break
        echo -e "${RED}PrivateKey обязателен!${NC}"
    done

    while true; do
        read -r -p "PublicKey (сервера): " WG_PUBLIC_KEY
        [ -n "$WG_PUBLIC_KEY" ] && break
        echo -e "${RED}PublicKey обязателен!${NC}"
    done

    while true; do
        read -r -p "PresharedKey: " WG_PRESHARED_KEY
        [ -n "$WG_PRESHARED_KEY" ] && break
        echo -e "${RED}PresharedKey обязателен!${NC}"
    done

    read -r -p "PersistentKeepalive [15]: " WG_KEEPALIVE
    WG_KEEPALIVE="${WG_KEEPALIVE:-15}"

    WG_CONF_FILE="manual"
    save_wg_config
    echo -e "${GREEN}Данные WG сохранены.${NC}"
    return 0
}

rebuild_config_wg() {
    load_wg_config

    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WG_PUBLIC_KEY" ] || [ -z "$WG_ENDPOINT_HOST" ]; then
        echo -e "${RED}Не настроены параметры WG-соединения!${NC}"
        return 1
    fi

    if [ -z "$WG_PRESHARED_KEY" ]; then
        echo -e "${RED}Ошибка: PresharedKey не задан!${NC}"
        return 1
    fi

    if [ ! -f "$WG_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config-wg.json.template" "$WG_TEMPLATE" "шаблон WG" || return 1
    fi

    local tmp
    tmp=$(mktemp)

    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__WG_ADDRESS__|$WG_ADDRESS|g" \
        -e "s|__WG_PRIVATE_KEY__|$WG_PRIVATE_KEY|g" \
        -e "s|__WG_PUBLIC_KEY__|$WG_PUBLIC_KEY|g" \
        -e "s|__WG_PRESHARED_KEY__|$WG_PRESHARED_KEY|g" \
        -e "s|__WG_ENDPOINT_HOST__|$WG_ENDPOINT_HOST|g" \
        -e "s|__WG_ENDPOINT_PORT__|$WG_ENDPOINT_PORT|g" \
        -e "s|__WG_KEEPALIVE__|$WG_KEEPALIVE|g" \
        "$WG_TEMPLATE" > "$tmp"

    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации конфига WG!${NC}"
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box (WG) успешно обновлена.${NC}"
    return 0
}

# ===== Проверки AntiZapret =====

check_antizapret_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local az_warp
        az_warp=$(grep -E '^ANTIZAPRET_WARP=' "$setup_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$az_warp" = "y" ]; then
            return 0
        fi
    fi
    return 1
}

check_vpn_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local vpn_warp
        vpn_warp=$(grep -E '^VPN_WARP=' "$setup_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$vpn_warp" = "y" ]; then
            return 0
        fi
    fi
    return 1
}

check_warp_rules_active() {
    if ip link show warp >/dev/null 2>&1; then
        return 0
    fi
    if ip rule show 2>/dev/null | grep -q "lookup 13335"; then
        return 0
    fi
    return 1
}

needs_down_sh() {
    if ! check_vpn_warp && ! check_antizapret_warp; then
        if check_warp_rules_active; then
            return 0
        fi
    fi
    return 1
}

show_down_sh_warning() {
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}⚠️  Обнаружены активные правила от AntiZapret WARP!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}VPN_WARP и ANTIZAPRET_WARP выключены, но правила${NC}"
    echo -e "${YELLOW}от предыдущего запуска up.sh ещё активны.${NC}"
    echo -e ""
    echo -e "${CYAN}Для корректной работы WARPER выполните последовательно:${NC}"
    echo -e "  ${GREEN}/root/antizapret/down.sh${NC}"
    echo -e "  ${GREEN}/root/antizapret/up.sh${NC}"
    echo -e ""
    echo -e "${YELLOW}Это перезапустит правила AntiZapret и позволит${NC}"
    echo -e "${YELLOW}WARPER использовать локальные ключи.${NC}"
    echo -e "${RED}================================================${NC}"
}

show_antizapret_warp_warning() {
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}⚠️  ANTIZAPRET_WARP=y включён!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}WARPER не может работать при включённом ANTIZAPRET_WARP,${NC}"
    echo -e "${YELLOW}так как встроенный WARP AntiZapret конфликтует с WARPER.${NC}"
    echo -e ""
    echo -e "${CYAN}Для использования WARPER:${NC}"
    echo -e "1. Установите ANTIZAPRET_WARP=n в /root/antizapret/setup"
    echo -e "2. Выполните: /root/antizapret/down.sh"
    echo -e "3. Выполните: /root/antizapret/up.sh"
    echo -e "4. Запустите: warper"
    echo -e "${RED}================================================${NC}"
}

is_warper_active() {
    if systemctl is-active --quiet sing-box && grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ===== Валидация =====

escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    domain="${domain%.}"
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    if [ -z "$domain" ]; then return 1; fi
    if [[ ! "$domain" =~ \. ]]; then return 1; fi
    if [[ "$domain" =~ \.\. ]]; then return 1; fi
    if [[ "$domain" =~ ^- || "$domain" =~ -$ ]]; then return 1; fi
    if [[ ! "$domain" =~ ^[a-z0-9._-]+$ ]]; then return 1; fi
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        if [ -z "$label" ] || [ ${#label} -gt 63 ]; then return 1; fi
        if [[ "$label" =~ ^- || "$label" =~ -$ ]]; then return 1; fi
        if [[ ! "$label" =~ ^[a-z0-9_-]+$ ]]; then return 1; fi
    done
    echo "$domain"
    return 0
}

validate_subnet() {
    local subnet="$1"
    if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" mask="${BASH_REMATCH[4]}"
    if (( o1 > 255 || o2 > 255 || o3 > 255 || mask < 1 || mask > 32 )); then
        return 1
    fi
    return 0
}

validate_mtu() {
    local mtu="$1"
    if [[ ! "$mtu" =~ ^[0-9]+$ ]]; then return 1; fi
    if (( mtu < 1280 || mtu > 1500 )); then return 1; fi
    return 0
}

validate_port_simple() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
}

has_list_block() {
    local list_name="$1"
    grep -qxF "# --- ${list_name^^} ---" "$MASTER_FILE" 2>/dev/null
}

normalize_include_ips() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk 'NF && !seen[$0]++' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ===== Работа с IP-подсетями =====

detect_client_subnets() {
    local setup_file="/root/antizapret/setup"
    local client_prefix="10"

    if [ -f "$setup_file" ]; then
        local alt_client_ip=""
        alt_client_ip=$(grep -E '^ALTERNATIVE_CLIENT_IP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')

        local custom_client_ip=""
        custom_client_ip=$(grep -E '^CLIENT_IP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')

        if [ "$alt_client_ip" = "y" ]; then
            client_prefix="${custom_client_ip:-172}"
        else
            client_prefix="${custom_client_ip:-10}"
        fi
    fi

    AZ_CLIENT_NET="${client_prefix}.29.0.0/16"
    FULLVPN_CLIENT_NET="${client_prefix}.28.0.0/16"
    ALL_CLIENT_NET="${client_prefix}.28.0.0/15"
}

validate_cidr() {
    local cidr="$1"
    cidr=$(echo "$cidr" | tr -d '[:space:]')
    [ -z "$cidr" ] && return 1

    if [[ ! "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        return 1
    fi

    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" mask="${BASH_REMATCH[5]}"

    if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then return 1; fi
    if (( mask < 1 || mask > 32 )); then return 1; fi
    (( o1 == 127 || o1 == 0 || o1 >= 224 )) && return 1
    (( o1 == 169 && o2 == 254 )) && return 1

    echo "$cidr"
    return 0
}

extract_ip_ranges() {
    local file="${1:-$IP_RANGES_FILE}"
    [ -f "$file" ] || return 0
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$file" | while IFS= read -r line; do
        local trimmed
        trimmed=$(echo "$line" | tr -d '[:space:]')
        if validate_cidr "$trimmed" >/dev/null 2>&1; then
            echo "$trimmed"
        fi
    done | LC_ALL=C sort -u
}

get_applied_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    [ -f "$applied_file" ] || return 0
    LC_ALL=C sort -u "$applied_file"
}

save_applied_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    extract_ip_ranges | LC_ALL=C sort -u > "$applied_file"
}

get_current_kernel_ip_routes() {
    local source_net
    source_net=$(get_rule_source_net)

    if [ -z "$source_net" ]; then
        ip route show dev singbox-tun 2>/dev/null | awk '{print $1}' | while IFS= read -r cidr; do
            [ "$cidr" = "$SUBNET" ] && continue
            echo "$cidr"
        done | LC_ALL=C sort -u
    else
        ip route show table "$IP_ROUTE_TABLE" dev singbox-tun 2>/dev/null | awk '{print $1}' | LC_ALL=C sort -u
    fi
}

get_rule_source_net() {
    detect_client_subnets
    case "$IP_ROUTE_MODE" in
        antizapret) echo "$AZ_CLIENT_NET" ;;
        all_vpn)    echo "$ALL_CLIENT_NET" ;;
        all)        echo "" ;;
        *)          echo "$AZ_CLIENT_NET" ;;
    esac
}

ensure_ip_rule() {
    local source_net="$1"
    [ -z "$source_net" ] && return 0
    if ! ip rule show 2>/dev/null | grep -q "from ${source_net} lookup ${IP_ROUTE_TABLE}"; then
        ip rule add from "$source_net" lookup "$IP_ROUTE_TABLE" priority "$IP_ROUTE_PRIO" 2>/dev/null || true
    fi
}

remove_ip_rule() {
    local source_net="$1"
    [ -z "$source_net" ] && return 0
    while ip rule show 2>/dev/null | grep -q "from ${source_net} lookup ${IP_ROUTE_TABLE}"; do
        ip rule del from "$source_net" lookup "$IP_ROUTE_TABLE" priority "$IP_ROUTE_PRIO" 2>/dev/null || break
    done
}

remove_all_ip_rules() {
    detect_client_subnets
    remove_ip_rule "$AZ_CLIENT_NET"
    remove_ip_rule "$ALL_CLIENT_NET"
    for prefix in 10 172; do
        remove_ip_rule "${prefix}.29.0.0/16"
        remove_ip_rule "${prefix}.28.0.0/15"
    done
}

sync_ip_ranges() {
    if ! ip link show singbox-tun >/dev/null 2>&1; then
        echo -e "${RED}Интерфейс singbox-tun не найден. Sing-box запущен?${NC}"
        return 1
    fi

    detect_client_subnets

    local desired_tmp applied_tmp kernel_tmp add_tmp del_tmp
    desired_tmp=$(mktemp)
    applied_tmp=$(mktemp)
    kernel_tmp=$(mktemp)
    add_tmp=$(mktemp)
    del_tmp=$(mktemp)

    extract_ip_ranges | LC_ALL=C sort -u > "$desired_tmp"
    get_applied_ip_routes | LC_ALL=C sort -u > "$applied_tmp"
    get_current_kernel_ip_routes | LC_ALL=C sort -u > "$kernel_tmp"

    # Что нужно добавить в ядро: есть в файле, но нет в текущих kernel routes
    comm -23 "$desired_tmp" "$kernel_tmp" > "$add_tmp"

    # Что нужно удалить как WARPER-owned: было применено WARPER, но уже удалено из файла
    comm -23 "$applied_tmp" "$desired_tmp" > "$del_tmp"

    local added=0 removed=0 errors=0
    local source_net
    source_net=$(get_rule_source_net)

    local use_ipset=false
    if command -v ipset >/dev/null 2>&1 && ipset list antizapret-forward >/dev/null 2>&1; then
        use_ipset=true
    fi

    # Чистим stale routes из "другого режима"
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        if [ -z "$source_net" ]; then
            ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null || true
        else
            ip route del "$cidr" dev singbox-tun 2>/dev/null || true
            ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
        fi
    done < "$applied_tmp"

    # Удаляем лишние маршруты
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
        ((removed++))

        if [ "$use_ipset" = true ]; then
            ipset del antizapret-forward "$cidr" 2>/dev/null || true
        fi
    done < "$del_tmp"
    
    # Добавляем недостающие маршруты
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        if [ -z "$source_net" ]; then
            # Режим "all" — добавляем в main table
            ip route replace "$cidr" dev singbox-tun 2>/dev/null && ((added++)) || {
                echo -e "${YELLOW}Не удалось добавить маршрут: $cidr${NC}"
                ((errors++))
            }
            # Если есть table 13335 (VPN_WARP) — добавляем и туда
            if ip route show table 13335 2>/dev/null | grep -q "dev"; then
                ip route replace "$cidr" dev singbox-tun table 13335 2>/dev/null || true
            fi
        else
            ip route replace "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null && ((added++)) || {
                echo -e "${YELLOW}Не удалось добавить маршрут: $cidr${NC}"
                ((errors++))
            }
        fi
    done < "$add_tmp"

    # ip rule
    local total
    total=$(wc -l < "$desired_tmp" | tr -d ' ')

    if [ "$total" -gt 0 ] && [ -n "$source_net" ]; then
        remove_all_ip_rules
        ensure_ip_rule "$source_net"
    elif [ "$total" -eq 0 ]; then
        remove_all_ip_rules
    fi

    # ipset: добавляем ВСЕ желаемые CIDR, не только новые
    # это важно если ipset был перезагружен doall.sh / up.sh
    if [ "$use_ipset" = true ]; then
        while IFS= read -r cidr; do
            [ -z "$cidr" ] && continue
            ipset add antizapret-forward "$cidr" -exist 2>/dev/null || true
        done < "$desired_tmp"
    fi

    # Сохраняем applied-state
    save_applied_ip_routes

    # Если включён экспорт в AntiZapret — обновляем его
    sync_ip_ranges_to_antizapret || true

    rm -f "$desired_tmp" "$applied_tmp" "$kernel_tmp" "$add_tmp" "$del_tmp"

    if (( added == 0 && removed == 0 )); then
        echo -e "${GREEN}IP-маршруты синхронизированы (${total} подсетей, изменений нет).${NC}"
    else
        echo -e "${GREEN}IP-маршруты синхронизированы: +${added} -${removed} (всего ${total}).${NC}"
    fi

    if [ "$use_ipset" = true ]; then
        echo -e "${CYAN}antizapret-forward синхронизирован.${NC}"
    fi

    if [ -n "$source_net" ]; then
        echo -e "${CYAN}Режим: ${IP_ROUTE_MODE} (source: ${source_net})${NC}"
    else
        echo -e "${CYAN}Режим: Весь трафик сервера (Beta)${NC}"
    fi

    if (( errors > 0 )); then
        echo -e "${YELLOW}Ошибок: ${errors}${NC}"
        return 1
    fi
    return 0
}

remove_all_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    local removed=0
    
    local use_ipset=false
    if command -v ipset >/dev/null 2>&1 && ipset list antizapret-forward >/dev/null 2>&1; then
        use_ipset=true
    fi

    if [ -f "$applied_file" ]; then
        while IFS= read -r cidr; do
            [ -z "$cidr" ] && continue
            ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null && ((removed++))
            ip route del "$cidr" dev singbox-tun 2>/dev/null && ((removed++))
            ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
            if [ "$use_ipset" = true ]; then
                ipset del antizapret-forward "$cidr" 2>/dev/null || true
            fi
        done < "$applied_file"
        : > "$applied_file"
    fi

    remove_all_ip_rules
    echo -e "${GREEN}Удалено маршрутов: ${removed}${NC}"
}

count_ip_ranges() {
    extract_ip_ranges | wc -l | tr -d ' '
}

count_applied_routes() {
    get_applied_ip_routes | wc -l | tr -d ' '
}

get_current_kernel_ip_routes() {
    local source_net
    source_net=$(get_rule_source_net)

    if [ -z "$source_net" ]; then
        # Режим "server/main table"
        ip route show 2>/dev/null | awk '/dev singbox-tun/ {print $1}' | while IFS= read -r cidr; do
            [ "$cidr" = "$SUBNET" ] && continue
            echo "$cidr"
        done | LC_ALL=C sort -u
    else
        # Режим policy routing через отдельную таблицу
        ip route show table "$IP_ROUTE_TABLE" 2>/dev/null | awk '/dev singbox-tun/ {print $1}' | LC_ALL=C sort -u
    fi
}

get_current_tun_routes() {
    get_current_kernel_ip_routes
}

count_tun_routes() {
    get_current_kernel_ip_routes | wc -l | tr -d ' '
}

ip_ranges_in_sync() {
    local desired_tmp kernel_tmp
    desired_tmp=$(mktemp)
    kernel_tmp=$(mktemp)

    extract_ip_ranges > "$desired_tmp"
    get_current_kernel_ip_routes > "$kernel_tmp"

    cmp -s "$desired_tmp" "$kernel_tmp"
    local result=$?

    rm -f "$desired_tmp" "$kernel_tmp"
    return $result
}

add_ip_range() {
    local raw="$1"
    local cidr
    cidr=$(validate_cidr "$raw") || {
        echo -e "${RED}Некорректный формат CIDR: $raw${NC}"
        echo -e "${YELLOW}Ожидается: A.B.C.D/M (например 91.108.4.0/22 или 5.255.255.242/32)${NC}"
        return 1
    }

    if [ "$cidr" = "$SUBNET" ]; then
        echo -e "${RED}Нельзя добавить fake-подсеть WARPER ($SUBNET)!${NC}"
        return 1
    fi

    if extract_ip_ranges | grep -qxF "$cidr"; then
        echo -e "${YELLOW}Подсеть $cidr уже есть в списке.${NC}"
        return 0
    fi

    echo "$cidr" >> "$IP_RANGES_FILE"
    echo -e "${GREEN}Подсеть $cidr добавлена.${NC}"
    return 0
}

remove_ip_range() {
    local raw="$1"
    local cidr
    cidr=$(validate_cidr "$raw") || {
        echo -e "${RED}Некорректный формат CIDR: $raw${NC}"
        return 1
    }

    if ! extract_ip_ranges | grep -qxF "$cidr"; then
        echo -e "${YELLOW}Подсеть $cidr не найдена в списке.${NC}"
        return 0
    fi

    local escaped
    escaped=$(printf '%s\n' "$cidr" | sed 's/[[\.*^$()+?{|\\\/]/\\&/g')
    sed -i "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$IP_RANGES_FILE"
    echo -e "${GREEN}Подсеть $cidr удалена из списка.${NC}"
    return 0
}

resync_ip_routes_if_needed() {
    if [ "$(count_ip_ranges)" -gt 0 ]; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi
}

render_antizapret_include_ips_file() {
    local output_file="$1"
    {
        cat << 'EOF'
# Добавлено WARPER
# Этот файл автоматически создаётся WARPER.
# Не редактируйте его вручную, изменения будут перезаписаны.
#
# CIDR из этого файла попадают в AntiZapret route-ips через parse.sh
# потому что AntiZapret читает config/*include-ips.txt
EOF
        extract_ip_ranges
    } > "$output_file"
}

sync_ip_ranges_to_antizapret() {
    local changed=0
    local tmp
    tmp=$(mktemp)

    if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
        render_antizapret_include_ips_file "$tmp"
        if [ ! -f "$AZ_WARPER_INCLUDE_IPS" ] || ! cmp -s "$tmp" "$AZ_WARPER_INCLUDE_IPS"; then
            mv "$tmp" "$AZ_WARPER_INCLUDE_IPS"
            changed=1
        else
            rm -f "$tmp"
        fi
    else
        rm -f "$tmp"
        if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
            rm -f "$AZ_WARPER_INCLUDE_IPS"
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        echo -e "${CYAN}Обновление маршрутов AntiZapret (doall.sh ip)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        export SYSTEMD_PAGER=""
        if bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1; then
            echo -e "${GREEN}AntiZapret маршруты обновлены.${NC}"
            echo -e "${YELLOW}Для части клиентов может потребоваться переподключение.${NC}"
        else
            echo -e "${RED}Не удалось обновить маршруты AntiZapret через doall.sh ip${NC}"
            return 1
        fi
    fi

    return 0
}

# ===== Работа с доменами =====

extract_user_domains() {
    local input="$1"
    awk '
    BEGIN { in_block=0 }
    /^# --- [A-Z0-9_]+ ---$/ { in_block=1; next }
    /^# --- END [A-Z0-9_]+ ---$/ { in_block=0; next }
    {
        if (in_block) next
        if ($0 ~ /^\s*$/) next
        if ($0 ~ /^\s*#/) next
        print
    }
    ' "$input" | while IFS= read -r line; do
        validate_domain "$line" 2>/dev/null || true
    done | sort -u
}

extract_block() {
    local input="$1"
    local list_name="$2"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"
    awk -v start="$marker" -v end="$end_marker" '
    $0 == start { in_block=1 }
    in_block { print }
    $0 == end { in_block=0 }
    ' "$input"
}

rebuild_master_file() {
    local source_file="${1:-$MASTER_FILE}"
    local output_file="${2:-$MASTER_FILE}"
    local tmp user_tmp gemini_tmp chatgpt_tmp
    tmp=$(mktemp)
    user_tmp=$(mktemp)
    gemini_tmp=$(mktemp)
    chatgpt_tmp=$(mktemp)

    extract_user_domains "$source_file" > "$user_tmp"
    extract_block "$source_file" "gemini" > "$gemini_tmp"
    extract_block "$source_file" "chatgpt" > "$chatgpt_tmp"

    {
        cat << 'EOF'
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF
        if [ -s "$user_tmp" ]; then cat "$user_tmp"; fi
        if [ -s "$gemini_tmp" ]; then echo ""; cat "$gemini_tmp"; fi
        if [ -s "$chatgpt_tmp" ]; then echo ""; cat "$chatgpt_tmp"; fi
    } > "$tmp"

    mv "$tmp" "$output_file"
    rm -f "$user_tmp" "$gemini_tmp" "$chatgpt_tmp"
}

canonical_master_hash() {
    local tmp
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"
    sha256sum "$tmp" | awk '{print $1}'
    rm -f "$tmp"
}

insert_user_domain() {
    local domain="$1"
    local tmp
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"
    if extract_user_domains "$tmp" | grep -qxF "$domain"; then
        mv "$tmp" "$MASTER_FILE"
        return 0
    fi
    awk -v domain="$domain" '
    BEGIN { inserted=0 }
    {
        print
        if ($0 == "# Пользовательские домены:" && inserted == 0) {
            print domain
            inserted=1
        }
    }
    ' "$tmp" > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
    rebuild_master_file "$tmp" "$MASTER_FILE"
    rm -f "$tmp"
}

# ===== Sing-box параметры =====

get_log_level() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.log.level // "info"' "$SINGBOX_CONF" 2>/dev/null || echo "info"
    else
        echo "info"
    fi
}

set_log_level() {
    local new_level="$1"
    case "$new_level" in
        debug|info|warn|error) ;;
        *) echo -e "${RED}Некорректный log level: $new_level${NC}"; return 1 ;;
    esac
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"; return 1
    fi
    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"; return 1
    fi
    local backup tmp old_level
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)
    cp -a "$SINGBOX_CONF" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    old_level=$(get_log_level)
    if [ "$old_level" = "$new_level" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}log level уже установлен: $new_level${NC}"
        return 0
    fi
    if ! jq --arg lvl "$new_level" '.log.level = $lvl' "$SINGBOX_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"; return 1
    fi
    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"
    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"; rm -f "$backup"
        echo -e "${RED}Откат выполнен.${NC}"; return 1
    fi
    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"; return 1
    fi
    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    resync_ip_routes_if_needed    
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true
    rm -f "$backup"
    echo -e "${GREEN}log level изменён: ${old_level} → ${new_level}${NC}"
    return 0
}

get_mtu() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.endpoints[0].mtu // 1420' "$SINGBOX_CONF" 2>/dev/null || echo "1420"
    else
        echo "1420"
    fi
}

set_mtu() {
    local new_mtu="$1"
    if ! validate_mtu "$new_mtu"; then
        echo -e "${RED}Некорректный MTU: $new_mtu (допустимо 1280-1500)${NC}"; return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"; return 1
    fi
    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"; return 1
    fi
    local backup tmp old_mtu
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)
    cp -a "$SINGBOX_CONF" "$backup" || { rm -f "$backup" "$tmp"; return 1; }
    old_mtu=$(get_mtu)
    if [ "$old_mtu" = "$new_mtu" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}MTU уже установлен: $new_mtu${NC}"
        return 0
    fi
    if ! jq --argjson mtu "$new_mtu" '.endpoints[0].mtu = $mtu' "$SINGBOX_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"; return 1
    fi
    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"
    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"; rm -f "$backup"
        echo -e "${RED}Откат выполнен.${NC}"; return 1
    fi
    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"; return 1
    fi
    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    resync_ip_routes_if_needed
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true
    rm -f "$backup"
    echo -e "${GREEN}MTU изменён: ${old_mtu} → ${new_mtu}${NC}"
    return 0
}

# ===== Версионирование =====

version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        local fetched
        fetched=$(curl -4 -sf --max-time 2 "$REPO_URL/version" | tr -d '\r\n')
        if [[ "$fetched" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            REMOTE_VER_CACHE="$fetched"
        else
            REMOTE_VER_CACHE="$LOCAL_VER"
        fi
        REMOTE_VER_TIME=$now
    fi
    echo "${REMOTE_VER_CACHE:-$LOCAL_VER}"
}

download_file_safe() {
    local url="$1" dest="$2" desc="$3"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" "${url}?t=$(date +%s)"; then
        echo -e "${RED}Ошибка загрузки: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

filter_valid_domains_file() {
    local input="$1" output="$2"
    : > "$output"
    while IFS= read -r line; do
        local trimmed clean
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" =~ ^# ]] && continue
        clean=$(validate_domain "$trimmed" 2>/dev/null || true)
        [ -n "$clean" ] && echo "$clean" >> "$output"
    done < "$input"
    sort -u -o "$output" "$output"
}

# ===== Синхронизация доменов =====

sync_domains() {
    local tmp
    tmp=$(mktemp /tmp/warper_sync.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

domains_in_sync() {
    local tmp_master tmp_active
    tmp_master=$(mktemp /tmp/warper_master_compare.XXXXXX)
    tmp_active=$(mktemp /tmp/warper_active_compare.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp_master"
    if [ -f "$ACTIVE_FILE" ]; then
        filter_valid_domains_file "$ACTIVE_FILE" "$tmp_active"
    else
        : > "$tmp_active"
    fi
    local result=1
    if cmp -s "$tmp_master" "$tmp_active"; then result=0; fi
    rm -f "$tmp_master" "$tmp_active"
    return "$result"
}

# ===== Сетевые проверки =====

subnet_conflicts() {
    local subnet="$1"
    local line iface route_net
    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        route_net=$(echo "$line" | awk '{print $4}')
        [ "$route_net" = "$subnet" ] || continue
        [ "$iface" = "singbox-tun" ] && continue
        return 0
    done < <(ip -o -4 addr show 2>/dev/null)
    while IFS= read -r line; do
        route_net=$(echo "$line" | awk '{print $1}')
        [ "$route_net" = "$subnet" ] || continue
        echo "$line" | grep -q "dev singbox-tun" && continue
        return 0
    done < <(ip route 2>/dev/null)
    if command -v docker >/dev/null 2>&1; then
        local ids
        ids=$(docker network ls -q 2>/dev/null || true)
        if [ -n "$ids" ]; then
            local -a id_array
            mapfile -t id_array <<< "$ids"
            if [ ${#id_array[@]} -gt 0 ]; then
                docker network inspect "${id_array[@]}" 2>/dev/null | grep -qF "\"Subnet\": \"$subnet\"" && return 0
            fi
        fi
    fi
    return 1
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then return 1; fi
    if ! sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then return 1; fi
    return 0
}

ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

restart_singbox_full() {
    systemctl stop sing-box >/dev/null 2>&1 || true
    sleep 1
    systemctl start sing-box
    if ! ensure_singbox_running; then
        return 1
    fi
    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 >/dev/null 2>&1 || true
    resync_ip_routes_if_needed
    return 0
}

ensure_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null || \
        iptables -I "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

# ===== WARP-ключи =====

get_warp_credentials() {
    local address="" private_key=""

    if [ -f "$WARP_SYSTEM_CONF" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WARP_SYSTEM_CONF" 2>/dev/null; then
        private_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        address=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$private_key" ]; then
            [ -z "$address" ] && address="172.16.0.2/32"
            [[ ! "$address" =~ / ]] && address="${address}/32"
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        address=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        private_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        if [ -n "$address" ] && [ -n "$private_key" ] && [ "$address" != "__WARP_ADDRESS__" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    if [ -f "$SINGBOX_CONF" ] && grep -q '"tag": "warp"' "$SINGBOX_CONF" 2>/dev/null; then
        address=$(grep -o '"address": \[ "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
        private_key=$(grep -o '"private_key": "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
        if [ -n "$address" ] && [ -n "$private_key" ] && [ "$address" != "__WARP_ADDRESS__" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    local wgcf_profile="$WGCF_DIR/wgcf-profile.conf"
    if [ -f "$wgcf_profile" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$wgcf_profile" 2>/dev/null; then
        address=$(grep -m 1 '^Address = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$address" ] && [ -n "$private_key" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    return 1
}

get_current_warp_key_source() {
    local cur_pk=""
    local src="local"

    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    [ -z "$cur_pk" ] && { echo "$src"; return 0; }

    # Приоритет 1: системный warp.conf
    if [ -f "$WARP_SYSTEM_CONF" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WARP_SYSTEM_CONF" 2>/dev/null; then
        local sys_pk=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ] && [ "$sys_pk" = "$cur_pk" ]; then
            echo "$WARP_SYSTEM_CONF"
            return 0
        fi
    fi

    # Приоритет 2: локальный wgcf WARPER
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        local wgcf_pk=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
            echo "$WGCF_DIR/wgcf-profile.conf"
            return 0
        fi
    fi

    # Приоритет 3: профиль в /root
    if [ -f "/root/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        local root_pk=""
        root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$root_pk" ] && [ "$root_pk" = "$cur_pk" ]; then
            echo "/root/wgcf-profile.conf"
            return 0
        fi
    fi

    echo "$src"
    return 0
}

check_and_sync_warp_keys() {
    if needs_down_sh; then
        if is_interactive; then
            show_down_sh_warning
            read -r -p "Нажмите Enter для продолжения..."
        else
            echo "WARNING: Active WARP rules detected. Run: /root/antizapret/down.sh && /root/antizapret/up.sh" >&2
        fi
        return 1
    fi

    # В slave/wg режиме синхронизация WARP-ключей не нужна
    load_slave_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] || [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        return 0
    fi

    if [ ! -f "$WARP_SYSTEM_CONF" ]; then
        return 0
    fi

    local sys_key="" sys_addr="" current_key="" current_addr=""
    sys_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    sys_addr=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')

    if [ -z "$sys_key" ] || [ -z "$sys_addr" ]; then
        return 0
    fi

    [[ ! "$sys_addr" =~ / ]] && sys_addr="${sys_addr}/32"

    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        current_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        current_addr=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    if [ "$sys_key" != "$current_key" ] || [ "$sys_addr" != "$current_addr" ]; then
        if is_interactive; then
            echo -e "${YELLOW}Обнаружены другие WARP-ключи в $WARP_SYSTEM_CONF.${NC}"
            echo -e "${CYAN}Текущие: ${current_addr:-n/a}${NC}"
            echo -e "${CYAN}Новые:   ${sys_addr}${NC}"
            read -r -p "Переключиться на ключи из $WARP_SYSTEM_CONF? (y/N): " sync_choice
            if [[ ! "$sync_choice" =~ ^[Yy]$ ]]; then
                return 0
            fi
        fi
        echo -e "${YELLOW}Синхронизация WARP-ключей...${NC}"
        if [ -f "$SINGBOX_TEMPLATE" ]; then
            # Временно форсируем WARP-режим для пересборки
            local saved_mode="$CURRENT_OUTBOUND_MODE"
            CURRENT_OUTBOUND_MODE="warp"
            if rebuild_config "$SINGBOX_TEMPLATE"; then
                if systemctl is-active --quiet sing-box; then
                    systemctl restart sing-box
                    ensure_iptables_rule FORWARD -o singbox-tun
                    ensure_iptables_rule FORWARD -i singbox-tun
                fi
                systemctl restart kresd@1 >/dev/null 2>&1 || true
                echo -e "${GREEN}Ключи WARP синхронизированы.${NC}"
            fi
            CURRENT_OUTBOUND_MODE="$saved_mode"
        fi
    fi
}

# ===== Конфигурация sing-box =====

rebuild_config() {
    local template="$1"

    load_slave_config
    load_wg_config

    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        rebuild_config_slave
        return $?
    fi

    if [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        rebuild_config_wg
        return $?
    fi

    # WARP mode
    local creds=""
    creds=$(get_warp_credentials) || {
        echo -e "${RED}Ошибка: Не удалось извлечь WARP-ключи!${NC}"
        return 1
    }
    local warp_address="" warp_private_key=""
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')
    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$template" > "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"
    if ! validate_singbox_config; then return 1; fi
    if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
        echo -e "${GREEN}Конфигурация sing-box (WARP) успешно обновлена.${NC}"
    else
        echo -e "${GREEN}Конфигурация sing-box успешно обновлена.${NC}"
    fi
    return 0
}

rebuild_config_slave() {
    if [ -z "$SLAVE_SERVER" ] || [ -z "$SLAVE_PASSWORD" ]; then
        echo -e "${RED}Не настроены параметры slave-сервера!${NC}"
        return 1
    fi

    if [ ! -f "$SLAVE_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config-slave-master.json.template" "$SLAVE_TEMPLATE" "шаблон slave-master" || return 1
    fi

    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__SLAVE_SERVER__|$SLAVE_SERVER|g" \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT|g" \
        -e "s|__SLAVE_PASSWORD__|$SLAVE_PASSWORD|g" \
        "$SLAVE_TEMPLATE" > "$SINGBOX_CONF"

    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации конфига slave!${NC}"
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box (slave) успешно обновлена.${NC}"
    return 0
}

# ===== Kresd =====

backup_kresd() {
    if [ -f "$KRESD_CONF" ] && [ ! -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_CONF" "$KRESD_BACKUP" || return 1
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi
    return 0
}

restore_kresd_backup() {
    if [ -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_BACKUP" "$KRESD_CONF" || return 1
        chmod 644 "$KRESD_CONF" 2>/dev/null || true
        systemctl restart kresd@1 kresd@2 || return 1
        return 0
    fi
    return 1
}

file_mode_is_600() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$(stat -c %a "$file" 2>/dev/null || true)" = "600" ]
}

patch_kresd() {
    if check_antizapret_warp; then
        echo -e "${RED}ANTIZAPRET_WARP=y — патч kresd.conf не может быть применён.${NC}" >&2
        return 1
    fi

    if needs_down_sh; then
        echo -e "${RED}Активны правила от up.sh — сначала выполните /root/antizapret/down.sh${NC}" >&2
        return 1
    fi

    sync_domains
    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}" >&2
        return 1
    fi
    backup_kresd || {
        echo -e "${RED}Не удалось создать backup $KRESD_CONF.${NC}" >&2
        return 1
    }
    local clean_tmp tmpfile
    clean_tmp=$(mktemp /tmp/kresd.clean.XXXXXX)
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)
    sed '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF" > "$clean_tmp"
    awk '
    BEGIN { in_inst1=0; inserted1=0 }
    function print_warp_block() {
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_domains = {}"
        print "\tlocal wfile = io.open(\"/etc/knot-resolver/warper-domains.txt\", \"r\")"
        print "\tif wfile then"
        print "\t\tfor line in wfile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" and clean:sub(1,1) ~= \"#\" then table.insert(warp_domains, clean .. \".\") end"
        print "\t\tend"
        print "\t\twfile:close()"
        print "\t\tif #warp_domains > 0 then"
        print "\t\t\tpolicy.add(policy.suffix(policy.STUB(\"127.0.0.1@40000\"), policy.todnames(warp_domains)))"
        print "\t\tend"
        print "\tend"
        print "\t-- [WARP-MOD-END]"
        print ""
    }
    /^if string.match\(systemd_instance, .?\^1.?\) then$/ { in_inst1=1; print; next }
    /^elseif string.match\(systemd_instance, .?\^2.?\) then$/ { in_inst1=0; print; next }
    in_inst1 && /Resolve blocked domains using Proxy Resolver/ && inserted1==0 {
        print_warp_block()
        inserted1=1
        print
        next
    }
    { print }
    END { if (inserted1 == 0) exit 42 }
    ' "$clean_tmp" > "$tmpfile"
    local awk_rc=$?
    rm -f "$clean_tmp"
    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 42 ]; then
            echo -e "${RED}Не удалось найти точку вставки в kresd@1.${NC}" >&2
        else
            echo -e "${RED}Ошибка при патчинге $KRESD_CONF.${NC}" >&2
        fi
        return 1
    fi
    if ! mv "$tmpfile" "$KRESD_CONF"; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось записать $KRESD_CONF.${NC}" >&2
        return 1
    fi
    chmod 644 "$KRESD_CONF"
    if ! systemctl restart kresd@1 kresd@2; then
        echo -e "${RED}Не удалось перезапустить kresd.${NC}" >&2
        return 1
    fi
    return 0
}

unpatch_kresd() {
    if [ -f "$KRESD_BACKUP" ]; then
        restore_kresd_backup && return 0
    fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        sed -i '/^$/N;/^\n$/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2 || return 1
    fi
    return 0
}

# ===== Статус и диагностика =====

status_cmd() {
    load_config
    load_slave_config
    local sb_run="" sb_en="" kr_stat="" dom_stat="" az_stat="" ap_stat="" subnet_conflict="" log_level="" mtu="" az_warp_stat="" warp_rules_stat=""
    if systemctl is-active --quiet sing-box; then sb_run="running"; else sb_run="stopped"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then sb_en="enabled"; else sb_en="disabled"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then kr_stat="patched"; else kr_stat="not patched"; fi
    if domains_in_sync; then dom_stat="synced"; else dom_stat="not synced"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then az_stat="present"; else az_stat="missing"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then ap_stat="enabled"; else ap_stat="disabled"; fi
    if subnet_conflicts "$SUBNET"; then subnet_conflict="yes"; else subnet_conflict="no"; fi
    if check_antizapret_warp; then az_warp_stat="ENABLED (conflict!)"; else az_warp_stat="disabled"; fi
    if needs_down_sh; then warp_rules_stat="active (run down.sh + up.sh!)"; else warp_rules_stat="ok"; fi
    log_level=$(get_log_level)
    mtu=$(get_mtu)
    echo "Version: $LOCAL_VER"
    echo "ANTIZAPRET_WARP: $az_warp_stat"
    echo "VPN_WARP: $(check_vpn_warp && echo "enabled" || echo "disabled")"
    echo "WARP rules from up.sh: $warp_rules_stat"
    echo "outbound mode: $CURRENT_OUTBOUND_MODE"
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo "slave server: $SLAVE_SERVER:$SLAVE_PORT"
        echo "slave key: $SLAVE_PASSWORD"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        load_wg_config
        echo "wg endpoint: $WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT"
        echo "wg address: $WG_ADDRESS"
        if [ "$WG_CONF_FILE" = "manual" ] || [ -z "$WG_CONF_FILE" ]; then
            echo "wg source: manual"
        else
            echo "wg source: $WG_CONF_FILE"
        fi
    fi
    echo "sing-box: $sb_run"
    echo "sing-box autostart: $sb_en"
    echo "sing-box log level: $log_level"
    echo "sing-box MTU: $mtu"
    echo "kresd patch: $kr_stat"
    echo "domains: $dom_stat"
    echo "subnet in AntiZapret: $az_stat"
    echo "autopatch: $ap_stat"
    echo "subnet conflict: $subnet_conflict"
    local ip_count route_count ip_sync_stat
    ip_count=$(count_ip_ranges)
    route_count=$(count_tun_routes)
    if ip_ranges_in_sync; 
        then ip_sync_stat="synced"; 
        else ip_sync_stat="not synced"; 
    fi
    echo "ip ranges in file: $ip_count"
    echo "ip routes active: $route_count"
    echo "ip routes sync: $ip_sync_stat"
    echo "ip route mode: $IP_ROUTE_MODE"    
    echo "warp keys source: $([ -f "$WARP_SYSTEM_CONF" ] && echo "$WARP_SYSTEM_CONF" || echo "local")"
    echo "ip export to AntiZapret: $IP_EXPORT_TO_ANTIZAPRET"    
}

doctor() {
    load_config
    load_slave_config
    echo -e "${CYAN}==========================================${NC}"
    echo -e "        🩺 ${YELLOW}WARPER DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"
    local failed=0
    check_item() {
        local label="$1" cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }
    if check_antizapret_warp; then
        echo -e " ${RED}✘${NC} ANTIZAPRET_WARP=n (сейчас: ANTIZAPRET_WARP=y — WARPER не работает!)"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} ANTIZAPRET_WARP=n"
    fi
    if needs_down_sh; then
        echo -e " ${RED}✘${NC} Правила от up.sh неактивны (сейчас: активны — выполните down.sh!)"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Правила от up.sh неактивны"
    fi

    # Режим маршрутизации
    load_wg_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}!${NC} Режим: Slave ($SLAVE_SERVER:$SLAVE_PORT)"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        echo -e " ${CYAN}!${NC} Режим: WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)"
    else
        echo -e " ${GREEN}✔${NC} Режим: WARP (локальный)"
    fi

    check_item "AntiZapret установлен" "[ -x /root/antizapret/doall.sh ]"
    check_item "Файл конфигурации warper существует" "[ -f '$CONF_FILE' ]"
    check_item "Файл списка доменов существует" "[ -f '$MASTER_FILE' ]"
    check_item "Активный список доменов существует" "[ -f '$ACTIVE_FILE' ]"
    check_item "Конфиг sing-box существует" "[ -f '$SINGBOX_CONF' ]"
    check_item "Конфиг sing-box валиден" "validate_singbox_config"
    check_item "Служба sing-box активна" "systemctl is-active --quiet sing-box"
    check_item "Автозагрузка sing-box включена" "systemctl is-enabled --quiet sing-box"
    check_item "Службы kresd активны" "systemctl is-active --quiet kresd@1 && systemctl is-active --quiet kresd@2"
    check_item "Автопатч warper включен" "systemctl is-enabled --quiet warper-autopatch"
    check_item "kresd.conf пропатчен" "grep -q 'WARP-MOD-START' '$KRESD_CONF'"
    check_item "В kresd.conf ровно 1 WARP-блок" "[ \"\$(grep -c 'WARP-MOD-START' '$KRESD_CONF' 2>/dev/null)\" -eq 1 ]"
    check_item "Права config.json ограничены" "file_mode_is_600 '$SINGBOX_CONF'"
    check_item "Права warper.conf ограничены" "file_mode_is_600 '$CONF_FILE'"
    check_item "Резервная копия kresd.conf существует" "[ -f '$KRESD_BACKUP' ]"
    check_item "Домены синхронизированы" "domains_in_sync"
    check_item "Подсеть $SUBNET в include-ips.txt" "grep -qF '$SUBNET' '$AZ_INC'"
    check_item "Интерфейс singbox-tun существует" "ip link show singbox-tun"
    check_item "iptables FORWARD -o singbox-tun" "iptables -C FORWARD -o singbox-tun -j ACCEPT"
    check_item "iptables FORWARD -i singbox-tun" "iptables -C FORWARD -i singbox-tun -j ACCEPT"
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        check_item "Права wgcf-profile.conf ограничены" "file_mode_is_600 '$WGCF_DIR/wgcf-profile.conf'"
    fi
    if [ -f "$WARP_SYSTEM_CONF" ]; then
        echo -e " ${GREEN}✔${NC} Используются ключи из $WARP_SYSTEM_CONF"
    elif [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}!${NC} Режим Slave — WARP-ключи не используются"
    else
        echo -e " ${YELLOW}!${NC} Системный файл $WARP_SYSTEM_CONF не найден, используются локальные ключи"
    fi
    # Проверка IP-маршрутов
    local ip_cnt route_cnt
    ip_cnt=$(count_ip_ranges)
    route_cnt=$(count_tun_routes)
    if [ "$ip_cnt" -gt 0 ] || [ "$route_cnt" -gt 0 ]; then
        echo -e " ${CYAN}!${NC} IP-подсетей в файле: $ip_cnt, маршрутов активно: $route_cnt"
        if ip_ranges_in_sync; then
            echo -e " ${GREEN}✔${NC} IP-маршруты синхронизированы"
        else
            echo -e " ${YELLOW}!${NC} IP-маршруты не синхронизированы (выполните warper ipsync)"
            failed=1
        fi
    fi
    if subnet_conflicts "$SUBNET"; then
        echo -e " ${YELLOW}!${NC} Возможный конфликт fake-подсети $SUBNET"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Конфликт fake-подсети не обнаружен"
    fi
    if [ "$ip_cnt" -gt 0 ]; then
        detect_client_subnets
        local rule_net
        rule_net=$(get_rule_source_net)
        if [ -n "$rule_net" ]; then
            if ip rule show 2>/dev/null | grep -q "from ${rule_net} lookup ${IP_ROUTE_TABLE}"; then
                echo -e " ${GREEN}✔${NC} ip rule для ${rule_net} → table ${IP_ROUTE_TABLE} активно"
            else
                echo -e " ${RED}✘${NC} ip rule для ${rule_net} → table ${IP_ROUTE_TABLE} отсутствует"
                failed=1
            fi
        else
            echo -e " ${CYAN}!${NC} Режим IP-маршрутов: all (без ip rule)"
        fi
    fi
    if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
        if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
            echo -e " ${GREEN}✔${NC} Экспорт WARPER CIDR в AntiZapret включён"
        else
            echo -e " ${RED}✘${NC} Экспорт в AntiZapret включён, но файл $AZ_WARPER_INCLUDE_IPS отсутствует"
            failed=1
        fi
    else
        echo -e " ${CYAN}!${NC} Экспорт WARPER CIDR в AntiZapret выключен"
    fi
    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Диагностика завершена: проблем не обнаружено.${NC}"
        return 0
    else
        echo -e "${YELLOW}Диагностика завершена: обнаружены проблемы.${NC}"
        return 1
    fi
}

# ===== Управление =====

prompt_apply() {
    if check_antizapret_warp; then
        echo -e "\n${RED}⚠️  ANTIZAPRET_WARP=y — изменения НЕ будут применены к DNS.${NC}"
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    if needs_down_sh; then
        show_down_sh_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    if ! is_warper_active; then
        echo -e "\n${YELLOW}WARPER выключен. Домены сохранены, но патч DNS не применяется.${NC}"
        echo -e "${CYAN}Синхронизация списка доменов...${NC}"
        sync_domains
        echo -e "${GREEN}Домены синхронизированы.${NC}"
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -r -e -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        if patch_kresd > /dev/null 2>&1; then
            echo -e "${GREEN}Изменения успешно применены!${NC}"
        else
            echo -e "${RED}Не удалось применить изменения к DNS.${NC}"
        fi
    else
        echo -e "${YELLOW}Домены сохранены в файл, но НЕ применены к DNS.${NC}"
        sync_domains
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

prompt_confirm() {
    read -r -e -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0; else return 1; fi
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Чтение логов sing-box...${NC}"
    echo -e "${GREEN}Для выхода нажмите Ctrl+C${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u sing-box -n 20 -f
    trap - SIGINT
}

toggle_warper() {
    if check_antizapret_warp; then
        show_antizapret_warp_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    if needs_down_sh; then
        show_down_sh_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    check_and_sync_warp_keys || return
    local action="ВКЛЮЧИТЬ"
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        action="ВЫКЛЮЧИТЬ"
    fi
    if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
        echo -e "\n${YELLOW}Вы уверены что хотите выключить warper? (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}Вы уверены что хотите включить warper? (Y/n)${NC}"
    fi
    read -r -e -p "Выбор: " conf
    if [[ -z "$conf" || "$conf" == "Y" || "$conf" == "y" ]]; then
        if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
            echo -e "${YELLOW}Отключение WARPER...${NC}"
            systemctl stop sing-box
            systemctl disable sing-box 2>/dev/null
            systemctl disable warper-autopatch 2>/dev/null
            remove_iptables_rule FORWARD -o singbox-tun
            remove_iptables_rule FORWARD -i singbox-tun
            unpatch_kresd || { echo -e "${RED}Ошибка при удалении патча DNS.${NC}"; sleep 2; return; }
            # Удаляем IP-маршруты (tun будет уничтожен, но на всякий случай)
            if [ "$(count_tun_routes)" -gt 0 ]; then
                remove_all_ip_routes || true
            fi
            echo -e "${GREEN}WARPER успешно отключен!${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            if ! validate_singbox_config; then sleep 2; return; fi
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            if ! ensure_singbox_running; then sleep 2; return; fi
            systemctl enable warper-autopatch 2>/dev/null
            ensure_iptables_rule FORWARD -o singbox-tun
            ensure_iptables_rule FORWARD -i singbox-tun
            if ! patch_kresd >/dev/null 2>&1; then
                echo -e "${RED}Не удалось применить патч DNS.${NC}"
                sleep 2; return
            fi
            # Синхронизируем IP-маршруты
            if [ "$(count_ip_ranges)" -gt 0 ]; then
                echo -e "${CYAN}Синхронизация IP-маршрутов...${NC}"
                sync_ip_ranges || true
            fi
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi
}

# ===== Списки доменов =====

enable_disable_list() {
    local action="$1" list_name="$2"
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"
    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден!${NC}"
        return 1
    fi
    local valid_tmp tmp
    valid_tmp=$(mktemp /tmp/warper_valid_list.XXXXXX)
    tmp=$(mktemp /tmp/warper_master.XXXXXX)
    filter_valid_domains_file "$list_file" "$valid_tmp"
    rebuild_master_file "$MASTER_FILE" "$tmp"
    if [ "$action" = "enable" ]; then
        if extract_block "$tmp" "$list_name" | grep -qxF "$marker"; then
            rm -f "$valid_tmp" "$tmp"
            echo -e "${YELLOW}Список ${list_name^^} уже включен.${NC}"
            return 0
        fi
        cp "$tmp" "${tmp}.new"
        { echo ""; echo "$marker"; cat "$valid_tmp"; echo "$end_marker"; } >> "${tmp}.new"
        rebuild_master_file "${tmp}.new" "$MASTER_FILE"
        rm -f "$valid_tmp" "$tmp" "${tmp}.new"
        echo -e "${GREEN}Список ${list_name^^} включен.${NC}"
        return 0
    fi
    if [ "$action" = "disable" ]; then
        if extract_block "$tmp" "$list_name" | grep -qxF "$marker"; then
            awk -v start="$marker" -v end="$end_marker" '
            $0 == start { skip=1; next }
            $0 == end { skip=0; next }
            !skip { print }
            ' "$tmp" > "${tmp}.new"
            rebuild_master_file "${tmp}.new" "$MASTER_FILE"
            rm -f "$valid_tmp" "$tmp" "${tmp}.new"
            echo -e "${YELLOW}Список ${list_name^^} выключен.${NC}"
            return 0
        fi
        rm -f "$valid_tmp" "$tmp"
        echo -e "${YELLOW}Список ${list_name^^} уже выключен.${NC}"
        return 0
    fi
    rm -f "$valid_tmp" "$tmp"
    return 1
}

toggle_list() {
    local list_name=$1
    if has_list_block "$list_name"; then
        enable_disable_list disable "$list_name"
    else
        enable_disable_list enable "$list_name"
    fi
    prompt_apply
}

update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        if has_list_block "$list_name"; then
            enable_disable_list disable "$list_name" >/dev/null 2>&1 || true
            enable_disable_list enable "$list_name" >/dev/null 2>&1 || true
        fi
    done
}

# ===== Переключение режима маршрутизации =====

switch_outbound_mode() {
    load_slave_config

    echo -e "\n${CYAN}================================================${NC}"
    echo -e "       ${YELLOW}Режим маршрутизации трафика${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""

    if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
        echo -e " Текущий режим: ${GREEN}WARP (локальный)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        load_wg_config
        echo -e " Текущий режим: ${CYAN}WG (${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT})${NC}"
    else
        echo -e " Текущий режим: ${CYAN}Slave (донор: ${SLAVE_SERVER}:${SLAVE_PORT})${NC}"
    fi

    echo -e ""
    echo -e " ${GREEN}1.${NC} WARP  — трафик идёт через Cloudflare WARP"
    echo -e " ${CYAN}2.${NC} Slave — трафик идёт через донор-сервер (Shadowsocks)"
    echo -e " ${CYAN}3.${NC} WG    — трафик идёт через WireGuard-соединение"
    echo -e " ${CYAN}0.${NC} Назад"
    echo -e "${CYAN}================================================${NC}"

    read -r -p "Выбор [0-3]: " mode_choice

    case "${mode_choice:-}" in
        1)
            if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
                echo -e "${YELLOW}Уже в режиме WARP.${NC}"
                sleep 1
                return
            fi

            echo -e "${YELLOW}Переключение на WARP...${NC}"

            if [ ! -f "$SINGBOX_TEMPLATE" ]; then
                download_file_safe "$REPO_URL/templates/config.json.template" "$SINGBOX_TEMPLATE" "config.json.template" || {
                    echo -e "${RED}Не удалось загрузить шаблон WARP-конфига.${NC}"
                    sleep 2
                    return
                }
            fi

            CURRENT_OUTBOUND_MODE="warp"
            save_slave_config

            # Показываем источник WARP-ключей
            local warp_creds_info=""
            if [ -f "$WARP_SYSTEM_CONF" ]; then
                local sys_pk
                sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                if [ -n "$sys_pk" ]; then
                    warp_creds_info="$WARP_SYSTEM_CONF"
                fi
            fi
            if [ -z "$warp_creds_info" ] && [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
                local existing_pk
                existing_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
                if [ -n "$existing_pk" ] && [ "$existing_pk" != "__WARP_PRIVATE_KEY__" ]; then
                    warp_creds_info="существующий конфиг sing-box"
                fi
            fi
            if [ -z "$warp_creds_info" ] && [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
                warp_creds_info="$WGCF_DIR/wgcf-profile.conf"
            fi
            if [ -n "$warp_creds_info" ]; then
                echo -e " - ${GREEN}Источник WARP-ключей: ${warp_creds_info}${NC}"
            else
                echo -e " - ${YELLOW}WARP-ключи будут получены при пересборке конфига...${NC}"
            fi

            if rebuild_config "$SINGBOX_TEMPLATE"; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим WARP активирован!${NC}"
                else
                    echo -e "${RED}Не удалось корректно перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка пересборки конфига!${NC}"
            fi
            sleep 2
            ;;
        2)
            echo -e "\n${CYAN}Настройка подключения к донор-серверу${NC}"
            echo -e "${YELLOW}На донор-сервере должен быть установлен warperslave.${NC}"
            echo -e ""

            local new_server new_port new_password
            local use_saved=false

            # Проверяем есть ли сохранённые данные от предыдущего подключения
            if [ -n "$SLAVE_SERVER" ] && [ -n "$SLAVE_PASSWORD" ]; then
                echo -e "${GREEN}Найдено сохранённое подключение:${NC}"
                echo -e "  ${CYAN}Сервер:${NC} ${YELLOW}${SLAVE_SERVER}${NC}"
                echo -e "  ${CYAN}Порт:${NC}   ${YELLOW}${SLAVE_PORT}${NC}"
                echo -e "  ${CYAN}Ключ:${NC}   ${YELLOW}${SLAVE_PASSWORD:0:8}...${NC}"
                echo -e ""
                echo -e " ${GREEN}1.${NC} Использовать сохранённое подключение"
                echo -e " ${CYAN}2.${NC} Ввести новый сервер"
                echo -e " ${CYAN}0.${NC} Отмена"

                while true; do
                    read -r -p "Выбор [0-2]: " saved_choice
                    case "${saved_choice:-}" in
                        1)
                            use_saved=true
                            new_server="$SLAVE_SERVER"
                            new_port="$SLAVE_PORT"
                            new_password="$SLAVE_PASSWORD"
                            break
                            ;;
                        2)
                            use_saved=false
                            break
                            ;;
                        0)
                            return
                            ;;
                        *)
                            echo -e "${RED}Введите 0, 1 или 2.${NC}"
                            ;;
                    esac
                done
            fi

            if [ "$use_saved" = false ]; then
                # IP/домен сервера
                while true; do
                    read -r -p "IP или домен slave-сервера (Enter для отмены): " new_server
                    if [ -z "$new_server" ]; then
                        echo -e "${YELLOW}Отмена.${NC}"; return
                    fi
                    if [[ "$new_server" =~ ^[0-9a-zA-Z._:-]+$ ]]; then
                        break
                    fi
                    echo -e "${RED}Некорректный адрес!${NC}"
                done

                # Порт
                local default_sp="${SLAVE_PORT:-8444}"
                read -r -p "Порт [по умолчанию $default_sp]: " new_port
                if [ -z "$new_port" ]; then
                    new_port="$default_sp"
                fi
                if ! validate_port_simple "$new_port"; then
                    echo -e "${RED}Некорректный порт!${NC}"
                    sleep 1
                    return
                fi

                # Ключ
                while true; do
                    read -r -p "Ключ Shadowsocks: " new_password
                    if [ -z "$new_password" ]; then
                        echo -e "${RED}Ключ не может быть пустым!${NC}"
                        continue
                    fi
                    break
                done
            fi

            SLAVE_SERVER="$new_server"
            SLAVE_PORT="$new_port"
            SLAVE_PASSWORD="$new_password"
            CURRENT_OUTBOUND_MODE="slave"
            save_slave_config

            echo -e "${YELLOW}Создание конфигурации...${NC}"
            if rebuild_config_slave; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим Slave активирован!${NC}"
                    echo -e "${CYAN}Трафик идёт через: $SLAVE_SERVER:$SLAVE_PORT${NC}"
                else
                    echo -e "${RED}Не удалось корректно перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка! Возврат к режиму WARP.${NC}"
                CURRENT_OUTBOUND_MODE="warp"
                save_slave_config
                if [ -f "$SINGBOX_TEMPLATE" ]; then
                    rebuild_config "$SINGBOX_TEMPLATE" >/dev/null 2>&1 || true
                    restart_singbox_full >/dev/null 2>&1 || true
                fi
            fi
            sleep 2
            ;;
        3)
            echo -e "\n${CYAN}Настройка WireGuard-соединения${NC}"

            load_wg_config
            local use_saved_wg=false

            # Проверяем сохранённые данные
            if [ -n "$WG_PRIVATE_KEY" ] && [ -n "$WG_ENDPOINT_HOST" ]; then
                echo -e "${GREEN}Найдено сохранённое WG-подключение:${NC}"
                echo -e "  ${CYAN}Endpoint:${NC} ${YELLOW}${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT}${NC}"
                echo -e "  ${CYAN}Address:${NC}  ${YELLOW}${WG_ADDRESS}${NC}"
                if [ "$WG_CONF_FILE" != "manual" ] && [ -n "$WG_CONF_FILE" ]; then
                    echo -e "  ${CYAN}Из файла:${NC} ${YELLOW}${WG_CONF_FILE}${NC}"
                fi
                echo -e ""
                echo -e " ${GREEN}1.${NC} Использовать сохранённое подключение"
                echo -e " ${CYAN}2.${NC} Выбрать новый конфиг / ввести вручную"
                echo -e " ${CYAN}0.${NC} Отмена"

                while true; do
                    read -r -p "Выбор [0-2]: " saved_wg_choice
                    case "${saved_wg_choice:-}" in
                        1) use_saved_wg=true; break ;;
                        2) use_saved_wg=false; break ;;
                        0) return ;;
                        *) echo -e "${RED}Введите 0, 1 или 2.${NC}" ;;
                    esac
                done
            fi

            if [ "$use_saved_wg" = false ]; then
                if ! select_wg_config; then
                    echo -e "${YELLOW}Отмена.${NC}"
                    sleep 1
                    return
                fi
            fi

            CURRENT_OUTBOUND_MODE="wg"
            save_slave_config

            echo -e "${YELLOW}Создание конфигурации...${NC}"
            if rebuild_config_wg; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим WG активирован!${NC}"
                    echo -e "${CYAN}Трафик идёт через: $WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT${NC}"
                else
                    echo -e "${RED}Не удалось перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка! Возврат к предыдущему режиму.${NC}"
                CURRENT_OUTBOUND_MODE="warp"
                save_slave_config
                if [ -f "$SINGBOX_TEMPLATE" ]; then
                    rebuild_config "$SINGBOX_TEMPLATE" >/dev/null 2>&1 || true
                    restart_singbox_full >/dev/null 2>&1 || true
                fi
            fi
            sleep 2
            ;;
        0) return ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
}

# ===== Управление WARP ключами =====

manage_warp_keys() {
    load_slave_config
    if [ "$CURRENT_OUTBOUND_MODE" != "warp" ]; then
        echo -e "${YELLOW}Управление WARP-ключами доступно только в режиме WARP.${NC}"
        sleep 2
        return
    fi

    echo -e "\n${CYAN}================================================${NC}"
    echo -e "       ${YELLOW}Управление WARP-ключами${NC}"
    echo -e "${CYAN}================================================${NC}"

    # Показываем текущий источник
    local current_source="неизвестно"
    if [ -f "$WARP_SYSTEM_CONF" ]; then
        local sys_pk=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ]; then
            # Сравниваем с текущим ключом в sing-box
            local cur_pk=""
            if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
                cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
            fi
            if [ "$sys_pk" = "$cur_pk" ]; then
                current_source="$WARP_SYSTEM_CONF"
            fi
        fi
    fi
    if [ "$current_source" = "неизвестно" ] && [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        local wgcf_pk=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        local cur_pk=""
        if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
            cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        fi
        if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
            current_source="$WGCF_DIR/wgcf-profile.conf"
        fi
    fi
    if [ "$current_source" = "неизвестно" ]; then
        current_source="конфиг sing-box"
    fi

    echo -e ""
    echo -e " ${CYAN}Текущий источник:${NC} ${YELLOW}${current_source}${NC}"
    echo -e ""

    # Формируем список доступных источников
    local -a sources=()
    local -a source_labels=()
    local idx=1

    if [ -f "$WARP_SYSTEM_CONF" ]; then
        local sys_pk=""
        local sys_addr=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        sys_addr=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ]; then
            sources+=("system")
            source_labels+=("$WARP_SYSTEM_CONF (${sys_addr:-без адреса}) — рекомендуется")
            echo -e " ${GREEN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        local wgcf_pk=""
        local wgcf_addr=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        wgcf_addr=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ]; then
            sources+=("wgcf")
            source_labels+=("$WGCF_DIR/wgcf-profile.conf ($wgcf_addr)")
            echo -e " ${CYAN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    if [ -f "/root/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        local root_pk=""
        local root_addr=""
        root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        root_addr=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$root_pk" ]; then
            sources+=("root")
            source_labels+=("/root/wgcf-profile.conf ($root_addr)")
            echo -e " ${CYAN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    sources+=("generate")
    source_labels+=("Сгенерировать новый ключ WARP")
    echo -e " ${YELLOW}${idx}.${NC} ${source_labels[$((idx-1))]}"
    ((idx++))

    echo -e " ${CYAN}0.${NC} Отмена"
    echo -e ""

    read -r -p "Выбор: " key_choice

    if [ "$key_choice" = "0" ] || [ -z "$key_choice" ]; then
        return
    fi

    if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || (( key_choice < 1 || key_choice > ${#sources[@]} )); then
        echo -e "${RED}Неверный выбор.${NC}"
        sleep 1
        return
    fi

    local selected="${sources[$((key_choice-1))]}"
    local new_address="" new_private_key=""

    case "$selected" in
        system)
            new_private_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            new_address=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            [ -z "$new_address" ] && new_address="172.16.0.2/32"
            [[ ! "$new_address" =~ / ]] && new_address="${new_address}/32"
            echo -e "${CYAN}Используем ключи из $WARP_SYSTEM_CONF${NC}"
            ;;
        wgcf)
            new_private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            echo -e "${CYAN}Используем ключи из $WGCF_DIR/wgcf-profile.conf${NC}"
            ;;
        root)
            new_private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            echo -e "${CYAN}Используем ключи из /root/wgcf-profile.conf${NC}"
            ;;
        generate)
            echo -e "${YELLOW}Генерация нового ключа WARP...${NC}"
            mkdir -p "$WGCF_DIR"
            cd "$WGCF_DIR" || { echo -e "${RED}Ошибка перехода в $WGCF_DIR${NC}"; return 1; }

            if [ ! -f "/usr/local/bin/wgcf" ]; then
                local sys_arch
                sys_arch=$(uname -m)
                case "$sys_arch" in
                    x86_64)  sys_arch="amd64" ;;
                    aarch64) sys_arch="arm64" ;;
                    armv7l)  sys_arch="armv7" ;;
                    *) echo -e "${RED}Неподдерживаемая архитектура.${NC}"; return 1 ;;
                esac
                echo -e " - ${CYAN}Скачивание wgcf...${NC}"
                if ! wget -qO wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${sys_arch}"; then
                    echo -e "${RED}Ошибка загрузки wgcf!${NC}"
                    return 1
                fi
                chmod +x wgcf
                mv wgcf /usr/local/bin/wgcf
            fi

            echo -e " - ${CYAN}Регистрация WARP...${NC}"
            /usr/local/bin/wgcf register --accept-tos > /dev/null 2>&1
            /usr/local/bin/wgcf generate > /dev/null 2>&1

            if [ ! -f "wgcf-profile.conf" ]; then
                echo -e "${RED}Ошибка: wgcf-profile.conf не создан!${NC}"
                echo -e "${YELLOW}Cloudflare мог заблокировать регистрацию с этого IP.${NC}"
                return 1
            fi

            chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true
            new_private_key=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            echo -e "${GREEN}Новый ключ WARP сгенерирован!${NC}"
            ;;
    esac

    if [ -z "$new_private_key" ] || [ -z "$new_address" ]; then
        echo -e "${RED}Не удалось получить ключи.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Пересборка конфигурации...${NC}"

    # Подставляем ключи напрямую в шаблон
    if [ ! -f "$SINGBOX_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config.json.template" "$SINGBOX_TEMPLATE" "config.json.template" || return 1
    fi

    sed \
        -e "s|__WARP_ADDRESS__|$new_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$new_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        return 1
    fi

    if restart_singbox_full; then
        echo -e "${GREEN}WARP-ключи успешно обновлены!${NC}"
    else
        echo -e "${RED}Ошибка перезапуска sing-box.${NC}"
    fi
    sleep 2
}


syntax_check_bash_file() {
    local file="$1"
    local desc="$2"
    if ! bash -n "$file"; then
        echo -e "${RED}Ошибка синтаксиса в ${desc}${NC}"
        return 1
    fi
    return 0
}

validate_template_marker() {
    local file="$1"
    local marker="$2"
    local desc="$3"
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
        echo -e "${RED}Файл ${desc} повреждён или неполон.${NC}"
        return 1
    fi
    return 0
}

backup_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

restore_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

rollback_warper_update() {
    local backupdir="$1"

    restore_if_exists "$backupdir/warper.sh" "$WARPER_DIR/warper.sh"
    restore_if_exists "$backupdir/uninstaller.sh" "$WARPER_DIR/uninstaller.sh"
    restore_if_exists "$backupdir/version" "$WARPER_DIR/version"

    restore_if_exists "$backupdir/config.json.template" "$SINGBOX_TEMPLATE"
    restore_if_exists "$backupdir/config-slave-master.json.template" "$SLAVE_TEMPLATE"
    restore_if_exists "$backupdir/config-wg.json.template" "$WG_TEMPLATE"

    restore_if_exists "$backupdir/gemini.txt" "$DOWNLOAD_DIR/gemini.txt"
    restore_if_exists "$backupdir/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt"

    restore_if_exists "$backupdir/sing-box.service" "/etc/systemd/system/sing-box.service"
    restore_if_exists "$backupdir/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service"

    restore_if_exists "$backupdir/config.json" "$SINGBOX_CONF"
    restore_if_exists "$backupdir/domains.txt" "$MASTER_FILE"

    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh" 2>/dev/null || true
    ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ===== Обновление =====

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"

    local tmpdir backupdir
    local had_singbox=false

    tmpdir=$(mktemp -d /tmp/warper-update.XXXXXX) || {
        echo -e "${RED}Не удалось создать временную директорию.${NC}"
        return 1
    }

    backupdir=$(mktemp -d /tmp/warper-backup.XXXXXX) || {
        rm -rf "$tmpdir"
        echo -e "${RED}Не удалось создать директорию для backup.${NC}"
        return 1
    }

    # ===== Скачиваем всё во временную директорию =====
    download_file_safe "$REPO_URL/warper.sh" "$tmpdir/warper.sh" "warper.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/uninstaller.sh" "$tmpdir/uninstaller.sh" "uninstaller.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/version" "$tmpdir/version" "version" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    download_file_safe "$REPO_URL/templates/sing-box.service" "$tmpdir/sing-box.service" "sing-box.service" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/warper-autopatch.service" "$tmpdir/warper-autopatch.service" "warper-autopatch.service" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    download_file_safe "$REPO_URL/templates/config.json.template" "$tmpdir/config.json.template" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/config-slave-master.json.template" "$tmpdir/config-slave-master.json.template" "config-slave-master.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/config-wg.json.template" "$tmpdir/config-wg.json.template" "config-wg.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    download_file_safe "$REPO_URL/download/gemini.txt" "$tmpdir/gemini.txt" "gemini.txt" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/download/chatgpt.txt" "$tmpdir/chatgpt.txt" "chatgpt.txt" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # ===== Проверяем синтаксис bash-скриптов =====
    syntax_check_bash_file "$tmpdir/warper.sh" "warper.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    syntax_check_bash_file "$tmpdir/uninstaller.sh" "uninstaller.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # ===== Проверяем шаблоны =====
    validate_template_marker "$tmpdir/config.json.template" "__WARP_ADDRESS__" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    validate_template_marker "$tmpdir/config.json.template" "__SUBNET__" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    validate_template_marker "$tmpdir/config-slave-master.json.template" "__SLAVE_SERVER__" "config-slave-master.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    validate_template_marker "$tmpdir/config-wg.json.template" "__WG_ENDPOINT_HOST__" "config-wg.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Опционально проверяем unit-файлы
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$tmpdir/sing-box.service" >/dev/null 2>&1 || {
            echo -e "${RED}Некорректный unit-файл sing-box.service${NC}"
            rm -rf "$tmpdir" "$backupdir"
            return 1
        }
        systemd-analyze verify "$tmpdir/warper-autopatch.service" >/dev/null 2>&1 || {
            echo -e "${RED}Некорректный unit-файл warper-autopatch.service${NC}"
            rm -rf "$tmpdir" "$backupdir"
            return 1
        }
    fi

    # ===== Backup текущих файлов =====
    backup_if_exists "$WARPER_DIR/warper.sh" "$backupdir/warper.sh"
    backup_if_exists "$WARPER_DIR/uninstaller.sh" "$backupdir/uninstaller.sh"
    backup_if_exists "$WARPER_DIR/version" "$backupdir/version"

    backup_if_exists "$SINGBOX_TEMPLATE" "$backupdir/config.json.template"
    backup_if_exists "$SLAVE_TEMPLATE" "$backupdir/config-slave-master.json.template"
    backup_if_exists "$WG_TEMPLATE" "$backupdir/config-wg.json.template"

    backup_if_exists "$DOWNLOAD_DIR/gemini.txt" "$backupdir/gemini.txt"
    backup_if_exists "$DOWNLOAD_DIR/chatgpt.txt" "$backupdir/chatgpt.txt"

    backup_if_exists "/etc/systemd/system/sing-box.service" "$backupdir/sing-box.service"
    backup_if_exists "/etc/systemd/system/warper-autopatch.service" "$backupdir/warper-autopatch.service"

    backup_if_exists "$SINGBOX_CONF" "$backupdir/config.json"
    backup_if_exists "$MASTER_FILE" "$backupdir/domains.txt"

    if systemctl is-active --quiet sing-box; then
        had_singbox=true
    fi

    # ===== Устанавливаем новые файлы =====
    install -m 755 "$tmpdir/warper.sh" "$WARPER_DIR/warper.sh" || {
        echo -e "${RED}Ошибка установки warper.sh, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 755 "$tmpdir/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" || {
        echo -e "${RED}Ошибка установки uninstaller.sh, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/version" "$WARPER_DIR/version" || {
        echo -e "${RED}Ошибка установки version, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/config.json.template" "$SINGBOX_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/config-slave-master.json.template" "$SLAVE_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config-slave-master.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/config-wg.json.template" "$WG_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config-wg.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" || {
        echo -e "${RED}Ошибка установки gemini.txt, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" || {
        echo -e "${RED}Ошибка установки chatgpt.txt, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/sing-box.service" "/etc/systemd/system/sing-box.service" || {
        echo -e "${RED}Ошибка установки sing-box.service, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" || {
        echo -e "${RED}Ошибка установки warper-autopatch.service, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper

    if ! systemctl daemon-reload; then
        echo -e "${RED}Ошибка systemctl daemon-reload, откат.${NC}"
        rollback_warper_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    fi

    systemctl enable warper-autopatch >/dev/null 2>&1 || true

    # ===== Пересобираем текущую конфигурацию =====
    echo -e "${CYAN}Обновление конфигурации sing-box...${NC}"
    if ! rebuild_config "$SINGBOX_TEMPLATE"; then
        echo -e "${RED}Ошибка пересборки config.json, откат.${NC}"
        rollback_warper_update "$backupdir"
        if [ "$had_singbox" = true ]; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
        rm -rf "$tmpdir" "$backupdir"
        return 1
    fi

    if [ "$had_singbox" = true ]; then
        systemctl restart sing-box
        if ! ensure_singbox_running; then
            echo -e "${RED}Новая версия sing-box не запустилась, выполняется откат.${NC}"
            rollback_warper_update "$backupdir"
            systemctl restart sing-box >/dev/null 2>&1 || true
            rm -rf "$tmpdir" "$backupdir"
            return 1
        fi
        echo -e "${GREEN}Служба sing-box перезапущена.${NC}"
    fi

    systemctl restart kresd@1 >/dev/null 2>&1 || true

    # ===== Перестраиваем и синхронизируем домены =====
    rebuild_master_file
    update_list_blocks

    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || {
            echo -e "${YELLOW}Предупреждение: обновление прошло, но патч DNS не удалось переприменить.${NC}"
        }
    else
        sync_domains >/dev/null 2>&1 || true
    fi
        # Пересинхронизируем IP-маршруты после обновления
    if is_warper_active && [ "$(count_ip_ranges)" -gt 0 ]; then
        echo -e "${CYAN}Синхронизация IP-маршрутов...${NC}"
        sync_ip_ranges || true
    fi

    rm -rf "$tmpdir" "$backupdir"

    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -r -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
}

# ===== Меню IP-подсетей =====

ip_ranges_menu() {
    while true; do
        clear
        local ip_cnt route_cnt sync_stat
        ip_cnt=$(count_ip_ranges)
        route_cnt=$(count_tun_routes)
        if ip_ranges_in_sync; then sync_stat="${GREEN}✅ синхронизированы${NC}"; else sync_stat="${YELLOW}⚠️ не синхронизированы${NC}"; fi

        echo -e "${CYAN}================================================${NC}"
        echo -e "    🌐 ${YELLOW}УПРАВЛЕНИЕ IP-ПОДСЕТЯМИ${NC} 🌐"
        echo -e "${CYAN}================================================${NC}"
        echo -e ""
        echo -e " 📁 ${CYAN}Подсетей в файле:${NC}     ${YELLOW}${ip_cnt}${NC}"
        echo -e " 🔀 ${CYAN}Маршрутов активно:${NC}    ${YELLOW}${route_cnt}${NC}"
        echo -e " 📊 ${CYAN}Статус:${NC}               $sync_stat"
        echo -e ""
        echo -e "${CYAN}------------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} ➕ Добавить подсеть"
        echo -e " ${RED}2.${NC} ➖ Удалить подсеть"
        echo -e " ${CYAN}3.${NC} 📋 Показать список подсетей"
        echo -e " ${CYAN}4.${NC} ✏️  Редактировать файл (nano)"
        echo -e " ${GREEN}5.${NC} 🔄 Синхронизировать (файл → маршруты)"
        echo -e " ${CYAN}6.${NC} 📊 Показать активные маршруты"
        echo -e " ${RED}7.${NC} 🗑️  Удалить все маршруты"
        local mode_label
        case "$IP_ROUTE_MODE" in
            antizapret) mode_label="${GREEN}Только AntiZapret${NC}" ;;
            all_vpn)    mode_label="${CYAN}AntiZapret + FullVPN${NC}" ;;
            all)        mode_label="${YELLOW}Весь трафик сервера(Beta)${NC}" ;;
            *)          mode_label="${RED}неизвестно${NC}" ;;
        esac
        echo -e " ${CYAN}8.${NC} 🎯 Режим применения: [$mode_label]"
        local export_label
        if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
            export_label="${GREEN}ВКЛ${NC}"
        else
            export_label="${RED}ВЫКЛ${NC}"
        fi
        echo -e " ${CYAN}9.${NC} 📤 Экспорт в AntiZapret route-ips: [$export_label]"
        echo -e " ${CYAN}0.${NC} ↩️  Назад"
        echo -e "${CYAN}================================================${NC}"

        read -r -e -p "Выбор [0-9]: " ipchoice
        case "${ipchoice:-}" in
            1)
                echo -e "\n${CYAN}Введите подсеть в формате A.B.C.D/M:${NC}"
                echo -e "${YELLOW}Примеры: 91.108.4.0/22  5.255.255.242/32  104.24.0.0/14${NC}"
                read -r -e -p "> " raw_cidr
                if [ -z "$raw_cidr" ]; then
                    echo -e "${YELLOW}Отмена.${NC}"
                    sleep 1
                    continue
                fi
                if add_ip_range "$raw_cidr"; then
                    if is_warper_active; then
                        echo -e "${CYAN}Применить маршрут сейчас?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    else
                        echo -e "${YELLOW}WARPER выключен — маршрут будет применён при включении и синхронизации.${NC}"
                    fi
                fi
                read -r -p "Нажмите Enter..."
                ;;
            2)
                echo -e "\n${CYAN}Текущие подсети:${NC}"
                local ranges_list
                ranges_list=$(extract_ip_ranges)
                if [ -z "$ranges_list" ]; then
                    echo -e "${YELLOW}Список пуст.${NC}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi

                local idx=1
                local -a ranges_array
                mapfile -t ranges_array <<< "$ranges_list"
                for r in "${ranges_array[@]}"; do
                    echo -e " ${GREEN}${idx}.${NC} $r"
                    ((idx++))
                done
                echo -e ""
                echo -e "${CYAN}Введите номер или подсеть для удаления (0 = отмена):${NC}"
                read -r -e -p "> " del_input

                if [ "$del_input" = "0" ] || [ -z "$del_input" ]; then
                    continue
                fi

                local to_remove=""
                if [[ "$del_input" =~ ^[0-9]+$ ]] && (( del_input >= 1 && del_input <= ${#ranges_array[@]} )); then
                    to_remove="${ranges_array[$((del_input-1))]}"
                else
                    to_remove="$del_input"
                fi

                if remove_ip_range "$to_remove"; then
                    if is_warper_active; then
                        echo -e "${CYAN}Удалить маршрут сейчас?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    fi
                fi
                read -r -p "Нажмите Enter..."
                ;;
            3)
                echo -e "\n${CYAN}--- Подсети в $IP_RANGES_FILE ---${NC}"
                local ranges
                ranges=$(extract_ip_ranges)
                if [ -n "$ranges" ]; then
                    echo "$ranges" | nl -ba
                else
                    echo -e "${YELLOW}Список пуст.${NC}"
                fi
                echo -e "${CYAN}--------------------------------${NC}"
                read -r -p "Нажмите Enter..."
                ;;
            4)
                local before_hash after_hash
                before_hash=$(extract_ip_ranges | sha256sum | awk '{print $1}')
                nano "$IP_RANGES_FILE"
                after_hash=$(extract_ip_ranges | sha256sum | awk '{print $1}')
                if [ "$before_hash" != "$after_hash" ]; then
                    echo -e "${GREEN}Файл изменён.${NC}"
                    if is_warper_active; then
                        echo -e "${CYAN}Синхронизировать маршруты?${NC}"
                        read -r -e -p "[Y/n]: " apply_now
                        if [[ -z "$apply_now" || "$apply_now" =~ ^[Yy]$ ]]; then
                            sync_ip_ranges
                        fi
                    fi
                else
                    echo -e "${YELLOW}Изменений нет.${NC}"
                fi
                sleep 1
                ;;
            5)
                sync_ip_ranges
                read -r -p "Нажмите Enter..."
                ;;
            6)
                echo -e "\n${CYAN}--- Применённые WARPER IP-маршруты ---${NC}"
                local routes
                routes=$(get_current_tun_routes)
                if [ -n "$routes" ]; then
                    echo "$routes" | nl -ba
                else
                    echo -e "${YELLOW}Нет активных маршрутов (кроме fake-подсети).${NC}"
                fi
                echo -e "${CYAN}--------------------------------------------${NC}"
                read -r -p "Нажмите Enter..."
                ;;
            7)
                echo -e "\n${RED}Удалить ВСЕ пользовательские IP-маршруты через singbox-tun?${NC}"
                read -r -e -p "Вы уверены? [y/N]: " confirm_del
                if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                    remove_all_ip_routes
                fi
                read -r -p "Нажмите Enter..."
                ;;
            8)
                echo -e "\n${CYAN}Выберите, для каких клиентов применять IP-маршруты:${NC}"
                echo -e ""
                detect_client_subnets
                echo -e " ${GREEN}1.${NC} Только AntiZapret   (${AZ_CLIENT_NET})"
                echo -e " ${CYAN}2.${NC} AntiZapret + FullVPN (${ALL_CLIENT_NET})"
                echo -e " ${YELLOW}3.${NC} Весь трафик сервера (Beta)"
                echo -e " ${CYAN}0.${NC} Отмена"
                echo -e ""
                read -r -e -p "Выбор [0-3]: " mode_choice
                case "${mode_choice:-}" in
                    1) IP_ROUTE_MODE="antizapret" ;;
                    2) IP_ROUTE_MODE="all_vpn" ;;
                    3) IP_ROUTE_MODE="all" ;;
                    0) continue ;;
                    *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1; continue ;;
                esac
                # Сохраняем в конфиг
                if grep -q '^IP_ROUTE_MODE=' "$CONF_FILE" 2>/dev/null; then
                    sed -i "s/^IP_ROUTE_MODE=.*/IP_ROUTE_MODE=$IP_ROUTE_MODE/" "$CONF_FILE"
                else
                    echo "IP_ROUTE_MODE=$IP_ROUTE_MODE" >> "$CONF_FILE"
                fi
                echo -e "${GREEN}Режим изменён на: $IP_ROUTE_MODE${NC}"
                # Пересинхронизируем если есть активные маршруты
                if [ "$(count_ip_ranges)" -gt 0 ] && is_warper_active; then
                    echo -e "${CYAN}Пересинхронизация маршрутов...${NC}"
                    sync_ip_ranges
                fi
                read -r -p "Нажмите Enter..."
                ;;
            9)
                if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
                    IP_EXPORT_TO_ANTIZAPRET="n"
                else
                    IP_EXPORT_TO_ANTIZAPRET="y"
                fi

                if grep -q '^IP_EXPORT_TO_ANTIZAPRET=' "$CONF_FILE" 2>/dev/null; then
                    sed -i "s/^IP_EXPORT_TO_ANTIZAPRET=.*/IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET/" "$CONF_FILE"
                else
                    echo "IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET" >> "$CONF_FILE"
                fi

                echo -e "${GREEN}Экспорт в AntiZapret: $IP_EXPORT_TO_ANTIZAPRET${NC}"
                sync_ip_ranges_to_antizapret
                read -r -p "Нажмите Enter..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ===== Меню настроек =====

settings_menu() {
    while true; do
        clear
        load_slave_config
        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        local AP_STAT GEM_STAT GPT_STAT LOG_LEVEL MTU MODE_STAT
        LOG_LEVEL=$(get_log_level)
        MTU=$(get_mtu)
        if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}ВКЛ${NC}"; else AP_STAT="${RED}ВЫКЛ${NC}"; fi
        if has_list_block "gemini"; then GEM_STAT="${GREEN}ВКЛ${NC}"; else GEM_STAT="${RED}ВЫКЛ${NC}"; fi
        if has_list_block "chatgpt"; then GPT_STAT="${GREEN}ВКЛ${NC}"; else GPT_STAT="${RED}ВЫКЛ${NC}"; fi
        load_wg_config
        if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
            MODE_STAT="${CYAN}Slave ($SLAVE_SERVER:$SLAVE_PORT)${NC}"
        elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
            MODE_STAT="${CYAN}WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)${NC}"
        else
            MODE_STAT="${GREEN}WARP (локальный)${NC}"
        fi
        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке: [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Интеграция доменов Gemini:     [$GEM_STAT]"
        echo -e " ${CYAN}3.${NC} Интеграция доменов ChatGPT:    [$GPT_STAT]"
        echo -e " ${CYAN}4.${NC} Изменить фейковую подсеть:     [$SUBNET]"
        echo -e " ${CYAN}5.${NC} Изменить log level sing-box:   [$LOG_LEVEL]"
        echo -e " ${CYAN}6.${NC} Изменить MTU sing-box:         [$MTU]"
        echo -e " ${CYAN}7.${NC} Режим маршрутизации:           [$MODE_STAT]"
        if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
            echo -e " ${CYAN}8.${NC} Управление WARP-ключами"
        fi        
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-8]: " set_choice
        case "${set_choice:-}" in
            1)
                if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
                    systemctl disable warper-autopatch >/dev/null 2>&1
                    echo -e "${YELLOW}Автопатч отключен.${NC}"; sleep 1
                else
                    systemctl enable warper-autopatch >/dev/null 2>&1
                    echo -e "${GREEN}Автопатч включен.${NC}"; sleep 1
                fi
                ;;
            2) toggle_list "gemini" ;;
            3) toggle_list "chatgpt" ;;
            4)
                echo -e "\n${YELLOW}Внимание! Изменение подсети перезапустит службы.${NC}"
                read -r -e -p "Вы уверены? [y/N]: " conf_sub
                if [[ "$conf_sub" == "y" || "$conf_sub" == "Y" ]]; then
                    while true; do
                        read -r -e -p "Введите новую подсеть (X.X.X.0/XX) или пустое для отмены: " new_subnet
                        if [ -z "$new_subnet" ]; then echo -e "${YELLOW}Отмена.${NC}"; sleep 1; break; fi
                        if validate_subnet "$new_subnet"; then
                            if subnet_conflicts "$new_subnet"; then
                                echo -e "${YELLOW}Предупреждение: подсеть может конфликтовать.${NC}"
                                read -r -e -p "Использовать? [y/N]: " force_subnet
                                if [[ ! "$force_subnet" =~ ^[Yy]$ ]]; then continue; fi
                            fi
                            local old_subnet old_tun new_tun
                            old_subnet="$SUBNET"; old_tun="$TUN_IP"
                            new_tun=$(calculate_tun_ip "$new_subnet")
                            SUBNET="$new_subnet"; TUN_IP="$new_tun"
                            if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
                                if ! rebuild_config "$SINGBOX_TEMPLATE"; then
                                    SUBNET="$old_subnet"; TUN_IP="$old_tun"
                                    echo -e "${RED}Ошибка пересборки конфига.${NC}"; sleep 2; break
                                fi
                            else
                                sed -i "s|\"$old_subnet\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
                                sed -i "s|\"$old_tun\"|\"$new_tun\"|g" "$SINGBOX_CONF"
                                if ! validate_singbox_config; then
                                    sed -i "s|\"$new_subnet\"|\"$old_subnet\"|g" "$SINGBOX_CONF"
                                    sed -i "s|\"$new_tun\"|\"$old_tun\"|g" "$SINGBOX_CONF"
                                    SUBNET="$old_subnet"; TUN_IP="$old_tun"
                                    echo -e "${RED}Откат выполнен.${NC}"; sleep 2; break
                                fi
                            fi
                            sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
                            grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || echo "$new_subnet" >> "$AZ_INC"
                            normalize_include_ips "$AZ_INC"
                            {
                                echo "SUBNET=$new_subnet"
                                echo "TUN_IP=$new_tun"
                                echo "IP_ROUTE_MODE=$IP_ROUTE_MODE"
                                echo "IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET"
                            } > "$CONF_FILE"
                            chmod 600 "$CONF_FILE"
                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret...${NC}"
                            export DEBIAN_FRONTEND=noninteractive SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1
                            systemctl restart sing-box
                            if ! ensure_singbox_running; then sleep 2; break; fi
                            ensure_iptables_rule FORWARD -o singbox-tun
                            ensure_iptables_rule FORWARD -i singbox-tun
                            echo -e "${GREEN}Подсеть успешно изменена!${NC}"; sleep 2; break
                        else
                            echo -e "${RED}Некорректная подсеть!${NC}"
                        fi
                    done
                fi
                ;;
            5)
                echo -e "\n${CYAN}Доступные уровни логирования:${NC}"
                echo -e " ${CYAN}1.${NC} debug"
                echo -e " ${CYAN}2.${NC} info"
                echo -e " ${CYAN}3.${NC} warn"
                echo -e " ${CYAN}4.${NC} error"
                echo -e " ${CYAN}0.${NC} Отмена"
                read -r -e -p "Выбор [0-4]: " log_choice
                case "${log_choice:-}" in
                    1) set_log_level "debug"; sleep 2 ;;
                    2) set_log_level "info"; sleep 2 ;;
                    3) set_log_level "warn"; sleep 2 ;;
                    4) set_log_level "error"; sleep 2 ;;
                    0) ;;
                    *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
                esac
                ;;
            6)
                echo -e "\n${CYAN}Текущий MTU: $(get_mtu)${NC}"
                echo -e "${YELLOW}Допустимые значения: 1280-1500${NC}"
                read -r -e -p "Введите новый MTU (или пустое для отмены): " new_mtu
                if [ -n "$new_mtu" ]; then set_mtu "$new_mtu"; sleep 2; fi
                ;;
            7) switch_outbound_mode ;;
            8) manage_warp_keys ;;        
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

# ===== Меню sing-box =====

singbox_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "       ⚙️  ${YELLOW}УПРАВЛЕНИЕ SING-BOX${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        if systemctl is-active --quiet sing-box; then echo -e "Статус: ${GREEN}ЗАПУЩЕН 🟢${NC}"; else echo -e "Статус: ${RED}ОСТАНОВЛЕН 🔴${NC}"; fi
        if systemctl is-enabled --quiet sing-box 2>/dev/null; then echo -e "Автозагрузка: ${GREEN}ВКЛ${NC}"; else echo -e "Автозагрузка: ${RED}ВЫКЛ${NC}"; fi
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} Запустить службу"
        echo -e " ${RED}2.${NC} Остановить службу"
        echo -e " ${GREEN}3.${NC} Включить автозагрузку"
        echo -e " ${RED}4.${NC} Выключить автозагрузку"
        echo -e " ${YELLOW}5.${NC} Посмотреть логи"
        echo -e " ${CYAN}0.${NC} Назад"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-5]: " sb_choice
        case "${sb_choice:-}" in
            1)
                if prompt_confirm; then
                    if needs_down_sh; then
                        show_down_sh_warning
                        sleep 2
                        continue
                    fi
                    check_and_sync_warp_keys || continue
                    if ! validate_singbox_config; then sleep 2; continue; fi
                    systemctl start sing-box
                    if ensure_singbox_running; then
                        echo -e "${GREEN}Запущено.${NC}"
                        resync_ip_routes_if_needed
                    fi
                    sleep 1
                fi
                ;;
            2)
                if prompt_confirm; then
                    if [ "$(count_ip_ranges)" -gt 0 ]; then
                        remove_all_ip_routes >/dev/null 2>&1 || true
                    fi
                    systemctl stop sing-box
                    echo -e "${YELLOW}Остановлено.${NC}"
                    sleep 1
                fi
                ;;
            3) if prompt_confirm; then systemctl enable sing-box; echo -e "${GREEN}Добавлено в автозапуск.${NC}"; sleep 1; fi ;;
            4) if prompt_confirm; then systemctl disable sing-box; echo -e "${YELLOW}Убрано из автозапуска.${NC}"; sleep 1; fi ;;
            5) show_logs ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

# ===== Главное меню =====

show_main_menu() {
    clear
    load_slave_config
    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)
    echo -e "${CYAN}================================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления WARPER${NC} 🚀"
    echo -e "${CYAN}================================================${NC}"

    local VER_STR SB_RUN SB_EN KR_STAT DOM_STAT AZ_STAT AP_STAT UPDATE_AVAILABLE LOG_LEVEL MTU AZ_WARP_STAT WARP_KEYS_SRC MODE_DISPLAY
    UPDATE_AVAILABLE=false
    LOG_LEVEL=$(get_log_level)
    MTU=$(get_mtu)

    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER${NC} (📦 Доступно обновление: ${GREEN}$REMOTE_VER${NC})"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER${NC} (✅ актуальная)"
    fi

    if check_antizapret_warp; then
        AZ_WARP_STAT="${RED}⚠️  ANTIZAPRET_WARP=y (КОНФЛИКТ!)${NC}"
    else
        AZ_WARP_STAT="${GREEN}✅ OK${NC}"
    fi

    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}🟢 запущен${NC}"; else SB_RUN="${RED}🔴 остановлен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена${NC}"; else SB_EN="${RED}выключена${NC}"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then KR_STAT="${GREEN}✅ пропатчен${NC}"; else KR_STAT="${RED}❌ не пропатчен${NC}"; fi
    if domains_in_sync; then DOM_STAT="${GREEN}✅ синхронизированы${NC}"; else DOM_STAT="${YELLOW}⚠️  требуется синхронизация${NC}"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}✅ добавлена${NC}"; else AZ_STAT="${RED}❌ отсутствует${NC}"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}✅ включён${NC}"; else AP_STAT="${RED}❌ выключен${NC}"; fi

    # Режим маршрутизации
    load_wg_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        MODE_DISPLAY="${CYAN}Slave ($SLAVE_SERVER:$SLAVE_PORT)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        MODE_DISPLAY="${CYAN}WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)${NC}"
    else
        MODE_DISPLAY="${GREEN}WARP (локальный)${NC}"
    fi

    # Источник WARP-ключей
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        WARP_KEYS_SRC="${CYAN}не используются (Slave)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        if [ "$WG_CONF_FILE" = "manual" ] || [ -z "$WG_CONF_FILE" ]; then
            WARP_KEYS_SRC="${CYAN}WG: ручной ввод${NC}"
        else
            WARP_KEYS_SRC="${CYAN}WG: ${WG_CONF_FILE}${NC}"
        fi
    elif [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
        # Определяем точный источник ключей
        local cur_pk=""
        if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
            cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        fi
        WARP_KEYS_SRC="${YELLOW}конфиг sing-box${NC}"
        if [ -n "$cur_pk" ]; then
            # Приоритет 1: системный warp.conf — проверяем первым, при совпадении останавливаемся
            if [ -f "$WARP_SYSTEM_CONF" ]; then
                local sys_pk=""
                sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                if [ -n "$sys_pk" ] && [ "$sys_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}$WARP_SYSTEM_CONF${NC}"
                fi
            fi
            # Приоритет 2: только если ещё не нашли источник через system
            if [ "$WARP_KEYS_SRC" = "${YELLOW}конфиг sing-box${NC}" ] && \
               [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
                local wgcf_pk=""
                wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
                if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}$WGCF_DIR/wgcf-profile.conf${NC}"
                fi
            fi
            # Приоритет 3: только если ещё не нашли источник
            if [ "$WARP_KEYS_SRC" = "${YELLOW}конфиг sing-box${NC}" ] && \
               [ -f "/root/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
                local root_pk=""
                root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
                if [ -n "$root_pk" ] && [ "$root_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}/root/wgcf-profile.conf${NC}"
                fi
            fi
        fi
    else
        WARP_KEYS_SRC="${YELLOW}локальные ключи${NC}"
    fi

    echo -e ""
    echo -e " 📌 ${CYAN}Версия:${NC}        $VER_STR"
    echo -e " 🔗 ${CYAN}AntiZapret:${NC}    $AZ_WARP_STAT"
    echo -e ""
    echo -e " 📡 ${CYAN}Sing-box:${NC}      $SB_RUN | Автозагрузка: $SB_EN"
    echo -e " ⚙️  ${CYAN}Параметры:${NC}    Log: ${CYAN}$LOG_LEVEL${NC} | MTU: ${CYAN}$MTU${NC}"
    echo -e " 🔀 ${CYAN}Режим:${NC}         $MODE_DISPLAY"
    echo -e ""
    echo -e " 🌐 ${CYAN}DNS (kresd):${NC}   $KR_STAT"
    echo -e " 📁 ${CYAN}Домены:${NC}        $DOM_STAT"
    echo -e "    ${CYAN}Файл:${NC}          ${YELLOW}$MASTER_FILE${NC}"
    echo -e ""
    echo -e " 🔀 ${CYAN}Fake-подсеть:${NC}  ${YELLOW}$SUBNET${NC} — $AZ_STAT"
    echo -e " 🔄 ${CYAN}Автопатч DNS:${NC}  $AP_STAT"
    echo -e " 🔑 ${CYAN}WARP-ключи:${NC}    $WARP_KEYS_SRC"
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] && [ -n "$SLAVE_PASSWORD" ]; then
        echo -e " 🔐 ${CYAN}SS-ключ:${NC}       ${YELLOW}${SLAVE_PASSWORD:0:8}...${NC}"
    fi

    if needs_down_sh; then
        echo -e ""
        echo -e " ${RED}⚠️  ВНИМАНИЕ:${NC}     ${RED}Требуется перезапуск правил AntiZapret!${NC}"
        echo -e "                  ${YELLOW}Выполните: down.sh && up.sh${NC}"
    fi

    echo -e ""
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} ➕ Добавить домен в WARP"
    echo -e " ${RED}2.${NC} ➖ Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} 📋 Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} ✏️  Редактировать список (nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Применить изменения / Синхронизация / перезапуск Kresd"
    echo -e " ${CYAN}6.${NC} ⚙️  Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи sing-box"
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика (doctor)"
    echo -e " ${CYAN}S.${NC} 📊 Краткий статус"
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}K.${NC} 🔐 Показать полный SS-ключ"
    fi
    echo -e "${CYAN}------------------------------------------------${NC}"

    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        echo -e " ${RED}8.${NC} ⏹️  Отключить WARPER"
    else
        echo -e " ${GREEN}8.${NC} ▶️  Включить WARPER"
    fi

    local ip_cnt_menu
    ip_cnt_menu=$(count_ip_ranges)
    local ip_route_cnt_menu
    ip_route_cnt_menu=$(count_tun_routes)
    if [ "$ip_cnt_menu" -gt 0 ] || [ "$ip_route_cnt_menu" -gt 0 ]; then
        local ip_sync_menu
        if ip_ranges_in_sync; then ip_sync_menu="${GREEN}✅${NC}"; else ip_sync_menu="${YELLOW}⚠️${NC}"; fi
        echo -e " ${CYAN}I.${NC} 🌐 IP-подсети ($ip_sync_menu ${CYAN}файл:${NC}${ip_cnt_menu} ${CYAN}маршруты:${NC}${ip_route_cnt_menu})"
    else
        echo -e " ${CYAN}I.${NC} 🌐 Управление IP-подсетями"
    fi

    echo -e " ${CYAN}9.${NC} 🛠️  Настройки (Автопатч, Подсеть, Списки, Log, MTU, Режим)"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}10.${NC} ⚡ Обновить WARPER до ${GREEN}$REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}10.${NC} 🔄 Проверить обновления списков доменов"
    fi

    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${RED}U.${NC} 🗑️  Удалить WARPER полностью"
    echo -e " ${CYAN}0.${NC} 🚪 Выход"
    echo -e "${CYAN}================================================${NC}"

    MENU_UPDATE_AVAILABLE=$UPDATE_AVAILABLE
    MENU_REMOTE_VER=$REMOTE_VER
}

# ===== CLI-команды =====

cli_add_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || { echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1; }
    if grep -qxF "$domain" "$MASTER_FILE"; then
        echo -e "${YELLOW}Домен уже есть: $domain${NC}"; return 0
    fi
    insert_user_domain "$domain"
    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || true
    else
        sync_domains
    fi
    echo -e "${GREEN}Домен добавлен: $domain${NC}"
    return 0
}

cli_remove_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || { echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1; }
    if grep -qxF "$domain" "$MASTER_FILE"; then
        local escaped
        escaped=$(escape_regex "$domain")
        sed -i "/^${escaped}$/d" "$MASTER_FILE"
        rebuild_master_file
        if is_warper_active; then
            patch_kresd >/dev/null 2>&1 || true
        else
            sync_domains
        fi
        echo -e "${GREEN}Домен удалён: $domain${NC}"
        return 0
    fi
    echo -e "${YELLOW}Домен не найден: $domain${NC}"
    return 0
}

cli_enable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list enable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}

cli_disable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list disable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}

# ===== Инициализация =====

load_config
load_wg_config
rebuild_master_file
check_and_sync_warp_keys

# ===== CLI-обработка =====

case "${1:-}" in
    patch) patch_kresd >/dev/null 2>&1; exit $? ;;
    doctor) doctor; exit $? ;;
    status) status_cmd; exit $? ;;
    sync)
        if is_warper_active; then
            patch_kresd
        else
            sync_domains
            echo -e "${GREEN}Домены синхронизированы.${NC}"
        fi
        exit $?
        ;;
    add) [ -n "${2:-}" ] || { echo "Использование: warper add DOMAIN"; exit 1; }; cli_add_domain "$2"; exit $? ;;
    remove) [ -n "${2:-}" ] || { echo "Использование: warper remove DOMAIN"; exit 1; }; cli_remove_domain "$2"; exit $? ;;
    enable) [ -n "${2:-}" ] || { echo "Использование: warper enable gemini|chatgpt"; exit 1; }; cli_enable_list "$2"; exit $? ;;
    disable) [ -n "${2:-}" ] || { echo "Использование: warper disable gemini|chatgpt"; exit 1; }; cli_disable_list "$2"; exit $? ;;
    ipadd)
        [ -n "${2:-}" ] || { echo "Использование: warper ipadd A.B.C.D/M"; exit 1; }
        add_ip_range "$2"
        if is_warper_active; then sync_ip_ranges; fi
        exit $?
        ;;
    ipremove)
        [ -n "${2:-}" ] || { echo "Использование: warper ipremove A.B.C.D/M"; exit 1; }
        remove_ip_range "$2"
        if is_warper_active; then sync_ip_ranges; fi
        exit $?
        ;;
    ipsync)
        sync_ip_ranges
        exit $?
        ;;
    iplist)
        extract_ip_ranges
        exit $?
        ;;
    iproutes)
        get_current_tun_routes
        exit $?
        ;;
esac

# ===== Интерактивное меню =====

MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

while true; do
    show_main_menu
    read -r -e -p "Выбор: " choice
    choice=$(echo "${choice:-}" | tr -d ' ')
    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
            read -r -e -p "> " raw_domain
            new_domain=$(validate_domain "${raw_domain:-}") || {
                echo -e "${RED}Некорректный формат домена!${NC}"; sleep 2; continue
            }
            if grep -qxF "$new_domain" "$MASTER_FILE"; then
                echo -e "${YELLOW}Домен уже есть в списке!${NC}"; sleep 1
            else
                insert_user_domain "$new_domain"
                echo -e "${GREEN}Домен '$new_domain' добавлен!${NC}"
                prompt_apply
            fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -r -e -p "> " raw_del_domain
            del_domain=$(validate_domain "${raw_del_domain:-}") || {
                echo -e "${RED}Некорректный формат домена!${NC}"; sleep 2; continue
            }
            if grep -qxF "$del_domain" "$MASTER_FILE"; then
                escaped=$(escape_regex "$del_domain")
                sed -i "/^${escaped}$/d" "$MASTER_FILE"
                rebuild_master_file
                echo -e "${GREEN}Домен '$del_domain' удалён!${NC}"
                prompt_apply
            else
                echo -e "${RED}Домен не найден в списке!${NC}"; sleep 1
            fi
            ;;
        3)
            rebuild_master_file
            echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
            if [ -s "$MASTER_FILE" ]; then cat "$MASTER_FILE"; else echo -e "${YELLOW}Список пуст.${NC}"; fi
            echo -e "${CYAN}---------------------${NC}"
            read -r -p "Нажмите Enter..."
            ;;
        4)
            before_hash=$(canonical_master_hash)
            nano "$MASTER_FILE"
            after_hash=$(canonical_master_hash)
            if [ "$before_hash" != "$after_hash" ]; then
                rebuild_master_file
                prompt_apply
            else
                rebuild_master_file
                echo -e "${YELLOW}Изменений не обнаружено.${NC}"; sleep 1
            fi
            ;;
        5)
            echo -e "\n${YELLOW}Запуск синхронизации...${NC}"
            rebuild_master_file
            if is_warper_active; then
                if patch_kresd; then echo -e "${GREEN}Готово!${NC}"; else echo -e "${RED}Ошибка синхронизации.${NC}"; fi
            else
                sync_domains
                echo -e "${GREEN}Домены синхронизированы. WARPER выключен — патч DNS не применён.${NC}"
            fi
            sleep 1
            ;;
        6) singbox_menu ;;
        7) show_logs ;;
        8) toggle_warper ;;
        9) settings_menu ;;
        10)
            if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                update_warper
            else
                echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                mkdir -p "$DOWNLOAD_DIR"
                download_file_safe "$REPO_URL/download/gemini.txt" "/tmp/gemini.txt" "gemini.txt" || { sleep 2; continue; }
                download_file_safe "$REPO_URL/download/chatgpt.txt" "/tmp/chatgpt.txt" "chatgpt.txt" || { rm -f /tmp/gemini.txt; sleep 2; continue; }
                LISTS_CHANGED=false
                if ! cmp -s /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt" 2>/dev/null; then
                    mv /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt"; LISTS_CHANGED=true
                else rm -f /tmp/gemini.txt; fi
                if ! cmp -s /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt" 2>/dev/null; then
                    mv /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt"; LISTS_CHANGED=true
                else rm -f /tmp/chatgpt.txt; fi
                if [ "$LISTS_CHANGED" = true ]; then
                    update_list_blocks
                    echo -e "${GREEN}Найдены новые домены! Списки обновлены.${NC}"
                    prompt_apply
                else
                    echo -e "${GREEN}Версия и файлы актуальны.${NC}"; sleep 2
                fi
            fi
            ;;
        i|I) ip_ranges_menu ;;
        d|D) doctor; read -r -p "Нажмите Enter..." ;;
        s|S) status_cmd; read -r -p "Нажмите Enter..." ;;
        k|K)
            load_slave_config
            if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] && [ -n "$SLAVE_PASSWORD" ]; then
                echo -e "\n${CYAN}Полный ключ Shadowsocks:${NC} ${YELLOW}${SLAVE_PASSWORD}${NC}"
                echo -e "${CYAN}Сервер:${NC} ${YELLOW}${SLAVE_SERVER}:${SLAVE_PORT}${NC}"
            else
                echo -e "${YELLOW}Режим Slave не активен.${NC}"
            fi
            read -r -p "Нажмите Enter..."
            ;;
        u|U)
            if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                exec bash "$WARPER_DIR/uninstaller.sh"
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
