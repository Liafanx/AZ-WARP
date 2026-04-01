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
    local action="ВКЛЮЧИТЬ"
    local action_ru="включить"
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        action="ВЫКЛЮЧИТЬ"
        action_ru="выключить"
    fi
    
    echo -e "\n${YELLOW}Внимание: Вы собираетесь ${action_ru} WARPER.${NC}"
    read -p "Вы уверены? (y/N): " conf
    if [[ ! "$conf" =~ ^[Yy]$ ]]; then return; fi

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
        patch_kresd
        echo -e "${GREEN}WARPER успешно включен!${NC}"
    fi
    sleep 2
}

if [ "$1" == "patch" ]; then patch_kresd; exit 0; fi

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    curl -s -o /root/warper/warper.sh "$REPO_URL/warper.sh"
    curl -s -o /root/warper/uninstaller.sh "$REPO_URL/uninstaller.sh"
    curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service"
    curl -s -o /root/warper/version "$REPO_URL/version"
    chmod +x /root/warper/warper.sh /root/warper/uninstaller.sh
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
            5) echo -e "\n${CYAN}Открываю логи... (Для выхода нажмите Ctrl+C)${NC}"; sleep 1; journalctl -u sing-box -f ;;
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
    
    # 1. Версия
    if [ "$REMOTE_VER" != "$LOCAL_VER" ] && [ -n "$REMOTE_VER" ]; then VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"; else VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"; fi
    # 2. Sing-box
    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}запущен${NC}"; else SB_RUN="${RED}выключен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена автозагрузка${NC}"; else SB_EN="${RED}отключена автозагрузка${NC}"; fi
    # 3. Kresd.conf
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then KR_STAT="${GREEN}пропатчен${NC}"; else KR_STAT="${RED}не пропатчен${NC}"; fi
    # 4. Домены
    if diff -q "$MASTER_FILE" "$ACTIVE_FILE" >/dev/null 2>&1; then DOM_STAT="${GREEN}синхронизированы${NC}"; else DOM_STAT="${RED}не синхронизированы${NC}"; fi
    # 5. Fake подсеть
    if grep -q "198.18.0.0/24" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}добавлена${NC}"; else AZ_STAT="${RED}не добавлена${NC}"; fi

    echo -e " - Версия: $VER_STR"
    echo -e " - Sing-box ($SB_RUN, $SB_EN)"
    echo -e " - Kresd.conf ($KR_STAT)"
    echo -e " - 📁 Домены: /root/warper/domains.txt ($DOM_STAT)"
    echo -e " - Fake подсеть 198.18.0.0/24 в include-ips ($AZ_STAT)"
    
    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Восстановить / Пропатчить DNS"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи"
    
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        echo -e " ${RED}8. ⏹ Отключить WARPER${NC}"
    else
        echo -e " ${GREEN}8. ▶ Включить WARPER${NC}"
    fi

    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then echo -e " ${YELLOW}9. ⚡ Обновить WARPER до $REMOTE_VER${NC}"; fi
    echo -e " ${RED}U. Удалить warper полностью${NC}"
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
        7) echo -e "\n${CYAN}Открываю логи... (Для выхода нажмите Ctrl+C)${NC}"; sleep 1; journalctl -u sing-box -f ;;
        8) toggle_warper ;;
        9) update_warper ;;
        [Uu]) 
            if [ -f "/root/warper/uninstaller.sh" ]; then
                bash /root/warper/uninstaller.sh
            else
                curl -fsSL "$REPO_URL/uninstaller.sh" | bash
            fi
            if [ ! -f "/usr/local/bin/warper" ]; then exit 0; fi # Если удаление успешно, скрипт завершится
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
