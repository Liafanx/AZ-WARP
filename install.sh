#!/bin/bash

REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"

# Цвета
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

# 1. Интеллектуальная установка sing-box
echo -e "\n${YELLOW}[1/7] Проверка sing-box...${NC}"
if command -v sing-box >/dev/null 2>&1; then
    CURRENT_SB=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    LATEST_SB=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name": "v\K(.*)(?=")')
    
    if [ "$CURRENT_SB" == "$LATEST_SB" ] && [ -n "$CURRENT_SB" ]; then
        echo -e "${GREEN}sing-box актуальной версии ($CURRENT_SB), пропускаем скачивание.${NC}"
    else
        echo -e "${YELLOW}Доступно обновление ($CURRENT_SB -> $LATEST_SB). Обновляем...${NC}"
        curl -fsSL https://sing-box.app/install.sh | bash
    fi
else
    echo "Устанавливаем sing-box..."
    curl -fsSL https://sing-box.app/install.sh | bash
fi

# 2. Интеллектуальная настройка WARP
echo -e "\n${YELLOW}[2/7] Настройка Cloudflare WARP...${NC}"
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

if [ ! -f "/usr/local/bin/wgcf" ]; then
    echo "Скачиваем утилиту wgcf..."
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
    chmod +x wgcf
    mv wgcf /usr/local/bin/wgcf
fi

GENERATE_WARP=true
if [ -f "wgcf-profile.conf" ]; then
    if grep -q "PrivateKey" wgcf-profile.conf && grep -q "Address" wgcf-profile.conf; then
        echo -e "${GREEN}Профиль WARP уже существует и настроен. Пропускаем регистрацию.${NC}"
        GENERATE_WARP=false
    fi
fi

if [ "$GENERATE_WARP" = true ]; then
    echo "Регистрируем новый аккаунт WARP и генерируем профиль..."
    wgcf register --accept-tos > /dev/null 2>&1
    wgcf generate > /dev/null 2>&1
fi

WARP_ADDRESS=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
WARP_PRIVATE_KEY=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')

if [ -z "$WARP_ADDRESS" ] || [ -z "$WARP_PRIVATE_KEY" ]; then
    echo -e "${RED}Ошибка: Не удалось получить ключи WARP. Проверьте wgcf-profile.conf${NC}"
    exit 1
fi
echo -e "${GREEN}Ключи WARP успешно получены (IP: $WARP_ADDRESS)${NC}"

# 3. Настройка config.json (С ФЕЙКОВЫМ IPv6 ДЛЯ ЗАЩИТЫ ОТ УТЕЧЕК)
echo -e "\n${YELLOW}[3/7] Создание конфигурации sing-box...${NC}"
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

# 4. Скачивание и настройка Systemd
echo -e "\n${YELLOW}[4/7] Загрузка и настройка службы sing-box...${NC}"
curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service"
systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}Служба sing-box успешно запущена!${NC}"
else
    echo -e "${RED}Ошибка: Служба sing-box не запустилась. Проверьте логи: journalctl -u sing-box${NC}"
fi

# 5. Маршруты AntiZapret
echo -e "\n${YELLOW}[5/7] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ]; then
    sed -i '/10.255.0.0\/24/d' "$AZ_INC"
    if ! grep -q "198.18.0.0/24" "$AZ_INC"; then
        echo "198.18.0.0/24" >> "$AZ_INC"
        echo "Обновляем конфигурацию AntiZapret (doall.sh)..."
        /root/antizapret/doall.sh > /dev/null 2>&1
    else
        echo -e "${GREEN}Подсеть 198.18.0.0/24 уже есть в маршрутах.${NC}"
    fi
else
    echo -e "${RED}Файл маршрутов AZ не найден.${NC}"
fi

# 6. Скачивание утилиты WARPER
echo -e "\n${YELLOW}[6/7] Скачивание утилиты WARPER с GitHub...${NC}"
mkdir -p /root/warper
MASTER_FILE="/root/warper/domains.txt"

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
gemini.google.com
proactivebackend-pa.googleapis.com
assistant-s3-pa.googleapis.com
gemini.google
alkaliminer-pa.googleapis.com
robinfrontend-pa.googleapis.com
EOF
fi

curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh"
curl -s -o /root/warper/version "$REPO_URL/version"
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper

# 7. Финальный патч
echo -e "\n${YELLOW}[7/7] Применение правил DNS...${NC}"
/usr/local/bin/warper patch > /dev/null 2>&1

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"
echo -e "Для управления доменами введите команду: ${CYAN}warper${NC}"
