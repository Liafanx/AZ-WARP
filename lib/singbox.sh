#!/bin/bash
# warper lib: singbox.sh
# Управление sing-box: запуск, остановка, перезапуск,
# пересборка конфигурации, управление MTU и log level.
# Подключается через source из warper.sh

# ===== Проверки состояния =====

# Проверяет валидность текущего config.json через sing-box check
validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then return 1; fi
    if ! sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then return 1; fi
    return 0
}

# Проверяет что служба sing-box активна.
# При ошибке выводит последние логи.
ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

# Полный перезапуск sing-box: stop → start → проверка → iptables → kresd → ресинк IP.
# Используется при смене режима, обновлении конфига и т.д.
restart_singbox_full() {
    systemctl stop sing-box >/dev/null 2>&1 || true
    sleep 1
    systemctl start sing-box
    if ! ensure_singbox_running; then
        return 1
    fi
    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 >/dev/null 2>&1 || true
    resync_ip_routes_if_needed
    return 0
}

# Пересинхронизирует IP-маршруты после перезапуска sing-box,
# если в ip-ranges.txt есть подсети (kernel routes слетают при restart)
resync_ip_routes_if_needed() {
    if [ "$(count_ip_ranges)" -gt 0 ]; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi
}

# ===== Пересборка конфигурации =====

# Точка входа для пересборки config.json.
# Определяет текущий режим (warp/slave/wg) и вызывает нужную функцию.
rebuild_config() {
    local template="$1"

    load_slave_config
    load_wg_config

    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        rebuild_config_slave
        return $?
    fi

    if [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        rebuild_config_wg
        return $?
    fi

    # WARP mode
    local creds=""
    creds=$(get_warp_credentials) || {
        echo -e "${RED}Ошибка: Не удалось извлечь WARP-ключи!${NC}"
        return 1
    }
    local warp_address="" warp_private_key=""
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')

    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$template" > "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then return 1; fi

    echo -e "${GREEN}Конфигурация sing-box (WARP) успешно обновлена.${NC}"
    return 0
}

# Пересобирает config.json для режима Slave (Shadowsocks outbound)
rebuild_config_slave() {
    if [ -z "$SLAVE_SERVER" ] || [ -z "$SLAVE_PASSWORD" ]; then
        echo -e "${RED}Не настроены параметры slave-сервера!${NC}"
        return 1
    fi

    if [ ! -f "$SLAVE_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config-slave-master.json.template" \
            "$SLAVE_TEMPLATE" "шаблон slave-master" || return 1
    fi

    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__SLAVE_SERVER__|$SLAVE_SERVER|g" \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT|g" \
        -e "s|__SLAVE_PASSWORD__|$SLAVE_PASSWORD|g" \
        "$SLAVE_TEMPLATE" > "$SINGBOX_CONF"

    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации конфига slave!${NC}"
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box (slave) успешно обновлена.${NC}"
    return 0
}

# ===== Log level =====

# Читает текущий log level из config.json
get_log_level() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.log.level // "info"' "$SINGBOX_CONF" 2>/dev/null || echo "info"
    else
        echo "info"
    fi
}

# Устанавливает log level в config.json с backup и откатом при ошибке.
# Допустимые значения: debug, info, warn, error
set_log_level() {
    local new_level="$1"
    case "$new_level" in
        debug|info|warn|error) ;;
        *) echo -e "${RED}Некорректный log level: $new_level${NC}"; return 1 ;;
    esac
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"; return 1
    fi
    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"; return 1
    fi

    local backup tmp old_level
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)
    cp -a "$SINGBOX_CONF" "$backup" || { rm -f "$backup" "$tmp"; return 1; }

    old_level=$(get_log_level)
    if [ "$old_level" = "$new_level" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}log level уже установлен: $new_level${NC}"
        return 0
    fi

    if ! jq --arg lvl "$new_level" '.log.level = $lvl' "$SINGBOX_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"; return 1
    fi
    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"; rm -f "$backup"
        echo -e "${RED}Откат выполнен.${NC}"; return 1
    fi

    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"; return 1
    fi

    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true
    resync_ip_routes_if_needed
    rm -f "$backup"

    echo -e "${GREEN}log level изменён: ${old_level} → ${new_level}${NC}"
    return 0
}

# ===== MTU =====

# Читает текущий MTU.
# Для WARP/WG режимов: MTU из endpoints[0].mtu
# Для Slave режима: MTU из inbounds[?type=tun].mtu (применяется на TUN)
get_mtu() {
    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        local mtu=""

        # Сначала пробуем endpoints (WARP, WG)
        mtu=$(jq -r '.endpoints[0].mtu // empty' "$SINGBOX_CONF" 2>/dev/null)

        # Если нет endpoints - пробуем tun inbound (Slave)
        if [ -z "$mtu" ] || [ "$mtu" = "null" ]; then
            mtu=$(jq -r '.inbounds[] | select(.type=="tun") | .mtu // empty' "$SINGBOX_CONF" 2>/dev/null | head -1)
        fi

        # Дефолт
        if [ -z "$mtu" ] || [ "$mtu" = "null" ]; then
            echo "1420"
        else
            echo "$mtu"
        fi
    else
        echo "1420"
    fi
}

# Устанавливает MTU.
# Для WARP/WG: меняет endpoints[0].mtu
# Для Slave: меняет mtu на tun-inbound (Shadowsocks не имеет MTU как туннеля)
set_mtu() {
    local new_mtu="$1"
    if ! validate_mtu "$new_mtu"; then
        echo -e "${RED}Некорректный MTU: $new_mtu (допустимо 1280-1500)${NC}"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"
        return 1
    fi
    if [ ! -f "$SINGBOX_CONF" ]; then
        echo -e "${RED}Файл $SINGBOX_CONF не найден.${NC}"
        return 1
    fi

    local backup tmp old_mtu
    backup=$(mktemp /tmp/singbox_config_backup.XXXXXX)
    tmp=$(mktemp /tmp/singbox_config_new.XXXXXX)
    cp -a "$SINGBOX_CONF" "$backup" || { rm -f "$backup" "$tmp"; return 1; }

    old_mtu=$(get_mtu)
    if [ "$old_mtu" = "$new_mtu" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}MTU уже установлен: $new_mtu${NC}"
        return 0
    fi

    # Определяем где менять MTU - в endpoints или в tun-inbound
    local has_endpoints
    has_endpoints=$(jq 'has("endpoints") and (.endpoints | length > 0)' "$SINGBOX_CONF" 2>/dev/null)

    if [ "$has_endpoints" = "true" ]; then
        # WARP / WG режим - меняем endpoints[0].mtu
        if ! jq --argjson mtu "$new_mtu" '.endpoints[0].mtu = $mtu' "$SINGBOX_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка изменения MTU в endpoints${NC}"
            return 1
        fi
    else
        # Slave режим - меняем mtu на tun-inbound
        if ! jq --argjson mtu "$new_mtu" \
            '(.inbounds[] | select(.type=="tun") | .mtu) = $mtu' \
            "$SINGBOX_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка изменения MTU в inbounds[tun]${NC}"
            return 1
        fi
    fi

    mv "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        rm -f "$backup"
        echo -e "${RED}Конфиг невалиден после изменения MTU. Откат выполнен.${NC}"
        return 1
    fi

    systemctl restart sing-box
    if ! ensure_singbox_running; then
        cp -a "$backup" "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$backup"
        echo -e "${RED}sing-box не запустился. Откат выполнен.${NC}"
        return 1
    fi

    ensure_iptables_rule FORWARD -o singbox-tun
    ensure_iptables_rule FORWARD -i singbox-tun
    systemctl restart kresd@1 kresd@2 >/dev/null 2>&1 || true
    resync_ip_routes_if_needed
    rm -f "$backup"

    echo -e "${GREEN}MTU изменён: ${old_mtu} → ${new_mtu}${NC}"
    return 0
}

# ===== Логи =====

# Показывает логи sing-box в реальном времени (journalctl -f).
# Ctrl+C возвращает в меню.
show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Чтение логов sing-box...${NC}"
    echo -e "${GREEN}Для выхода нажмите Ctrl+C${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u sing-box -n 20 -f
    trap - SIGINT
}
