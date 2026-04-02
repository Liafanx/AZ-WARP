#!/bin/bash

MASTER_FILE="/root/warper/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
AZ_INC="/root/antizapret/config/include-ips.txt"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat /root/warper/version 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="/root/warper/warper.conf"

if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    SUBNET="198.18.0.0/24"
    TUN_IP="198.18.0.1/24"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ==========================================

# Пользовательские домены:
EOF
fi

sync_domains() {
    cp "$MASTER_FILE" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

prompt_apply() {
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -e -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        patch_kresd > /dev/null 2>&1
        echo -e "${GREEN}Изменения успешно применены!${NC}"
    else
        echo -e "${YELLOW}Домены сохранены в файл, но НЕ применены к DNS.${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

prompt_confirm() {
    read -e -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0; else return 1; fi
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Чтение логов sing-box...${NC}"
    echo -e "${GREEN}Для выхода обратно в меню нажмите Ctrl+C${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u sing-box -n 20 -f
    trap - SIGINT
}

patch_kresd() {
    sync_domains
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        systemctl restart kresd@1 kresd@2
        return 0
    fi
    awk '
    /-- Resolve non-blocked domains/ || /-- Resolve blocked domains/ {
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_domains = {}"
        print "\tlocal wfile = io.open(\"/etc/knot-resolver/warper-domains.txt\", \"r\")"
        print "\tif wfile then"
        print "\t\tfor line in wfile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" and clean:sub(1,1) ~= \"#\" then table.insert(warp_domains, clean .. \".\") end"
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
    local action="ВКЛЮЧИТЬ"
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        action="ВЫКЛЮЧИТЬ"
    fi
    
    if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
        echo -e "\n${YELLOW}Вы уверены что хотите выключить warper? (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}Вы уверены что хотите включить warper? (Y/n)${NC}"
    fi
    
    read -e -p "Выбор: " conf
    if [[ -z "$conf" || "$conf" == "Y" || "$conf" == "y" ]]; then
        if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
            echo -e "${YELLOW}Отключение WARPER...${NC}"
            systemctl stop sing-box
            systemctl disable sing-box 2>/dev/null
            unpatch_kresd
            echo -e "${GREEN}WARPER успешно отключен! Трафик идет по умолчанию.${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            patch_kresd >/dev/null 2>&1
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi
}

toggle_list() {
    local list_name=$1
    local list_file="/root/warper/download/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    
    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден! Пожалуйста, обновите списки через меню.${NC}"
        sleep 2
        return
    fi

    if grep -q "$marker" "$MASTER_FILE"; then
        sed -i "/$marker/,/# --- END ${list_name^^} ---/d" "$MASTER_FILE"
        echo -e "${YELLOW}Домены ${list_name^^} выключены.${NC}"
    else
        echo "$marker" >> "$MASTER_FILE"
        cat "$list_file" >> "$MASTER_FILE"
        echo "# --- END ${list_name^^} ---" >> "$MASTER_FILE"
        echo -e "${GREEN}Домены ${list_name^^} включены.${NC}"
    fi
    prompt_apply
}

update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        local marker="# --- ${list_name^^} ---"
        if grep -q "$marker" "$MASTER_FILE"; then
            sed -i "/$marker/,/# --- END ${list_name^^} ---/d" "$MASTER_FILE"
            echo "$marker" >> "$MASTER_FILE"
            cat "/root/warper/download/${list_name}.txt" >> "$MASTER_FILE"
            echo "# --- END ${list_name^^} ---" >> "$MASTER_FILE"
        fi
    done
}

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p /root/warper/download
    curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh?t=$(date +%s)"
    curl -s -o /root/warper/uninstaller.sh "$REPO_URL/uninstaller.sh?t=$(date +%s)"
    curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service?t=$(date +%s)"
    curl -s -o /usr/lib/systemd/system/warper-autopatch.service "$REPO_URL/warper-autopatch.service?t=$(date +%s)"
    curl -s -o /root/warper/version "$REPO_URL/version?t=$(date +%s)"
    
    curl -s -o /root/warper/download/gemini.txt "$REPO_URL/download/gemini.txt?t=$(date +%s)"
    curl -s -o /root/warper/download/chatgpt.txt "$REPO_URL/download/chatgpt.txt?t=$(date +%s)"
    
    chmod +x /root/warper/warper.sh /root/warper/uninstaller.sh
    systemctl daemon-reload
    systemctl enable warper-autopatch >/dev/null 2>&1
    
    update_list_blocks
    
    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
}

settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        
        if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else AP_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if grep -q "# --- GEMINI ---" "$MASTER_FILE"; then GEM_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GEM_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then GPT_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GPT_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        
        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке:  [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Интеграция доменов Gemini:      [$GEM_STAT]"
        echo -e " ${CYAN}3.${NC} Интеграция доменов ChatGPT:     [$GPT_STAT]"
        echo -e " ${CYAN}4.${NC} Изменить фейковую подсеть:      [Текущая: $SUBNET]"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -e -p "Выбор [0-4]: " set_choice
        case $set_choice in
            1)
                if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
                    systemctl disable warper-autopatch >/dev/null 2>&1
                    echo -e "${YELLOW}Автопатч отключен.${NC}"; sleep 1
                else
                    systemctl enable warper-autopatch >/dev/null 2>&1
                    echo -e "${GREEN}Автопатч включен.${NC}"; sleep 1
                fi
                ;;
            2) toggle_list "gemini" ;;
            3) toggle_list "chatgpt" ;;
            4)
                echo -e "\n${YELLOW}Внимание! Изменение подсети обновит конфигурации и перезапустит службы.${NC}"
                read -e -p "Вы уверены? [y/N]: " conf_sub
                if [[ "$conf_sub" == "y" || "$conf_sub" == "Y" ]]; then
                    while true; do
                        read -e -p "Введите новую подсеть (X.X.X.0/XX) или оставьте пустым для отмены: " new_subnet
                        if [ -z "$new_subnet" ]; then
                            echo -e "${YELLOW}Отмена.${NC}"; sleep 1; break
                        elif [[ "$new_subnet" =~ ^([0-9]{1,3}\.){3}0/[0-9]{1,2}$ ]]; then
                            new_tun="${new_subnet/.0\//.1\/}"
                            
                            sed -i "s|\"$SUBNET\"|\"$new_subnet\"|g" /etc/sing-box/config.json
                            sed -i "s|\"$TUN_IP\"|\"$new_tun\"|g" /etc/sing-box/config.json
                            
                            ESC_OLD=$(echo "$SUBNET" | sed 's/\//\\\//g')
                            sed -i "/$ESC_OLD/d" "$AZ_INC"
                            echo "$new_subnet" >> "$AZ_INC"
                            
                            echo "SUBNET=\"$new_subnet\"" > "$CONF_FILE"
                            echo "TUN_IP=\"$new_tun\"" >> "$CONF_FILE"
                            SUBNET="$new_subnet"
                            TUN_IP="$new_tun"
                            
                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret (подождите)...${NC}"
                            export DEBIAN_FRONTEND=noninteractive
                            export SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
                            
                            echo -e "${CYAN}Перезапуск службы sing-box для применения правил...${NC}"
                            systemctl restart sing-box
                            
                            echo -e "${GREEN}Подсеть успешно изменена!${NC}"
                            sleep 2
                            break
                        else
                            echo -e "${RED}Неверный формат! Ожидается подсеть вида X.X.X.0/XX (например 10.99.0.0/24)${NC}"
                        fi
                    done
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
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
        echo -e " ${YELLOW}5.${NC} Посмотреть логи"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -e -p "Выбор [0-5]: " sb_choice
        case $sb_choice in
            1) if prompt_confirm; then systemctl start sing-box; echo -e "${GREEN}Запущено.${NC}"; sleep 1; fi ;;
            2) if prompt_confirm; then systemctl stop sing-box; echo -e "${YELLOW}Остановлено.${NC}"; sleep 1; fi ;;
            3) if prompt_confirm; then systemctl enable sing-box; echo -e "${GREEN}Добавлено в автозапуск.${NC}"; sleep 1; fi ;;
            4) if prompt_confirm; then systemctl disable sing-box; echo -e "${YELLOW}Убрано из автозапуска.${NC}"; sleep 1; fi ;;
            5) show_logs ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    REMOTE_VER=$(curl -s --max-time 2 "$REPO_URL/version?t=$(date +%s)" | tr -d '\r\n')
    if [ -z "$REMOTE_VER" ]; then REMOTE_VER="$LOCAL_VER"; fi
    
    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления Warper${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"
    
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"; else VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"; fi
    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}запущен${NC}"; else SB_RUN="${RED}выключен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена автозагрузка${NC}"; else SB_EN="${RED}отключена автозагрузка${NC}"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then KR_STAT="${GREEN}пропатчен${NC}"; else KR_STAT="${RED}не пропатчен${NC}"; fi
    if diff -q "$MASTER_FILE" "$ACTIVE_FILE" >/dev/null 2>&1; then DOM_STAT="${GREEN}синхронизированы${NC}"; else DOM_STAT="${RED}не синхронизированы${NC}"; fi
    if grep -q "$SUBNET" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}добавлена${NC}"; else AZ_STAT="${RED}не добавлена${NC}"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}включено${NC}"; else AP_STAT="${RED}отключено${NC}"; fi

    echo -e " - Версия: $VER_STR"
    echo -e " - Sing-box ($SB_RUN, $SB_EN)"
    echo -e " - Kresd.conf ($KR_STAT)"
    echo -e " - 📁 Домены: /root/warper/domains.txt ($DOM_STAT)"
    echo -e " - Fake подсеть $SUBNET в include-ips ($AZ_STAT)"
    echo -e " - Автовосстановление DNS ($AP_STAT)"
    
    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Пропатчить DNS / Синхронизация"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи"
    
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        echo -e " ${RED}8. ⏹ Отключить WARPER${NC}"
    else
        echo -e " ${GREEN}8. ▶ Включить WARPER${NC}"
    fi

    echo -e " ${CYAN}9. 🛠 Настройки (Автопатч, Подсеть, Списки)${NC}"
    
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then 
        echo -e " ${YELLOW}10. ⚡ Обновить WARPER до $REMOTE_VER${NC}"
    else 
        echo -e " ${CYAN}10.${NC} 🔄 Проверить и обновить списки доменов"
    fi
    
    echo -e " ${RED}U. Удалить warper полностью${NC}"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"
}

if [ "$1" == "patch" ]; then patch_kresd >/dev/null 2>&1; exit 0; fi

while true; do
    show_main_menu
    read -e -p "Выбор: " choice
    
    choice=$(echo "$choice" | tr -d ' ')
    
    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
            read -e -p "> " new_domain
            if [ -z "$new_domain" ]; then echo -e "${RED}Пустой ввод!${NC}"; sleep 1
            elif grep -q "^$new_domain$" "$MASTER_FILE"; then echo -e "${YELLOW}Домен уже есть!${NC}"; sleep 1
            else echo "$new_domain" >> "$MASTER_FILE"; echo -e "${GREEN}Добавлено!${NC}"; prompt_apply; fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -e -p "> " del_domain
            if grep -q "^$del_domain$" "$MASTER_FILE"; then sed -i "/^$del_domain$/d" "$MASTER_FILE"; echo -e "${GREEN}Удалено!${NC}"; prompt_apply
            else echo -e "${RED}Домен не найден!${NC}"; sleep 1; fi
            ;;
        3)
            echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
            if [ -s "$MASTER_FILE" ]; then cat "$MASTER_FILE"; else echo -e "${YELLOW}Список пуст.${NC}"; fi
            echo -e "${CYAN}---------------------${NC}"
            read -p "Нажмите Enter..."
            ;;
        4) nano "$MASTER_FILE"; prompt_apply ;;
        5) echo -e "\n${YELLOW}Запуск синхронизации...${NC}"; patch_kresd; echo -e "${GREEN}Готово!${NC}"; sleep 1 ;;
        6) singbox_menu ;;
        7) show_logs ;;
        8) toggle_warper ;;
        9) settings_menu ;;
        10) 
            if [ "$REMOTE_VER" != "$LOCAL_VER" ] && [ -n "$REMOTE_VER" ]; then
                update_warper
            else
                echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                mkdir -p /root/warper/download
                curl -s -o /root/warper/download/gemini.txt "$REPO_URL/download/gemini.txt?t=$(date +%s)"
                curl -s -o /root/warper/download/chatgpt.txt "$REPO_URL/download/chatgpt.txt?t=$(date +%s)"
                update_list_blocks
                echo -e "${GREEN}Списки успешно обновлены!${NC}"
                prompt_apply
            fi
            ;;
        u|U) 
            if [ -f "/root/warper/uninstaller.sh" ]; then
                exec bash /root/warper/uninstaller.sh
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
