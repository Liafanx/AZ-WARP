# 🚀 Как точечно пустить сервисы (Gemini, ChatGPT и др.) через Cloudflare WARP на сервере с AntiZapret

Сам проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

**Проблема:** У вас установлен свой сервер с AntiZapret. Всё работает отлично, заблокированные сайты открываются. Но при попытке зайти на Gemini или ChatGPT вы получаете ошибку (сервис недоступен в вашей стране, что ваш IP заблокирован). Это происходит потому, что IP-адрес вашего VPS заблокирован или по GEO опредялется в недоступной стране.

**Решение:** Мы установим легковесное ядро `sing-box`, подключим его к Cloudflare WARP и создадим удобную интерактивную утилиту `warper`. Она позволит в пару кликов направлять любые нужные вам домены в туннель WARP, оставляя весь остальной трафик работать как обычно. Утилита полностью защищена от сброса настроек при обновлениях AntiZapret, потребуется только сделать восстановление.

**Внимание** используется подсеть в установке для fakeip 198.18.0.0/24
---

*Проверено и работает на Ubuntu 24.04*

### ⚡ Шаг 0. Установка в 1 команду (Рекомендуется)
Подключитесь к вашему серверу по SSH от имени `root` и выполните команду:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```
*После завершения установки просто введите команду `warper`.*

---

## 🛠 Ручная Установка (Для продвинутых пользователей)

### Шаг 1. Установка sing-box
Выполняем команду для установки актуальной версии `sing-box`:

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

### Шаг 2. Получение ключей Cloudflare WARP
Чтобы `sing-box` мог подключиться к WARP, нам нужно сгенерировать личный профиль через утилиту `wgcf`. Выполняем команды по очереди:

```bash
# Скачиваем утилиту и даем права на запуск
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
chmod +x wgcf

# Регистрируем аккаунт и генерируем конфиг
./wgcf register --accept-tos
./wgcf generate
```

Открываем созданный файл:
```bash
cat wgcf-profile.conf
```
Скопируйте из вывода два значения (сохраните их в блокнот):
* `PrivateKey` (строка вида `uBW0nm7U...=`)
* `Address` (ваш IPv4, обычно это `172.16.0.2/32`)

### Шаг 3. Настройка конфига sing-box
Создаем конфигурационный файл:
```bash
nano /etc/sing-box/config.json
```
Вставляем этот код. **Обязательно замените значения `Address` и `PrivateKey` на свои из Шага 2!**

```json
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "real-dns",
        "type": "udp",
        "server": "8.8.8.8",
        "detour": "warp"
      },
      {
        "tag": "fakeip-dns",
        "type": "fakeip",
        "inet4_range": "198.18.0.0/24"
      }
    ],
    "rules": [
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip-dns"
      }
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
      "address": [
        "ВАШ_ADDRESS_ИЗ_WGCF" 
      ],
      "private_key": "ВАШ_PRIVATE_KEY_ИЗ_WGCF",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "inbounds": [
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "listen_port": 40000,
      "network": "udp"
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox-tun",
      "address": [
        "198.18.0.1/24"
      ],
      "auto_route": false,
      "strict_route": false,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "dns-in",
        "action": "hijack-dns"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "outbound": "warp"
      }
    ],
    "default_domain_resolver": "real-dns",
    "auto_detect_interface": true,
    "final": "direct"
  }
}
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

### Шаг 4. Настройка службы systemd
Чтобы `sing-box` запускался автоматически от имени `root` и создавал интерфейс `tun`, создадим службу:

```bash
nano /usr/lib/systemd/system/sing-box.service
```
Вставляем следующий текст:

```ini
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
# Ждем 2 секунды, пока интерфейс resolved появится
ExecStartPost=/bin/sleep 2
# Полностью стираем DNS-сервер с этого интерфейса
ExecStartPost=-/usr/bin/resolvectl dns singbox-tun ""
# Полностью стираем DOMAINS=~. из правил resolved
ExecStartPost=-/usr/bin/resolvectl domain singbox-tun ""
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

Перезагружаем демоны, добавляем в автозагрузку и запускаем:
```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

### Шаг 5. Интеграция с маршрутами AntiZapret
Устройства должны знать, что трафик к виртуальным IP-адресам `sing-box` нужно отправлять в VPN.
Добавляем безопасную фейковую подсеть в конфиг маршрутов и применяем:
```bash
echo "198.18.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

---

### Шаг 6. Создание умной утилиты WARPER
Мы создадим мощный инструмент, который защитит ваши настройки от перезаписи при обновлениях AntiZapret и позволит легко управлять туннелем прямо из консоли.

**1. Создаем папку и мастер-файл с доменами (домены добавлены как пример для первого тестирования, их можно удалить позже, добавить свои):**
```bash
mkdir -p /root/warper

cat << 'EOF' > /root/warper/domains.txt
gemini.google.com
proactivebackend-pa.googleapis.com
assistant-s3-pa.googleapis.com
gemini.google
alkaliminer-pa.googleapis.com
robinfrontend-pa.googleapis.com
EOF
```

**2. Создаем скрипт-утилиту:**
```bash
nano /root/warper/warper.sh
```
Вставляем код утилиты:
```bash
#!/bin/bash

MASTER_FILE="/root/warper/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
AZ_INC="/root/antizapret/config/include-ips.txt"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat /root/warper/version 2>/dev/null || echo "0.0.0")

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
    }
    {print}' "$KRESD_CONF" > /tmp/kresd.conf.tmp && mv /tmp/kresd.conf.tmp "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2
}

unpatch_kresd() {
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2
    fi
}

toggle_warper() {
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        echo -e "\n${YELLOW}Отключение WARPER...${NC}"
        systemctl stop sing-box
        systemctl disable sing-box 2>/dev/null
        unpatch_kresd
        echo -e "${GREEN}WARPER успешно отключен! Трафик идет по умолчанию.${NC}"
    else
        echo -e "\n${YELLOW}Включение WARPER...${NC}"
        systemctl enable sing-box 2>/dev/null
        systemctl start sing-box
        patch_kresd
        echo -e "${GREEN}WARPER успешно включен!${NC}"
    fi
    sleep 2
}

if [ "$1" == "patch" ]; then patch_kresd; exit 0; fi

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh"
    curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service"
    curl -s -o /root/warper/version "$REPO_URL/version"
    chmod +x /root/warper/warper.sh
    systemctl daemon-reload
    echo -e "${GREEN}Утилита успешно обновлена! Перезапустите warper.${NC}"
    exit 0
}

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
        echo -e " ${YELLOW}5.${NC} Посмотреть логи (Ctrl+C для выхода)"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        echo -n -e "Выбор [0-5]: "
        read sb_choice
        case $sb_choice in
            1) if prompt_confirm; then systemctl start sing-box; echo -e "${GREEN}Запущено.${NC}"; sleep 1; fi ;;
            2) if prompt_confirm; then systemctl stop sing-box; echo -e "${YELLOW}Остановлено.${NC}"; sleep 1; fi ;;
            3) if prompt_confirm; then systemctl enable sing-box; echo -e "${GREEN}Добавлено в автозапуск.${NC}"; sleep 1; fi ;;
            4) if prompt_confirm; then systemctl disable sing-box; echo -e "${YELLOW}Убрано из автозапуска.${NC}"; sleep 1; fi ;;
            5) echo -e "\n${CYAN}Открываю логи...${NC}"; sleep 1; journalctl -u sing-box -f ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    REMOTE_VER=$(curl -s --max-time 1 "$REPO_URL/version" || echo "$LOCAL_VER")
    
    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}WARPER УПРАВЛЕНИЕ ДОМЕНАМИ${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"
    
    if [ "$REMOTE_VER" != "$LOCAL_VER" ] && [ -n "$REMOTE_VER" ]; then echo -e "Версия: ${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"; else echo -e "Версия: ${GREEN}$LOCAL_VER (Актуальная)${NC}"; fi
    
    # Определение глобального статуса WARPER
    if systemctl is-active --quiet sing-box && grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        echo -e "Глобальный статус: ${GREEN}▶ Включен (Активен)${NC}"
        local TOGGLE_TEXT="⏹ Отключить WARPER (Вернуть как было)"
        local TOGGLE_COLOR=$RED
    else
        echo -e "Глобальный статус: ${RED}⏹ Отключен${NC}"
        local TOGGLE_TEXT="▶ Включить WARPER"
        local TOGGLE_COLOR=$GREEN
    fi

    echo -e "📁 Домены: ${GREEN}${MASTER_FILE}${NC}"
    
    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Восстановить / Пропатчить DNS"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} Справка / FAQ"
    echo -e " ${TOGGLE_COLOR}8. ${TOGGLE_TEXT}${NC}"
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then echo -e " ${YELLOW}9. ⚡ Обновить WARPER до $REMOTE_VER${NC}"; fi
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"
    echo -n -e "Выбор: "
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
        7) echo -e "\n${YELLOW}--- FAQ ---${NC}"; echo -e "1. ${CYAN}Обновили AntiZapret?${NC} Зайдите сюда и нажмите ${CYAN}[5]${NC}."; read -p "Нажмите Enter..." ;;
        8) toggle_warper ;;
        9) update_warper ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

**3. Выдаем права и создаем ярлык:**
```bash
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

---

### Шаг 7. Активация и Финал
Теперь просто введите в консоли сервера команду:
```bash
warper
```
Перед вами появится меню утилиты.
1. Нажмите **5**, чтобы утилита внедрила правила в конфигурацию DNS.
2. Проверьте статусы в шапке (все должно светиться зеленым).
3. Нажмите **0** для выхода.

**Готово! 🎉**
У вас настроен идеальный гибридный VPN. AntiZapret обрабатывает стандартные блокировки, а `sing-box` (через WARP) берет на недоступные по какой либо причине или нужные вам для скрытия IP адреса. Если сервис перестал работать — просто введите `warper`, добавьте его домен в список, нажмите `Enter` (для авто-перезагрузки DNS) и пользуйтесь!
```
