#!/bin/bash

set -uo pipefail

REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.0beta"
SB_VERSION="1.13.5"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}================================================${NC}"
echo -e " 🚀 Установка интеграции AntiZapret + WARP"
echo -e "${CYAN}================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root.${NC}"
  exit 1
fi

download_file() {
    local url="$1" dest="$2" desc="$3"
    echo -e " - ${CYAN}Загрузка ${desc}...${NC}"
    if ! curl -sfSL -o "$dest" "${url}?t=$(date +%s)"; then
        echo -e " - ${RED}Ошибка загрузки: ${desc}${NC}"
        echo -e " - ${RED}URL: ${url}${NC}"
        return 1
    fi
    if [ ! -s "$dest" ]; then
        echo -e " - ${RED}Загруженный файл пуст: ${desc}${NC}"
        return 1
    fi
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

calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура процессора: $arch${NC}" >&2
            echo -e "${YELLOW}Поддерживаются: x86_64, aarch64, armv7l${NC}" >&2
            exit 1
            ;;
    esac
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}Не удалось определить операционную систему.${NC}"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    local supported=false
    case "$ID" in
        ubuntu)
            if [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]]; then
                supported=true
            fi
            ;;
        debian)
            if [[ "$VERSION_ID" == "12" || "$VERSION_ID" == "13" ]]; then
                supported=true
            fi
            ;;
    esac
    if [ "$supported" = false ]; then
        echo -e "${RED}Неподдерживаемая ОС: $PRETTY_NAME${NC}"
        echo -e "${YELLOW}Поддерживаются: Ubuntu 22.04/24.04, Debian 12/13${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}ОС: $PRETTY_NAME — поддерживается.${NC}"
}

check_dependencies() {
    local deps=("curl" "wget" "awk" "iptables" "nano" "grep" "sed" "jq")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e " - ${CYAN}Установка недостающих пакетов: ${missing[*]}...${NC}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    fi
    echo -e " - ${GREEN}Все зависимости установлены.${NC}"
}

check_antizapret() {
    if [ ! -x /root/antizapret/doall.sh ] || [ ! -f /root/antizapret/config/include-ips.txt ]; then
        echo -e "${RED}AntiZapret не найден или установлен не по ожидаемому пути /root/antizapret.${NC}"
        echo -e "${YELLOW}Убедитесь, что основной проект AntiZapret VPN уже установлен перед запуском этого скрипта.${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}AntiZapret найден.${NC}"
}

check_antizapret_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local az_warp
        az_warp=$(grep -E '^ANTIZAPRET_WARP=' "$setup_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$az_warp" = "y" ]; then
            return 0  # ANTIZAPRET_WARP включён
        fi
    fi
    return 1  # ANTIZAPRET_WARP выключен или не найден
}

has_list_block() {
    local list_name="$1"
    local file="$2"
    [ -f "$file" ] && grep -qxF "# --- ${list_name^^} ---" "$file" 2>/dev/null
}

normalize_include_ips() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk 'NF && !seen[$0]++' "$file" > "$tmp" && mv "$tmp" "$file"
}

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
            docker network inspect $ids 2>/dev/null | grep -qF "\"Subnet\": \"$subnet\"" && return 0
        fi
    fi

    return 1
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box не найден для проверки конфигурации.${NC}"
        return 1
    fi
    if ! sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then
        echo -e "${RED}Ошибка: сгенерирован некорректный config.json для sing-box.${NC}"
        return 1
    fi
    return 0
}

ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Ошибка: служба sing-box не запустилась.${NC}"
        echo -e "${YELLOW}Последние логи:${NC}"
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

ensure_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null || \
        iptables -I "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

# Функция поиска существующих WARP-ключей
find_existing_warp_keys() {
    local address="" private_key=""

    if [ -f "/etc/wireguard/warp.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/etc/wireguard/warp.conf" 2>/dev/null; then
        private_key=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        address=$(grep -m 1 '^Address' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$private_key" ]; then
            [ -z "$address" ] && address="172.16.0.2/32"
            [[ ! "$address" =~ / ]] && address="${address}/32"
            echo "$address"
            echo "$private_key"
            echo "/etc/wireguard/warp.conf"
            return 0
        fi
    fi

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$private_key" ] && [ -n "$address" ]; then
            echo "$address"
            echo "$private_key"
            echo "$WGCF_DIR/wgcf-profile.conf"
            return 0
        fi
    fi

    if [ -f "/root/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$private_key" ] && [ -n "$address" ]; then
            echo "$address"
            echo "$private_key"
            echo "/root/wgcf-profile.conf"
            return 0
        fi
    fi

    return 1
}

echo -e "\n${YELLOW}[0/8] Предварительные проверки...${NC}"
check_os
SYSTEM_ARCH=$(detect_arch)
echo -e " - ${GREEN}Архитектура: ${SYSTEM_ARCH}${NC}"
check_dependencies
check_antizapret

# Проверка ANTIZAPRET_WARP
ANTIZAPRET_WARP_ENABLED=false
if check_antizapret_warp; then
    ANTIZAPRET_WARP_ENABLED=true
    echo -e "\n${RED}================================================${NC}"
    echo -e "${RED}⚠️  ВНИМАНИЕ: ANTIZAPRET_WARP=y включён!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}При включённом ANTIZAPRET_WARP=y WARPER не может работать,${NC}"
    echo -e "${YELLOW}так как встроенный WARP AntiZapret конфликтует с WARPER.${NC}"
    echo -e ""
    echo -e "${CYAN}Установка будет продолжена, но:${NC}"
    echo -e " - Службы sing-box и warper-autopatch НЕ будут запущены"
    echo -e " - Патч kresd.conf НЕ будет применён"
    echo -e ""
    echo -e "${YELLOW}Чтобы использовать WARPER, отключите ANTIZAPRET_WARP в /root/antizapret/setup${NC}"
    echo -e "${YELLOW}и выполните: /root/antizapret/down.sh && /root/antizapret/up.sh${NC}"
    echo -e "${RED}================================================${NC}"
    echo ""
    read -r -p "Продолжить установку? (y/N): " continue_install < /dev/tty
    if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Установка отменена.${NC}"
        exit 0
    fi
fi

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
CONF_FILE="$WARPER_DIR/warper.conf"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"

mkdir -p "$WARPER_DIR" "$DOWNLOAD_DIR" "$WGCF_DIR"

# Создаём файл domains.txt только если его нет
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

ADD_GEMINI="n"
ADD_CHATGPT="n"
SUBNET="198.20.0.0/24"
TUN_IP="198.20.0.1/24"

echo -e "\n${YELLOW}⚙️  Настройка маршрутизации доменов${NC}"

if has_list_block "gemini" "$MASTER_FILE"; then
    echo -e "${GREEN}✔ Домены Gemini уже присутствуют в списке. Пропускаем.${NC}"
else
    while true; do
        read -r -p "Добавить Gemini в список доменов для WARP? (Y/n): " prompt_gemini < /dev/tty
        if [[ -z "$prompt_gemini" || "$prompt_gemini" =~ ^[Yy]$ ]]; then
            ADD_GEMINI="y"
            break
        elif [[ "$prompt_gemini" =~ ^[Nn]$ ]]; then
            ADD_GEMINI="n"
            break
        else
            echo -e "${RED}Ошибка: Пожалуйста, введите Y (да) или n (нет).${NC}"
        fi
    done
fi

if has_list_block "chatgpt" "$MASTER_FILE"; then
    echo -e "${GREEN}✔ Домены ChatGPT уже присутствуют в списке. Пропускаем.${NC}"
else
    while true; do
        read -r -p "Добавить ChatGPT в список доменов для WARP? (Y/n): " prompt_chatgpt < /dev/tty
        if [[ -z "$prompt_chatgpt" || "$prompt_chatgpt" =~ ^[Yy]$ ]]; then
            ADD_CHATGPT="y"
            break
        elif [[ "$prompt_chatgpt" =~ ^[Nn]$ ]]; then
            ADD_CHATGPT="n"
            break
        else
            echo -e "${RED}Ошибка: Пожалуйста, введите Y (да) или n (нет).${NC}"
        fi
    done
fi

echo -e "\n${YELLOW}⚙️  Настройка сети${NC}"
while true; do
    read -r -p "Использовать фейковую подсеть $SUBNET (рекомендуется)? [Y/n]: " prompt_subnet < /dev/tty
    if [[ -z "$prompt_subnet" || "$prompt_subnet" =~ ^[Yy]$ ]]; then
        break
    elif [[ "$prompt_subnet" =~ ^[Nn]$ ]]; then
        while true; do
            read -r -p "Введите новую подсеть (например 10.10.10.0/24): " custom_subnet < /dev/tty
            if validate_subnet "$custom_subnet"; then
                if subnet_conflicts "$custom_subnet"; then
                    echo -e "${YELLOW}Предупреждение: подсеть $custom_subnet уже может использоваться локально или Docker.${NC}"
                    read -r -p "Использовать её всё равно? [y/N]: " force_subnet < /dev/tty
                    if [[ ! "$force_subnet" =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi
                SUBNET="$custom_subnet"
                TUN_IP=$(calculate_tun_ip "$SUBNET")
                break 2
            else
                echo -e "${RED}Некорректная подсеть! Ожидается формат X.X.X.0/XX с валидными октетами (0-255) и маской (1-32).${NC}"
            fi
        done
    else
        echo -e "${RED}Ошибка: Пожалуйста, введите Y (да) или n (нет).${NC}"
    fi
done

{
    echo "SUBNET=$SUBNET"
    echo "TUN_IP=$TUN_IP"
} > "$CONF_FILE"
chmod 600 "$CONF_FILE"
echo -e "${GREEN}✔ Подсеть $SUBNET установлена.${NC}"

# ===== Выбор режима работы =====

MODE_CONFIGURED=false
while [ "$MODE_CONFIGURED" = false ]; do

INSTALL_MODE=""
SLAVE_SERVER_INSTALL=""
SLAVE_PORT_INSTALL="8444"
SLAVE_PASSWORD_INSTALL=""

WG_INSTALL_ADDRESS=""
WG_INSTALL_PRIVATE_KEY=""
WG_INSTALL_PUBLIC_KEY=""
WG_INSTALL_PRESHARED_KEY=""
WG_INSTALL_ENDPOINT_HOST=""
WG_INSTALL_ENDPOINT_PORT=""
WG_INSTALL_KEEPALIVE="15"
WG_INSTALL_CONF_FILE=""

echo -e "\n${YELLOW}⚙️  Выбор режима маршрутизации${NC}"
echo -e ""
echo -e " ${GREEN}1.${NC} WARP  — трафик доменов через Cloudflare WARP"
echo -e "    ${CYAN}(стандартный режим, требуются WARP-ключи)${NC}"
echo -e ""
echo -e " ${GREEN}2.${NC} Slave — трафик через внешний донор-сервер (Shadowsocks)"
echo -e "    ${CYAN}(нужен второй сервер с warperslave)${NC}"
echo -e ""
echo -e " ${GREEN}3.${NC} WG    — трафик через WireGuard-соединение"
echo -e "    ${CYAN}(нужен .conf файл от WireGuard-сервера, в папке /root/)${NC}"

while true; do
    read -r -p "Выбор [1-3] (по умолчанию 1): " install_mode_choice < /dev/tty
    if [[ -z "$install_mode_choice" || "$install_mode_choice" == "1" ]]; then
        INSTALL_MODE="warp"
        break
    elif [[ "$install_mode_choice" == "2" ]]; then
        INSTALL_MODE="slave"
        break
    elif [[ "$install_mode_choice" == "3" ]]; then
        INSTALL_MODE="wg"
        break
    else
        echo -e "${RED}Введите 1, 2 или 3.${NC}"
    fi
done

if [ "$INSTALL_MODE" = "slave" ]; then
    echo -e "\n${CYAN}Настройка подключения к донор-серверу${NC}"
    echo -e "${YELLOW}На донор-сервере должен быть установлен warperslave.${NC}"

    while true; do
        printf "IP или домен slave-сервера: "
        IFS= read -r SLAVE_SERVER_INSTALL < /dev/tty
        SLAVE_SERVER_INSTALL=$(echo "$SLAVE_SERVER_INSTALL" | tr -d '\r\n' | xargs)
        if [ -z "$SLAVE_SERVER_INSTALL" ]; then
            echo -e "${RED}Адрес не может быть пустым!${NC}"
            continue
        fi
        if [[ "$SLAVE_SERVER_INSTALL" =~ ^[0-9a-zA-Z._:-]+$ ]]; then
            break
        fi
        echo -e "${RED}Некорректный адрес!${NC}"
    done

    read -r -p "Порт [по умолчанию 8444]: " SLAVE_PORT_INSTALL < /dev/tty
    [ -z "$SLAVE_PORT_INSTALL" ] && SLAVE_PORT_INSTALL="8444"

    while true; do
        read -r -p "Ключ Shadowsocks: " SLAVE_PASSWORD_INSTALL < /dev/tty
        if [ -z "$SLAVE_PASSWORD_INSTALL" ]; then
            echo -e "${RED}Ключ не может быть пустым!${NC}"
            continue
        fi
        break
    done

    echo -e " - ${GREEN}Режим: Slave ($SLAVE_SERVER_INSTALL:$SLAVE_PORT_INSTALL)${NC}"
    MODE_CONFIGURED=true

elif [ "$INSTALL_MODE" = "wg" ]; then
    echo -e "\n${CYAN}Настройка WireGuard-соединения${NC}"

    _is_valid_wg_conf() {
        local file="$1"
        [ -f "$file" ] || return 1
        grep -q '^\[Peer\]' "$file" || return 1
        grep -q '^Endpoint' "$file" || return 1
        grep -q '^PublicKey' "$file" || return 1
        grep -q 'engage.cloudflareclient.com' "$file" 2>/dev/null && return 1
        grep -q '162.159.192.1' "$file" 2>/dev/null && return 1
        grep -q '162.159.193.1' "$file" 2>/dev/null && return 1
        grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$file" 2>/dev/null && return 1
        return 0
    }

    _parse_wg_conf_install() {
        local file="$1"
        WG_INSTALL_CONF_FILE="$file"
        WG_INSTALL_PRIVATE_KEY=$(grep -m 1 '^PrivateKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        WG_INSTALL_ADDRESS=$(grep -m 1 '^Address' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        WG_INSTALL_ADDRESS="${WG_INSTALL_ADDRESS%%,*}"
        WG_INSTALL_ADDRESS=$(echo "$WG_INSTALL_ADDRESS" | tr -d ' ')
        WG_INSTALL_PUBLIC_KEY=$(grep -m 1 '^PublicKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        WG_INSTALL_PRESHARED_KEY=$(grep -m 1 '^PresharedKey' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        local ep
        ep=$(grep -m 1 '^Endpoint' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        WG_INSTALL_ENDPOINT_HOST="${ep%:*}"
        WG_INSTALL_ENDPOINT_PORT="${ep##*:}"
        local ka
        ka=$(grep -m 1 '^PersistentKeepalive' "$file" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        WG_INSTALL_KEEPALIVE="${ka:-15}"

        local missing=()
        [ -z "$WG_INSTALL_ADDRESS" ]       && missing+=("Address")
        [ -z "$WG_INSTALL_PRIVATE_KEY" ]   && missing+=("PrivateKey")
        [ -z "$WG_INSTALL_PUBLIC_KEY" ]    && missing+=("PublicKey")
        [ -z "$WG_INSTALL_PRESHARED_KEY" ] && missing+=("PresharedKey")
        [ -z "$WG_INSTALL_ENDPOINT_HOST" ] && missing+=("Endpoint")

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${RED}В файле отсутствуют обязательные параметры: ${missing[*]}${NC}"
            return 1
        fi
        return 0
    }

    WG_SELECTED=false
    while [ "$WG_SELECTED" = false ]; do
        echo -e "\n${CYAN}Поиск WireGuard-конфигов в /root/ и /root/warper/...${NC}"
        wg_files=()
        wg_f=""
        for wg_dir in /root /root/warper; do
            if [ -d "$wg_dir" ]; then
                while IFS= read -r -d '' wg_f; do
                    if _is_valid_wg_conf "$wg_f"; then
                        wg_files+=("$wg_f")
                    fi
                done < <(find "$wg_dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
            fi
        done

        if [ ${#wg_files[@]} -gt 0 ]; then
            echo -e "${GREEN}Найдено конфигов: ${#wg_files[@]}${NC}"
            wi=1
            for wf in "${wg_files[@]}"; do
                wep=""
                wep=$(grep -m 1 '^Endpoint' "$wf" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                echo -e " ${GREEN}${wi}.${NC} ${YELLOW}${wf}${NC} (${CYAN}${wep}${NC})"
                ((wi++))
            done
            echo -e ""
            echo -e " ${CYAN}M.${NC} Ввести данные вручную"
            echo -e " ${CYAN}R.${NC} Обновить список"
            echo -e " ${CYAN}B.${NC} Вернуться к выбору режима"

            read -r -p "Выбор: " wg_choice < /dev/tty
            case "$wg_choice" in
                [0-9]*)
                    if (( wg_choice >= 1 && wg_choice <= ${#wg_files[@]} )); then
                        if _parse_wg_conf_install "${wg_files[$((wg_choice-1))]}"; then
                            WG_SELECTED=true
                            echo -e "${GREEN}Выбран: ${wg_files[$((wg_choice-1))]}${NC}"
                        else
                            echo -e "${YELLOW}Выберите другой файл или введите данные вручную.${NC}"
                        fi
                    else
                        echo -e "${RED}Неверный номер.${NC}"
                    fi
                    ;;
                m|M)
                    echo -e "\n${CYAN}Ввод данных WG вручную${NC}"
                    while true; do
                        read -r -p "Endpoint (IP:порт): " ep_in < /dev/tty
                        if [[ "$ep_in" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
                            WG_INSTALL_ENDPOINT_HOST="${ep_in%:*}"
                            WG_INSTALL_ENDPOINT_PORT="${ep_in##*:}"
                            break
                        fi
                        echo -e "${RED}Формат: IP:порт${NC}"
                    done
                    while true; do
                        read -r -p "Address (например 172.28.8.3/32): " WG_INSTALL_ADDRESS < /dev/tty
                        [ -n "$WG_INSTALL_ADDRESS" ] && break
                        echo -e "${RED}Address обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PrivateKey: " WG_INSTALL_PRIVATE_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PRIVATE_KEY" ] && break
                        echo -e "${RED}PrivateKey обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PublicKey: " WG_INSTALL_PUBLIC_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PUBLIC_KEY" ] && break
                        echo -e "${RED}PublicKey обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PresharedKey: " WG_INSTALL_PRESHARED_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PRESHARED_KEY" ] && break
                        echo -e "${RED}PresharedKey обязателен!${NC}"
                    done
                    read -r -p "PersistentKeepalive [15]: " WG_INSTALL_KEEPALIVE < /dev/tty
                    WG_INSTALL_KEEPALIVE="${WG_INSTALL_KEEPALIVE:-15}"
                    WG_INSTALL_CONF_FILE="manual"
                    WG_SELECTED=true
                    ;;
                r|R)
                    continue
                    ;;
                b|B)
                    echo -e "${YELLOW}Возврат к выбору режима.${NC}"
                    break
                    ;;
                *)
                    echo -e "${RED}Неверный выбор.${NC}"
                    ;;
            esac

        else
            echo -e "${YELLOW}WireGuard-конфиги не найдены.${NC}"
            echo -e ""
            echo -e " ${GREEN}1.${NC} Ввести данные вручную"
            echo -e " ${CYAN}2.${NC} Положите .conf в /root/ и нажмите 2 для обновления"
            echo -e " ${CYAN}0.${NC} Выбрать другой режим"

            read -r -p "Выбор: " wg_choice < /dev/tty
            case "$wg_choice" in
                1)
                    echo -e "\n${CYAN}Ввод данных WG вручную${NC}"
                    while true; do
                        read -r -p "Endpoint (IP:порт): " ep_in < /dev/tty
                        if [[ "$ep_in" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
                            WG_INSTALL_ENDPOINT_HOST="${ep_in%:*}"
                            WG_INSTALL_ENDPOINT_PORT="${ep_in##*:}"
                            break
                        fi
                        echo -e "${RED}Формат: IP:порт${NC}"
                    done
                    while true; do
                        read -r -p "Address (например 172.28.8.3/32): " WG_INSTALL_ADDRESS < /dev/tty
                        [ -n "$WG_INSTALL_ADDRESS" ] && break
                        echo -e "${RED}Address обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PrivateKey: " WG_INSTALL_PRIVATE_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PRIVATE_KEY" ] && break
                        echo -e "${RED}PrivateKey обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PublicKey: " WG_INSTALL_PUBLIC_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PUBLIC_KEY" ] && break
                        echo -e "${RED}PublicKey обязателен!${NC}"
                    done
                    while true; do
                        read -r -p "PresharedKey: " WG_INSTALL_PRESHARED_KEY < /dev/tty
                        [ -n "$WG_INSTALL_PRESHARED_KEY" ] && break
                        echo -e "${RED}PresharedKey обязателен!${NC}"
                    done
                    read -r -p "PersistentKeepalive [15]: " WG_INSTALL_KEEPALIVE < /dev/tty
                    WG_INSTALL_KEEPALIVE="${WG_INSTALL_KEEPALIVE:-15}"
                    WG_INSTALL_CONF_FILE="manual"
                    WG_SELECTED=true
                    ;;
                2)
                    echo -e "${YELLOW}Положите .conf файл и нажмите Enter...${NC}"
                    read -r -p "" < /dev/tty
                    ;;
                0)
                    echo -e "${YELLOW}Возврат к выбору режима.${NC}"
                    break
                    ;;
                *)
                    echo -e "${RED}Неверный выбор.${NC}"
                    ;;
            esac
        fi
    done

    if [ "$WG_SELECTED" = false ]; then
        continue
    fi

    echo -e " - ${GREEN}Режим: WG ($WG_INSTALL_ENDPOINT_HOST:$WG_INSTALL_ENDPOINT_PORT)${NC}"
    MODE_CONFIGURED=true

else
    MODE_CONFIGURED=true
fi

done

echo -e "\n${CYAN}Начинаем процесс установки...${NC}"

echo -e "\n${YELLOW}[1/8] Установка ядра sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "$CURRENT_SB" == "$SB_VERSION" ]; then
        echo -e " - ${GREEN}sing-box актуальной версии ($CURRENT_SB) уже установлен.${NC}"
    else
        echo -e " - ${YELLOW}Обновляем до версии $SB_VERSION...${NC}"
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
    fi
else
    echo -e " - ${CYAN}Скачивание и установка пакета sing-box $SB_VERSION...${NC}"
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
fi

echo -e "\n${YELLOW}[2/8] Получение ключей Cloudflare WARP...${NC}"

WARP_ADDRESS=""
WARP_PRIVATE_KEY=""
WARP_SOURCE=""

if [ "$INSTALL_MODE" = "slave" ]; then
    echo -e " - ${CYAN}Режим Slave — ключи WARP не требуются для установки.${NC}"
    echo -e " - ${CYAN}Они будут запрошены позже при переключении на режим WARP.${NC}"

elif [ "$INSTALL_MODE" = "wg" ]; then
    echo -e " - ${CYAN}Режим WG — ключи WARP не требуются.${NC}"
    echo -e " - ${CYAN}Данные WireGuard уже получены на предыдущем шаге.${NC}"

else
    # === Режим WARP ===
    echo -e "\n${YELLOW}Выбор источника WARP-ключей:${NC}"

    warp_sources=()
    warp_labels=()
    widx=1

    if [ -f "/etc/wireguard/warp.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/etc/wireguard/warp.conf" 2>/dev/null; then
        sys_pk=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        sys_addr=$(grep -m 1 '^Address' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ]; then
            warp_sources+=("system")
            warp_labels+=("/etc/wireguard/warp.conf (${sys_addr:-без адреса}) — рекомендуется")
            echo -e " ${GREEN}${widx}.${NC} ${warp_labels[$((widx-1))]}"
            ((widx++))
        fi
    fi

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        wgcf_addr=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ]; then
            warp_sources+=("wgcf")
            warp_labels+=("$WGCF_DIR/wgcf-profile.conf ($wgcf_addr)")
            echo -e " ${CYAN}${widx}.${NC} ${warp_labels[$((widx-1))]}"
            ((widx++))
        fi
    fi

    if [ -f "/root/wgcf-profile.conf" ] && grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        root_addr=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$root_pk" ]; then
            warp_sources+=("root")
            warp_labels+=("/root/wgcf-profile.conf ($root_addr)")
            echo -e " ${CYAN}${widx}.${NC} ${warp_labels[$((widx-1))]}"
            ((widx++))
        fi
    fi

    warp_sources+=("generate")
    warp_labels+=("Сгенерировать новый ключ WARP")
    echo -e " ${YELLOW}${widx}.${NC} ${warp_labels[$((widx-1))]}"

    echo -e ""
    read -r -p "Выбор [по умолчанию 1]: " warp_key_choice < /dev/tty
    [ -z "$warp_key_choice" ] && warp_key_choice="1"

    if ! [[ "$warp_key_choice" =~ ^[0-9]+$ ]] || (( warp_key_choice < 1 || warp_key_choice > ${#warp_sources[@]} )); then
        echo -e "${YELLOW}Выбран вариант по умолчанию (1).${NC}"
        warp_key_choice="1"
    fi

    warp_selected="${warp_sources[$((warp_key_choice-1))]}"

    case "$warp_selected" in
        system)
            WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            WARP_ADDRESS=$(grep -m 1 '^Address' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            [ -z "$WARP_ADDRESS" ] && WARP_ADDRESS="172.16.0.2/32"
            [[ ! "$WARP_ADDRESS" =~ / ]] && WARP_ADDRESS="${WARP_ADDRESS}/32"
            WARP_SOURCE="/etc/wireguard/warp.conf"
            echo -e " - ${GREEN}Используем ключи из /etc/wireguard/warp.conf${NC}"
            ;;
        wgcf)
            WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            WARP_ADDRESS=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            WARP_SOURCE="$WGCF_DIR/wgcf-profile.conf"
            echo -e " - ${GREEN}Используем ключи из $WGCF_DIR/wgcf-profile.conf${NC}"
            ;;
        root)
            WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            WARP_ADDRESS=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            WARP_SOURCE="/root/wgcf-profile.conf"
            echo -e " - ${GREEN}Используем ключи из /root/wgcf-profile.conf${NC}"
            ;;
        generate)
            echo -e " - ${CYAN}Попытка генерации нового ключа WARP...${NC}"
            mkdir -p "$WGCF_DIR"
            cd "$WGCF_DIR" || { echo -e "${RED}Не удалось перейти в $WGCF_DIR${NC}"; exit 1; }

            if [ ! -f "/usr/local/bin/wgcf" ]; then
                echo -e " - ${CYAN}Скачивание wgcf (${SYSTEM_ARCH})...${NC}"
                WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${SYSTEM_ARCH}"
                if ! wget -qO wgcf "$WGCF_URL"; then
                    echo -e "${RED}Ошибка загрузки wgcf!${NC}"
                    exit 1
                fi
                chmod +x wgcf
                mv wgcf /usr/local/bin/wgcf
            fi

            echo -e " - ${CYAN}Регистрация нового WARP-аккаунта...${NC}"
            /usr/local/bin/wgcf register --accept-tos > /dev/null 2>&1 || true

            echo -e " - ${CYAN}Генерация конфигурации...${NC}"
            /usr/local/bin/wgcf generate > /dev/null 2>&1 || true

            if [ ! -f "wgcf-profile.conf" ]; then
                echo -e "${RED}================================================${NC}"
                echo -e "${RED}Файл wgcf-profile.conf не создан!${NC}"
                echo -e "${YELLOW}Cloudflare заблокировал регистрацию с этого IP.${NC}"
                echo -e "${CYAN}Решение:${NC}"
                echo -e "1. Сгенерируйте wgcf-profile.conf на домашнем ПК"
                echo -e "2. Положите его в: ${YELLOW}${WGCF_DIR}/${NC}"
                echo -e "3. Запустите установку заново"
                echo -e "${RED}================================================${NC}"
                exit 1
            fi

            chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true

            WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            WARP_SOURCE="$WGCF_DIR/wgcf-profile.conf"

            if [ -z "$WARP_PRIVATE_KEY" ] || [ -z "$WARP_ADDRESS" ]; then
                echo -e "${RED}Не удалось извлечь ключи из сгенерированного файла.${NC}"
                echo -e "${YELLOW}Содержимое файла:${NC}"
                cat wgcf-profile.conf 2>/dev/null || true
                exit 1
            fi

            echo -e " - ${GREEN}Новый ключ WARP успешно сгенерирован!${NC}"
            ;;
    esac

    if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
        echo -e " - ${RED}Ошибка: Не удалось извлечь ключи WARP.${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}Ключи получены! Источник: $WARP_SOURCE${NC}"
fi

echo -e "\n${YELLOW}[3/8] Создание конфигурации sing-box (IPv4 only)...${NC}"
echo -e " - ${CYAN}Загрузка шаблона и генерация $SINGBOX_CONF...${NC}"
mkdir -p /etc/sing-box

if [ "$INSTALL_MODE" = "slave" ]; then
    download_file "$REPO_URL/templates/config-slave-master.json.template" "$WARPER_DIR/config-slave-master.json.template" "шаблон slave-master" || exit 1

    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__SLAVE_SERVER__|$SLAVE_SERVER_INSTALL|g" \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT_INSTALL|g" \
        -e "s|__SLAVE_PASSWORD__|$SLAVE_PASSWORD_INSTALL|g" \
        "$WARPER_DIR/config-slave-master.json.template" > "$SINGBOX_CONF"

    # Сохраняем slave-настройки
    {
        echo "OUTBOUND_MODE=slave"
        echo "SLAVE_SERVER=$SLAVE_SERVER_INSTALL"
        echo "SLAVE_PORT=$SLAVE_PORT_INSTALL"
        echo "SLAVE_PASSWORD=$SLAVE_PASSWORD_INSTALL"
    } > "$WARPER_DIR/slave_mode.conf"
    chmod 600 "$WARPER_DIR/slave_mode.conf"
    
elif [ "$INSTALL_MODE" = "wg" ]; then
    download_file "$REPO_URL/templates/config-wg.json.template" "$WARPER_DIR/config-wg.json.template" "шаблон WG" || exit 1
    
    tmp_wg=$(mktemp)
    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__WG_ADDRESS__|$WG_INSTALL_ADDRESS|g" \
        -e "s|__WG_PRIVATE_KEY__|$WG_INSTALL_PRIVATE_KEY|g" \
        -e "s|__WG_PUBLIC_KEY__|$WG_INSTALL_PUBLIC_KEY|g" \
        -e "s|__WG_ENDPOINT_HOST__|$WG_INSTALL_ENDPOINT_HOST|g" \
        -e "s|__WG_ENDPOINT_PORT__|$WG_INSTALL_ENDPOINT_PORT|g" \
        -e "s|__WG_KEEPALIVE__|$WG_INSTALL_KEEPALIVE|g" \
        "$WARPER_DIR/config-wg.json.template" > "$tmp_wg"

    if [ -z "$WG_INSTALL_PRESHARED_KEY" ]; then
        sed -i '/"pre_shared_key"/d' "$tmp_wg"
    else
        sed -i "s|__WG_PRESHARED_KEY__|$WG_INSTALL_PRESHARED_KEY|g" "$tmp_wg"
    fi

    mv "$tmp_wg" "$SINGBOX_CONF"

    # Сохраняем WG-настройки
    {
        echo "OUTBOUND_MODE=wg"
        echo "SLAVE_SERVER="
        echo "SLAVE_PORT=8444"
        echo "SLAVE_PASSWORD="
    } > "$WARPER_DIR/slave_mode.conf"
    chmod 600 "$WARPER_DIR/slave_mode.conf"

    {
        echo "WG_CONF_FILE=$WG_INSTALL_CONF_FILE"
        echo "WG_ADDRESS=$WG_INSTALL_ADDRESS"
        echo "WG_PRIVATE_KEY=$WG_INSTALL_PRIVATE_KEY"
        echo "WG_PUBLIC_KEY=$WG_INSTALL_PUBLIC_KEY"
        echo "WG_PRESHARED_KEY=$WG_INSTALL_PRESHARED_KEY"
        echo "WG_ENDPOINT_HOST=$WG_INSTALL_ENDPOINT_HOST"
        echo "WG_ENDPOINT_PORT=$WG_INSTALL_ENDPOINT_PORT"
        echo "WG_KEEPALIVE=$WG_INSTALL_KEEPALIVE"
    } > "$WARPER_DIR/wg_mode.conf"
    chmod 600 "$WARPER_DIR/wg_mode.conf"
else
    download_file "$REPO_URL/templates/config.json.template" "$SINGBOX_TEMPLATE" "шаблон config.json" || exit 1

    sed \
        -e "s|__WARP_ADDRESS__|$WARP_ADDRESS|g" \
        -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"

    # Сохраняем warp-режим
    {
        echo "OUTBOUND_MODE=warp"
        echo "SLAVE_SERVER="
        echo "SLAVE_PORT=8444"
        echo "SLAVE_PASSWORD="
    } > "$WARPER_DIR/slave_mode.conf"
    chmod 600 "$WARPER_DIR/slave_mode.conf"
fi

chmod 600 "$SINGBOX_CONF"

if ! validate_singbox_config; then
    exit 1
fi

echo -e " - ${GREEN}Конфигурация sing-box создана с подсетью $SUBNET.${NC}"

echo -e "\n${YELLOW}[4/8] Загрузка и настройка служб systemd...${NC}"
download_file "$REPO_URL/templates/sing-box.service" "/etc/systemd/system/sing-box.service" "служба sing-box.service" || exit 1
download_file "$REPO_URL/templates/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "служба warper-autopatch.service" || exit 1
systemctl daemon-reload

if [ "$ANTIZAPRET_WARP_ENABLED" = true ]; then
    echo -e " - ${YELLOW}ANTIZAPRET_WARP=y — службы НЕ будут запущены.${NC}"
else
    echo -e " - ${CYAN}Добавление служб в автозагрузку и запуск...${NC}"
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box
    if ! ensure_singbox_running; then
        exit 1
    fi
    systemctl enable warper-autopatch > /dev/null 2>&1
    sleep 2
fi

echo -e "\n${YELLOW}[5/8] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ]; then
    # Удаляем старую подсеть если была
    sed -i '\|198.18.0.0/24|d' "$AZ_INC" 2>/dev/null
    if ! grep -qxF "$SUBNET" "$AZ_INC"; then
        echo -e " - ${CYAN}Добавление подсети $SUBNET в include-ips.txt...${NC}"
        echo "$SUBNET" >> "$AZ_INC"
        normalize_include_ips "$AZ_INC"
        echo -e " - ${YELLOW}⏳ Запуск doall.sh (обновление конфигурации AntiZapret, от 1 до 5 минут)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        export SYSTEMD_PAGER=""
        bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
        echo -e " - ${GREEN}Конфигурация маршрутов успешно обновлена!${NC}"
    else
        normalize_include_ips "$AZ_INC"
        echo -e " - ${GREEN}Подсеть $SUBNET уже присутствует в include-ips.txt.${NC}"
    fi
fi

echo -e "\n${YELLOW}[6/8] Скачивание базовых списков с GitHub...${NC}"
download_file "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "список доменов Gemini" || exit 1
download_file "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "список доменов ChatGPT" || exit 1

echo -e "\n${YELLOW}[7/8] Настройка списка доменов и утилиты WARPER...${NC}"

if [ "$ADD_GEMINI" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов Gemini в мастер-файл...${NC}"
    if ! has_list_block "gemini" "$MASTER_FILE"; then
        echo "# --- GEMINI ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/gemini.txt" >> "$MASTER_FILE"
        echo "# --- END GEMINI ---" >> "$MASTER_FILE"
    fi
fi

if [ "$ADD_CHATGPT" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов ChatGPT в мастер-файл...${NC}"
    if ! has_list_block "chatgpt" "$MASTER_FILE"; then
        echo "# --- CHATGPT ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/chatgpt.txt" >> "$MASTER_FILE"
        echo "# --- END CHATGPT ---" >> "$MASTER_FILE"
    fi
fi

echo -e " - ${CYAN}Скачивание исполняемых файлов утилиты...${NC}"
download_file "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "утилита warper.sh" || exit 1
download_file "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "деинсталлятор uninstaller.sh" || exit 1
download_file "$REPO_URL/version" "$WARPER_DIR/version" "файл версии" || exit 1
download_file "$REPO_URL/templates/config-slave-master.json.template" "$WARPER_DIR/config-slave-master.json.template" "шаблон slave-master" || exit 1
download_file "$REPO_URL/templates/config.json.template" "$SINGBOX_TEMPLATE" "шаблон config.json (WARP)" || exit 1
download_file "$REPO_URL/templates/config-wg.json.template" "$WARPER_DIR/config-wg.json.template" "шаблон WG" || exit 1

# Создаём ip-ranges.txt если не существует
if [ ! -f "$WARPER_DIR/ip-ranges.txt" ]; then
cat << 'IPEOF' > "$WARPER_DIR/ip-ranges.txt"
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

chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper

echo -e "\n${YELLOW}[8/8] Применение правил DNS и Firewall...${NC}"

if [ "$ANTIZAPRET_WARP_ENABLED" = true ]; then
    echo -e " - ${YELLOW}ANTIZAPRET_WARP=y — патч kresd.conf НЕ будет применён.${NC}"
    echo -e " - ${YELLOW}Правила iptables НЕ будут применены.${NC}"
else
    echo -e " - ${CYAN}Патчинг конфигурации DNS-сервера (kresd)...${NC}"
    if ! /usr/local/bin/warper patch >/dev/null 2>&1; then
        echo -e " - ${RED}Ошибка применения патча WARPER к kresd.${NC}"
        exit 1
    fi

    echo -e " - ${CYAN}Применение разрешающих правил iptables для туннеля...${NC}"
    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
fi

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"

if [ "$ANTIZAPRET_WARP_ENABLED" = true ]; then
    echo -e "${RED}⚠️  WARPER установлен, но НЕ АКТИВЕН из-за ANTIZAPRET_WARP=y${NC}"
    echo -e "${YELLOW}Для активации:${NC}"
    echo -e "1. Установите ANTIZAPRET_WARP=n в /root/antizapret/setup"
    echo -e "2. Выполните: /root/antizapret/down.sh"
    echo -e "3. Выполните: /root/antizapret/up.sh"
    echo -e "4. Выполните: warper"
    echo -e "   и выберите пункт 8 для включения WARPER"
else
    echo -e "Для управления доменами введите команду: ${CYAN}warper${NC}"
fi

echo -e "Для диагностики используйте: ${CYAN}warper doctor${NC}"
echo -e "Для краткого статуса используйте: ${CYAN}warper status${NC}"
