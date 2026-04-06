#!/bin/bash

set -uo pipefail

REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
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
            [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] && supported=true
            ;;
        debian)
            [[ "$VERSION_ID" == "11" || "$VERSION_ID" == "12" ]] && supported=true
            ;;
    esac
    if [ "$supported" = false ]; then
        echo -e "${RED}Неподдерживаемая ОС: $PRETTY_NAME${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}ОС: $PRETTY_NAME — поддерживается.${NC}"
}

check_dependencies() {
    local deps=("curl" "wget" "awk" "iptables" "nano" "grep" "sed" "jq")
    local missing=()
    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e " - ${CYAN}Установка недостающих пакетов: ${missing[*]}...${NC}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    fi
    echo -e " - ${GREEN}Все зависимости установлены.${NC}"
}

check_antizapret() {
    if [ ! -x /root/antizapret/doall.sh ] || [ ! -f /root/antizapret/config/include-ips.txt ] || [ ! -f /root/antizapret/setup ]; then
        echo -e "${RED}AntiZapret не найден или установлен не по ожидаемому пути /root/antizapret.${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}AntiZapret найден.${NC}"
}

check_antizapret_warp_outbound() {
    local val
    val=$(grep -E '^WARP_OUTBOUND=' /root/antizapret/setup 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ "$val" = "y" ]; then
        echo -e "${RED}В AntiZapret включен режим WARP_OUTBOUND=y.${NC}"
        echo -e "${YELLOW}WARPER несовместим с этим режимом. Отключите его в AntiZapret и примените конфигурацию перед установкой WARPER.${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}WARP_OUTBOUND в AntiZapret выключен.${NC}"
}

validate_singbox_config() {
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1
}

ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Ошибка: служба sing-box не запустилась.${NC}"
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

read_warp_from_wgcf_profile() {
    local file="$1"
    local address private_key
    [ -f "$file" ] || return 1
    address=$(grep -m 1 '^Address = ' "$file" | awk '{print $3}' | tr -d '\r\n')
    private_key=$(grep -m 1 '^PrivateKey = ' "$file" | awk '{print $3}' | tr -d '\r\n')
    [ -n "$address" ] && [ -n "$private_key" ] || return 1
    echo "$address"
    echo "$private_key"
    return 0
}

read_warp_from_wireguard_conf() {
    local file="$1"
    local address private_key
    [ -f "$file" ] || return 1
    address=$(grep -m 1 '^Address *= *' "$file" | cut -d'=' -f2- | awk -F',' '{print $1}' | xargs)
    private_key=$(grep -m 1 '^PrivateKey *= *' "$file" | cut -d'=' -f2- | xargs)
    [ -n "$address" ] && [ -n "$private_key" ] || return 1
    echo "$address"
    echo "$private_key"
    return 0
}

echo -e "\n${YELLOW}[0/9] Предварительные проверки...${NC}"
check_os
SYSTEM_ARCH=$(detect_arch)
echo -e " - ${GREEN}Архитектура: ${SYSTEM_ARCH}${NC}"
check_dependencies
check_antizapret
check_antizapret_warp_outbound

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
EXCLUDE_FILE="$WARPER_DIR/exclude_domains.txt"
CONF_FILE="$WARPER_DIR/warper.conf"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"

mkdir -p "$WARPER_DIR" "$DOWNLOAD_DIR" "$WGCF_DIR"

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ РЕЖИМА SELECTIVE
# ==========================================

# Пользовательские домены:
EOF
fi

if [ ! -f "$EXCLUDE_FILE" ]; then
cat << 'EOF' > "$EXCLUDE_FILE"
# ==========================================
# СПИСОК ИСКЛЮЧЕНИЙ ДЛЯ РЕЖИМА GLOBAL-EXCEPT
# Всё идёт через WARP, кроме доменов отсюда
# ==========================================

# Пользовательские исключения:
EOF
fi

ADD_GEMINI="n"
ADD_CHATGPT="n"
SUBNET="198.18.0.0/24"
TUN_IP="198.18.0.1/24"
MODE="selective"

echo -e "\n${YELLOW}⚙️  Выбор режима работы${NC}"
while true; do
    echo "1) selective      - Только выбранные домены через WARP"
    echo "2) global-except  - Всё через WARP, кроме исключений"
    read -r -p "Выбор [1-2]: " mode_choice < /dev/tty
    case "${mode_choice:-}" in
        1) MODE="selective"; break ;;
        2) MODE="global-except"; break ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done

if [ "$MODE" = "selective" ]; then
    echo -e "\n${YELLOW}⚙️  Настройка маршрутизации доменов${NC}"

    if grep -q "^# --- GEMINI ---$" "$MASTER_FILE" && grep -q "^# --- END GEMINI ---$" "$MASTER_FILE"; then
        echo -e "${GREEN}✔ Блок Gemini уже присутствует в списке. Пропускаем вопрос.${NC}"
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
                echo -e "${RED}Ошибка: Пожалуйста, введите Y или n.${NC}"
            fi
        done
    fi

    if grep -q "^# --- CHATGPT ---$" "$MASTER_FILE" && grep -q "^# --- END CHATGPT ---$" "$MASTER_FILE"; then
        echo -e "${GREEN}✔ Блок ChatGPT уже присутствует в списке. Пропускаем вопрос.${NC}"
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
                echo -e "${RED}Ошибка: Пожалуйста, введите Y или n.${NC}"
            fi
        done
    fi
else
    echo -e "${CYAN}Выбран режим global-except. Встроенные списки Gemini/ChatGPT использоваться не будут.${NC}"
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
                SUBNET="$custom_subnet"
                TUN_IP=$(calculate_tun_ip "$SUBNET")
                break 2
            else
                echo -e "${RED}Некорректная подсеть.${NC}"
            fi
        done
    else
        echo -e "${RED}Ошибка: Пожалуйста, введите Y или n.${NC}"
    fi
done

{
    echo "SUBNET=$SUBNET"
    echo "TUN_IP=$TUN_IP"
    echo "MODE=$MODE"
} > "$CONF_FILE"
chmod 600 "$CONF_FILE"

echo -e "\n${CYAN}Начинаем процесс установки...${NC}"

echo -e "\n${YELLOW}[1/9] Установка ядра sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "$CURRENT_SB" != "$SB_VERSION" ]; then
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
    else
        echo -e " - ${GREEN}sing-box актуальной версии ($CURRENT_SB) уже установлен.${NC}"
    fi
else
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
fi

echo -e "\n${YELLOW}[2/9] Получение ключей Cloudflare WARP...${NC}"
cd "$WGCF_DIR" || exit 1

WARP_ADDRESS=""
WARP_PRIVATE_KEY=""

if creds=$(read_warp_from_wgcf_profile "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null); then
    WARP_ADDRESS=$(echo "$creds" | sed -n '1p')
    WARP_PRIVATE_KEY=$(echo "$creds" | sed -n '2p')
    echo -e " - ${GREEN}Найден существующий профиль в $WGCF_DIR/wgcf-profile.conf${NC}"
elif creds=$(read_warp_from_wgcf_profile "/root/wgcf-profile.conf" 2>/dev/null); then
    WARP_ADDRESS=$(echo "$creds" | sed -n '1p')
    WARP_PRIVATE_KEY=$(echo "$creds" | sed -n '2p')
    echo -e " - ${GREEN}Найден существующий профиль в /root/wgcf-profile.conf${NC}"
    cp /root/wgcf-profile.conf "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null || true
    cp /root/wgcf-account.toml "$WGCF_DIR/wgcf-account.toml" 2>/dev/null || true
elif creds=$(read_warp_from_wireguard_conf "/etc/wireguard/warp.conf" 2>/dev/null); then
    WARP_ADDRESS=$(echo "$creds" | sed -n '1p')
    WARP_PRIVATE_KEY=$(echo "$creds" | sed -n '2p')
    echo -e " - ${GREEN}Найден существующий профиль в /etc/wireguard/warp.conf${NC}"
fi

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    if [ ! -f "/usr/local/bin/wgcf" ]; then
        WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${SYSTEM_ARCH}"
        wget -qO wgcf "$WGCF_URL" || exit 1
        chmod +x wgcf
        mv wgcf /usr/local/bin/wgcf
    fi

    echo -e " - ${CYAN}Регистрация аккаунта Cloudflare WARP (подождите)...${NC}"
    wgcf register --accept-tos > /dev/null
    wgcf generate > /dev/null

    if [ ! -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        echo -e "${RED}Не удалось создать wgcf-profile.conf${NC}"
        exit 1
    fi

    WARP_ADDRESS=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
    WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
fi

chmod 600 "$WGCF_DIR"/wgcf-profile.conf 2>/dev/null || true
chmod 600 "$WGCF_DIR"/wgcf-account.toml 2>/dev/null || true

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    echo -e "${RED}Не удалось получить WARP-ключи.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}[3/9] Создание конфигурации sing-box...${NC}"
mkdir -p /etc/sing-box
download_file "$REPO_URL/config.json.template" "$SINGBOX_TEMPLATE" "шаблон config.json" || exit 1

sed \
    -e "s|__WARP_ADDRESS__|$WARP_ADDRESS|g" \
    -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
    -e "s|__SUBNET__|$SUBNET|g" \
    -e "s|__TUN_IP__|$TUN_IP|g" \
    "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"

chmod 600 "$SINGBOX_CONF"
validate_singbox_config || exit 1

echo -e "\n${YELLOW}[4/9] Загрузка и настройка systemd...${NC}"
download_file "$REPO_URL/sing-box.service" "/etc/systemd/system/sing-box.service" "служба sing-box.service" || exit 1
download_file "$REPO_URL/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "служба warper-autopatch.service" || exit 1
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
ensure_singbox_running || exit 1
systemctl enable warper-autopatch >/dev/null 2>&1

echo -e "\n${YELLOW}[5/9] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ] && ! grep -qF "$SUBNET" "$AZ_INC"; then
    echo "$SUBNET" >> "$AZ_INC"
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
fi

echo -e "\n${YELLOW}[6/9] Скачивание базовых списков с GitHub...${NC}"
if [ "$MODE" = "selective" ]; then
    download_file "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "список доменов Gemini" || exit 1
    download_file "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "список доменов ChatGPT" || exit 1
else
    echo -e " - ${GREEN}Режим global-except: встроенные списки не требуются.${NC}"
fi

echo -e "\n${YELLOW}[7/9] Настройка доменов и утилиты WARPER...${NC}"
if [ "$MODE" = "selective" ]; then
    if [ "$ADD_GEMINI" = "y" ] && ! grep -q "^# --- GEMINI ---$" "$MASTER_FILE"; then
        echo "# --- GEMINI ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/gemini.txt" >> "$MASTER_FILE"
        echo "# --- END GEMINI ---" >> "$MASTER_FILE"
    fi

    if [ "$ADD_CHATGPT" = "y" ] && ! grep -q "^# --- CHATGPT ---$" "$MASTER_FILE"; then
        echo "# --- CHATGPT ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/chatgpt.txt" >> "$MASTER_FILE"
        echo "# --- END CHATGPT ---" >> "$MASTER_FILE"
    fi
fi

download_file "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "утилита warper.sh" || exit 1
download_file "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "деинсталлятор uninstaller.sh" || exit 1
download_file "$REPO_URL/version" "$WARPER_DIR/version" "файл версии" || exit 1

chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper

echo -e "\n${YELLOW}[8/9] Применение правил DNS и Firewall...${NC}"
/usr/local/bin/warper patch >/dev/null 2>&1 || {
    echo -e "${RED}Ошибка применения патча WARPER к kresd.${NC}"
    exit 1
}
ensure_iptables_rule FORWARD -o singbox-tun
ensure_iptables_rule FORWARD -i singbox-tun

echo -e "\n${YELLOW}[9/9] Финал...${NC}"
echo -e "${GREEN}Установка успешно завершена!${NC}"
echo -e "Команда управления: ${CYAN}warper${NC}"
echo -e "Диагностика: ${CYAN}warper doctor${NC}"
