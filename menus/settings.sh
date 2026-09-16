#!/bin/bash
# warper menus: settings.sh
# Меню настроек WARPER: автопатч, списки доменов, подсеть,
# log level, MTU, режим маршрутизации, WARP-ключи.
# Также содержит switch_outbound_mode() для переключения WARP/Slave/WG.
# Подключается через source из warper.sh

# ===== Переключение режима исходящего соединения =====

# Интерактивное переключение между режимами WARP / Slave / WG.
# При переключении пересобирает config.json и перезапускает sing-box.
# Поддерживает сохранённые подключения для Slave и WG.
switch_outbound_mode() {
    load_slave_config

    echo -e "\n${CYAN}================================================${NC}"
    echo -e "       ${YELLOW}Режим маршрутизации трафика${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""

    if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
        echo -e " Текущий режим: ${GREEN}WARP (локальный)${NC}"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        load_wg_config
        echo -e " Текущий режим: ${CYAN}WG (${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT})${NC}"
    else
        echo -e " Текущий режим: ${CYAN}Slave (донор: ${SLAVE_SERVER}:${SLAVE_PORT})${NC}"
    fi

    echo -e ""
    echo -e " ${GREEN}1.${NC} WARP  — трафик через Cloudflare WARP"
    echo -e " ${CYAN}2.${NC} Slave — трафик через донор-сервер (Shadowsocks)"
    echo -e " ${CYAN}3.${NC} WG    — трафик через WireGuard-соединение"
    echo -e " ${CYAN}0.${NC} Назад"
    echo -e "${CYAN}================================================${NC}"

    read -r -p "Выбор [0-3]: " mode_choice

    case "${mode_choice:-}" in

        # ── WARP ──────────────────────────────────────────────────────────
        1)
            if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
                echo -e "${YELLOW}Уже в режиме WARP.${NC}"
                sleep 1; return
            fi

            echo -e "${YELLOW}Переключение на WARP...${NC}"

            if [ ! -f "$SINGBOX_TEMPLATE" ]; then
                download_file_safe "$REPO_URL/templates/config.json.template" \
                    "$SINGBOX_TEMPLATE" "config.json.template" || {
                    echo -e "${RED}Не удалось загрузить шаблон WARP-конфига.${NC}"
                    sleep 2; return
                }
            fi

            CURRENT_OUTBOUND_MODE="warp"
            save_slave_config

            # Показываем источник ключей
            local warp_creds_info=""
            if [ -f "$WARP_SYSTEM_CONF" ]; then
                local sys_pk
                sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null \
                    | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                [ -n "$sys_pk" ] && warp_creds_info="$WARP_SYSTEM_CONF"
            fi
            if [ -z "$warp_creds_info" ] && [ -f "$SINGBOX_CONF" ] && \
               command -v jq >/dev/null 2>&1; then
                local existing_pk
                existing_pk=$(jq -r \
                    '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
                    "$SINGBOX_CONF" 2>/dev/null || true)
                if [ -n "$existing_pk" ] && [ "$existing_pk" != "__WARP_PRIVATE_KEY__" ]; then
                    warp_creds_info="существующий конфиг sing-box"
                fi
            fi
            if [ -z "$warp_creds_info" ] && [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
               grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' \
               "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
                warp_creds_info="$WGCF_DIR/wgcf-profile.conf"
            fi

            if [ -n "$warp_creds_info" ]; then
                echo -e " - ${GREEN}Источник WARP-ключей: ${warp_creds_info}${NC}"
            else
                echo -e " - ${YELLOW}WARP-ключи будут получены при пересборке конфига...${NC}"
            fi

            if rebuild_config "$SINGBOX_TEMPLATE"; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим WARP активирован!${NC}"
                else
                    echo -e "${RED}Не удалось перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка пересборки конфига!${NC}"
            fi
            sleep 2
            ;;

        # ── Slave ─────────────────────────────────────────────────────────
        2)
            echo -e "\n${CYAN}Настройка подключения к донор-серверу${NC}"
            echo -e "${YELLOW}На донор-сервере должен быть установлен warperslave.${NC}"
            echo -e ""

            local new_server="" new_port="" new_password=""
            local use_saved=false

            # Предлагаем сохранённое подключение
            if [ -n "$SLAVE_SERVER" ] && [ -n "$SLAVE_PASSWORD" ]; then
                echo -e "${GREEN}Найдено сохранённое подключение:${NC}"
                echo -e "  ${CYAN}Сервер:${NC} ${YELLOW}${SLAVE_SERVER}${NC}"
                echo -e "  ${CYAN}Порт:${NC}   ${YELLOW}${SLAVE_PORT}${NC}"
                echo -e "  ${CYAN}Ключ:${NC}   ${YELLOW}${SLAVE_PASSWORD:0:8}...${NC}"
                echo -e ""
                echo -e " ${GREEN}1.${NC} Использовать сохранённое подключение"
                echo -e " ${CYAN}2.${NC} Ввести новый сервер"
                echo -e " ${CYAN}0.${NC} Отмена"

                while true; do
                    read -r -p "Выбор [0-2]: " saved_choice
                    case "${saved_choice:-}" in
                        1)
                            use_saved=true
                            new_server="$SLAVE_SERVER"
                            new_port="$SLAVE_PORT"
                            new_password="$SLAVE_PASSWORD"
                            break ;;
                        2) use_saved=false; break ;;
                        0) return ;;
                        *) echo -e "${RED}Введите 0, 1 или 2.${NC}" ;;
                    esac
                done
            fi

            if [ "$use_saved" = false ]; then
                # Адрес сервера
                while true; do
                    read -r -p "IP или домен slave-сервера (Enter для отмены): " new_server
                    if [ -z "$new_server" ]; then
                        echo -e "${YELLOW}Отмена.${NC}"; return
                    fi
                    if [[ "$new_server" =~ ^[0-9a-zA-Z._:-]+$ ]]; then
                        break
                    fi
                    echo -e "${RED}Некорректный адрес!${NC}"
                done

                # Порт
                local default_sp="${SLAVE_PORT:-8444}"
                read -r -p "Порт [по умолчанию $default_sp]: " new_port
                [ -z "$new_port" ] && new_port="$default_sp"
                if ! validate_port_simple "$new_port"; then
                    echo -e "${RED}Некорректный порт!${NC}"
                    sleep 1; return
                fi

                # Ключ
                while true; do
                    read -r -p "Ключ Shadowsocks: " new_password
                    [ -n "$new_password" ] && break
                    echo -e "${RED}Ключ не может быть пустым!${NC}"
                done
            fi

            SLAVE_SERVER="$new_server"
            SLAVE_PORT="$new_port"
            SLAVE_PASSWORD="$new_password"
            CURRENT_OUTBOUND_MODE="slave"
            save_slave_config

            echo -e "${YELLOW}Создание конфигурации...${NC}"
            if rebuild_config_slave; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим Slave активирован!${NC}"
                    echo -e "${CYAN}Трафик идёт через: $SLAVE_SERVER:$SLAVE_PORT${NC}"
                else
                    echo -e "${RED}Не удалось перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка! Возврат к режиму WARP.${NC}"
                CURRENT_OUTBOUND_MODE="warp"
                save_slave_config
                if [ -f "$SINGBOX_TEMPLATE" ]; then
                    rebuild_config "$SINGBOX_TEMPLATE" >/dev/null 2>&1 || true
                    restart_singbox_full >/dev/null 2>&1 || true
                fi
            fi
            sleep 2
            ;;

        # ── WG ────────────────────────────────────────────────────────────
        3)
            echo -e "\n${CYAN}Настройка WireGuard-соединения${NC}"

            load_wg_config
            local use_saved_wg=false

            # Предлагаем сохранённое подключение
            if [ -n "$WG_PRIVATE_KEY" ] && [ -n "$WG_ENDPOINT_HOST" ]; then
                echo -e "${GREEN}Найдено сохранённое WG-подключение:${NC}"
                echo -e "  ${CYAN}Endpoint:${NC} ${YELLOW}${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT}${NC}"
                echo -e "  ${CYAN}Address:${NC}  ${YELLOW}${WG_ADDRESS}${NC}"
                if [ "$WG_CONF_FILE" != "manual" ] && [ -n "$WG_CONF_FILE" ]; then
                    echo -e "  ${CYAN}Из файла:${NC} ${YELLOW}${WG_CONF_FILE}${NC}"
                fi
                echo -e ""
                echo -e " ${GREEN}1.${NC} Использовать сохранённое подключение"
                echo -e " ${CYAN}2.${NC} Выбрать новый конфиг / ввести вручную"
                echo -e " ${CYAN}0.${NC} Отмена"

                while true; do
                    read -r -p "Выбор [0-2]: " saved_wg_choice
                    case "${saved_wg_choice:-}" in
                        1) use_saved_wg=true; break ;;
                        2) use_saved_wg=false; break ;;
                        0) return ;;
                        *) echo -e "${RED}Введите 0, 1 или 2.${NC}" ;;
                    esac
                done
            fi

            if [ "$use_saved_wg" = false ]; then
                if ! select_wg_config; then
                    echo -e "${YELLOW}Отмена.${NC}"
                    sleep 1; return
                fi
            fi

            CURRENT_OUTBOUND_MODE="wg"
            save_slave_config

            echo -e "${YELLOW}Создание конфигурации...${NC}"
            if rebuild_config_wg; then
                if restart_singbox_full; then
                    echo -e "${GREEN}Режим WG активирован!${NC}"
                    echo -e "${CYAN}Трафик идёт через: $WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT${NC}"
                else
                    echo -e "${RED}Не удалось перезапустить sing-box.${NC}"
                fi
            else
                echo -e "${RED}Ошибка! Возврат к предыдущему режиму.${NC}"
                CURRENT_OUTBOUND_MODE="warp"
                save_slave_config
                if [ -f "$SINGBOX_TEMPLATE" ]; then
                    rebuild_config "$SINGBOX_TEMPLATE" >/dev/null 2>&1 || true
                    restart_singbox_full >/dev/null 2>&1 || true
                fi
            fi
            sleep 2
            ;;

        0) return ;;

        *)
            echo -e "${RED}Неверный выбор.${NC}"
            sleep 1
            ;;
    esac
}

# ===== Меню настроек =====

# Главное меню настроек WARPER.
# Управление автопатчем, списками доменов, подсетью,
# log level, MTU, режимом маршрутизации и WARP-ключами.
settings_menu() {
    while true; do
        clear
        load_slave_config

        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"

        local AP_STAT GEM_STAT GPT_STAT LOG_LEVEL MTU MODE_STAT
        LOG_LEVEL=$(get_log_level)
        MTU=$(get_mtu)

        if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
            AP_STAT="${GREEN}ВКЛ${NC}"
        else
            AP_STAT="${RED}ВЫКЛ${NC}"
        fi

        if has_list_block "gemini"; then GEM_STAT="${GREEN}ВКЛ${NC}"
        else GEM_STAT="${RED}ВЫКЛ${NC}"; fi

        if has_list_block "chatgpt"; then GPT_STAT="${GREEN}ВКЛ${NC}"
        else GPT_STAT="${RED}ВЫКЛ${NC}"; fi

        load_wg_config
        if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
            MODE_STAT="${CYAN}Slave ($SLAVE_SERVER:$SLAVE_PORT)${NC}"
        elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
            MODE_STAT="${CYAN}WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)${NC}"
        else
            MODE_STAT="${GREEN}WARP (локальный)${NC}"
        fi

        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке: [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Интеграция доменов Gemini:     [$GEM_STAT]"
        echo -e " ${CYAN}3.${NC} Интеграция доменов ChatGPT:    [$GPT_STAT]"
        echo -e " ${CYAN}4.${NC} Изменить фейковую подсеть:     [$SUBNET]"
        echo -e " ${CYAN}5.${NC} Изменить log level sing-box:   [$LOG_LEVEL]"
        echo -e " ${CYAN}6.${NC} Изменить MTU sing-box:         [$MTU]"
        echo -e " ${CYAN}7.${NC} Режим маршрутизации:           [$MODE_STAT]"
        if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
            echo -e " ${CYAN}8.${NC} Управление WARP-ключами"
        fi
        local FULLVPN_STAT
        if grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
            FULLVPN_STAT="${GREEN}ВКЛ${NC}"
        else
            FULLVPN_STAT="${RED}ВЫКЛ${NC}"
        fi
        echo -e " ${CYAN}9.${NC} FullVPN WARP-резолвинг:      [$FULLVPN_STAT]"        
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"

        read -r -e -p "Выбор [0-8]: " set_choice
        case "${set_choice:-}" in

            # ── Автопатч ──────────────────────────────────────────────────
            1)
                if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
                    systemctl disable warper-autopatch >/dev/null 2>&1
                    echo -e "${YELLOW}Автопатч отключен.${NC}"
                else
                    systemctl enable warper-autopatch >/dev/null 2>&1
                    echo -e "${GREEN}Автопатч включен.${NC}"
                fi
                sleep 1
                ;;

            # ── Gemini ────────────────────────────────────────────────────
            2) toggle_list "gemini" ;;

            # ── ChatGPT ───────────────────────────────────────────────────
            3) toggle_list "chatgpt" ;;

            # ── Изменить fake-подсеть ─────────────────────────────────────
            4)
                echo -e "\n${YELLOW}Внимание! Изменение подсети перезапустит службы.${NC}"
                read -r -e -p "Вы уверены? [y/N]: " conf_sub
                if [[ "$conf_sub" == "y" || "$conf_sub" == "Y" ]]; then
                    while true; do
                        read -r -e -p "Введите новую подсеть (X.X.X.0/XX) или пустое для отмены: " new_subnet
                        if [ -z "$new_subnet" ]; then
                            echo -e "${YELLOW}Отмена.${NC}"; sleep 1; break
                        fi
                        if validate_subnet "$new_subnet"; then
                            if subnet_conflicts "$new_subnet"; then
                                echo -e "${YELLOW}Предупреждение: подсеть может конфликтовать.${NC}"
                                read -r -e -p "Использовать? [y/N]: " force_subnet
                                if [[ ! "$force_subnet" =~ ^[Yy]$ ]]; then continue; fi
                            fi

                            local old_subnet old_tun new_tun
                            old_subnet="$SUBNET"
                            old_tun="$TUN_IP"
                            new_tun=$(calculate_tun_ip "$new_subnet")
                            SUBNET="$new_subnet"
                            TUN_IP="$new_tun"

                            # Пересобираем конфиг
                            if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
                                if ! rebuild_config "$SINGBOX_TEMPLATE"; then
                                    SUBNET="$old_subnet"; TUN_IP="$old_tun"
                                    echo -e "${RED}Ошибка пересборки конфига.${NC}"
                                    sleep 2; break
                                fi
                            else
                                sed -i "s|\"$old_subnet\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
                                sed -i "s|\"$old_tun\"|\"$new_tun\"|g" "$SINGBOX_CONF"
                                if ! validate_singbox_config; then
                                    sed -i "s|\"$new_subnet\"|\"$old_subnet\"|g" "$SINGBOX_CONF"
                                    sed -i "s|\"$new_tun\"|\"$old_tun\"|g" "$SINGBOX_CONF"
                                    SUBNET="$old_subnet"; TUN_IP="$old_tun"
                                    echo -e "${RED}Откат выполнен.${NC}"; sleep 2; break
                                fi
                            fi

                            # Обновляем include-ips AntiZapret
                            sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
                            grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || \
                                echo "$new_subnet" >> "$AZ_INC"
                            normalize_include_ips "$AZ_INC"

                            # Сохраняем warper.conf
                            save_main_config

                            # Обновляем маршруты AntiZapret
                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret...${NC}"
                            export DEBIAN_FRONTEND=noninteractive SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1

                            # Перезапускаем sing-box
                            systemctl restart sing-box
                            if ! ensure_singbox_running; then sleep 2; break; fi
                            ensure_iptables_rule FORWARD -o singbox-tun
                            ensure_iptables_rule FORWARD -i singbox-tun

                            # Пересинхронизируем IP-маршруты
                            resync_ip_routes_if_needed

                            echo -e "${GREEN}Подсеть успешно изменена!${NC}"
                            sleep 2; break
                        else
                            echo -e "${RED}Некорректная подсеть!${NC}"
                        fi
                    done
                fi
                ;;

            # ── Log level ─────────────────────────────────────────────────
            5)
                echo -e "\n${CYAN}Доступные уровни логирования:${NC}"
                echo -e " ${CYAN}1.${NC} debug"
                echo -e " ${CYAN}2.${NC} info"
                echo -e " ${CYAN}3.${NC} warn"
                echo -e " ${CYAN}4.${NC} error"
                echo -e " ${CYAN}0.${NC} Отмена"
                read -r -e -p "Выбор [0-4]: " log_choice
                case "${log_choice:-}" in
                    1) set_log_level "debug"; sleep 2 ;;
                    2) set_log_level "info";  sleep 2 ;;
                    3) set_log_level "warn";  sleep 2 ;;
                    4) set_log_level "error"; sleep 2 ;;
                    0) ;;
                    *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
                esac
                ;;

            # ── MTU ───────────────────────────────────────────────────────
            6)
                echo -e "\n${CYAN}Текущий MTU: $(get_mtu)${NC}"
                echo -e "${YELLOW}Допустимые значения: 1280-1500${NC}"
                read -r -e -p "Введите новый MTU (или пустое для отмены): " new_mtu
                if [ -n "$new_mtu" ]; then set_mtu "$new_mtu"; sleep 2; fi
                ;;

            # ── Режим маршрутизации ───────────────────────────────────────
            7) switch_outbound_mode ;;

            # ── WARP-ключи ────────────────────────────────────────────────
            8) manage_warp_keys ;;

            # ── Патч Kresd для full vpn конфигов ────────────────────────────────────────────────
            9)
                if grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
                    if prompt_confirm; then
                        unpatch_kresd_fullvpn
                        FULLVPN_WARP_RESOLVE="n"
                        save_main_config
                        echo -e "${YELLOW}FullVPN WARP-резолвинг отключён.${NC}"
                    fi
                else
                    if prompt_confirm; then
                        if patch_kresd_fullvpn; then
                            FULLVPN_WARP_RESOLVE="y"
                            save_main_config
                            echo -e "${GREEN}FullVPN WARP-резолвинг включён!${NC}"
                        fi
                    fi
                fi
                sleep 1
                ;;

            # ── Назад ─────────────────────────────────────────────────────
            0) return ;;

            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}
