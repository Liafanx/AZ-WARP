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
touch "$MASTER_FILE"

GEMINI_DOMAINS=("gemini.google.com" "proactivebackend-pa.googleapis.com" "assistant-s3-pa.googleapis.com" "gemini.google" "alkaliminer-pa.googleapis.com" "robinfrontend-pa.googleapis.com")
CHATGPT_DOMAINS=("chatgpt.com" "openai.com" "oaistatic.com" "oaiusercontent.com")

check_domains() {
    for d in "$@"; do
        if ! grep -q "^${d}$" "$MASTER_FILE"; then return 1; fi
    done
    return 0
}

ADD_GEMINI="n"
ADD_CHATGPT="n"

echo -e "\n${YELLOW}⚙️  Настройка маршрутизации доменов${NC}"

if check_domains "${GEMINI_DOMAINS[@]}"; then
    echo -e "${GREEN}✔ Домены Gemini уже присутствуют в списке. Пропускаем.${NC}"
else
    read -e -p "Добавить Gemini в список доменов для WARP? (Y/n): " prompt_gemini < /dev/tty
    if [[ -z "$prompt_gemini" || "$prompt_gemini" =~ ^[Yy]$ ]]; then ADD_GEMINI="y"; fi
fi

if check_domains "${CHATGPT_DOMAINS[@]}"; then
    echo -e "${GREEN}✔ Домены ChatGPT уже присутствуют в списке. Пропускаем.${NC}"
else
    read -e -p "Добавить ChatGPT в список доменов для WARP? (Y/n): " prompt_chatgpt < /dev/tty
    if [[ -z "$prompt_chatgpt" || "$prompt_chatgpt" =~ ^[Yy]$ ]]; then ADD_CHATGPT="y"; fi
fi

echo -e "\n${CYAN}Начинаем процесс установки...${NC}"

# ==============================================================================

echo -e "\n${YELLOW}[1/7] Установка ядра sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    if [ "$CURRENT_SB" == "$SB_VERSION" ]; then
        echo -e " - ${GREEN}sing-box актуальной версии ($CURRENT_SB) уже установлен. Пропускаем.${NC}"
    else
        echo -e " - ${YELLOW}Установлена версия ($CURRENT_SB). Обновляем до $SB_VERSION...${NC}"
        curl -fsSL https://sing-box.app/install.sh | bash -s -- --version $SB_VERSION >/dev/null 2>&1
    fi
else
    echo -e " - ${CYAN}Скачивание и установка пакета sing-box версии $SB_VERSION...${NC}"
    curl -fsSL https://sing-box.app/install.sh | bash -s -- --version $SB_VERSION >/dev/null 2>&1
fi

# ==============================================================================

echo -e "\n${YELLOW}[2/7] Получение ключей Cloudflare WARP...${NC}"
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

if [ ! -f "/usr/local/bin/wgcf" ]; then
    echo -e " - ${CYAN}Скачивание утилиты wgcf для регистрации...${NC}"
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
    chmod +x wgcf
    mv wgcf /usr/local/bin/wgcf
else
    echo -e " - ${GREEN}Утилита wgcf уже установлена.${NC}"
fi

GENERATE_WARP=true
if [ -f "wgcf-profile.conf" ]; then
    if grep -q "PrivateKey" wgcf-profile.conf && grep -q "Address" wgcf-profile.conf; then
        echo -e " - ${GREEN}Профиль WARP уже существует. Используем старые ключи.${NC}"
        GENERATE_WARP=false
    fi
fi

if [ "$GENERATE_WARP" = true ]; then
    echo -e " - ${CYAN}Регистрация бесплатного аккаунта Cloudflare WARP...${NC}"
    wgcf register --accept-tos > /dev/null 2>&1
    echo -e " - ${CYAN}Генерация конфигурации WireGuard...${NC}"
    wgcf generate > /dev/null 2>&1
fi

echo -e " - ${CYAN}Извлечение IPv4 и приватного ключа из профиля...${NC}"
WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    echo -e " - ${RED}Ошибка: Не удалось получить ключи WARP. Проверьте wgcf-profile.conf${NC}"
    exit 1
fi
echo -e " - ${GREEN}Ключи успешно извлечены!${NC}"

# ==============================================================================

echo -e "\n${YELLOW}[3/7] Создание конфигурации sing-box...${NC}"
echo -e " - ${CYAN}Генерация файла /etc/sing-box/config.json...${NC}"
echo -e " - ${CYAN}Подстановка фейковой подсети 198.18.0.0/24 и ключей WARP...${NC}"
mkdir -p /etc/sing-box
cat << EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "real-dns", "type": "udp", "server": "8.8.8.8", "detour": "warp" },
      { "tag": "fakeip-dns", "type": "fakeip", "inet4_range": "198.18.0.0/24", "inet6_range": "fc00::/18" }
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
    { "type": "tun", "tag": "tun-in", "interface_name": "singbox-tun", "address": ["198.18.0.1/24"], "auto_route": false, "strict_route": false, "stack": "system" }
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

echo -e "\n${YELLOW}[4/7] Загрузка и настройка службы systemd...${NC}"
echo -e " - ${CYAN}Скачивание sing-box.service с GitHub...${NC}"
curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service"
echo -e " - ${CYAN}Применение настроек демонов и включение автозагрузки...${NC}"
systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
echo -e " - ${CYAN}Запуск службы sing-box...${NC}"
systemctl restart sing-box
sleep 2

# ==============================================================================

echo -e "\n${YELLOW}[5/7] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ]; then
    if ! grep -q "198.18.0.0/24" "$AZ_INC"; then
        echo -e " - ${CYAN}Добавление подсети 198.18.0.0/24 в конфигурацию маршрутов...${NC}"
        echo "198.18.0.0/24" >> "$AZ_INC"
        
        echo -e " - ${CYAN}Запуск doall.sh (компиляция списков AntiZapret)...${NC}"
        echo -e " - ${YELLOW}⏳ ВНИМАНИЕ: Это может занять от 1 до 5 минут. Пожалуйста, подождите!${NC}"
        
        export DEBIAN_FRONTEND=noninteractive
        export SYSTEMD_PAGER=""
        bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
        
        echo -e " - ${GREEN}Конфигурация маршрутов успешно обновлена!${NC}"
    else
        echo -e " - ${GREEN}Подсеть уже прописана в маршрутах.${NC}"
    fi
else
    echo -e " - ${RED}Файл include-ips.txt не найден. Пропуск этапа.${NC}"
fi

# ==============================================================================

echo -e "\n${YELLOW}[6/7] Настройка списка доменов и утилиты WARPER...${NC}"
mkdir -p /root/warper
MASTER_FILE="/root/warper/domains.txt"

if [ "$ADD_GEMINI" == "y" ]; then
    echo -e " - ${CYAN}Внесение доменов Gemini в список...${NC}"
    for d in "${GEMINI_DOMAINS[@]}"; do grep -q "^${d}$" "$MASTER_FILE" || echo "$d" >> "$MASTER_FILE"; done
fi

if [ "$ADD_CHATGPT" == "y" ]; then
    echo -e " - ${CYAN}Внесение доменов ChatGPT в список...${NC}"
    for d in "${CHATGPT_DOMAINS[@]}"; do grep -q "^${d}$" "$MASTER_FILE" || echo "$d" >> "$MASTER_FILE"; done
fi

echo -e " - ${CYAN}Скачивание скриптов warper.sh и uninstaller.sh с GitHub...${NC}"
curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh"
curl -s -o /root/warper/uninstaller.sh "$REPO_URL/uninstaller.sh"
curl -s -o /root/warper/version "$REPO_URL/version"

echo -e " - ${CYAN}Выдача прав на исполнение...${NC}"
chmod +x /root/warper/warper.sh /root/warper/uninstaller.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper

# ==============================================================================

echo -e "\n${YELLOW}[7/7] Применение правил DNS и Firewall...${NC}"
echo -e " - ${CYAN}Внедрение lua-кода WARPER в конфиг kresd.conf...${NC}"
/usr/local/bin/warper patch > /dev/null 2>&1

echo -e " - ${CYAN}Прописывание правил iptables для совместимости с Docker...${NC}"
iptables -I FORWARD -o singbox-tun -j ACCEPT 2>/dev/null
iptables -I FORWARD -i singbox-tun -j ACCEPT 2>/dev/null

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"
echo -e "Для управления доменами введите команду: ${CYAN}warper${NC}"
