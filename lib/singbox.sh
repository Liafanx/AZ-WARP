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
    # Маршрут fake-подсети в таблицах AntiZapret отвечает за домены,
    # поэтому нужен и при пустом списке ip-ranges.
    sync_az_table_routes
    if [ "$(count_ip_ranges)" -gt 0 ]; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi
}

# ===== Пересборка конфигурации =====

# sing-box 1.14 по умолчанию перехватывает DNS в tun и прописывает себя в
# systemd-resolved — выключаем. В шаблонах этого поля нет: 1.13 его не
# знает, а шаблоны собирает и обновлятор 1.4.x на старом sing-box.
#   singbox_tun_compat ФАЙЛ
singbox_tun_compat() {
    local ver tmp
    ver=$(get_singbox_version) || return 0
    [ "$(printf '1.14.0\n%s\n' "$ver" | sort -V | head -n1)" = "1.14.0" ] || return 0
    tmp=$(mktemp)
    jq '.inbounds |= map(if .type == "tun" then .dns_mode = "disabled" else . end)' \
        "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$1"
}

# Точка входа для пересборки config.json.
# Определяет текущий режим (warp/slave/wg) и вызывает нужную функцию.
# Проверяет собранный конфиг и атомарно ставит его на место.
# При ошибке текущий конфиг не трогается — раньше сборка писала сразу в
# config.json, и неудачная смена режима оставляла sing-box с битым конфигом.
install_singbox_config() {
    local tmp="$1"
    singbox_tun_compat "$tmp" || { rm -f "$tmp"; return 1; }
    if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
        echo -e "${RED}Собранный конфиг не прошёл проверку sing-box:${NC}" >&2
        sing-box check -c "$tmp" 2>&1 | tail -n 3 >&2 || true
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$SINGBOX_CONF")"
    [ -f "$SINGBOX_CONF" ] && cp -a "$SINGBOX_CONF" "${SINGBOX_CONF}.bak"
    mv -f "$tmp" "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"
}

# Собирает config.json под текущий режим.
# Неизвестный режим — ошибка: раньше он молча получал WARP-конфиг.
rebuild_config() {
    local template="${1:-$SINGBOX_TEMPLATE}"

    load_slave_config
    load_wg_config

    case "$CURRENT_OUTBOUND_MODE" in
        warp)  rebuild_config_warp "$template" ;;
        slave) rebuild_config_slave ;;
        wg)    rebuild_config_wg ;;
        vless|hy2|openvpn) rebuild_config_proxy ;;
        *)
            echo -e "${RED}Неизвестный режим: $CURRENT_OUTBOUND_MODE${NC}" >&2
            return 1
            ;;
    esac
}

rebuild_config_warp() {
    local template="$1"
    local creds=""
    creds=$(get_warp_credentials) || {
        echo -e "${RED}Ошибка: Не удалось извлечь WARP-ключи!${NC}"
        return 1
    }
    local warp_address="" warp_private_key=""
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')

    local tmp
    tmp=$(mktemp)
    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$template" > "$tmp"
    install_singbox_config "$tmp" || return 1

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

    local tmp
    tmp=$(mktemp)
    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__SLAVE_SERVER__|$SLAVE_SERVER|g" \
        -e "s|__SLAVE_PORT__|$SLAVE_PORT|g" \
        -e "s|__SLAVE_PASSWORD__|$SLAVE_PASSWORD|g" \
        "$SLAVE_TEMPLATE" > "$tmp"
    if ! install_singbox_config "$tmp"; then
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

# ===== CLI: версия и обновление sing-box =====

# Установленная версия sing-box (пусто, если бинарник не найден).
get_singbox_version() {
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box version 2>/dev/null | awk 'NR == 1 {print $3}'
}

# CLI: warper singbox version|upgrade [VERSION]
cli_singbox() {
    local action="${1:-}" arg="${2:-}"
    case "$action" in
        version)
            local ver
            ver=$(get_singbox_version) || { echo "ERROR: sing-box not installed" >&2; return 1; }
            echo "$ver"
            ;;
        upgrade)
            local target="${arg:-$SB_VERSION}"
            local current
            current=$(get_singbox_version || echo "none")
            if [ "$current" = "$target" ]; then
                echo "sing-box already $target"
                return 0
            fi
            echo "Upgrading sing-box: $current -> $target"
            if ! curl -fsSL https://sing-box.app/install.sh \
                | bash -s -- --version "$target" >/dev/null 2>&1; then
                echo "ERROR: sing-box install failed" >&2
                return 1
            fi
            current=$(get_singbox_version || echo "none")
            if [ "$current" != "$target" ]; then
                echo "ERROR: expected $target, got $current" >&2
                return 1
            fi
            if ! validate_singbox_config; then
                echo "ERROR: config invalid on $target, not restarting" >&2
                return 1
            fi
            # Бинарник общий с sing-box-slave, перезапускаем обе службы
            local unit
            for unit in sing-box sing-box-slave; do
                systemctl is-active --quiet "$unit" 2>/dev/null || continue
                systemctl restart "$unit" || echo "WARNING: $unit restart failed" >&2
            done
            ensure_singbox_running >/dev/null 2>&1 || true
            cli_resync >/dev/null 2>&1 || true
            echo "sing-box upgraded to $target"
            ;;
        start)
            systemctl start sing-box || { echo "ERROR: start failed" >&2; return 1; }
            ensure_singbox_running >/dev/null 2>&1 || {
                echo "ERROR: sing-box did not come up" >&2; return 1; }
            ensure_iptables_rule FORWARD -o singbox-tun
            ensure_iptables_rule FORWARD -i singbox-tun
            resync_ip_routes_if_needed
            echo "sing-box: started"
            ;;
        stop)
            traffic_finalize_session 2>/dev/null || true
            remove_all_ip_routes >/dev/null 2>&1 || true
            systemctl stop sing-box || { echo "ERROR: stop failed" >&2; return 1; }
            echo "sing-box: stopped"
            ;;
        restart)
            restart_singbox_full >/dev/null 2>&1 || {
                echo "ERROR: restart failed" >&2; return 1; }
            echo "sing-box: restarted"
            ;;
        enable|disable)
            systemctl "$action" sing-box >/dev/null 2>&1 || {
                echo "ERROR: systemctl $action sing-box failed" >&2; return 1; }
            echo "sing-box autostart: $action"
            ;;
        status)
            echo "active=$(systemctl is-active sing-box 2>/dev/null)"
            echo "enabled=$(systemctl is-enabled sing-box 2>/dev/null || echo disabled)"
            echo "version=$(get_singbox_version || echo unknown)"
            echo "log_level=$(get_log_level)"
            echo "mtu=$(get_mtu)"
            ;;
        *)
            echo "Usage: warper singbox start|stop|restart|enable|disable|status|version|upgrade [VERSION]" >&2
            return 1
            ;;
    esac
}

# ===== Смена режима с откатом =====

# Файлы, из которых складывается состояние режима.
_outbound_state_files() {
    echo "$SINGBOX_CONF $CONF_FILE $SLAVE_MODE_FILE $WG_MODE_FILE $OUTBOUND_JSON"
}

_outbound_snapshot() {
    local snap="$1" f
    for f in $(_outbound_state_files); do
        if [ -f "$f" ]; then
            cp -a "$f" "$snap/$(basename "$f")"
        else
            : > "$snap/$(basename "$f").absent"
        fi
    done
}

_outbound_restore() {
    local snap="$1" f base
    for f in $(_outbound_state_files); do
        base=$(basename "$f")
        if [ -f "$snap/$base" ]; then
            cp -a "$snap/$base" "$f"
        elif [ -f "$snap/$base.absent" ]; then
            rm -f "$f"
        fi
    done
    load_config
    load_slave_config
    load_wg_config
}

# Переключает режим: SETTER записывает параметры режима, затем конфиг
# собирается и sing-box перезапускается. При любой ошибке возвращается всё
# прежнее состояние — раньше меню откатывало всегда на WARP, а CLI не
# откатывал вовсе и оставлял сохранённым неработающий режим.
#   apply_outbound_mode MODE [SETTER [ARGS...]]
apply_outbound_mode() {
    local new_mode="$1"; shift
    local snap prev_mode
    snap=$(mktemp -d)
    _outbound_snapshot "$snap"
    prev_mode="$CURRENT_OUTBOUND_MODE"

    if [ $# -gt 0 ] && ! "$@"; then
        _outbound_restore "$snap"; rm -rf "$snap"
        return 1
    fi

    CURRENT_OUTBOUND_MODE="$new_mode"
    save_slave_config

    if ! rebuild_config "$SINGBOX_TEMPLATE"; then
        _outbound_restore "$snap"; rm -rf "$snap"
        echo -e "${RED}Режим не изменён, остаётся: $prev_mode${NC}" >&2
        return 1
    fi

    if systemctl is-active --quiet sing-box && ! restart_singbox_full >/dev/null 2>&1; then
        _outbound_restore "$snap"
        restart_singbox_full >/dev/null 2>&1 || true
        rm -rf "$snap"
        echo -e "${RED}sing-box не запустился в новом режиме, возвращён: $prev_mode${NC}" >&2
        return 1
    fi

    rm -rf "$snap"
    return 0
}
