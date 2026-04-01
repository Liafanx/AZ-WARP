#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}================================================${NC}"
echo -e " 🚀 Установка интеграции AntiZapret + WARP"
echo -e "${CYAN}================================================${NC}"

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root (sudo -i).${NC}"
  exit 1
fi

# 1. Установка sing-box
echo -e "\n${YELLOW}[1/7] Проверка и установка sing-box...${NC}"
if command -v sing-box &> /dev/null; then
    echo -e "${GREEN}sing-box уже установлен. Обновляем до актуальной версии...${NC}"
fi
curl -fsSL https://sing-box.app/install.sh | bash

# 2. Установка wgcf и генерация профиля
echo -e "\n${YELLOW}[2/7] Настройка Cloudflare WARP (генерация профиля)...${NC}"
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

if [ ! -f "/usr/local/bin/wgcf" ]; then
    echo "Скачиваем wgcf..."
    wget -qO wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
    chmod +x wgcf
    mv wgcf /usr/local/bin/wgcf
fi

if [ ! -f "wgcf-profile.conf" ]; then
    echo "Регистрируем аккаунт WARP..."
    wgcf register --accept-tos > /dev/null 2>&1
    echo "Генерируем конфигурацию..."
    wgcf generate > /dev/null 2>&1
fi

if [ ! -f "wgcf-profile.conf" ]; then
    echo -e "${RED}Ошибка: Не удалось сгенерировать профиль WARP.${NC}"
    exit 1
fi

# Парсим ключи
WARP_ADDRESS=$(grep -oP '(?<=^Address = ).*' wgcf-profile.conf)
WARP_PRIVATE_KEY=$(grep -oP '(?<=^PrivateKey = ).*' wgcf-profile.conf)

echo -e "${GREEN}Ключи WARP успешно получены!${NC}"

# 3. Настройка config.json
echo -e "\n${YELLOW}[3/7] Создание конфигурации sing-box...${NC}"
mkdir -p /etc/sing-box

cat << EOF > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "real-dns", "type": "udp", "server": "8.8.8.8", "detour": "warp" },
      { "tag": "fakeip-dns", "type": "fakeip", "inet4_range": "10.255.0.0/24" }
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
    { "type": "tun", "tag": "tun-in", "interface_name": "singbox-tun", "address": ["10.255.0.1/24"], "auto_route": false, "strict_route": false, "stack": "system" }
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

# 4. Настройка Systemd
echo -e "\n${YELLOW}[4/7] Настройка службы sing-box...${NC}"
cat << 'EOF' > /usr/lib/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecStartPost=/bin/sleep 2
ExecStartPost=-/usr/bin/resolvectl dns singbox-tun ""
ExecStartPost=-/usr/bin/resolvectl domain singbox-tun ""
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box > /dev/null 2>&1
systemctl restart sing-box

# 5. Маршруты AntiZapret
echo -e "\n${YELLOW}[5/7] Интеграция с маршрутами AntiZapret...${NC}"
AZ_INC="/root/antizapret/config/include-ips.txt"
if [ -f "$AZ_INC" ]; then
    if ! grep -q "10.255.0.0/24" "$AZ_INC"; then
        echo "10.255.0.0/24" >> "$AZ_INC"
        echo "Обновляем конфигурацию AntiZapret (doall.sh)..."
        /root/antizapret/doall.sh > /dev/null 2>&1
    else
        echo "Подсеть 10.255.0.0/24 уже добавлена."
    fi
else
    echo -e "${RED}Файл $AZ_INC не найден. Возможно, AntiZapret не установлен?${NC}"
fi

# 6. Установка утилиты WARPER
echo -e "\n${YELLOW}[6/7] Создание утилиты WARPER...${NC}"
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

# Создаем скрипт утилиты
cat << 'EOF' > /root/warper/warper.sh
#!/bin/bash

MASTER_FILE="/root/warper/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

touch "$MASTER_FILE"

sync_domains() {
    cp "$MASTER_FILE" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

prompt_apply() {
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        sync_domains
        systemctl restart kresd@1 kresd@2
        echo -e "${GREEN}Изменения успешно применены!${NC}"
    else
        echo -e "${YELLOW}Домены сохранены в файл, но НЕ применены к DNS.${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

prompt_confirm() {
    read -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0; else return 1; fi
}

patch_kresd() {
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        if [ ! -f "$ACTIVE_FILE" ]; then sync_domains; systemctl restart kresd@1 kresd@2; fi
        return 0
    fi
    sync_domains
    awk '
    /-- Resolve non-blocked domains/ || /-- Resolve blocked domains/ {
        print ""
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_domains = {}"
        print "\tlocal wfile = io.open(\"/etc/knot-resolver/warper-domains.txt\", \"r\")"
        print "\tif wfile then"
        print "\t\tfor line in wfile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" then table.insert(warp_domains, clean .. \".\") end"
        print "\t\tend"
        print "\t\twfile:close()"
        print "\t\tif #warp_domains > 0 then"
        print "\t\t\tpolicy.add(policy.suffix(policy.STUB(\"127.0.0.1@40000\"), policy.todnames(warp_domains)))"
        print "\t\tend"
        print "\tend"
        print "\t-- [WARP-MOD-END]"
        print ""
    }
    {print}' "$KRESD_CONF" > /tmp/kresd.conf.tmp && mv /tmp/kresd.conf.tmp "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2
}

# Поддержка CLI-команды для автоустановщика
if [ "$1" == "patch" ]; then
    patch_kresd
    exit 0
fi

singbox_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "       ⚙️  ${YELLOW}УПРАВЛЕНИЕ SING-BOX${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        if systemctl is-active --quiet sing-box; then echo -e "Текущий статус: ${GREEN}ЗАПУЩЕН 🟢${NC}"; else echo -e "Текущий статус: ${RED}ОСТАНОВЛЕН 🔴${NC}"; fi
        if systemctl is-enabled --quiet sing-box 2>/dev/null; then echo -e "Автозагрузка: ${GREEN}ВКЛЮЧЕНА${NC}"; else echo -e "Автозагрузка: ${RED}ВЫКЛЮЧЕНА${NC}"; fi
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} Запустить службу"
        echo -e " ${RED}2.${NC} Остановить службу"
        echo -e " ${GREEN}3.${NC} Включить в автозагрузку"
        echo -e " ${RED}4.${NC} Выключить из автозагрузки"
        echo -e " ${YELLOW}5.${NC} Посмотреть логи"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        echo -n -e "Выбор [0-5]: "
        read sb_choice
        case $sb_choice in
            1) if prompt_confirm; then systemctl start sing-box; echo -e "${GREEN}Запущено.${NC}"; sleep 1; fi ;;
            2) if prompt_confirm; then systemctl stop sing-box; echo -e "${YELLOW}Остановлено.${NC}"; sleep 1; fi ;;
            3) if prompt_confirm; then systemctl enable sing-box; echo -e "${GREEN}Добавлено в автозапуск.${NC}"; sleep 1; fi ;;
            4) if prompt_confirm; then systemctl disable sing-box; echo -e "${YELLOW}Убрано из автозапуска.${NC}"; sleep 1; fi ;;
            5) echo -e "\n${CYAN}Открываю логи... (Для выхода нажмите Ctrl+C)${NC}"; sleep 1; journalctl -u sing-box -f ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}WARPER УПРАВЛЕНИЕ ДОМЕНАМИ${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "📁 Домены: ${GREEN}${MASTER_FILE}${NC}"
    if [ -f "/etc/sing-box/config.json" ]; then echo -n -e "📦 WARP (sing-box): ${GREEN}[УСТАНОВЛЕН]${NC} "; else echo -n -e "📦 WARP (sing-box): ${RED}[НЕ УСТАНОВЛЕН]${NC} "; fi
    if systemctl is-active --quiet sing-box; then echo -e "🟢 Статус: ${GREEN}[ЗАПУЩЕН]${NC}"; else echo -e "🔴 Статус: ${RED}[ОСТАНОВЛЕН]${NC}"; fi

    local status_text="[ERR] Конфиг НЕ пропатчен"
    local status_color=$RED
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then status_text="[OK] Конфиг пропатчен"; status_color=$GREEN; fi
    echo -n -e "🔧 Интеграция DNS: ${status_color}${status_text}${NC} "
    if ! diff -q "$MASTER_FILE" "$ACTIVE_FILE" > /dev/null 2>&1; then echo -e "${YELLOW}(Есть рассинхрон)${NC}"; else echo ""; fi

    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Восстановить / Пропатчить DNS"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} Справка / FAQ"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"
    echo -n -e "Выбор [0-7]: "
}

while true; do
    show_main_menu
    read choice
    case $choice in
        1)
            echo -e "\n${CYAN}Введите домен (напр. openai.com):${NC}"
            read new_domain
            if [ -z "$new_domain" ]; then echo -e "${RED}Пустой ввод!${NC}"; sleep 1
            elif grep -q "^$new_domain$" "$MASTER_FILE"; then echo -e "${YELLOW}Домен уже есть!${NC}"; sleep 1
            else echo "$new_domain" >> "$MASTER_FILE"; echo -e "${GREEN}Добавлено!${NC}"; prompt_apply; fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read del_domain
            if grep -q "^$del_domain$" "$MASTER_FILE"; then sed -i "/^$del_domain$/d" "$MASTER_FILE"; echo -e "${GREEN}Удалено!${NC}"; prompt_apply
            else echo -e "${RED}Домен не найден!${NC}"; sleep 1; fi
            ;;
        3)
            echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
            if [ -s "$MASTER_FILE" ]; then cat -n "$MASTER_FILE"; else echo -e "${YELLOW}Список пуст.${NC}"; fi
            echo -e "${CYAN}---------------------${NC}"
            read -p "Нажмите Enter..."
            ;;
        4) nano "$MASTER_FILE"; prompt_apply ;;
        5) echo -e "\n${YELLOW}Запуск полного восстановления...${NC}"; patch_kresd; echo -e "${GREEN}Готово!${NC}"; sleep 1 ;;
        6) singbox_menu ;;
        7)
            echo -e "\n${YELLOW}--- FAQ ---${NC}"
            echo -e "1. ${CYAN}Обновили AntiZapret?${NC} Зайдите сюда и нажмите ${CYAN}[5]${NC}."
            read -p "Нажмите Enter..."
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
EOF

chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper

# 7. Финальный патч
echo -e "\n${YELLOW}[7/7] Применение правил DNS...${NC}"
/usr/local/bin/warper patch > /dev/null 2>&1

echo -e "\n${GREEN}================================================${NC}"
echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}================================================${NC}"
echo -e "Для управления доменами и туннелем введите команду:"
echo -e "${CYAN}warper${NC}"
