#!/bin/bash
# warper menus: main.sh
# Главное меню WARPER и главный цикл обработки выбора.
# Отображает полный статус системы и предоставляет
# доступ ко всем основным функциям.
# Подключается через source из warper.sh

# Отображает главное меню с полным статусом WARPER.
# Вызывается перед каждой итерацией главного цикла.
show_main_menu() {
    clear
    load_slave_config

    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)

    local VER_STR SB_RUN SB_EN KR_STAT DOM_STAT AZ_STAT AP_STAT
    local UPDATE_AVAILABLE LOG_LEVEL MTU AZ_WARP_STAT WARP_KEYS_SRC MODE_DISPLAY
    UPDATE_AVAILABLE=false
    LOG_LEVEL=$(get_log_level)
    MTU=$(get_mtu)

    # Версия
    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER${NC} (📦 Доступно обновление: ${GREEN}$REMOTE_VER${NC})"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER${NC} (✅ актуальная)"
    fi

    # ANTIZAPRET_WARP
    if check_antizapret_warp; then
        AZ_WARP_STAT="${RED}⚠️  ANTIZAPRET_WARP=y (КОНФЛИКТ!)${NC}"
    else
        AZ_WARP_STAT="${GREEN}✅ OK${NC}"
    fi

    # Sing-box
    if systemctl is-active --quiet sing-box; then
        SB_RUN="${GREEN}🟢 запущен${NC}"
    else
        SB_RUN="${RED}🔴 остановлен${NC}"
    fi

    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
        SB_EN="${GREEN}включена${NC}"
    else
        SB_EN="${RED}выключена${NC}"
    fi

    # DNS
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        KR_STAT="${GREEN}✅ пропатчен${NC}"
    else
        KR_STAT="${RED}❌ не пропатчен${NC}"
    fi

    # Домены
    if domains_in_sync; then
        DOM_STAT="${GREEN}✅ синхронизированы${NC}"
    else
        DOM_STAT="${YELLOW}⚠️  требуется синхронизация${NC}"
    fi

    # AntiZapret include-ips
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then
        AZ_STAT="${GREEN}✅ добавлена${NC}"
    else
        AZ_STAT="${RED}❌ отсутствует${NC}"
    fi

    # Автопатч
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
        AP_STAT="${GREEN}✅ включён${NC}"
    else
        AP_STAT="${RED}❌ выключен${NC}"
    fi

    # Режим маршрутизации
    load_wg_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        MODE_DISPLAY="${CYAN}Slave ($SLAVE_SERVER:$SLAVE_PORT)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        MODE_DISPLAY="${CYAN}WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)${NC}"
    else
        MODE_DISPLAY="${GREEN}WARP (локальный)${NC}"
    fi

    # Источник WARP-ключей
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        WARP_KEYS_SRC="${CYAN}не используются (Slave)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        if [ "$WG_CONF_FILE" = "manual" ] || [ -z "$WG_CONF_FILE" ]; then
            WARP_KEYS_SRC="${CYAN}WG: ручной ввод${NC}"
        else
            WARP_KEYS_SRC="${CYAN}WG: ${WG_CONF_FILE}${NC}"
        fi
    elif [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
        local cur_pk=""
        if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
            cur_pk=$(jq -r \
                '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
                "$SINGBOX_CONF" 2>/dev/null || true)
        fi
        WARP_KEYS_SRC="${YELLOW}конфиг sing-box${NC}"
        if [ -n "$cur_pk" ]; then
            # Приоритет 1: системный warp.conf
            if [ -f "$WARP_SYSTEM_CONF" ]; then
                local sys_pk=""
                sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null \
                    | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                if [ -n "$sys_pk" ] && [ "$sys_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}$WARP_SYSTEM_CONF${NC}"
                fi
            fi
            # Приоритет 2: локальный wgcf
            if [ "$WARP_KEYS_SRC" = "${YELLOW}конфиг sing-box${NC}" ] && \
               [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' \
               "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
                local wgcf_pk=""
                wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" \
                    | awk '{print $3}' | tr -d '\r\n')
                if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}$WGCF_DIR/wgcf-profile.conf${NC}"
                fi
            fi
            # Приоритет 3: /root/wgcf-profile.conf
            if [ "$WARP_KEYS_SRC" = "${YELLOW}конфиг sing-box${NC}" ] && \
               [ -f "/root/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' \
               "/root/wgcf-profile.conf" 2>/dev/null; then
                local root_pk=""
                root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" \
                    | awk '{print $3}' | tr -d '\r\n')
                if [ -n "$root_pk" ] && [ "$root_pk" = "$cur_pk" ]; then
                    WARP_KEYS_SRC="${GREEN}/root/wgcf-profile.conf${NC}"
                fi
            fi
        fi
    else
        WARP_KEYS_SRC="${YELLOW}локальные ключи${NC}"
    fi

    # ── Вывод заголовка ──────────────────────────────────────────────────

    echo -e "${CYAN}================================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления WARPER${NC} 🚀"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""
    echo -e " 📌 ${CYAN}Версия:${NC}        $VER_STR"
    echo -e " 🔗 ${CYAN}AntiZapret:${NC}    $AZ_WARP_STAT"
    echo -e ""
    echo -e " 📡 ${CYAN}Sing-box:${NC}      $SB_RUN | Автозагрузка: $SB_EN"
    echo -e " ⚙️  ${CYAN}Параметры:${NC}    Log: ${CYAN}$LOG_LEVEL${NC} | MTU: ${CYAN}$MTU${NC}"
    echo -e " 🔀 ${CYAN}Режим:${NC}         $MODE_DISPLAY"
    echo -e ""
    echo -e " 🌐 ${CYAN}DNS (kresd):${NC}   $KR_STAT"
    echo -e " 📁 ${CYAN}Домены:${NC}        $DOM_STAT"
    echo -e "    ${CYAN}Файл:${NC}          ${YELLOW}$MASTER_FILE${NC}"
    echo -e ""
    echo -e " 🔀 ${CYAN}Fake-подсеть:${NC}  ${YELLOW}$SUBNET${NC} — $AZ_STAT"
    echo -e " 🔄 ${CYAN}Автопатч DNS:${NC}  $AP_STAT"
    echo -e " 🔑 ${CYAN}WARP-ключи:${NC}    $WARP_KEYS_SRC"

    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] && [ -n "$SLAVE_PASSWORD" ]; then
        echo -e " 🔐 ${CYAN}SS-ключ:${NC}       ${YELLOW}${SLAVE_PASSWORD:0:8}...${NC}"
    fi

    local fullvpn_resolve_display
    if [ "$FULLVPN_WARP_RESOLVE" = "y" ]; then
        if check_vpn_warp; then
            fullvpn_resolve_display="${RED}ВКЛ (конфликт VPN_WARP=y)${NC}"
        else
            fullvpn_resolve_display="${GREEN}ВКЛ${NC}"
        fi
    else
        fullvpn_resolve_display="${RED}ВЫКЛ${NC}"
    fi
    echo -e " 🌐 ${CYAN}FullVPN WARP доменов:${NC}  $fullvpn_resolve_display"    

    # Предупреждение о правилах up.sh
    if needs_down_sh; then
        echo -e ""
        echo -e " ${RED}⚠️  ВНИМАНИЕ:${NC}     ${RED}Требуется перезапуск правил AntiZapret!${NC}"
        echo -e "                  ${YELLOW}Выполните: down.sh && up.sh${NC}"
    fi

    # ── Меню ─────────────────────────────────────────────────────────────

    echo -e ""
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} ➕ Добавить домен в WARP"
    echo -e " ${RED}2.${NC} ➖ Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} 📋 Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} ✏️  Редактировать список (nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Применить изменения / Синхронизация / Перезапуск Kresd"
    echo -e " ${CYAN}6.${NC} ⚙️  Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи sing-box"
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика (doctor)"
    echo -e " ${CYAN}S.${NC} 📊 Краткий статус"
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}K.${NC} 🔐 Показать полный SS-ключ"
    fi
    echo -e "${CYAN}------------------------------------------------${NC}"

    # Кнопка включения / выключения WARPER
    if systemctl is-active --quiet sing-box || \
       grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        echo -e " ${RED}8.${NC} ⏹️  Отключить WARPER"
    else
        echo -e " ${GREEN}8.${NC} ▶️  Включить WARPER"
    fi

    # IP-подсети
    local ip_cnt_menu route_cnt_menu
    ip_cnt_menu=$(count_ip_ranges)
    route_cnt_menu=$(count_tun_routes)
    if [ "$ip_cnt_menu" -gt 0 ] || [ "$route_cnt_menu" -gt 0 ]; then
        local ip_sync_menu
        if ip_ranges_in_sync; then
            ip_sync_menu="${GREEN}✅${NC}"
        else
            ip_sync_menu="${YELLOW}⚠️${NC}"
        fi
        echo -e " ${CYAN}I.${NC} 🌐 IP-подсети ($ip_sync_menu ${CYAN}файл:${NC}${ip_cnt_menu} ${CYAN}маршруты:${NC}${route_cnt_menu})"
    else
        echo -e " ${CYAN}I.${NC} 🌐 Управление IP-подсетями"
    fi

    echo -e " ${CYAN}9.${NC} 🛠️  Настройки"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}10.${NC} ⚡ Обновить WARPER до ${GREEN}$REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}10.${NC} 🔄 Проверить обновления списков доменов"
    fi

    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${RED}U.${NC} 🗑️  Удалить WARPER полностью"
    echo -e " ${CYAN}0.${NC} 🚪 Выход"
    echo -e "${CYAN}================================================${NC}"

    MENU_UPDATE_AVAILABLE=$UPDATE_AVAILABLE
    MENU_REMOTE_VER=$REMOTE_VER
}

# Главный интерактивный цикл WARPER.
# Отображает меню и обрабатывает выбор пользователя.
run_main_menu() {
    while true; do
        show_main_menu
        read -r -e -p "Выбор: " choice
        choice=$(echo "${choice:-}" | tr -d ' ')

        case "$choice" in

            # ── Добавить домен ────────────────────────────────────────────
            1)
                echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
                read -r -e -p "> " raw_domain
                local new_domain
                new_domain=$(validate_domain "${raw_domain:-}") || {
                    echo -e "${RED}Некорректный формат домена!${NC}"
                    sleep 2; continue
                }
                if grep -qxF "$new_domain" "$MASTER_FILE"; then
                    echo -e "${YELLOW}Домен уже есть в списке!${NC}"; sleep 1
                else
                    insert_user_domain "$new_domain"
                    echo -e "${GREEN}Домен '$new_domain' добавлен!${NC}"
                    prompt_apply
                fi
                ;;

            # ── Удалить домен ─────────────────────────────────────────────
            2)
                echo -e "\n${CYAN}Введите домен для удаления:${NC}"
                read -r -e -p "> " raw_del_domain
                local del_domain
                del_domain=$(validate_domain "${raw_del_domain:-}") || {
                    echo -e "${RED}Некорректный формат домена!${NC}"
                    sleep 2; continue
                }
                if grep -qxF "$del_domain" "$MASTER_FILE"; then
                    local escaped
                    escaped=$(escape_regex "$del_domain")
                    sed -i "/^${escaped}$/d" "$MASTER_FILE"
                    rebuild_master_file
                    echo -e "${GREEN}Домен '$del_domain' удалён!${NC}"
                    prompt_apply
                else
                    echo -e "${RED}Домен не найден в списке!${NC}"; sleep 1
                fi
                ;;

            # ── Показать список доменов ───────────────────────────────────
            3)
                rebuild_master_file
                echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
                if [ -s "$MASTER_FILE" ]; then
                    cat "$MASTER_FILE"
                else
                    echo -e "${YELLOW}Список пуст.${NC}"
                fi
                echo -e "${CYAN}---------------------${NC}"
                read -r -p "Нажмите Enter..."
                ;;

            # ── Редактировать в nano ──────────────────────────────────────
            4)
                local before_hash after_hash
                before_hash=$(canonical_master_hash)
                nano "$MASTER_FILE"
                after_hash=$(canonical_master_hash)
                if [ "$before_hash" != "$after_hash" ]; then
                    rebuild_master_file
                    prompt_apply
                else
                    rebuild_master_file
                    echo -e "${YELLOW}Изменений не обнаружено.${NC}"; sleep 1
                fi
                ;;

            # ── Синхронизация / патч DNS ──────────────────────────────────
            5)
                echo -e "\n${YELLOW}Запуск синхронизации...${NC}"
                rebuild_master_file
                if is_warper_active; then
                    if patch_kresd; then
                        echo -e "${GREEN}Готово!${NC}"
                    else
                        echo -e "${RED}Ошибка синхронизации.${NC}"
                    fi
                else
                    sync_domains
                    echo -e "${GREEN}Домены синхронизированы. WARPER выключен — патч DNS не применён.${NC}"
                fi
                sleep 1
                ;;

            # ── Управление sing-box ───────────────────────────────────────
            6) singbox_menu ;;

            # ── Логи ──────────────────────────────────────────────────────
            7) show_logs ;;

            # ── Включить / выключить WARPER ───────────────────────────────
            8) toggle_warper ;;

            # ── Настройки ─────────────────────────────────────────────────
            9) settings_menu ;;

            # ── Обновление / проверка списков ─────────────────────────────
            10)
                if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                    update_warper
                else
                    echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                    mkdir -p "$DOWNLOAD_DIR"

                    download_file_safe "$REPO_URL/download/gemini.txt" \
                        "/tmp/gemini.txt" "gemini.txt" || { sleep 2; continue; }
                    download_file_safe "$REPO_URL/download/chatgpt.txt" \
                        "/tmp/chatgpt.txt" "chatgpt.txt" || {
                        rm -f /tmp/gemini.txt; sleep 2; continue
                    }

                    local lists_changed=false
                    if ! cmp -s /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt" 2>/dev/null; then
                        mv /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt"
                        lists_changed=true
                    else
                        rm -f /tmp/gemini.txt
                    fi
                    if ! cmp -s /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt" 2>/dev/null; then
                        mv /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt"
                        lists_changed=true
                    else
                        rm -f /tmp/chatgpt.txt
                    fi

                    if [ "$lists_changed" = true ]; then
                        update_list_blocks
                        echo -e "${GREEN}Найдены новые домены! Списки обновлены.${NC}"
                        prompt_apply
                    else
                        echo -e "${GREEN}Версия и файлы актуальны.${NC}"
                        sleep 2
                    fi
                fi
                ;;

            # ── IP-подсети ────────────────────────────────────────────────
            i|I) ip_ranges_menu ;;

            # ── Doctor ────────────────────────────────────────────────────
            d|D)
                doctor
                read -r -p "Нажмите Enter..."
                ;;

            # ── Status ────────────────────────────────────────────────────
            s|S)
                status_cmd
                read -r -p "Нажмите Enter..."
                ;;

            # ── Показать полный SS-ключ ───────────────────────────────────
            k|K)
                load_slave_config
                if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] && [ -n "$SLAVE_PASSWORD" ]; then
                    echo -e "\n${CYAN}Полный ключ Shadowsocks:${NC} ${YELLOW}${SLAVE_PASSWORD}${NC}"
                    echo -e "${CYAN}Сервер:${NC} ${YELLOW}${SLAVE_SERVER}:${SLAVE_PORT}${NC}"
                else
                    echo -e "${YELLOW}Режим Slave не активен.${NC}"
                fi
                read -r -p "Нажмите Enter..."
                ;;

            # ── Удаление WARPER ───────────────────────────────────────────
            u|U)
                if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                    exec bash "$WARPER_DIR/uninstaller.sh"
                else
                    exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
                fi
                ;;

            # ── Выход ─────────────────────────────────────────────────────
            0)
                clear
                exit 0
                ;;

            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}
