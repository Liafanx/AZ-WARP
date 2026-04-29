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
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
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

_rebuild_master_tmpfiles=""

_cleanup_rebuild() {
    # shellcheck disable=SC2086
    rm -f $_rebuild_master_tmpfiles
    _rebuild_master_tmpfiles=""
}

rebuild_master_file() {
    local source_file="${1:-$MASTER_FILE}"
    local output_file="${2:-$MASTER_FILE}"
    local tmp user_tmp gemini_tmp chatgpt_tmp
    tmp=$(mktemp)
    user_tmp=$(mktemp)
    gemini_tmp=$(mktemp)
    chatgpt_tmp=$(mktemp)
    _rebuild_master_tmpfiles="$tmp $user_tmp $gemini_tmp $chatgpt_tmp"

    trap '_cleanup_rebuild' RETURN

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
    echo "warp keys source: $([ -f "$WARP_SYSTEM_CONF" ] && echo "$WARP_SYSTEM_CONF" || echo "local")"
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
    if subnet_conflicts "$SUBNET"; then
        echo -e " ${YELLOW}!${NC} Возможный конфликт fake-подсети $SUBNET"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Конфликт fake-подсети не обнаружен"
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

# ===== Обновление =====

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"
    download_file_safe "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "warper.sh" || return 1
    download_file_safe "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "uninstaller.sh" || return 1
    download_file_safe "$REPO_URL/templates/sing-box.service" "/etc/systemd/system/sing-box.service" "sing-box.service" || return 1
    download_file_safe "$REPO_URL/templates/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "warper-autopatch.service" || return 1
    download_file_safe "$REPO_URL/version" "$WARPER_DIR/version" "version" || return 1
    download_file_safe "$REPO_URL/templates/config.json.template" "$SINGBOX_TEMPLATE" "config.json.template" || return 1
    download_file_safe "$REPO_URL/templates/config-slave-master.json.template" "$SLAVE_TEMPLATE" "config-slave-master.json.template" || true
    download_file_safe "$REPO_URL/templates/config-wg.json.template" "$WG_TEMPLATE" "config-wg.json.template" || true
    download_file_safe "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "gemini.txt" || return 1
    download_file_safe "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "chatgpt.txt" || return 1
    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
    systemctl daemon-reload
    systemctl enable warper-autopatch >/dev/null 2>&1
    check_and_sync_warp_keys
    if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
        echo -e "${CYAN}Обновление конфигурации sing-box...${NC}"
        if rebuild_config "$SINGBOX_TEMPLATE"; then
            systemctl restart sing-box
            if ensure_singbox_running; then
                echo -e "${GREEN}Служба sing-box перезапущена.${NC}"
            fi
            systemctl restart kresd@1 >/dev/null 2>&1 || true
        fi
    fi
    rebuild_master_file
    update_list_blocks
    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -r -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
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
                            { echo "SUBNET=$new_subnet"; echo "TUN_IP=$new_tun"; } > "$CONF_FILE"
                            chmod 600 "$CONF_FILE"
                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret...${NC}"
                            export DEBIAN_FRONTEND=noninteractive SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
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
                    if ensure_singbox_running; then echo -e "${GREEN}Запущено.${NC}"; fi
                    sleep 1
                fi
                ;;
            2) if prompt_confirm; then systemctl stop sing-box; echo -e "${YELLOW}Остановлено.${NC}"; sleep 1; fi ;;
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
