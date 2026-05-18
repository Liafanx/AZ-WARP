#!/bin/bash
# warper lib: cli.sh
# CLI-обёртки для команд веб-панели и автоматизации.
# Возвращают exit code 0 при успехе, ненулевой при ошибке.
# Подключается через source из warper.sh

# ===== TOGGLE =====

# Включает или выключает WARPER (без интерактивности).
# Аналог пункта 8 в главном меню, но без вопросов.
cli_toggle_warper() {
    if check_antizapret_warp; then
        echo "ERROR: ANTIZAPRET_WARP=y - WARPER cannot work" >&2
        return 1
    fi

    if needs_down_sh; then
        echo "ERROR: WARP rules from up.sh are active. Run /root/antizapret/down.sh && /root/antizapret/up.sh" >&2
        return 1
    fi

    # Автоотключение FullVPN при VPN_WARP=y
    if [ "$FULLVPN_WARP_RESOLVE" = "y" ] && check_vpn_warp; then
        unpatch_kresd_fullvpn
        FULLVPN_WARP_RESOLVE="n"
        save_main_config
    fi

    if systemctl is-active --quiet sing-box || \
       grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        # Выключаем
        systemctl stop sing-box
        systemctl disable sing-box 2>/dev/null
        systemctl disable warper-autopatch 2>/dev/null
        remove_iptables_rule FORWARD -o singbox-tun
        remove_iptables_rule FORWARD -i singbox-tun
        unpatch_kresd || return 1

        if [ "$(count_ip_ranges)" -gt 0 ]; then
            remove_all_ip_routes >/dev/null 2>&1 || true
        fi

        if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
            rm -f "$AZ_WARPER_INCLUDE_IPS"
            export DEBIAN_FRONTEND=noninteractive
            export SYSTEMD_PAGER=""
            bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1 || true
        fi

        echo "WARPER disabled"
        return 0
    else
        # Включаем
        check_and_sync_warp_keys || return 1
        if ! validate_singbox_config; then
            echo "ERROR: invalid sing-box config" >&2
            return 1
        fi
        systemctl enable sing-box 2>/dev/null
        systemctl start sing-box
        if ! ensure_singbox_running; then
            echo "ERROR: sing-box failed to start" >&2
            return 1
        fi
        systemctl enable warper-autopatch 2>/dev/null
        ensure_iptables_rule FORWARD -o singbox-tun
        ensure_iptables_rule FORWARD -i singbox-tun
        if ! patch_kresd >/dev/null 2>&1; then
            echo "ERROR: failed to patch kresd" >&2
            return 1
        fi
        if [ "$(count_ip_ranges)" -gt 0 ]; then
            sync_ip_ranges >/dev/null 2>&1 || true
        fi
        echo "WARPER enabled"
        return 0
    fi
}

# ===== РЕЖИМ МАРШРУТИЗАЦИИ =====

# Переключает на режим WARP.
# Опционально принимает source: system | wgcf | root | generate
cli_mode_warp() {
    local key_source="${1:-}"

    load_slave_config
    CURRENT_OUTBOUND_MODE="warp"
    save_slave_config

    # Если указан источник ключа, применяем его
    if [ -n "$key_source" ]; then
        local new_address="" new_private_key=""
        case "$key_source" in
            system)
                if [ ! -f "$WARP_SYSTEM_CONF" ]; then
                    echo "ERROR: $WARP_SYSTEM_CONF not found" >&2
                    return 1
                fi
                new_private_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" \
                    | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                new_address=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" \
                    | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                [ -z "$new_address" ] && new_address="172.16.0.2/32"
                [[ ! "$new_address" =~ / ]] && new_address="${new_address}/32"
                ;;
            wgcf)
                local wgcf_file="$WGCF_DIR/wgcf-profile.conf"
                if [ ! -f "$wgcf_file" ]; then
                    echo "ERROR: $wgcf_file not found" >&2
                    return 1
                fi
                new_private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_file" \
                    | awk '{print $3}' | tr -d '\r\n')
                new_address=$(grep -m 1 '^Address = ' "$wgcf_file" \
                    | awk '{print $3}' | tr -d '\r\n')
                ;;
            root)
                local root_file="/root/wgcf-profile.conf"
                if [ ! -f "$root_file" ]; then
                    echo "ERROR: $root_file not found" >&2
                    return 1
                fi
                new_private_key=$(grep -m 1 '^PrivateKey = ' "$root_file" \
                    | awk '{print $3}' | tr -d '\r\n')
                new_address=$(grep -m 1 '^Address = ' "$root_file" \
                    | awk '{print $3}' | tr -d '\r\n')
                ;;
            generate)
                cli_generate_warp_key || return 1
                new_private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" \
                    | awk '{print $3}' | tr -d '\r\n')
                new_address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" \
                    | awk '{print $3}' | tr -d '\r\n')
                ;;
            *)
                echo "ERROR: unknown key_source '$key_source' (use: system|wgcf|root|generate)" >&2
                return 1
                ;;
        esac

        if [ -z "$new_private_key" ] || [ -z "$new_address" ]; then
            echo "ERROR: failed to extract WARP keys" >&2
            return 1
        fi

        if [ ! -f "$SINGBOX_TEMPLATE" ]; then
            download_file_safe "$REPO_URL/templates/config.json.template" \
                "$SINGBOX_TEMPLATE" "config.json.template" || return 1
        fi

        sed \
            -e "s|__WARP_ADDRESS__|$new_address|g" \
            -e "s|__WARP_PRIVATE_KEY__|$new_private_key|g" \
            -e "s|__SUBNET__|$SUBNET|g" \
            -e "s|__TUN_IP__|$TUN_IP|g" \
            "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"
        chmod 600 "$SINGBOX_CONF"
    else
        # Без указания source — стандартная пересборка через get_warp_credentials
        if ! rebuild_config "$SINGBOX_TEMPLATE"; then
            echo "ERROR: failed to rebuild config" >&2
            return 1
        fi
    fi

    if ! validate_singbox_config; then
        echo "ERROR: invalid sing-box config" >&2
        return 1
    fi

    if systemctl is-active --quiet sing-box; then
        if ! restart_singbox_full; then
            echo "ERROR: failed to restart sing-box" >&2
            return 1
        fi
    fi

    echo "Mode switched to WARP"
    return 0
}

# Переключает на режим Slave.
# Аргументы: SERVER PORT PASSWORD
cli_mode_slave() {
    local server="$1"
    local port="$2"
    local password="$3"

    if [ -z "$server" ] || [ -z "$port" ] || [ -z "$password" ]; then
        echo "Usage: warper mode slave SERVER PORT PASSWORD" >&2
        return 1
    fi

    if ! validate_port_simple "$port"; then
        echo "ERROR: invalid port: $port" >&2
        return 1
    fi

    if [[ ! "$server" =~ ^[0-9a-zA-Z._:-]+$ ]]; then
        echo "ERROR: invalid server address" >&2
        return 1
    fi

    SLAVE_SERVER="$server"
    SLAVE_PORT="$port"
    SLAVE_PASSWORD="$password"
    CURRENT_OUTBOUND_MODE="slave"
    save_slave_config

    if ! rebuild_config_slave; then
        echo "ERROR: failed to rebuild slave config" >&2
        return 1
    fi

    if systemctl is-active --quiet sing-box; then
        if ! restart_singbox_full; then
            echo "ERROR: failed to restart sing-box" >&2
            return 1
        fi
    fi

    echo "Mode switched to Slave ($server:$port)"
    return 0
}

# Переключает на режим WG из указанного .conf файла.
cli_mode_wg() {
    local conf_path="$1"

    if [ -z "$conf_path" ]; then
        echo "Usage: warper mode wg /path/to/file.conf" >&2
        return 1
    fi

    if [ ! -f "$conf_path" ]; then
        echo "ERROR: file not found: $conf_path" >&2
        return 1
    fi

    if ! is_valid_wg_conf "$conf_path"; then
        echo "ERROR: not a valid WireGuard config (or it's a Cloudflare WARP file)" >&2
        return 1
    fi

    if ! parse_wg_conf "$conf_path"; then
        echo "ERROR: failed to parse WG config" >&2
        return 1
    fi

    save_wg_config

    CURRENT_OUTBOUND_MODE="wg"
    save_slave_config

    if ! rebuild_config_wg; then
        echo "ERROR: failed to rebuild WG config" >&2
        return 1
    fi

    if systemctl is-active --quiet sing-box; then
        if ! restart_singbox_full; then
            echo "ERROR: failed to restart sing-box" >&2
            return 1
        fi
    fi

    echo "Mode switched to WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)"
    return 0
}

# ===== ГЕНЕРАЦИЯ WARP-КЛЮЧА =====

# Генерирует новый wgcf-profile.conf через wgcf.
# Используется при "warper mode warp generate".
cli_generate_warp_key() {
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR" || return 1

    if [ ! -f "/usr/local/bin/wgcf" ]; then
        local sys_arch
        sys_arch=$(uname -m)
        case "$sys_arch" in
            x86_64)  sys_arch="amd64" ;;
            aarch64) sys_arch="arm64" ;;
            armv7l)  sys_arch="armv7" ;;
            *) echo "ERROR: unsupported arch" >&2; return 1 ;;
        esac
        if ! wget -qO wgcf \
            "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${sys_arch}"; then
            echo "ERROR: failed to download wgcf" >&2
            return 1
        fi
        chmod +x wgcf
        mv wgcf /usr/local/bin/wgcf
    fi

    /usr/local/bin/wgcf register --accept-tos > /dev/null 2>&1
    /usr/local/bin/wgcf generate > /dev/null 2>&1

    if [ ! -f "wgcf-profile.conf" ]; then
        echo "ERROR: wgcf-profile.conf not generated (Cloudflare may have blocked this IP)" >&2
        return 1
    fi

    chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true
    echo "WARP key generated: $WGCF_DIR/wgcf-profile.conf"
    return 0
}

# ===== ЛОГИ =====

# Возвращает последние N строк логов sing-box.
cli_logs() {
    local lines="${1:-100}"
    if [[ ! "$lines" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid line count" >&2
        return 1
    fi
    journalctl -u sing-box -n "$lines" --no-pager
}

# ===== КОНФИГУРАЦИЯ =====

# Читает значение из warper.conf.
# Доступные ключи: SUBNET, TUN_IP, IP_ROUTE_MODE, IP_EXPORT_TO_ANTIZAPRET, FULLVPN_WARP_RESOLVE
cli_config_get() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "Usage: warper config get KEY" >&2
        return 1
    fi
    case "$key" in
        SUBNET) echo "$SUBNET" ;;
        TUN_IP) echo "$TUN_IP" ;;
        IP_ROUTE_MODE) echo "$IP_ROUTE_MODE" ;;
        IP_EXPORT_TO_ANTIZAPRET) echo "$IP_EXPORT_TO_ANTIZAPRET" ;;
        FULLVPN_WARP_RESOLVE) echo "$FULLVPN_WARP_RESOLVE" ;;
        OUTBOUND_MODE) echo "$CURRENT_OUTBOUND_MODE" ;;
        SLAVE_SERVER) echo "$SLAVE_SERVER" ;;
        SLAVE_PORT) echo "$SLAVE_PORT" ;;
        WG_ENDPOINT_HOST) load_wg_config; echo "$WG_ENDPOINT_HOST" ;;
        WG_ENDPOINT_PORT) load_wg_config; echo "$WG_ENDPOINT_PORT" ;;
        WG_ADDRESS) load_wg_config; echo "$WG_ADDRESS" ;;
        WG_CONF_FILE) load_wg_config; echo "$WG_CONF_FILE" ;;
        LOG_LEVEL) get_log_level ;;
        MTU) get_mtu ;;
        *) echo "ERROR: unknown key: $key" >&2; return 1 ;;
    esac
}

# ===== СМЕНА ПОДСЕТИ =====

# Меняет fake-подсеть и пересобирает конфиг + AntiZapret routes.
cli_subnet() {
    local new_subnet="$1"

    if [ -z "$new_subnet" ]; then
        echo "Usage: warper subnet NEW_SUBNET (e.g. 198.20.0.0/24)" >&2
        return 1
    fi

    if ! validate_subnet "$new_subnet"; then
        echo "ERROR: invalid subnet format. Expected X.X.X.0/XX" >&2
        return 1
    fi

    local old_subnet="$SUBNET"
    local old_tun="$TUN_IP"
    local new_tun
    new_tun=$(calculate_tun_ip "$new_subnet")

    # Если та же подсеть - ничего не делаем
    if [ "$new_subnet" = "$old_subnet" ]; then
        echo "Subnet unchanged: $new_subnet"
        return 0
    fi

    SUBNET="$new_subnet"
    TUN_IP="$new_tun"

    # Пересобираем конфиг
    if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
        if ! rebuild_config "$SINGBOX_TEMPLATE" >/dev/null 2>&1; then
            SUBNET="$old_subnet"
            TUN_IP="$old_tun"
            echo "ERROR: failed to rebuild config, rolled back" >&2
            return 1
        fi
    else
        sed -i "s|\"$old_subnet\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
        sed -i "s|\"$old_tun\"|\"$new_tun\"|g" "$SINGBOX_CONF"
        if ! validate_singbox_config; then
            sed -i "s|\"$new_subnet\"|\"$old_subnet\"|g" "$SINGBOX_CONF"
            sed -i "s|\"$new_tun\"|\"$old_tun\"|g" "$SINGBOX_CONF"
            SUBNET="$old_subnet"
            TUN_IP="$old_tun"
            echo "ERROR: invalid config after subnet change, rolled back" >&2
            return 1
        fi
    fi

    # Обновляем include-ips
    sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
    grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || echo "$new_subnet" >> "$AZ_INC"
    normalize_include_ips "$AZ_INC"

    save_main_config

    # Обновляем маршруты AntiZapret. Запускаем "doall.sh ip" (только маршруты)
    # вместо полного "doall.sh", который намного дольше и может зависнуть
    export DEBIAN_FRONTEND=noninteractive
    export SYSTEMD_PAGER=""
    timeout 180 bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1 || {
        echo "WARNING: doall.sh ip exited non-zero or timed out" >&2
    }

    if systemctl is-active --quiet sing-box; then
        systemctl restart sing-box
        if ! ensure_singbox_running; then
            echo "ERROR: sing-box failed to restart" >&2
            return 1
        fi
        ensure_iptables_rule FORWARD -o singbox-tun
        ensure_iptables_rule FORWARD -i singbox-tun
        resync_ip_routes_if_needed
    fi

    echo "Subnet changed: $old_subnet -> $new_subnet"
    return 0
}

# ===== LOG LEVEL =====

# Wrapper для set_log_level (тихий режим).
cli_loglevel() {
    local level="$1"
    if [ -z "$level" ]; then
        echo "Usage: warper loglevel debug|info|warn|error" >&2
        return 1
    fi
    if set_log_level "$level" >/dev/null 2>&1; then
        echo "Log level set to: $level"
        return 0
    else
        echo "ERROR: failed to set log level" >&2
        return 1
    fi
}

# ===== MTU =====

cli_mtu() {
    local mtu="$1"
    if [ -z "$mtu" ]; then
        echo "Usage: warper mtu 1280-1500" >&2
        return 1
    fi
    if set_mtu "$mtu" >/dev/null 2>&1; then
        echo "MTU set to: $mtu"
        return 0
    else
        echo "ERROR: failed to set MTU" >&2
        return 1
    fi
}

# ===== АВТОПАТЧ =====

cli_autopatch() {
    local action="$1"
    case "$action" in
        on|enable)
            systemctl enable warper-autopatch >/dev/null 2>&1
            echo "Autopatch enabled"
            ;;
        off|disable)
            systemctl disable warper-autopatch >/dev/null 2>&1
            echo "Autopatch disabled"
            ;;
        *)
            echo "Usage: warper autopatch on|off" >&2
            return 1
            ;;
    esac
}

# ===== FULLVPN WARP-РЕЗОЛВИНГ =====

cli_fullvpn() {
    local action="$1"
    case "$action" in
        on|enable)
            if check_vpn_warp; then
                echo "ERROR: VPN_WARP=y - cannot enable FullVPN WARP resolve" >&2
                return 1
            fi
            if patch_kresd_fullvpn; then
                FULLVPN_WARP_RESOLVE="y"
                save_main_config
                echo "FullVPN WARP resolve enabled"
                return 0
            else
                echo "ERROR: failed to patch kresd@2" >&2
                return 1
            fi
            ;;
        off|disable)
            unpatch_kresd_fullvpn
            FULLVPN_WARP_RESOLVE="n"
            save_main_config
            echo "FullVPN WARP resolve disabled"
            ;;
        *)
            echo "Usage: warper fullvpn on|off" >&2
            return 1
            ;;
    esac
}

# ===== РЕЖИМ IP-МАРШРУТОВ =====

cli_iproutemode() {
    local mode="$1"
    case "$mode" in
        antizapret|all_vpn|all)
            IP_ROUTE_MODE="$mode"
            save_main_config
            if [ "$(count_ip_ranges)" -gt 0 ] && is_warper_active; then
                sync_ip_ranges >/dev/null 2>&1 || true
            fi
            echo "IP route mode: $mode"
            ;;
        *)
            echo "Usage: warper iproutemode antizapret|all_vpn|all" >&2
            return 1
            ;;
    esac
}

# ===== ЭКСПОРТ В АНТИЗАПРЕТ =====

cli_ipexport() {
    local action="$1"
    case "$action" in
        on|y|yes)
            IP_EXPORT_TO_ANTIZAPRET="y"
            save_main_config
            sync_ip_ranges_to_antizapret >/dev/null 2>&1 || true
            echo "IP export to AntiZapret: enabled"
            ;;
        off|n|no)
            IP_EXPORT_TO_ANTIZAPRET="n"
            save_main_config
            sync_ip_ranges_to_antizapret >/dev/null 2>&1 || true
            echo "IP export to AntiZapret: disabled"
            ;;
        *)
            echo "Usage: warper ipexport on|off" >&2
            return 1
            ;;
    esac
}

# ===== СПИСОК WARP-КЛЮЧЕЙ =====

# Возвращает доступные источники WARP-ключей в формате:
# source|path|address|is_current
cli_warpkey_list() {
    local cur_pk=""
    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    # Системный warp.conf
    if [ -f "$WARP_SYSTEM_CONF" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WARP_SYSTEM_CONF" 2>/dev/null; then
        local pk addr is_cur="0"
        pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        addr=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        [ "$pk" = "$cur_pk" ] && is_cur="1"
        echo "system|$WARP_SYSTEM_CONF|${addr:-n/a}|$is_cur"
    fi

    # Локальный wgcf
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        local pk addr is_cur="0"
        pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        addr=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        [ "$pk" = "$cur_pk" ] && is_cur="1"
        echo "wgcf|$WGCF_DIR/wgcf-profile.conf|${addr:-n/a}|$is_cur"
    fi

    # /root/wgcf-profile.conf
    if [ -f "/root/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        local pk addr is_cur="0"
        pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        addr=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        [ "$pk" = "$cur_pk" ] && is_cur="1"
        echo "root|/root/wgcf-profile.conf|${addr:-n/a}|$is_cur"
    fi
}

# ===== СПИСОК WG-КОНФИГОВ =====

# Возвращает список валидных WG-конфигов в формате:
# path|endpoint
cli_wg_list() {
    local file ep
    for dir in /root /root/warper; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' file; do
                if is_valid_wg_conf "$file"; then
                    ep=$(grep -m 1 '^Endpoint' "$file" 2>/dev/null \
                        | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                    echo "$file|${ep:-?}"
                fi
            done < <(find "$dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
        fi
    done
}

# ===== СТАТУС В JSON =====

# Возвращает полный статус WARPER в JSON.
# Используется веб-панелью для отрисовки dashboard.
cli_status_json() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq required for JSON output" >&2
        return 1
    fi

    load_config
    load_slave_config
    load_wg_config

    local sb_run="false" sb_en="false" kr_patched="false" dom_synced="false"
    local az_present="false" ap_en="false" sub_conflict="false"
    local az_warp_en="false" vpn_warp_en="false" warp_rules="false"
    local fullvpn_patched="false" ip_synced="false"

    systemctl is-active --quiet sing-box && sb_run="true"
    systemctl is-enabled --quiet sing-box 2>/dev/null && sb_en="true"
    grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null && kr_patched="true"
    domains_in_sync && dom_synced="true"
    grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null && az_present="true"
    systemctl is-enabled --quiet warper-autopatch 2>/dev/null && ap_en="true"
    subnet_conflicts "$SUBNET" && sub_conflict="true"
    check_antizapret_warp && az_warp_en="true"
    check_vpn_warp && vpn_warp_en="true"
    needs_down_sh && warp_rules="true"
    grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null && fullvpn_patched="true"
    ip_ranges_in_sync && ip_synced="true"

    local log_level mtu warp_key_src
    log_level=$(get_log_level)
    mtu=$(get_mtu)
    warp_key_src=$(get_current_warp_key_source)

    local ip_count route_count
    ip_count=$(count_ip_ranges)
    route_count=$(count_tun_routes)

    local remote_ver update_avail="false"
    remote_ver=$(get_remote_version)
    if version_gt "$remote_ver" "$LOCAL_VER"; then
        update_avail="true"
    fi

    jq -n \
        --arg version "$LOCAL_VER" \
        --arg remote_version "$remote_ver" \
        --argjson update_available "$update_avail" \
        --argjson antizapret_warp "$az_warp_en" \
        --argjson vpn_warp "$vpn_warp_en" \
        --argjson warp_rules_active "$warp_rules" \
        --arg outbound_mode "$CURRENT_OUTBOUND_MODE" \
        --arg slave_server "$SLAVE_SERVER" \
        --arg slave_port "$SLAVE_PORT" \
        --arg slave_password "$SLAVE_PASSWORD" \
        --arg wg_endpoint_host "$WG_ENDPOINT_HOST" \
        --arg wg_endpoint_port "$WG_ENDPOINT_PORT" \
        --arg wg_address "$WG_ADDRESS" \
        --arg wg_conf_file "$WG_CONF_FILE" \
        --argjson singbox_running "$sb_run" \
        --argjson singbox_enabled "$sb_en" \
        --arg log_level "$log_level" \
        --argjson mtu "$mtu" \
        --argjson kresd_patched "$kr_patched" \
        --argjson fullvpn_patched "$fullvpn_patched" \
        --arg fullvpn_warp_resolve "$FULLVPN_WARP_RESOLVE" \
        --argjson domains_synced "$dom_synced" \
        --arg fake_subnet "$SUBNET" \
        --argjson subnet_in_az "$az_present" \
        --argjson autopatch_enabled "$ap_en" \
        --argjson subnet_conflict "$sub_conflict" \
        --arg warp_keys_source "$warp_key_src" \
        --argjson ip_ranges_count "$ip_count" \
        --argjson ip_routes_count "$route_count" \
        --argjson ip_ranges_synced "$ip_synced" \
        --arg ip_route_mode "$IP_ROUTE_MODE" \
        --arg ip_export_to_az "$IP_EXPORT_TO_ANTIZAPRET" \
        '{
            version: $version,
            remote_version: $remote_version,
            update_available: $update_available,
            antizapret_warp: $antizapret_warp,
            vpn_warp: $vpn_warp,
            warp_rules_active: $warp_rules_active,
            outbound_mode: $outbound_mode,
            slave: {
                server: $slave_server,
                port: $slave_port,
                password: $slave_password
            },
            wg: {
                endpoint_host: $wg_endpoint_host,
                endpoint_port: $wg_endpoint_port,
                address: $wg_address,
                conf_file: $wg_conf_file
            },
            singbox: {
                running: $singbox_running,
                enabled: $singbox_enabled,
                log_level: $log_level,
                mtu: $mtu
            },
            kresd: {
                patched: $kresd_patched,
                fullvpn_patched: $fullvpn_patched
            },
            fullvpn_warp_resolve: $fullvpn_warp_resolve,
            domains: {
                synced: $domains_synced
            },
            subnet: {
                fake: $fake_subnet,
                in_antizapret: $subnet_in_az,
                conflict: $subnet_conflict
            },
            autopatch_enabled: $autopatch_enabled,
            warp_keys_source: $warp_keys_source,
            ip_ranges: {
                count: $ip_ranges_count,
                routes_count: $ip_routes_count,
                synced: $ip_ranges_synced,
                mode: $ip_route_mode,
                export_to_antizapret: $ip_export_to_az
            }
        }'
}

# ===== СПИСКИ ДОМЕНОВ И IP =====

# Выводит все домены в формате: name|type|enabled
# type: user|gemini|chatgpt
cli_domains_list() {
    if [ ! -f "$MASTER_FILE" ]; then
        return 0
    fi

    local in_gemini=0 in_chatgpt=0
    local has_gemini=0 has_chatgpt=0

    has_list_block "gemini" && has_gemini=1
    has_list_block "chatgpt" && has_chatgpt=1

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ "$line" == "# --- GEMINI ---" ]]; then in_gemini=1; continue; fi
        if [[ "$line" == "# --- END GEMINI ---" ]]; then in_gemini=0; continue; fi
        if [[ "$line" == "# --- CHATGPT ---" ]]; then in_chatgpt=1; continue; fi
        if [[ "$line" == "# --- END CHATGPT ---" ]]; then in_chatgpt=0; continue; fi

        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        if [ "$in_gemini" = "1" ]; then
            echo "$line|gemini|$has_gemini"
        elif [ "$in_chatgpt" = "1" ]; then
            echo "$line|chatgpt|$has_chatgpt"
        else
            echo "$line|user|1"
        fi
    done < "$MASTER_FILE"
}

# ===== РЕДАКТИРОВАНИЕ ip-ranges.txt =====

# Возвращает содержимое ip-ranges.txt без стандартной шапки-инструкции.
# Шапка определяется по строкам которые содержат типичные фразы шапки.
# Пользовательские комментарии и пустые строки сохраняются.
cli_ip_ranges_content() {
    if [ ! -f "$IP_RANGES_FILE" ]; then
        return 0
    fi

    # Точно определяем конец шапки: ищем последнюю строку шапки и выводим всё после неё.
    # Шапка по умолчанию заканчивается строкой:
    #   "# После изменения файла выполните: warper ipsync"
    # Если такой строки нет (старый файл) — берём весь файл как есть.

    local header_end_line
    header_end_line=$(grep -n '^# После изменения файла выполните' "$IP_RANGES_FILE" 2>/dev/null | head -1 | cut -d: -f1)

    if [ -z "$header_end_line" ]; then
        # Шапка не найдена — возвращаем весь файл как есть
        cat "$IP_RANGES_FILE"
        return 0
    fi

    # Пропускаем шапку и одну пустую строку после неё (если есть)
    local skip_lines=$header_end_line
    # Проверяем, есть ли пустая строка сразу после шапки
    local next_line
    next_line=$(sed -n "$((header_end_line + 1))p" "$IP_RANGES_FILE")
    if [ -z "$next_line" ]; then
        skip_lines=$((header_end_line + 1))
    fi

    tail -n +$((skip_lines + 1)) "$IP_RANGES_FILE"
}

# Заменяет содержимое ip-ranges.txt на переданные строки и синкает.
# Сохраняет пользовательские комментарии (#...) и пустые строки.
# Принимает строки из stdin.
cli_ip_ranges_save() {
    local tmp
    tmp=$(mktemp)

    # Стандартная шапка - должна точно совпадать с тем что ожидает cli_ip_ranges_content
    cat << 'IPEOF' > "$tmp"
# Добавление IPv4-адресов для маршрутизации через Warper (Sing-box tun)
#
# Формат записи: A.B.C.D/M
# Примеры: 5.255.255.242/32  66.22.192.0/18  104.24.0.0/14
#
# Строки начинающиеся с # - комментарии, не обрабатываются.
# После изменения файла выполните: warper ipsync

IPEOF

    local invalid_count=0
    local valid_count=0
    local raw_line stripped

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        raw_line="${raw_line%$'\r'}"
        stripped=$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Пустая строка - сохраняем
        if [ -z "$stripped" ]; then
            echo "" >> "$tmp"
            continue
        fi

        # Комментарий - сохраняем как есть
        if [[ "$stripped" == \#* ]]; then
            echo "$raw_line" >> "$tmp"
            continue
        fi

        # CIDR - валидируем
        local cidr="$stripped"
        if [[ "$cidr" != */* ]]; then
            cidr="${cidr}/32"
        fi

        if validate_cidr "$cidr" >/dev/null 2>&1; then
            echo "$cidr" >> "$tmp"
            valid_count=$((valid_count + 1))
        else
            invalid_count=$((invalid_count + 1))
            rm -f "$tmp"
            echo "ERROR: invalid CIDR: $stripped" >&2
            return 1
        fi
    done

    mv "$tmp" "$IP_RANGES_FILE"
    chmod 644 "$IP_RANGES_FILE"

    if is_warper_active; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi

    echo "Saved $valid_count CIDR entries"
    return 0
}


# ===== СБРОС ПАРОЛЯ ВЕБ-ПАНЕЛИ =====

# Сбрасывает учётные данные веб-панели.
# Использование:
#   warper webpass                          # интерактивно
#   warper webpass USERNAME PASSWORD        # неинтерактивно
#   warper webpass --reset                  # удалить БД (создаст admin/admin при следующем старте)
cli_webpass() {
    local web_dir="/root/warper/web"
    local users_file="$web_dir/data/users.json"
    local venv_python="$web_dir/venv/bin/python3"

    if [ ! -d "$web_dir" ]; then
        echo -e "${RED}Веб-панель не установлена ($web_dir не найден)${NC}" >&2
        return 1
    fi

    if [ ! -x "$venv_python" ]; then
        echo -e "${RED}Python venv не найден: $venv_python${NC}" >&2
        return 1
    fi

    # Режим полного сброса
    if [ "${1:-}" = "--reset" ]; then
        echo -e "${YELLOW}Удаление БД пользователей...${NC}"
        rm -f "$users_file"
        echo -e "${GREEN}БД удалена.${NC}"
        echo -e "${CYAN}При следующем запуске будет создан admin/admin.${NC}"
        if systemctl is-active --quiet warper-web 2>/dev/null; then
            echo -e "${CYAN}Перезапуск warper-web...${NC}"
            systemctl restart warper-web
            sleep 2
            echo -e "${GREEN}Готово. Логин: admin / Пароль: admin${NC}"
        else
            echo -e "${YELLOW}Сервис warper-web не запущен. Запустите вручную.${NC}"
        fi
        return 0
    fi

    local new_user="${1:-}"
    local new_pass="${2:-}"

    # Интерактивный режим
    if [ -z "$new_user" ]; then
        echo -e "${CYAN}Сброс учётных данных веб-панели WARPER${NC}"
        echo -e ""
        read -r -p "Новый логин [admin]: " new_user
        new_user="${new_user:-admin}"
    fi

    # Валидация логина
    if ! [[ "$new_user" =~ ^[A-Za-z0-9_-]{3,32}$ ]]; then
        echo -e "${RED}Логин должен быть 3-32 символа: латиница, цифры, _ или -${NC}" >&2
        return 1
    fi

    if [ -z "$new_pass" ]; then
        while true; do
            read -r -s -p "Новый пароль (мин. 6 симв.): " new_pass
            echo ""
            if [ ${#new_pass} -lt 6 ]; then
                echo -e "${RED}Пароль слишком короткий${NC}"
                continue
            fi
            read -r -s -p "Подтвердите пароль: " confirm
            echo ""
            if [ "$new_pass" != "$confirm" ]; then
                echo -e "${RED}Пароли не совпадают${NC}"
                continue
            fi
            break
        done
    fi

    if [ ${#new_pass} -lt 6 ]; then
        echo -e "${RED}Пароль должен быть минимум 6 символов${NC}" >&2
        return 1
    fi

    if [ ${#new_pass} -gt 256 ]; then
        echo -e "${RED}Пароль слишком длинный (максимум 256)${NC}" >&2
        return 1
    fi

    # Хешируем и сохраняем через Python (используем тот же bcrypt что и приложение)
    mkdir -p "$web_dir/data"
    chmod 700 "$web_dir/data"

    "$venv_python" - <<PYEOF
import json
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    from flask_bcrypt import Bcrypt
    from flask import Flask
except ImportError as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(2)

app = Flask(__name__)
bcrypt = Bcrypt(app)

username = "$new_user"
password = """$new_pass"""
users_file = Path("$users_file")

# Создаём папку
users_file.parent.mkdir(mode=0o700, exist_ok=True)

# Хешируем
password_hash = bcrypt.generate_password_hash(password).decode("utf-8")

users = {
    username: {
        "password_hash": password_hash,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "last_login": None,
    }
}

# Атомарная запись
tmp = users_file.with_suffix(".tmp")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
os.chmod(tmp, 0o600)
tmp.replace(users_file)
os.chmod(users_file, 0o600)

print("OK")
PYEOF

    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}Не удалось сохранить учётные данные${NC}" >&2
        return 1
    fi

    echo ""
    echo -e "${GREEN}✓ Учётные данные обновлены${NC}"
    echo -e "  Логин:  ${CYAN}$new_user${NC}"
    echo -e "  Пароль: ${CYAN}[скрыт]${NC}"

    # Перезапускаем сервис чтобы сбросить активные сессии
    if systemctl is-active --quiet warper-web 2>/dev/null; then
        echo -e ""
        echo -e "${YELLOW}Перезапуск warper-web (сбросит активные сессии)...${NC}"
        systemctl restart warper-web
        sleep 1
        echo -e "${GREEN}Готово. Войдите в веб-панель с новыми данными.${NC}"
    fi

    return 0
}
