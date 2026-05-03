#!/bin/bash

set -uo pipefail

REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
SB_VERSION="1.13.11"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SLAVE_DIR="/root/warperslave"
SLAVE_CONF="$SLAVE_DIR/slave.conf"
SINGBOX_SLAVE_CONF="/etc/sing-box-slave/config.json"
SERVICE_NAME="sing-box-slave"
DEFAULT_PORT=8444
WGCF_DIR="$SLAVE_DIR/wgcf"

echo -e "${CYAN}================================================${NC}"
echo -e " 🚀 Установка WARPERSLAVE (сервер-донор)"
echo -e "${CYAN}================================================${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите скрипт от имени root.${NC}"
    exit 1
fi

# ===== Функции =====

download_file() {
    local url="$1" dest="$2" desc="$3"
    echo -e " - ${CYAN}Загрузка ${desc}...${NC}"
    if ! curl -sfSL -o "$dest" "${url}?t=$(date +%s)"; then
        echo -e " - ${RED}Ошибка загрузки: ${desc}${NC}"
        return 1
    fi
    if [ ! -s "$dest" ]; then
        echo -e " - ${RED}Загруженный файл пуст: ${desc}${NC}"
        return 1
    fi
    return 0
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура: $arch${NC}" >&2
            exit 1
            ;;
    esac
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}Не удалось определить ОС.${NC}"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    local supported=false
    case "$ID" in
        ubuntu)
            local major
            major=$(echo "$VERSION_ID" | cut -d. -f1)
            if (( major >= 20 )); then
                supported=true
            fi
            ;;
        debian)
            if (( VERSION_ID >= 10 )); then
                supported=true
            fi
            ;;
    esac
    if [ "$supported" = false ]; then
        echo -e "${RED}Неподдерживаемая ОС: $PRETTY_NAME${NC}"
        echo -e "${YELLOW}Поддерживаются: Ubuntu 20.04+, Debian 10+${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}ОС: $PRETTY_NAME — поддерживается.${NC}"
}

check_dependencies() {
    local deps=("curl" "wget" "jq" "iptables" "openssl")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e " - ${CYAN}Установка зависимостей: ${missing[*]}...${NC}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
    fi
    echo -e " - ${GREEN}Все зависимости установлены.${NC}"
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then return 1; fi
    if (( port < 1 || port > 65535 )); then return 1; fi
    return 0
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

ensure_port_open() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT
}

remove_port_rules() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT
}

is_public_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
    (( o1 == 10 )) && return 1
    (( o1 == 127 )) && return 1
    (( o1 == 169 && o2 == 254 )) && return 1
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 1
    (( o1 == 192 && o2 == 168 )) && return 1
    (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 1
    (( o1 == 198 && (o2 == 18 || o2 == 19) )) && return 1
    (( o1 >= 224 )) && return 1
    return 0
}

get_local_public_ipv4() {
    local ip candidate

    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }
    }')
    if [ -n "$ip" ] && is_public_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    while IFS= read -r candidate; do
        if is_public_ipv4 "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)

    return 1
}

find_warp_keys() {
    local address="" private_key=""

    # Приоритет 1: /etc/wireguard/warp.conf
    if [ -f "/etc/wireguard/warp.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/etc/wireguard/warp.conf" 2>/dev/null; then
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
    fi

    # Приоритет 2: Локальный wgcf-profile
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
            address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            if [ -n "$private_key" ] && [ -n "$address" ]; then
                echo "$address"
                echo "$private_key"
                echo "$WGCF_DIR/wgcf-profile.conf"
                return 0
            fi
        fi
    fi

    # Приоритет 3: /root/wgcf-profile.conf
    if [ -f "/root/wgcf-profile.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
            address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            if [ -n "$private_key" ] && [ -n "$address" ]; then
                echo "$address"
                echo "$private_key"
                echo "/root/wgcf-profile.conf"
                return 0
            fi
        fi
    fi

    return 1
}

generate_warp_keys() {
    local system_arch="$1"
    local wgcf_dir="$SLAVE_DIR/wgcf"
    mkdir -p "$wgcf_dir"
    cd "$wgcf_dir" || exit 1

    if [ ! -f "/usr/local/bin/wgcf" ]; then
        echo -e " - ${CYAN}Скачивание wgcf (${system_arch})...${NC}"
        local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${system_arch}"
        if ! wget -qO wgcf "$wgcf_url"; then
            echo -e " - ${RED}Ошибка загрузки wgcf!${NC}"
            return 1
        fi
        chmod +x wgcf
        mv wgcf /usr/local/bin/wgcf
    fi

    echo -e " - ${CYAN}Регистрация WARP...${NC}"
    /usr/local/bin/wgcf register --accept-tos > /dev/null 2>&1
    /usr/local/bin/wgcf generate > /dev/null 2>&1

    if [ ! -f "wgcf-profile.conf" ]; then
        echo -e "${RED}================================================${NC}"
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: wgcf-profile.conf не создан!${NC}"
        echo -e "${YELLOW}Cloudflare мог заблокировать регистрацию с этого IP.${NC}"
        echo -e "${CYAN}Решение:${NC}"
        echo -e "1. Сгенерируйте wgcf-profile.conf на домашнем ПК."
        echo -e "2. Положите в ${YELLOW}${wgcf_dir}/${NC}"
        echo -e "3. Запустите установку заново."
        echo -e "${RED}================================================${NC}"
        return 1
    fi

    chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true
    return 0
}

# ===== Начало установки =====

echo -e "\n${YELLOW}[0/7] Предварительные проверки...${NC}"
check_os
SYSTEM_ARCH=$(detect_arch)
echo -e " - ${GREEN}Архитектура: ${SYSTEM_ARCH}${NC}"
check_dependencies

# Проверяем нет ли уже установленного slave
if [ -f "$SLAVE_CONF" ]; then
    echo -e "\n${YELLOW}Обнаружена существующая установка warperslave.${NC}"
    while true; do
        read -r -p "Переустановить? (y/N): " reinstall < /dev/tty
        if [[ -z "$reinstall" || "$reinstall" =~ ^[Nn]$ ]]; then
            echo -e "${GREEN}Отмена.${NC}"
            exit 0
        elif [[ "$reinstall" =~ ^[Yy]$ ]]; then
            echo -e " - ${CYAN}Останавливаем старую службу...${NC}"
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            break
        else
            echo -e "${RED}Введите y или N.${NC}"
        fi
    done
fi

mkdir -p "$SLAVE_DIR" "$SLAVE_DIR/wgcf"

# ===== Выбор режима =====

echo -e "\n${CYAN}================================================${NC}"
echo -e "    ${YELLOW}Выберите режим работы slave-сервера${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e ""
echo -e " ${GREEN}1.${NC} Direct — трафик выходит напрямую через IP этого сервера"
echo -e "    ${CYAN}(сервер работает как прокси, клиент видит IP этого сервера)${NC}"
echo -e ""
echo -e " ${GREEN}2.${NC} WARP   — трафик дополнительно проходит через Cloudflare WARP"
echo -e "    ${CYAN}(клиент видит IP Cloudflare, нужны WARP-ключи)${NC}"
echo -e "${CYAN}================================================${NC}"

SLAVE_MODE=""
while true; do
    read -r -p "Выбор [1-2]: " mode_choice < /dev/tty
    case "$mode_choice" in
        1) SLAVE_MODE="direct"; break ;;
        2) SLAVE_MODE="warp"; break ;;
        *) echo -e "${RED}Введите 1 или 2.${NC}" ;;
    esac
done
echo -e " - ${GREEN}Режим: ${SLAVE_MODE}${NC}"

# ===== Настройка порта =====

echo -e "\n${YELLOW}⚙️  Настройка порта Shadowsocks${NC}"
SLAVE_PORT=$DEFAULT_PORT

while true; do
    read -r -p "Порт [по умолчанию $DEFAULT_PORT]: " custom_port < /dev/tty
    if [ -z "$custom_port" ]; then
        custom_port=$DEFAULT_PORT
    fi
    if ! validate_port "$custom_port"; then
        echo -e "${RED}Некорректный порт! Допустимо: 1-65535.${NC}"
        continue
    fi
    if ! check_port_available "$custom_port"; then
        echo -e "${YELLOW}⚠️  Порт $custom_port уже занят:${NC}"
        ss -tlnp 2>/dev/null | grep ":${custom_port} " || true
        while true; do
            read -r -p "Использовать другой порт? (Y/n): " retry < /dev/tty
            if [[ -z "$retry" || "$retry" =~ ^[Yy]$ ]]; then
                break
            elif [[ "$retry" =~ ^[Nn]$ ]]; then
                echo -e "${YELLOW}Используем порт $custom_port (предупреждение проигнорировано).${NC}"
                SLAVE_PORT=$custom_port
                break 2
            else
                echo -e "${RED}Введите Y или n.${NC}"
            fi
        done
        continue
    fi
    SLAVE_PORT=$custom_port
    break
done
echo -e " - ${GREEN}Порт: ${SLAVE_PORT}${NC}"

# ===== Генерация или ввод ключа Shadowsocks =====

echo -e "\n${YELLOW}⚙️  Настройка ключа Shadowsocks${NC}"
echo -e "${CYAN}Этот ключ должен совпадать на основном WARPER-сервере и на slave.${NC}"
echo -e ""
echo -e " ${GREEN}1.${NC} Сгенерировать новый ключ"
echo -e " ${GREEN}2.${NC} Ввести существующий ключ (если уже настроен на основном сервере)"

SS_PASSWORD=""
while true; do
    read -r -p "Выбор [1-2]: " key_choice < /dev/tty
    case "$key_choice" in
        1)
            SS_PASSWORD=$(openssl rand -base64 16)
            echo -e ""
            echo -e "${GREEN}================================================${NC}"
            echo -e " 🔑 Сгенерирован ключ: ${YELLOW}${SS_PASSWORD}${NC}"
            echo -e "${GREEN}================================================${NC}"
            echo -e "${RED}⚠️  ВАЖНО! Сохраните этот ключ!${NC}"
            echo -e "${YELLOW}   Он понадобится при настройке основного${NC}"
            echo -e "${YELLOW}   WARPER-сервера в режиме Slave.${NC}"
            echo -e "${GREEN}================================================${NC}"
            break
            ;;
        2)
            while true; do
                read -r -p "Введите ключ: " SS_PASSWORD < /dev/tty
                if [ -z "$SS_PASSWORD" ]; then
                    echo -e "${RED}Ключ не может быть пустым!${NC}"
                    continue
                fi
                if ! echo "$SS_PASSWORD" | base64 -d >/dev/null 2>&1; then
                    echo -e "${YELLOW}Предупреждение: ключ не похож на base64. Продолжить? (Y/n)${NC}"
                    read -r -p "> " b64_confirm < /dev/tty
                    if [[ "$b64_confirm" =~ ^[Nn]$ ]]; then
                        continue
                    fi
                fi
                echo -e " - ${GREEN}Ключ принят.${NC}"
                break
            done
            break
            ;;
        *) echo -e "${RED}Введите 1 или 2.${NC}" ;;
    esac
done

# ===== WARP-ключи (если режим WARP) =====

WARP_ADDRESS=""
WARP_PRIVATE_KEY=""
WARP_SOURCE=""

if [ "$SLAVE_MODE" = "warp" ]; then
    echo -e "\n${YELLOW}[1/7] Получение ключей WARP...${NC}"

    if existing_keys=$(find_warp_keys); then
        WARP_ADDRESS=$(echo "$existing_keys" | sed -n '1p')
        WARP_PRIVATE_KEY=$(echo "$existing_keys" | sed -n '2p')
        WARP_SOURCE=$(echo "$existing_keys" | sed -n '3p')
        echo -e " - ${GREEN}Найдены WARP-ключи в: $WARP_SOURCE${NC}"
    else
        echo -e " - ${CYAN}WARP-ключи не найдены. Генерируем...${NC}"
        if ! generate_warp_keys "$SYSTEM_ARCH"; then
            echo -e "${RED}Не удалось получить WARP-ключи!${NC}"
            exit 1
        fi
        cd "$SLAVE_DIR/wgcf" || exit 1
        WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
        WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
    fi

    if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
        echo -e "${RED}Ошибка: не удалось извлечь WARP-ключи!${NC}"
        exit 1
    fi
    echo -e " - ${GREEN}WARP-ключи получены!${NC}"
else
    echo -e "\n${YELLOW}[1/7] Режим Direct — WARP-ключи не требуются.${NC}"
fi

# ===== Установка sing-box =====

echo -e "\n${YELLOW}[2/7] Установка sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "$CURRENT_SB" == "$SB_VERSION" ]; then
        echo -e " - ${GREEN}sing-box $CURRENT_SB уже установлен.${NC}"
    else
        echo -e " - ${YELLOW}Обновление до $SB_VERSION...${NC}"
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
    fi
else
    echo -e " - ${CYAN}Установка sing-box $SB_VERSION...${NC}"
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version "$SB_VERSION" >/dev/null 2>&1
fi

if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${RED}Ошибка: sing-box не установлен после попытки установки!${NC}"
    exit 1
fi
echo -e " - ${GREEN}sing-box готов.${NC}"

# ===== Создание конфигурации =====

echo -e "\n${YELLOW}[3/7] Создание конфигурации...${NC}"
mkdir -p /etc/sing-box-slave

if [ "$SLAVE_MODE" = "direct" ]; then
    download_file "$REPO_URL/templates/config-slave-direct.json.template" "$SLAVE_DIR/config-slave.json.template" "шаблон конфигурации (direct)" || exit 1
    sed \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT|g" \
        -e "s|__SLAVE_PASSWORD__|$SS_PASSWORD|g" \
        "$SLAVE_DIR/config-slave.json.template" > "$SINGBOX_SLAVE_CONF"
else
    download_file "$REPO_URL/templates/config-slave-warp.json.template" "$SLAVE_DIR/config-slave.json.template" "шаблон конфигурации (warp)" || exit 1
    sed \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT|g" \
        -e "s|__SLAVE_PASSWORD__|$SS_PASSWORD|g" \
        -e "s|__WARP_ADDRESS__|$WARP_ADDRESS|g" \
        -e "s|__WARP_PRIVATE_KEY__|$WARP_PRIVATE_KEY|g" \
        "$SLAVE_DIR/config-slave.json.template" > "$SINGBOX_SLAVE_CONF"
fi

chmod 600 "$SINGBOX_SLAVE_CONF"

if ! sing-box check -c "$SINGBOX_SLAVE_CONF" >/dev/null 2>&1; then
    echo -e "${RED}Ошибка: конфигурация sing-box невалидна!${NC}"
    echo -e "${YELLOW}Проверьте: sing-box check -c $SINGBOX_SLAVE_CONF${NC}"
    exit 1
fi
echo -e " - ${GREEN}Конфигурация создана и проверена.${NC}"

# ===== Сохранение конфигурации slave =====

echo -e "\n${YELLOW}[4/7] Сохранение настроек...${NC}"
{
    echo "SLAVE_MODE=$SLAVE_MODE"
    echo "SLAVE_PORT=$SLAVE_PORT"
    echo "SS_PASSWORD=$SS_PASSWORD"
} > "$SLAVE_CONF"
chmod 600 "$SLAVE_CONF"
echo -e " - ${GREEN}Настройки сохранены в $SLAVE_CONF${NC}"

# ===== Systemd сервис =====

echo -e "\n${YELLOW}[5/7] Настройка systemd...${NC}"

download_file "$REPO_URL/templates/sing-box-slave.service" "/etc/systemd/system/${SERVICE_NAME}.service" "служба ${SERVICE_NAME}" || {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << 'SVCEOF'
[Unit]
Description=sing-box slave service (warperslave)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box-slave/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SVCEOF
}

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$SERVICE_NAME"

sleep 3
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${RED}Ошибка: $SERVICE_NAME не запустился!${NC}"
    echo -e "${YELLOW}Последние логи:${NC}"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
    exit 1
fi
echo -e " - ${GREEN}Служба $SERVICE_NAME запущена и добавлена в автозагрузку.${NC}"

# ===== Открытие порта =====

echo -e "\n${YELLOW}[6/7] Настройка firewall...${NC}"
ensure_port_open "$SLAVE_PORT"
echo -e " - ${GREEN}Порт $SLAVE_PORT открыт (TCP+UDP).${NC}"

echo -e " - ${CYAN}Проверка доступности порта...${NC}"
if ss -tlnp 2>/dev/null | grep -q ":${SLAVE_PORT} "; then
    echo -e " - ${GREEN}Порт $SLAVE_PORT слушается.${NC}"
else
    echo -e " - ${YELLOW}Порт $SLAVE_PORT не обнаружен в списке слушающих (может быть UDP).${NC}"
fi

# ===== Установка утилиты управления =====

echo -e "\n${YELLOW}[7/7] Установка утилиты управления...${NC}"
download_file "$REPO_URL/warperslave.sh" "$SLAVE_DIR/warperslave.sh" "утилита warperslave" || exit 1
download_file "$REPO_URL/uninstall-slave.sh" "$SLAVE_DIR/uninstall-slave.sh" "деинсталлятор" || exit 1
download_file "$REPO_URL/versionslave" "$SLAVE_DIR/versionslave" "файл версии" || exit 1
chmod +x "$SLAVE_DIR/warperslave.sh" "$SLAVE_DIR/uninstall-slave.sh"
ln -sf "$SLAVE_DIR/warperslave.sh" /usr/local/bin/warperslave

# ===== Определяем публичный IPv4 локально =====

EXTERNAL_IP=$(get_local_public_ipv4 || true)
[ -z "$EXTERNAL_IP" ] && EXTERNAL_IP="<IPv4 не обнаружен>"

if [ "$EXTERNAL_IP" = "<IPv4 не обнаружен>" ]; then
    echo -e "${YELLOW}⚠️  Публичный IPv4 локально не обнаружен.${NC}"
    echo -e "${YELLOW}WARPER/WARPERSLAVE работают в IPv4-сценарии.${NC}"
    echo -e "${YELLOW}Если сервер за NAT или без белого IPv4 — подключение может не работать.${NC}"
fi

LOCAL_VER=$(cat "$SLAVE_DIR/versionslave" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 WARPERSLAVE v${LOCAL_VER} УСПЕШНО УСТАНОВЛЕН!"
echo -e "${GREEN}================================================${NC}"
echo -e ""
echo -e " ${CYAN}Режим:${NC}      ${YELLOW}${SLAVE_MODE}${NC}"
echo -e " ${CYAN}Порт:${NC}       ${YELLOW}${SLAVE_PORT}${NC}"
echo -e " ${CYAN}Ключ SS:${NC}    ${YELLOW}${SS_PASSWORD}${NC}"
echo -e " ${CYAN}Внешний IP:${NC} ${YELLOW}${EXTERNAL_IP}${NC}"
echo -e ""
echo -e "${CYAN}================================================${NC}"
echo -e "${YELLOW}📋 Для настройки основного WARPER-сервера:${NC}"
echo -e ""
echo -e "  1. На основном сервере запустите: ${GREEN}warper${NC}"
echo -e "  2. Перейдите в: ${GREEN}Настройки (9) → Режим маршрутизации (7)${NC}"
echo -e "  3. Выберите: ${GREEN}Slave (донор-сервер)${NC}"
echo -e "  4. Укажите:"
echo -e "     - IP:    ${YELLOW}${EXTERNAL_IP}${NC}"
echo -e "     - Порт:  ${YELLOW}${SLAVE_PORT}${NC}"
echo -e "     - Ключ:  ${YELLOW}${SS_PASSWORD}${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e ""
echo -e " Управление:  ${GREEN}warperslave${NC}"
echo -e " Статус:      ${GREEN}warperslave status${NC}"
echo -e " Логи:        ${GREEN}journalctl -u $SERVICE_NAME -f${NC}"
echo -e " Удаление:    ${GREEN}warperslave uninstall${NC}"
echo -e "              ${GREEN}curl -fsSL $REPO_URL/uninstall-slave.sh | bash${NC}"
