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

# === ФУНКЦИИ-ПОМОЩНИКИ ===

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
    source /etc/os-release
    local supported=false
    case "$ID" in
        ubuntu)
            if [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]]; then
                supported=true
            fi
            ;;
        debian)
            if [[ "$VERSION_ID" == "11" || "$VERSION_ID" == "12" ]]; then
                supported=true
            fi
            ;;
    esac
    if [ "$supported" = false ]; then
        echo -e "${RED}Неподдерживаемая ОС: $PRETTY_NAME${NC}"
        echo -e "${YELLOW}Поддерживаются: Ubuntu 22.04/24.04, Debian 11/12${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}ОС: $PRETTY_NAME — поддерживается.${NC}"
}

check_dependencies() {
    local deps=("curl" "wget" "awk" "iptables" "nano" "grep" "sed")
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

# === ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ ===
echo -e "\n${YELLOW}[0/8] Предварительные проверки...${NC}"
check_os
SYSTEM_ARCH=$(detect_arch)
echo -e " - ${GREEN}Архитектура: ${SYSTEM_ARCH}${NC}"
check_dependencies

# === ПРЕДВАРИТЕЛЬНЫЙ ОПРОС ПОЛЬЗОВАТЕЛЯ ===
WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
CONF_FILE="$WARPER_DIR/warper.conf"
SINGBOX_CONF="/etc/sing-box/config.json"

mkdir -p "$WARPER_DIR" "$DOWNLOAD_DIR" "$WGCF_DIR"

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте маркеры вида # --- GEMINI ---
#    Они используются для управления списками.
# ==========================================

# Пользовательские домены:
EOF
fi

ADD_GEMINI="n"
ADD_CHATGPT="n"
SUBNET="198.18.0.0/24"
TUN_IP="198.18.0.1/24"

echo -e "\n${YELLOW}⚙️  Настройка маршрутизации доменов${NC}"

if grep -q "# --- GEMINI ---" "$MASTER_FILE"; then
    echo -e "${GREEN}✔ Домены Gemini уже присутствуют в списке. Пропускаем.${NC}"
else
    while true; do
        read -p "Добавить Gemini в список доменов для WARP? (Y/n): " prompt_gemini < /dev/tty
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

if grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then
    echo -e "${GREEN}✔ Домены ChatGPT уже присутствуют в списке. Пропускаем.${NC}"
else
    while true; do
        read -p "Добавить ChatGPT в список доменов для WARP? (Y/n): " prompt_chatgpt < /dev/tty
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
    read -p "Использовать фейковую подсеть $SUBNET (рекомендуется)? [Y/n]: " prompt_subnet < /dev/tty
    if [[ -z "$prompt_subnet" || "$prompt_subnet" =~ ^[Yy]$ ]]; then
        break
    elif [[ "$prompt_subnet" =~ ^[Nn]$ ]]; then
        while true; do
            read -p "Введите новую подсеть (например 10.10.10.0/24): " custom_subnet < /dev/tty
            if validate_subnet "$custom_subnet"; then
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

echo "SUBNET=\"$SUBNET\"" > "$CONF_FILE"
echo "TUN_IP=\"$TUN_IP\"" >> "$CONF_FILE"
echo -e "${GREEN}✔ Подсеть $SUBNET установлена.${NC}"

echo -e "\n${CYAN}Начинаем процесс установки...${NC}"

# ==============================================================================
echo -e "\n${YELLOW}[1/8] Установка ядра sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "$CURRENT_SB" == "$SB_VERSION" ]; then
        echo -e " - ${GREEN}sing-box актуальной версии ($CURRENT_SB) уже установлен.${NC}"
    else
        echo -e " - ${YELLOW}Обновляем до версии $SB_VERSION...${NC}"
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version $SB_VERSION >/dev/null 2>&1
    fi
else
    echo -e " - ${CYAN}Скачивание и установка пакета sing-box $SB_VERSION...${NC}"
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version $SB_VERSION >/dev/null 2>&1
fi

# ==============================================================================
echo -e "\n${YELLOW}[2/8] Получение ключей Cloudflare WARP...${NC}"
cd "$WGCF_DIR"

if [ ! -f "/usr/local/bin/wgcf" ]; then
    echo -e " - ${CYAN}Скачивание утилиты wgcf (архитектура: ${SYSTEM_ARCH})...${NC}"
    WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${SYSTEM_ARCH}"
    if ! wget -qO wgcf "$WGCF_URL"; then
        echo -e " - ${RED}Ошибка загрузки wgcf для архитектуры ${SYSTEM_ARCH}!${NC}"
        exit 1
    fi
    chmod +x wgcf
    mv wgcf /usr/local/bin/wgcf
fi

# Поиск ключей в корне (для совместимости со старыми установками)
if [ -f "/root/wgcf-profile.conf" ] && [ ! -f "wgcf-profile.conf" ]; then
    echo -e " - ${CYAN}Найден профиль WARP в /root/, переносим...${NC}"
    cp /root/wgcf-account.toml . 2>/dev/null
    cp /root/wgcf-profile.conf . 2>/dev/null
fi

GENERATE_WARP=true
if [ -f "wgcf-profile.conf" ] && grep -q "PrivateKey" wgcf-profile.conf && grep -q "Address" wgcf-profile.conf; then
    echo -e " - ${GREEN}Профиль WARP уже существует. Используем старые ключи.${NC}"
    GENERATE_WARP=false
fi

if [ "$GENERATE_WARP" = true ]; then
    echo -e " - ${CYAN}Регистрация аккаунта Cloudflare WARP (подождите)...${NC}"
    wgcf register --accept-tos > /dev/null
    wgcf generate > /dev/null

    if [ ! -f "wgcf-profile.conf" ]; then
        echo -e "\n${RED}================================================${NC}"
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Файл wgcf-profile.conf не был создан!${NC}"
        echo -e "${YELLOW}Скорее всего Cloudflare заблокировал регистрацию с IP-адреса вашего сервера.${NC}"
        echo -e "${CYAN}Решение:${NC}"
        echo -e "1. Сгенерируйте файл wgcf-profile.conf на своем домашнем ПК (Windows/Mac/Linux)."
        echo -e "2. Положите этот файл в директорию ${YELLOW}${WGCF_DIR}/${NC} на сервере."
        echo -e "3. Запустите скрипт установки заново."
        echo -e "${RED}================================================${NC}"
        exit 1
    fi
fi

WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    echo -e " - ${RED}Ошибка: Не удалось извлечь ключи из файла wgcf-profile.conf.${NC}"
    exit 1
fi
echo -e " - ${GREEN}Ключи успешно извлечены!${NC}"

# ==============================================================================
echo -e "\n${YELLOW}[3/8] Создание конфигурации sing-box (IPv4 only)...${NC}"
echo -e " - ${CYAN}Генерация файла $SINGBOX_CONF с подсетью $SUBNET...${NC}"
mkdir -p /etc/sing-box
cat << EOF > "$SINGBOX_CONF"
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "real-dns", "type": "udp", "server": "1.1.1.1", "detour": "warp" },
      { "tag": "fakeip-dns", "type": "fakeip", "inet4_range": "$SUBNET" }
    ],
    "rules": [
      { "query_type": ["A"], "server": "fakeip-dns" }
    ],
    "independent_cache": true
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "name": "warp-tun",
      "system": false,
      "mtu": 1280,
      "address": [ "$WARP_ADDRESS" ],
      "private_key": "$WARP_PRIVATE_KEY",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0"],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "inbounds": [
    { "type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": 40000, "network": "udp" },
    { "type": "tun", "tag": "tun-in", "interface_name": "singbox-tun", "address": ["$TUN_IP"], "auto_route": false, "strict_route": false, "stack": "system" }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "inbound": "dns-in", "action": "hijack-dns" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "inbound": "tun-in", "outbound": "warp" }
    ],
    "default_domain_resolver": "real-dns",
    "auto_detect_interface": true,
    "final": "direct"
  }
}
EOF

# ==============================================================================
echo -e "\n${YELLOW}[4/8] Загрузка и настройка служб systemd...${NC}"
download_file "$REPO_URL/sing-box.service" "/usr/lib/systemd/system/sing-box.service" "служба sing-box.service" || exit 1
download_file "$REPO_URL/warper-autopatch.service" "/usr/lib/systemd/system/warper-autopatch.service" "служба warper-autopatch.service" || exit 1
echo -e " - ${CYAN}Добавление служб в автозагрузку и запуск...${NC}"
systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box
systemctl enable warper-autopatch > /dev/null 2>&1
sleep 2

# ==============================================================================
echo -e "\n${YELLOW}[5/8] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ]; then
    sed -i '\|10.255.0.0/24|d' "$AZ_INC" 2>/dev/null
    if ! grep -qF "$SUBNET" "$AZ_INC"; then
        echo -e " - ${CYAN}Добавление подсети $SUBNET в include-ips.txt...${NC}"
        echo "$SUBNET" >> "$AZ_INC"
        echo -e " - ${YELLOW}⏳ Запуск doall.sh (обновление конфигурации AntiZapret, от 1 до 5 минут)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        export SYSTEMD_PAGER=""
        bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
        echo -e " - ${GREEN}Конфигурация маршрутов успешно обновлена!${NC}"
    else
        echo -e " - ${GREEN}Подсеть $SUBNET уже присутствует в include-ips.txt.${NC}"
    fi
fi

# ==============================================================================
echo -e "\n${YELLOW}[6/8] Скачивание базовых списков с GitHub...${NC}"
download_file "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "список доменов Gemini" || exit 1
download_file "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "список доменов ChatGPT" || exit 1

# ==============================================================================
echo -e "\n${YELLOW}[7/8] Настройка списка доменов и утилиты WARPER...${NC}"

if [ "$ADD_GEMINI" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов Gemini в мастер-файл...${NC}"
    if ! grep -q "# --- GEMINI ---" "$MASTER_FILE"; then
        echo "# --- GEMINI ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/gemini.txt" >> "$MASTER_FILE"
        echo "# --- END GEMINI ---" >> "$MASTER_FILE"
    fi
fi

if [ "$ADD_CHATGPT" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов ChatGPT в мастер-файл...${NC}"
    if ! grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then
        echo "# --- CHATGPT ---" >> "$MASTER_FILE"
        cat "$DOWNLOAD_DIR/chatgpt.txt" >> "$MASTER_FILE"
        echo "# --- END CHATGPT ---" >> "$MASTER_FILE"
    fi
fi

echo -e " - ${CYAN}Скачивание исполняемых файлов утилиты...${NC}"
download_file "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "утилита warper.sh" || exit 1
download_file "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "деинсталлятор uninstaller.sh" || exit 1
download_file "$REPO_URL/version" "$WARPER_DIR/version" "файл версии" || exit 1

chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper

# ==============================================================================
echo -e "\n${YELLOW}[8/8] Применение правил DNS и Firewall...${NC}"
echo -e " - ${CYAN}Патчинг конфигурации DNS-сервера (kresd)...${NC}"
/usr/local/bin/warper patch > /dev/null 2>&1

echo -e " - ${CYAN}Применение разрешающих правил iptables для туннеля...${NC}"
iptables -I FORWARD -o singbox-tun -j ACCEPT 2>/dev/null
iptables -I FORWARD -i singbox-tun -j ACCEPT 2>/dev/null

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"
echo -e "Для управления доменами введите команду: ${CYAN}warper${NC}"
