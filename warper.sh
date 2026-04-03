#!/bin/bash

set -u

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
MASTER_FILE="$WARPER_DIR/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
AZ_INC="/root/antizapret/config/include-ips.txt"
SINGBOX_CONF="/etc/sing-box/config.json"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"

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

# Кеш удалённой версии
REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

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

# === ФУНКЦИИ-ПОМОЩНИКИ ===

escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    if [ -z "$domain" ]; then
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    echo "$domain"
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

version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        REMOTE_VER_CACHE=$(curl -s --max-time 2 "$REPO_URL/version?t=$now" | tr -d '\r\n')
        REMOTE_VER_TIME=$now
    fi
    echo "${REMOTE_VER_CACHE:-$LOCAL_VER}"
}

# Извлекает чистый список доменов (без комментариев, пустых строк, дубликатов)
get_clean_domains() {
    grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u
}

# Синхронизация: создаёт чистый активный файл для kresd
sync_domains() {
    get_clean_domains "$MASTER_FILE" > "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

# Проверяет, синхронизированы ли домены (сравнивает очищенные версии)
domains_in_sync() {
    local clean_master clean_active
    clean_master=$(get_clean_domains "$MASTER_FILE")
    clean_active=$(cat "$ACTIVE_FILE" 2>/dev/null | sort -u)
    [ "$clean_master" = "$clean_active" ]
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
    local tmpfile
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)
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
    {print}' "$KRESD_CONF" > "$tmpfile" && mv "$tmpfile" "$KRESD_CONF"
    chmod 644 "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2
}

unpatch_kresd() {
    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
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
            systemctl disable warper-autopatch 2>/dev/null
            unpatch_kresd
            echo -e "${GREEN}WARPER успешно отключен! Трафик идет по умолчанию.${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            systemctl enable warper-autopatch 2>/dev/null
            patch_kresd >/dev/null 2>&1
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi
}

toggle_list() {
    local list_name=$1
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден! Пожалуйста, обновите списки через меню.${NC}"
        sleep 2
        return
    fi

    if grep -q "$marker" "$MASTER_FILE"; then
        # Выключение: удаляем блок с маркерами
        sed -i "/$marker/,/$end_marker/d" "$MASTER_FILE"
        echo -e "${YELLOW}Домены ${list_name^^} выключены.${NC}"
    else
        # Включение: сначала удаляем возможные дубликаты доменов из списка
        # (на случай если маркеры были удалены вручную, а домены остались)
        local dedup_tmp
        dedup_tmp=$(mktemp /tmp/warper_dedup.XXXXXX)
        grep -vE '^\s*#|^\s*$' "$list_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$dedup_tmp"
        if [ -s "$dedup_tmp" ]; then
            # Удаляем из мастер-файла только точные совпадения строк, которые НЕ внутри других блоков
            local master_tmp
            master_tmp=$(mktemp /tmp/warper_master.XXXXXX)
            local in_block=false
            while IFS= read -r line; do
                # Проверяем, находимся ли мы внутри другого блока
                if [[ "$line" =~ ^#\ ---\ .+\ ---$ ]] && [[ ! "$line" =~ END ]]; then
                    in_block=true
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                if [[ "$line" =~ ^#\ ---\ END\ .+\ ---$ ]]; then
                    in_block=false
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                # Если внутри другого блока — не трогаем
                if [ "$in_block" = true ]; then
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                # Если строка — домен из добавляемого списка, пропускаем (удаляем дубликат)
                local clean_line
                clean_line=$(echo "$line" | xargs)
                if [ -n "$clean_line" ] && [ "${clean_line:0:1}" != "#" ] && grep -qxF "$clean_line" "$dedup_tmp"; then
                    continue
                fi
                echo "$line" >> "$master_tmp"
            done < "$MASTER_FILE"
            mv "$master_tmp" "$MASTER_FILE"
        fi
        rm -f "$dedup_tmp"

        # Добавляем блок с маркерами
        echo "$marker" >> "$MASTER_FILE"
        cat "$list_file" >> "$MASTER_FILE"
        echo "$end_marker" >> "$MASTER_FILE"
        echo -e "${GREEN}Домены ${list_name^^} включены.${NC}"
    fi
    prompt_apply
}

update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        local marker="# --- ${list_name^^} ---"
        local end_marker="# --- END ${list_name^^} ---"
        local list_file="$DOWNLOAD_DIR/${list_name}.txt"
        if grep -q "$marker" "$MASTER_FILE"; then
            if [ ! -f "$list_file" ]; then
                echo -e "${RED}Файл $list_file не найден, пропускаем ${list_name}${NC}"
                continue
            fi
            sed -i "/$marker/,/$end_marker/d" "$MASTER_FILE"
            echo "$marker" >> "$MASTER_FILE"
            cat "$list_file" >> "$MASTER_FILE"
            echo "$end_marker" >> "$MASTER_FILE"
        fi
    done
}

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"
    curl -s -o "$WARPER_DIR/warper.sh" "$REPO_URL/warper.sh?t=$(date +%s)"
    curl -s -o "$WARPER_DIR/uninstaller.sh" "$REPO_URL/uninstaller.sh?t=$(date +%s)"
    curl -s -o /usr/lib/systemd/system/sing-box.service "$REPO_URL/sing-box.service?t=$(date +%s)"
    curl -s -o /usr/lib/systemd/system/warper-autopatch.service "$REPO_URL/warper-autopatch.service?t=$(date +%s)"
    curl -s -o "$WARPER_DIR/version" "$REPO_URL/version?t=$(date +%s)"

    curl -s -o "$DOWNLOAD_DIR/gemini.txt" "$REPO_URL/download/gemini.txt?t=$(date +%s)"
    curl -s -o "$DOWNLOAD_DIR/chatgpt.txt" "$REPO_URL/download/chatgpt.txt?t=$(date +%s)"

    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
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

        local AP_STAT GEM_STAT GPT_STAT
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
        case "${set_choice:-}" in
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
                        elif validate_subnet "$new_subnet"; then
                            local new_tun
                            new_tun=$(calculate_tun_ip "$new_subnet")

                            sed -i "s|\"$SUBNET\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
                            sed -i "s|\"$TUN_IP\"|\"$new_tun\"|g" "$SINGBOX_CONF"

                            sed -i "\|$SUBNET|d" "$AZ_INC"
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
                            echo -e "${RED}Некорректная подсеть! Ожидается формат X.X.X.0/XX с валидными октетами (0-255) и маской (1-32).${NC}"
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
        case "${sb_choice:-}" in
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
    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)

    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления Warper${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"

    local VER_STR SB_RUN SB_EN KR_STAT DOM_STAT AZ_STAT AP_STAT UPDATE_AVAILABLE
    UPDATE_AVAILABLE=false

    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"
    fi

    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}зап��щен${NC}"; else SB_RUN="${RED}выключен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена автозагрузка${NC}"; else SB_EN="${RED}отключена автозагрузка${NC}"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then KR_STAT="${GREEN}пропатчен${NC}"; else KR_STAT="${RED}не пропатчен${NC}"; fi
    if domains_in_sync; then DOM_STAT="${GREEN}синхронизированы${NC}"; else DOM_STAT="${RED}не синхронизированы${NC}"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}добавлена${NC}"; else AZ_STAT="${RED}не добавлена${NC}"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}включено${NC}"; else AP_STAT="${RED}отключено${NC}"; fi

    echo -e " - Версия: $VER_STR"
    echo -e " - Sing-box ($SB_RUN, $SB_EN)"
    echo -e " - Kresd.conf ($KR_STAT)"
    echo -e " - 📁 Домены: $MASTER_FILE ($DOM_STAT)"
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

    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        echo -e " ${RED}8. ⏹ Отключить WARPER${NC}"
    else
        echo -e " ${GREEN}8. ▶ Включить WARPER${NC}"
    fi

    echo -e " ${CYAN}9. 🛠 Настройки (Автопатч, Подсеть, Списки)${NC}"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}10. ⚡ Обновить WARPER до $REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}10.${NC} 🔄 Проверить и обновить списки доменов"
    fi

    echo -e " ${RED}U. Удалить warper полностью${NC}"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"

    # Экспортируем для использования в main loop
    MENU_UPDATE_AVAILABLE=$UPDATE_AVAILABLE
    MENU_REMOTE_VER=$REMOTE_VER
}

# === ТОЧКА ВХОДА ===

if [ "${1:-}" == "patch" ]; then patch_kresd >/dev/null 2>&1; exit 0; fi

MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

while true; do
    show_main_menu
    read -e -p "Выбор: " choice

    choice=$(echo "${choice:-}" | tr -d ' ')

    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
            read -e -p "> " raw_domain
            new_domain=$(validate_domain "${raw_domain:-}") || {
                echo -e "${RED}Некорректный формат домена! Допускаются буквы, цифры, точки и дефисы.${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$new_domain" "$MASTER_FILE"; then
                echo -e "${YELLOW}Домен уже есть в списке!${NC}"
                sleep 1
            else
                echo "$new_domain" >> "$MASTER_FILE"
                echo -e "${GREEN}Домен '$new_domain' добавлен!${NC}"
                prompt_apply
            fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -e -p "> " raw_del_domain
            del_domain=$(validate_domain "${raw_del_domain:-}") || {
                echo -e "${RED}Некорректный формат домена!${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$del_domain" "$MASTER_FILE"; then
                escaped=$(escape_regex "$del_domain")
                sed -i "/^${escaped}$/d" "$MASTER_FILE"
                echo -e "${GREEN}Домен '$del_domain' удалён!${NC}"
                prompt_apply
            else
                echo -e "${RED}Домен не найден в списке!${NC}"
                sleep 1
            fi
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
            if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                update_warper
            else
                echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                mkdir -p "$DOWNLOAD_DIR"

                curl -s -o /tmp/gemini.txt "$REPO_URL/download/gemini.txt?t=$(date +%s)"
                curl -s -o /tmp/chatgpt.txt "$REPO_URL/download/chatgpt.txt?t=$(date +%s)"

                LISTS_CHANGED=false

                if ! cmp -s /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt" 2>/dev/null; then
                    mv /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/gemini.txt
                fi

                if ! cmp -s /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt" 2>/dev/null; then
                    mv /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/chatgpt.txt
                fi

                if [ "$LISTS_CHANGED" = true ]; then
                    update_list_blocks
                    echo -e "${GREEN}Найдены новые домены! Списки успешно обновлены.${NC}"
                    prompt_apply
                else
                    echo -e "${GREEN}Версия и файлы актуальны, обновление не требуется.${NC}"
                    sleep 2
                fi
            fi
            ;;
        u|U)
            if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                exec bash "$WARPER_DIR/uninstaller.sh"
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
