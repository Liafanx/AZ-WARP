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

check_antizapret() {
    if [ ! -x /root/antizapret/doall.sh ] || [ ! -f /root/antizapret/config/include-ips.txt ]; then
        echo -e "${RED}AntiZapret не найден или установлен не по ожидаемому пути /root/antizapret.${NC}"
        echo -e "${YELLOW}Убедитесь, что основной проект AntiZapret VPN уже установлен перед запуском этого скрипта.${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}AntiZapret найден.${NC}"
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

echo -e "\n${YELLOW}[0/8] Предварительные проверки...${NC}"
check_os
SYSTEM_ARCH=$(detect_arch)
echo -e " - ${GREEN}Архитектура: ${SYSTEM_ARCH}${NC}"
check_dependencies
check_antizapret

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
CONF_FILE="$WARPER_DIR/warper.conf"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"

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

if grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then
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
cd "$WGCF_DIR" || exit 1

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

if [ -f "/root/wgcf-profile.conf" ] && [ ! -f "wgcf-profile.conf" ]; then
    echo -e " - ${CYAN}Найден профиль WARP в /root/, переносим...${NC}"
    cp /root/wgcf-account.toml . 2>/dev/null || true
    cp /root/wgcf-profile.conf . 2>/dev/null || true
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

chmod 600 "$WGCF_DIR"/wgcf-profile.conf 2>/dev/null || true
chmod 600 "$WGCF_DIR"/wgcf-account.toml 2>/dev/null || true

WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    echo -e " - ${RED}Ошибка: Не удалось извлечь ключи из файла wgcf-profile.conf.${NC}"
    exit 1
fi
echo -e " - ${GREEN}Ключи успешно извлечены!${NC}"

echo -e "\n${YELLOW}[3/8] Создание конфигурации sing-box (IPv4 only)...${NC}"
echo -e " - ${CYAN}Загрузка шаблона и генерация $SINGBOX_CONF...${NC}"
mkdir -p /etc/sing-box

download_file "$REPO_URL/config.json.template" "$SINGBOX_TEMPLATE" "шаблон config.json" || exit 1

sed \
    -e "s|__WARP_ADDRESS__|$WARP_ADDRESS|g" \
    -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
    -e "s|__SUBNET__|$SUBNET|g" \
    -e "s|__TUN_IP__|$TUN_IP|g" \
    "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"

chmod 600 "$SINGBOX_CONF"

if ! validate_singbox_config; then
    exit 1
fi

echo -e " - ${GREEN}Конфигурация sing-box создана с подсетью $SUBNET.${NC}"

echo -e "\n${YELLOW}[4/8] Загрузка и настройка служб systemd...${NC}"
download_file "$REPO_URL/sing-box.service" "/etc/systemd/system/sing-box.service" "служба sing-box.service" || exit 1
download_file "$REPO_URL/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "служба warper-autopatch.service" || exit 1
echo -e " - ${CYAN}Добавление служб в автозагрузку и запуск...${NC}"
systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box
if ! ensure_singbox_running; then
    exit 1
fi
systemctl enable warper-autopatch > /dev/null 2>&1
sleep 2

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

echo -e "\n${YELLOW}[6/8] Скачивание базовых списков с GitHub...${NC}"
download_file "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "список доменов Gemini" || exit 1
download_file "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "список доменов ChatGPT" || exit 1

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

echo -e "\n${YELLOW}[8/8] Применение правил DNS и Firewall...${NC}"
echo -e " - ${CYAN}Патчинг конфигурации DNS-сервера (kresd)...${NC}"
if ! /usr/local/bin/warper patch >/dev/null 2>&1; then
    echo -e " - ${RED}Ошибка применения патча WARPER к kresd.${NC}"
    exit 1
fi

echo -e " - ${CYAN}Применение разрешающих правил iptables для туннеля...${NC}"
ensure_iptables_rule FORWARD -o singbox-tun
ensure_iptables_rule FORWARD -i singbox-tun

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"
echo -e "Для управления доменами введите команду: ${CYAN}warper${NC}"
echo -e "Для диагностики используйте: ${CYAN}warper doctor${NC}"