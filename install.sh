#!/bin/bash

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

# === ПРЕДВАРИТЕЛЬНЫЙ ОПРОС ПОЛЬЗОВАТЕЛЯ ===
mkdir -p /root/warper
MASTER_FILE="/root/warper/domains.txt"
CONF_FILE="/root/warper/warper.conf"

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
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
            if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}0/[0-9]{1,2}$ ]]; then
                SUBNET="$custom_subnet"
                TUN_IP="${SUBNET/.0\//.1\/}"
                break 2
            else
                echo -e "${RED}Неверный формат! Ожидается подсеть вида X.X.X.0/XX (например, 10.99.0.0/24)${NC}"
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
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

if [ ! -f "/usr/local/bin/wgcf" ]; then
    echo -e " - ${CYAN}Скачивание утилиты wgcf...${NC}"
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
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
        echo -e "2. Положите этот файл в директорию ${YELLOW}/root/warper/wgcf/${NC} на сервере."
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
echo -e "\n${YELLOW}[3/8] Создание конфигурации sing-box...${NC}"
echo -e " - ${CYAN}Генерация файла /etc/sing-box/config.json с подсетью $SUBNET...${NC}"
mkdir -p /etc/sing-box
cat << EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "real-dns", "type": "udp", "server": "1.1.1.1", "detour": "warp" },
      { "tag": "fakeip-dns", "type": "fakeip", "inet4_range": "$SUBNET", "inet6_range": "fc00::/18" }
    ],
    "rules": [
      { "query_type": ["A", "AAAA"], "server": "fakeip-dns" }
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
          "allowed_ips": ["0.0.0.0/0", "::/0"],
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
echo -e " - ${CYAN}Скачивание файла службы sing-box.service...${NC}"
curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service?t=$(date +%s)"
echo -e " - ${CYAN}Скачивание файла службы warper-autopatch.service...${NC}"
curl -s -o /usr/lib/systemd/system/warper-autopatch.service "$REPO_URL/warper-autopatch.service?t=$(date +%s)"
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
    sed -i '/10.255.0.0\/24/d' "$AZ_INC" 2>/dev/null
    if ! grep -q "$SUBNET" "$AZ_INC"; then
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
mkdir -p /root/warper/download
echo -e " - ${CYAN}Загрузка списка доменов Gemini...${NC}"
curl -s -o /root/warper/download/gemini.txt "$REPO_URL/download/gemini.txt?t=$(date +%s)"
echo -e " - ${CYAN}Загрузка списка доменов ChatGPT...${NC}"
curl -s -o /root/warper/download/chatgpt.txt "$REPO_URL/download/chatgpt.txt?t=$(date +%s)"

# ==============================================================================
echo -e "\n${YELLOW}[7/8] Настройка списка доменов и утилиты WARPER...${NC}"

if [ "$ADD_GEMINI" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов Gemini в мастер-файл...${NC}"
    if ! grep -q "# --- GEMINI ---" "$MASTER_FILE"; then
        echo "# --- GEMINI ---" >> "$MASTER_FILE"
        cat /root/warper/download/gemini.txt >> "$MASTER_FILE"
        echo "# --- END GEMINI ---" >> "$MASTER_FILE"
    fi
fi

if [ "$ADD_CHATGPT" == "y" ]; then
    echo -e " - ${CYAN}Интеграция доменов ChatGPT в мастер-файл...${NC}"
    if ! grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then
        echo "# --- CHATGPT ---" >> "$MASTER_FILE"
        cat /root/warper/download/chatgpt.txt >> "$MASTER_FILE"
        echo "# --- END CHATGPT ---" >> "$MASTER_FILE"
    fi
fi

echo -e " - ${CYAN}Скачивание исполняемого файла утилиты warper.sh...${NC}"
curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh?t=$(date +%s)"
curl -s -o /root/warper/uninstaller.sh "$REPO_URL/uninstaller.sh?t=$(date +%s)"
curl -s -o /root/warper/version "$REPO_URL/version?t=$(date +%s)"

chmod +x /root/warper/warper.sh /root/warper/uninstaller.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper

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
