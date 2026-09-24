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
# Применяет режим через apply_outbound_mode и сообщает результат.
#   _menu_apply_mode MODE НАЗВАНИЕ [SETTER [ARGS...]]
# НАЗВАНИЕ оставлено для читаемости вызовов, итог печатает outbound_mode_label.
_menu_apply_mode() {
    local mode="$1"; shift 2
    echo -e "${YELLOW}Создание конфигурации...${NC}"
    if apply_outbound_mode "$mode" "$@"; then
        echo -e "${GREEN}Режим активирован: $(outbound_mode_label)${NC}"
    else
        echo -e "${RED}Не удалось переключиться, прежний режим сохранён.${NC}"
    fi
    sleep 2
}

switch_outbound_mode() {
    load_slave_config

    echo -e "\n${CYAN}================================================${NC}"
    echo -e "       ${YELLOW}Режим маршрутизации трафика${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""
    echo -e " Текущий режим: ${GREEN}$(outbound_mode_label)${NC}"
    echo -e ""
    echo -e " ${GREEN}1.${NC} WARP  — трафик через Cloudflare WARP"
    echo -e " ${CYAN}2.${NC} Slave — донор-сервер по Shadowsocks"
    echo -e " ${CYAN}3.${NC} WG    — трафик через WireGuard-соединение"
    echo -e " ${CYAN}4.${NC} VLESS — VLESS / VLESS+Reality по ссылке"
    echo -e " ${CYAN}5.${NC} Hysteria2 — по ссылке hy2://"
    echo -e " ${CYAN}6.${NC} OpenVPN — по файлу .ovpn"
    echo -e " ${CYAN}0.${NC} Назад"
    echo -e "${CYAN}================================================${NC}"

    read -r -p "Выбор: " mode_choice
    case "${mode_choice:-}" in

        # ── WARP ──────────────────────────────────────────────────────────
        1)
            if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
                echo -e "${YELLOW}Уже в режиме WARP.${NC}"
                sleep 1; return
            fi
            if [ ! -f "$SINGBOX_TEMPLATE" ]; then
                download_file_safe "$REPO_URL/templates/config.json.template" \
                    "$SINGBOX_TEMPLATE" "config.json.template" || {
                    echo -e "${RED}Не удалось загрузить шаблон WARP-конфига.${NC}"
                    sleep 2; return
                }
            fi
            _menu_apply_mode warp WARP
            ;;

        # ── Slave ─────────────────────────────────────────────────────────
        2)
            echo -e "\n${CYAN}Подключение к донор-серверу по Shadowsocks${NC}"
            echo -e "${YELLOW}Для VLESS или Hysteria2 возьмите ссылку командой${NC}"
            echo -e "${YELLOW}warperslave link на доноре и выберите режим ниже.${NC}"
            echo -e ""

            # Предлагаем сохранённое подключение
            if [ -n "$SLAVE_SERVER" ] && [ -n "$SLAVE_PASSWORD" ]; then
                echo -e "${GREEN}Найдено сохранённое подключение:${NC}"
                echo -e "  ${CYAN}Сервер:${NC} ${YELLOW}${SLAVE_SERVER}:${SLAVE_PORT}${NC}"
                echo -e "  ${CYAN}Ключ:${NC}   ${YELLOW}${SLAVE_PASSWORD:0:8}...${NC}"
                echo -e ""
                echo -e " ${GREEN}1.${NC} Использовать сохранённое подключение"
                echo -e " ${CYAN}2.${NC} Ввести новое"
                echo -e " ${CYAN}0.${NC} Отмена"
                local saved_choice
                read -r -p "Выбор [0-2]: " saved_choice
                case "${saved_choice:-}" in
                    1) _menu_apply_mode slave Slave; return ;;
                    2) ;;
                    *) return ;;
                esac
            fi

            local input=""
            read -r -p "Ссылка ss:// или IP/домен донора (Enter — отмена): " input
            [ -z "$input" ] && return

            if [[ "$input" == ss://* ]]; then
                _menu_apply_mode slave Slave _set_slave_from_link "$input"
                return
            fi

            if [[ ! "$input" =~ ^[0-9a-zA-Z._:-]+$ ]]; then
                echo -e "${RED}Некорректный адрес!${NC}"; sleep 1; return
            fi
            local new_port new_password=""
            read -r -p "Порт [${SLAVE_PORT:-8444}]: " new_port
            new_port="${new_port:-${SLAVE_PORT:-8444}}"
            if ! validate_port_simple "$new_port"; then
                echo -e "${RED}Некорректный порт!${NC}"; sleep 1; return
            fi
            while [ -z "$new_password" ]; do
                read -r -p "Ключ Shadowsocks: " new_password
            done
            _menu_apply_mode slave Slave _set_slave_params "$input" "$new_port" "$new_password"
            ;;

        # ── WG ────────────────────────────────────────────────────────────
        3)
            echo -e "\n${CYAN}Настройка WireGuard-соединения${NC}"
            load_wg_config

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
                local saved_wg_choice
                read -r -p "Выбор [0-2]: " saved_wg_choice
                case "${saved_wg_choice:-}" in
                    1) _menu_apply_mode wg WG; return ;;
                    2) ;;
                    *) return ;;
                esac
            fi

            # select_wg_config сам сохраняет параметры — вызываем его внутри
            # apply_outbound_mode, чтобы отмена и ошибка откатывались целиком
            _menu_apply_mode wg WG select_wg_config
            ;;

        # ── VLESS / Hysteria2 ────────────────────────────────────────────
        4|5)
            local mode scheme
            if [ "$mode_choice" = "4" ]; then mode=vless; scheme="vless://"
            else mode=hy2; scheme="hy2://"; fi

            echo -e "\n${CYAN}Подключение по ссылке ${scheme}${NC}"
            echo -e "${YELLOW}Ссылку для своего донора выдаёт команда warperslave link.${NC}"
            if [ "$CURRENT_OUTBOUND_MODE" = "$mode" ]; then
                echo -e "Текущее: ${GREEN}$(outbound_mode_label)${NC}"
                echo -e "Enter без ссылки — пересобрать текущее подключение."
            fi
            local link=""
            read -r -p "Ссылка (Enter — отмена): " link
            if [ -z "$link" ]; then
                [ "$CURRENT_OUTBOUND_MODE" = "$mode" ] && _menu_apply_mode "$mode" "$mode"
                return
            fi
            _menu_apply_mode "$mode" "$mode" _set_outbound "$mode" "$link"
            ;;

        # ── OpenVPN ──────────────────────────────────────────────────────
        6)
            echo -e "\n${CYAN}Подключение по файлу .ovpn${NC}"
            echo -e "${YELLOW}Положите .ovpn в /root или /root/warper — он появится в списке.${NC}"
            local -a files=()
            local f i=1
            while IFS= read -r f; do
                files+=("$f")
                echo -e " ${CYAN}${i}.${NC} $f"
                i=$((i + 1))
            done < <(scan_ovpn_configs)
            [ ${#files[@]} -eq 0 ] && echo -e " ${YELLOW}Файлы .ovpn не найдены.${NC}"
            echo -e " ${CYAN}P.${NC} Указать путь вручную"
            echo -e " ${CYAN}0.${NC} Отмена"

            local pick path=""
            read -r -p "Выбор: " pick
            case "${pick:-}" in
                p|P) read -r -p "Путь к .ovpn: " path ;;
                0|"") return ;;
                *)
                    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#files[@]} )); then
                        path="${files[$((pick - 1))]}"
                    fi
                    ;;
            esac
            if [ -z "$path" ] || [ ! -f "$path" ]; then
                echo -e "${RED}Файл не найден.${NC}"; sleep 1; return
            fi

            local ov_user="" ov_pass=""
            if ovpn_needs_auth "$path"; then
                echo -e "${YELLOW}Конфиг требует логин и пароль (auth-user-pass).${NC}"
                read -r -p "Логин: " ov_user
                read -r -s -p "Пароль: " ov_pass; echo ""
            fi
            _menu_apply_mode openvpn OpenVPN _set_outbound openvpn "$path" "$ov_user" "$ov_pass"
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
        if [ "$CURRENT_OUTBOUND_MODE" = "warp" ]; then
            MODE_STAT="${GREEN}$(outbound_mode_label)${NC}"
        else
            MODE_STAT="${CYAN}$(outbound_mode_label)${NC}"
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
