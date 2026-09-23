#!/bin/bash
# warper lib: outbound.sh
# Режимы vless / hy2 / openvpn: разбор ссылки или .ovpn, сборка конфига,
# отображение. Разбор — в outbound-parse.py (URL-encoding и инлайн-блоки
# .ovpn в bash надёжно не разобрать).
# Подключается через source из warper.sh

OUTBOUND_PARSER="${OUTBOUND_PARSER:-$WARPER_DIR/lib/outbound-parse.py}"

# Режим warper → подкоманда разборщика
_outbound_parser_kind() {
    case "$1" in
        vless)   echo "vless" ;;
        hy2)     echo "hy2" ;;
        openvpn) echo "ovpn" ;;
        *)       return 1 ;;
    esac
}

# Разбирает ссылку или .ovpn и сохраняет результат в outbound.json.
# Используется как SETTER в apply_outbound_mode.
#   _set_outbound MODE ИСТОЧНИК [ЛОГИН ПАРОЛЬ]
_set_outbound() {
    local mode="$1" source="$2" kind parsed
    kind=$(_outbound_parser_kind "$mode") || {
        echo "ERROR: unknown mode $mode" >&2; return 1; }

    local -a args=("$kind" "$source")
    if [ "$mode" = "openvpn" ]; then
        [ -n "${3:-}" ] && args+=(--user "$3")
        [ -n "${4:-}" ] && args+=(--pass "$4")
    fi

    parsed=$(python3 "$OUTBOUND_PARSER" "${args[@]}") || return 1

    local warning
    while IFS= read -r warning; do
        [ -n "$warning" ] && echo -e "${YELLOW}Предупреждение: ${warning}${NC}" >&2
    done < <(jq -r '.warnings[]?' <<< "$parsed")

    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$parsed" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$OUTBOUND_JSON"
}

# Ссылка ss:// донора → параметры режима slave.
_set_slave_from_link() {
    local parsed
    parsed=$(python3 "$OUTBOUND_PARSER" ss "$1") || return 1
    SLAVE_SERVER=$(jq -r '.server' <<< "$parsed")
    SLAVE_PORT=$(jq -r '.port' <<< "$parsed")
    SLAVE_PASSWORD=$(jq -r '.password' <<< "$parsed")
}

# Собирает config.json из config-proxy.json.template и outbound.json.
# Прокси (vless, hy2) идут в outbounds. OpenVPN — L3-endpoint: как и
# WireGuard, в 1.14 он требует resolve перед маршрутом, иначе соединения
# на fake-IP отбрасываются.
rebuild_config_proxy() {
    if [ ! -s "$OUTBOUND_JSON" ]; then
        echo -e "${RED}Нет параметров подключения ($OUTBOUND_JSON)${NC}" >&2
        return 1
    fi
    local protocol
    protocol=$(jq -r '.protocol // empty' "$OUTBOUND_JSON" 2>/dev/null)
    if [ "$protocol" != "$CURRENT_OUTBOUND_MODE" ]; then
        echo -e "${RED}outbound.json содержит ${protocol:-неизвестно}, а режим — $CURRENT_OUTBOUND_MODE${NC}" >&2
        return 1
    fi

    if [ ! -f "$PROXY_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config-proxy.json.template" \
            "$PROXY_TEMPLATE" "шаблон proxy" || return 1
    fi

    local tmp
    tmp=$(mktemp)
    sed -e "s|__SUBNET__|$SUBNET|g" -e "s|__TUN_IP__|$TUN_IP|g" "$PROXY_TEMPLATE" \
        | jq --slurpfile p "$OUTBOUND_JSON" '
            ($p[0]) as $o
            | if $o.kind == "endpoint" then
                .endpoints = [$o.object]
                | .route.rules |= map(
                    if .inbound == "tun-in" and .outbound == "proxy"
                    then ({inbound: "tun-in", action: "resolve", server: "real-dns"}), .
                    else . end)
              else
                .outbounds = [$o.object] + .outbounds
              end' > "$tmp" || { rm -f "$tmp"; return 1; }

    install_singbox_config "$tmp" || return 1
    echo -e "${GREEN}Конфигурация sing-box ($(outbound_protocol_label)) успешно обновлена.${NC}"
}

# ===== Отображение =====

# Название протокола текущего outbound.json
outbound_protocol_label() {
    [ -s "$OUTBOUND_JSON" ] || { echo "?"; return; }
    jq -r '
        if .protocol == "vless" then
            if .object.tls.reality.enabled then "VLESS+Reality" else "VLESS" end
        elif .protocol == "hy2" then "Hysteria2"
        elif .protocol == "openvpn" then "OpenVPN"
        else .protocol end' "$OUTBOUND_JSON" 2>/dev/null || echo "?"
}

# Сервер, порт и имя без секретов — для меню, статуса и API.
outbound_summary_json() {
    [ -s "$OUTBOUND_JSON" ] || { echo '{}'; return; }
    jq -c '{protocol, server, port,
            ports: (.object.server_ports // null),
            name, transport: (.object.transport.type // null)}' \
        "$OUTBOUND_JSON" 2>/dev/null || echo '{}'
}

# Человекочитаемое описание текущего режима.
outbound_mode_label() {
    case "$CURRENT_OUTBOUND_MODE" in
        warp)  echo "WARP (локальный)" ;;
        slave) echo "Slave (донор ${SLAVE_SERVER}:${SLAVE_PORT}, Shadowsocks)" ;;
        wg)
            load_wg_config
            echo "WG (${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT})"
            ;;
        vless|hy2|openvpn)
            local server port name
            server=$(jq -r '.server // "?"' "$OUTBOUND_JSON" 2>/dev/null)
            port=$(jq -r '.port // (.object.server_ports[0] // "?")' "$OUTBOUND_JSON" 2>/dev/null)
            name=$(jq -r '.name // ""' "$OUTBOUND_JSON" 2>/dev/null)
            if [ -n "$name" ] && [ "$name" != "$server" ]; then
                echo "$(outbound_protocol_label) (${name}, ${server}:${port})"
            else
                echo "$(outbound_protocol_label) (${server}:${port})"
            fi
            ;;
        *) echo "$CURRENT_OUTBOUND_MODE" ;;
    esac
}

# ===== .ovpn =====

# Ищет .ovpn в /root и /root/warper — по образцу scan_wg_configs
scan_ovpn_configs() {
    local dir file
    for dir in /root "$WARPER_DIR"; do
        [ -d "$dir" ] || continue
        while IFS= read -r file; do
            grep -qiE '^[[:space:]]*remote[[:space:]]' "$file" 2>/dev/null && echo "$file"
        done < <(find "$dir" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | sort)
    done
}

# Нужен ли конфигу логин/пароль
ovpn_needs_auth() {
    grep -qiE '^[[:space:]]*auth-user-pass' "$1" 2>/dev/null
}

# ===== CLI =====

# warper mode vless|hy2 ССЫЛКА
# warper mode openvpn ФАЙЛ [ЛОГИН ПАРОЛЬ]
cli_mode_proxy() {
    local mode="$1"; shift
    local source="${1:-}"
    if [ -z "$source" ]; then
        case "$mode" in
            vless)   echo "Usage: warper mode vless 'vless://...'" >&2 ;;
            hy2)     echo "Usage: warper mode hy2 'hy2://...'" >&2 ;;
            openvpn) echo "Usage: warper mode openvpn /path/file.ovpn [USER PASS]" >&2 ;;
        esac
        return 1
    fi

    if ! apply_outbound_mode "$mode" _set_outbound "$mode" "$@"; then
        echo "ERROR: failed to switch to $mode mode" >&2
        return 1
    fi
    echo "Mode switched to $(outbound_mode_label)"
}

# warper outbound — текущий режим и сервер без секретов
cli_outbound() {
    echo "mode=$CURRENT_OUTBOUND_MODE"
    echo "label=$(outbound_mode_label)"
    case "$CURRENT_OUTBOUND_MODE" in
        vless|hy2|openvpn)
            outbound_summary_json | jq -r 'to_entries[] | select(.value != null)
                | "\(.key)=\(.value | if type == "array" then join(",") else tostring end)"'
            ;;
    esac
}

# warper ovpnconfig list — path|server
cli_ovpn_list() {
    local file server
    while IFS= read -r file; do
        server=$(grep -m1 -iE '^[[:space:]]*remote[[:space:]]' "$file" | awk '{print $2":"($3?$3:"1194")}')
        echo "$file|$server"
    done < <(scan_ovpn_configs)
}
