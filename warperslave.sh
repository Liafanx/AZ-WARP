#!/bin/bash

set -uo pipefail

SLAVE_DIR="/root/warperslave"
SLAVE_CONF="$SLAVE_DIR/slave.conf"
WGCF_DIR="$SLAVE_DIR/wgcf"
SINGBOX_SLAVE_CONF="/etc/sing-box-slave/config.json"
SERVICE_NAME="sing-box-slave"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
SB_VERSION="1.14.1"
LOCAL_VER=$(cat "$SLAVE_DIR/versionslave" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOCK_FILE="/var/run/warperslave.lock"
REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

acquire_lock() {
    exec 8>"$LOCK_FILE"
    if ! flock -n 8; then
        echo -e "${RED}Другой экземпляр warperslave уже запущен.${NC}" >&2
        exit 1
    fi
}

release_lock() {
    rm -f "$LOCK_FILE"
}

trap 'release_lock' EXIT
acquire_lock

load_config_value() {
    local key="$1"
    grep -E "^${key}=" "$SLAVE_CONF" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

# Выход донора: direct | warp | wg | openvpn | vless | hy2 | ss.
# Протокол входа: ss | vless | hy2.
SLAVE_MODE=""
SLAVE_PROTO=""
SLAVE_PORT=""
SLAVE_HOST=""
SLAVE_SNI=""
SS_PASSWORD=""
VLESS_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
HY2_PASSWORD=""
HY2_OBFS_PASSWORD=""

LOCAL_PORT=""
EXIT_JSON="$SLAVE_DIR/exit.json"
EXIT_PARSER="$SLAVE_DIR/outbound-parse.py"
OVPN_AUTH_JSON="$SLAVE_DIR/ovpn-auth.json"

HY2_CERT="/etc/sing-box-slave/hy2.crt"
HY2_KEY="/etc/sing-box-slave/hy2.key"
DEFAULT_SNI="www.microsoft.com"

load_config() {
    if [ ! -f "$SLAVE_CONF" ]; then
        echo -e "${RED}Конфигурация warperslave не найдена: $SLAVE_CONF${NC}"
        echo -e "${YELLOW}Запустите установщик:${NC}"
        echo -e "  ${GREEN}curl -fsSL $REPO_URL/install-slave.sh | bash${NC}"
        exit 1
    fi
    SLAVE_MODE=$(load_config_value "SLAVE_MODE" | tr -d '[:space:]')
    SLAVE_PROTO=$(load_config_value "SLAVE_PROTO" | tr -d '[:space:]')
    SLAVE_PORT=$(load_config_value "SLAVE_PORT" | tr -d '[:space:]')
    SLAVE_HOST=$(load_config_value "SLAVE_HOST" | tr -d '[:space:]')
    SLAVE_SNI=$(load_config_value "SLAVE_SNI" | tr -d '[:space:]')
    SS_PASSWORD=$(load_config_value "SS_PASSWORD")
    VLESS_UUID=$(load_config_value "VLESS_UUID" | tr -d '[:space:]')
    REALITY_PRIVATE_KEY=$(load_config_value "REALITY_PRIVATE_KEY" | tr -d '[:space:]')
    REALITY_PUBLIC_KEY=$(load_config_value "REALITY_PUBLIC_KEY" | tr -d '[:space:]')
    REALITY_SHORT_ID=$(load_config_value "REALITY_SHORT_ID" | tr -d '[:space:]')
    HY2_PASSWORD=$(load_config_value "HY2_PASSWORD" | tr -d '[:space:]')
    HY2_OBFS_PASSWORD=$(load_config_value "HY2_OBFS_PASSWORD" | tr -d '[:space:]')
    LOCAL_PORT=$(load_config_value "LOCAL_PORT" | tr -d '[:space:]')
    # Установки до 1.1.0 знали только Shadowsocks
    SLAVE_PROTO="${SLAVE_PROTO:-ss}"
    SLAVE_SNI="${SLAVE_SNI:-$DEFAULT_SNI}"
}

save_config() {
    {
        echo "SLAVE_MODE=$SLAVE_MODE"
        echo "SLAVE_PROTO=$SLAVE_PROTO"
        echo "SLAVE_PORT=$SLAVE_PORT"
        echo "SLAVE_HOST=$SLAVE_HOST"
        echo "SLAVE_SNI=$SLAVE_SNI"
        echo "SS_PASSWORD=$SS_PASSWORD"
        echo "VLESS_UUID=$VLESS_UUID"
        echo "REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY"
        echo "REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY"
        echo "REALITY_SHORT_ID=$REALITY_SHORT_ID"
        echo "HY2_PASSWORD=$HY2_PASSWORD"
        echo "HY2_OBFS_PASSWORD=$HY2_OBFS_PASSWORD"
        echo "LOCAL_PORT=$LOCAL_PORT"
    } > "$SLAVE_CONF"
    chmod 600 "$SLAVE_CONF"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# Свободен ли порт по TCP и UDP (Hysteria2 слушает UDP). Собственный
# процесс службы занятостью не считается. Вывод ss читается целиком:
# под pipefail "ss | grep -q" возвращает 141 при найденном совпадении.
check_port_available() {
    local port="$1" current_pid listeners
    current_pid=$(systemctl show -p MainPID "$SERVICE_NAME" 2>/dev/null | cut -d= -f2)
    listeners=$(ss -tulnp 2>/dev/null || true)
    listeners=$(grep ":${port} " <<< "$listeners" || true)
    if [ -n "$current_pid" ] && [ "$current_pid" != "0" ]; then
        listeners=$(grep -v "pid=${current_pid}," <<< "$listeners" || true)
    fi
    [ -z "$listeners" ]
}

ensure_port_open() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT
}

remove_port_rules() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT
}

get_log_level() {
    if [ -f "$SINGBOX_SLAVE_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.log.level // "info"' "$SINGBOX_SLAVE_CONF" 2>/dev/null || echo "info"
    else
        echo "info"
    fi
}

set_log_level() {
    local new_level="$1"
    case "$new_level" in
        debug|info|warn|error) ;;
        *) echo -e "${RED}Некорректный log level: $new_level${NC}"; return 1 ;;
    esac
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"; return 1
    fi
    local backup tmp old_level
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    tmp=$(mktemp)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"
    old_level=$(get_log_level)
    if [ "$old_level" = "$new_level" ]; then
        rm -f "$backup" "$tmp"
        echo -e "${YELLOW}log level уже установлен: $new_level${NC}"
        return 0
    fi
    if ! jq --arg lvl "$new_level" '.log.level = $lvl' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"; return 1
    fi
    mv "$tmp" "$SINGBOX_SLAVE_CONF"
    chmod 600 "$SINGBOX_SLAVE_CONF"
    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"; chmod 600 "$SINGBOX_SLAVE_CONF"; rm -f "$backup"
        echo -e "${RED}Откат выполнен.${NC}"; return 1
    fi
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"; chmod 600 "$SINGBOX_SLAVE_CONF"
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"; return 1
    fi
    rm -f "$backup"
    echo -e "${GREEN}log level изменён: ${old_level} → ${new_level}${NC}"
    return 0
}

get_mtu() {
    if [ -f "$SINGBOX_SLAVE_CONF" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.endpoints[0].mtu // empty' "$SINGBOX_SLAVE_CONF" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

set_mtu() {
    local new_mtu="$1"
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || (( new_mtu < 1280 || new_mtu > 1500 )); then
        echo -e "${RED}Некорректный MTU: $new_mtu (допустимо 1280-1500)${NC}"; return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq не найден.${NC}"; return 1
    fi
    local old_mtu
    old_mtu=$(get_mtu)
    if [ -z "$old_mtu" ]; then
        echo -e "${RED}MTU доступен только для выходов WARP, WireGuard и OpenVPN.${NC}"; return 1
    fi
    if [ "$old_mtu" = "$new_mtu" ]; then
        echo -e "${YELLOW}MTU уже установлен: $new_mtu${NC}"; return 0
    fi
    local backup tmp
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    tmp=$(mktemp)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"
    if ! jq --argjson mtu "$new_mtu" '.endpoints[0].mtu = $mtu' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
        rm -f "$backup" "$tmp"; return 1
    fi
    mv "$tmp" "$SINGBOX_SLAVE_CONF"
    chmod 600 "$SINGBOX_SLAVE_CONF"
    if ! validate_singbox_config; then
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"; chmod 600 "$SINGBOX_SLAVE_CONF"; rm -f "$backup"
        echo -e "${RED}Откат выполнен.${NC}"; return 1
    fi
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"; chmod 600 "$SINGBOX_SLAVE_CONF"
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"; return 1
    fi
    rm -f "$backup"
    # Иначе пересборка вернёт MTU из импортированного конфига
    if [ "$SLAVE_MODE" = "wg" ] || [ "$SLAVE_MODE" = "openvpn" ]; then
        tmp=$(mktemp)
        if jq --argjson mtu "$new_mtu" '.object.mtu = $mtu' "$EXIT_JSON" > "$tmp"; then
            chmod 600 "$tmp"; mv -f "$tmp" "$EXIT_JSON"
        else
            rm -f "$tmp"
        fi
    fi
    echo -e "${GREEN}MTU изменён: ${old_mtu} → ${new_mtu}${NC}"
    return 0
}

# Установленная версия sing-box (пусто, если бинарник не найден).
get_singbox_version() {
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box version 2>/dev/null | awk 'NR == 1 {print $3}'
}

# Установлен ли sing-box не старше VERSION.
singbox_at_least() {
    local current
    current=$(get_singbox_version) || return 1
    [ "$(printf '%s\n' "$1" "$current" | sort -V | head -n1)" = "$1" ]
}

# Предлагает обновить sing-box до SB_VERSION. Без терминала — только подсказка.
offer_singbox_upgrade() {
    local reason="$1" answer
    echo -e "${YELLOW}${reason}: установлен sing-box $(get_singbox_version || echo '?'), нужен $SB_VERSION.${NC}" >&2
    if ! [ -t 0 ] || ! [ -t 1 ]; then
        echo -e "${CYAN}Обновить: warperslave singbox upgrade${NC}" >&2
        return 1
    fi
    read -r -p "Обновить sing-box до $SB_VERSION? [Y/n]: " answer
    [[ -n "$answer" && ! "$answer" =~ ^[Yy]$ ]] && return 1
    singbox_cmd upgrade
}

# CLI: warperslave singbox version|upgrade [VERSION]
singbox_cmd() {
    local action="${1:-}" arg="${2:-}"
    case "$action" in
        version)
            local ver
            ver=$(get_singbox_version) || { echo "ERROR: sing-box not installed" >&2; return 1; }
            echo "$ver"
            ;;
        upgrade)
            local target="${arg:-$SB_VERSION}" current
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
            # Бинарник общий с основным sing-box, перезапускаем обе службы
            local unit
            for unit in "$SERVICE_NAME" sing-box; do
                systemctl is-active --quiet "$unit" 2>/dev/null || continue
                systemctl restart "$unit" || echo "WARNING: $unit restart failed" >&2
            done
            echo "sing-box upgraded to $target"
            ;;
        *)
            echo "Usage: warperslave singbox version|upgrade [VERSION]" >&2
            return 1
            ;;
    esac
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then return 1; fi
    sing-box check -c "$SINGBOX_SLAVE_CONF" >/dev/null 2>&1
}

# ===== Сборка конфига =====
#
# Конфиг собирается через jq из slave.conf: вход (протокол) × выход
# (direct/warp). Раньше это были два heredoc'а под Shadowsocks, которые
# дублировали шаблоны и расходились с ними.

# Генерирует недостающие учётные данные для протокола.
ensure_proto_credentials() {
    case "$SLAVE_PROTO" in
        ss)
            [ -n "$SS_PASSWORD" ] || SS_PASSWORD=$(openssl rand -base64 16)
            ;;
        vless)
            [ -n "$VLESS_UUID" ] || VLESS_UUID=$(sing-box generate uuid)
            if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
                local kp
                kp=$(sing-box generate reality-keypair) || return 1
                REALITY_PRIVATE_KEY=$(awk '/PrivateKey/{print $2}' <<< "$kp")
                REALITY_PUBLIC_KEY=$(awk '/PublicKey/{print $2}' <<< "$kp")
            fi
            [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID=$(sing-box generate rand --hex 8)
            ;;
        hy2)
            [ -n "$HY2_PASSWORD" ] || HY2_PASSWORD=$(sing-box generate rand --hex 16)
            [ -n "$HY2_OBFS_PASSWORD" ] || HY2_OBFS_PASSWORD=$(sing-box generate rand --hex 16)
            ensure_hy2_certificate || return 1
            ;;
        *)
            echo -e "${RED}Неизвестный протокол: $SLAVE_PROTO${NC}" >&2
            return 1
            ;;
    esac
}

# Самоподписанный сертификат для Hysteria2. Master пиннит его публичный
# ключ (spki в ссылке), поэтому CA не нужен.
ensure_hy2_certificate() {
    [ -s "$HY2_CERT" ] && [ -s "$HY2_KEY" ] && return 0
    mkdir -p "$(dirname "$HY2_CERT")"
    local out
    out=$(sing-box generate tls-keypair "$SLAVE_SNI") || return 1
    awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' <<< "$out" > "$HY2_KEY"
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' <<< "$out" > "$HY2_CERT"
    chmod 600 "$HY2_KEY"
    [ -s "$HY2_CERT" ] && [ -s "$HY2_KEY" ]
}

# Проверяет, что сайт для Reality отвечает по TLS 1.3 — иначе маскировка
# не заработает.
check_reality_sni() {
    local sni="$1"
    local out
    out=$(timeout 10 openssl s_client -connect "${sni}:443" -servername "$sni" -tls1_3 \
        </dev/null 2>/dev/null || true)
    grep -q "TLSv1.3" <<< "$out"
}

# Печатает inbound для текущего протокола.
_slave_inbound_json() {
    case "$SLAVE_PROTO" in
        ss)
            jq -n --argjson port "$SLAVE_PORT" --arg pw "$SS_PASSWORD" \
                '{type:"shadowsocks", tag:"in", listen:"0.0.0.0", listen_port:$port,
                  method:"2022-blake3-aes-128-gcm", password:$pw}'
            ;;
        vless)
            jq -n --argjson port "$SLAVE_PORT" --arg uuid "$VLESS_UUID" --arg sni "$SLAVE_SNI" \
                  --arg priv "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" \
                '{type:"vless", tag:"in", listen:"0.0.0.0", listen_port:$port,
                  users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
                  tls:{enabled:true, server_name:$sni,
                       reality:{enabled:true, handshake:{server:$sni, server_port:443},
                                private_key:$priv, short_id:[$sid]}}}'
            ;;
        hy2)
            jq -n --argjson port "$SLAVE_PORT" --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS_PASSWORD" \
                  --arg cert "$HY2_CERT" --arg key "$HY2_KEY" \
                '{type:"hysteria2", tag:"in", listen:"0.0.0.0", listen_port:$port,
                  users:[{password:$pw}], obfs:{type:"salamander", password:$obfs},
                  tls:{enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key}}'
            ;;
    esac
}

# WARP-endpoint из ключей AntiZapret или wgcf.
_warp_exit_json() {
    local mtu="$1" keys
    keys=$(find_warp_keys) || {
        echo -e "${RED}WARP-ключи не найдены!${NC}" >&2
        echo -e "${YELLOW}Положите wgcf-profile.conf в $SLAVE_DIR/wgcf/ и попробуйте снова.${NC}" >&2
        return 1
    }
    jq -n --argjson mtu "$mtu" --arg addr "$(sed -n '1p' <<< "$keys")" \
          --arg pk "$(sed -n '2p' <<< "$keys")" '
        {kind:"endpoint", dns:null,
         object:{type:"wireguard", tag:"exit", name:"warp-tun", system:false, mtu:$mtu,
                 address:[$addr], private_key:$pk,
                 peers:[{address:"162.159.192.1", port:2408,
                         public_key:"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                         allowed_ips:["0.0.0.0/0"], reserved:[0,0,0]}]}}'
}

# Выход из exit.json (wg, openvpn, vless, hy2, ss).
_custom_exit_json() {
    if [ ! -s "$EXIT_JSON" ]; then
        echo -e "${RED}Нет параметров выхода ($EXIT_JSON). Задайте: warperslave exit${NC}" >&2
        return 1
    fi
    local protocol
    protocol=$(jq -r '.protocol // empty' "$EXIT_JSON" 2>/dev/null)
    if [ "$protocol" != "$SLAVE_MODE" ]; then
        echo -e "${RED}exit.json содержит ${protocol:-неизвестно}, а выход — $SLAVE_MODE${NC}" >&2
        return 1
    fi
    jq -c '{kind, dns: (.dns // null), object: (.object | .tag = "exit")}' "$EXIT_JSON"
}

# Собирает конфиг в файл OUT. Уровень логов и MTU берутся из текущего
# конфига, чтобы пересборка не сбрасывала настройки пользователя.
# L3-выходы (WARP, WireGuard, OpenVPN) получают домены уже разрезолвленными
# через DNS внутри туннеля; прокси передают домен дальше как есть.
_slave_render() {
    local out="$1" inbound local_in="null" level mtu exit_spec="null"
    inbound=$(_slave_inbound_json) || return 1
    if [ -n "$LOCAL_PORT" ]; then
        local_in=$(jq -n --argjson port "$LOCAL_PORT" \
            '{type:"mixed", tag:"local", listen:"127.0.0.1", listen_port:$port}')
    fi
    level=$(jq -r '.log.level // "info"' "$SINGBOX_SLAVE_CONF" 2>/dev/null || echo info)
    mtu=$(jq -r '.endpoints[0].mtu // 1420' "$SINGBOX_SLAVE_CONF" 2>/dev/null || echo 1420)

    case "$SLAVE_MODE" in
        direct) ;;
        warp) exit_spec=$(_warp_exit_json "${mtu:-1420}") || return 1 ;;
        wg|openvpn|vless|hy2|ss) exit_spec=$(_custom_exit_json) || return 1 ;;
        *) echo -e "${RED}Неизвестный выход: $SLAVE_MODE${NC}" >&2; return 1 ;;
    esac

    jq -n --argjson in "$inbound" --argjson local "$local_in" --arg level "$level" \
          --argjson x "$exit_spec" '
        ([$in, $local] | map(select(. != null))) as $ins
        | ($ins | map(.tag)) as $tags
        | {log:{level:$level}, inbounds:$ins,
           outbounds:[{type:"direct", tag:"direct"}],
           route:{default_domain_resolver:"local", final:"direct"}}
        | if $x == null then
            .dns = {servers:[{tag:"local", type:"udp", server:"1.1.1.1"}], strategy:"ipv4_only"}
            | .route.rules = [{inbound:$tags, outbound:"direct"}]
          else
            .dns = {servers:[{tag:"exit-dns", type:"udp", server:($x.dns // "1.1.1.1"), detour:"exit"},
                             {tag:"local", type:"udp", server:"8.8.8.8"}],
                    strategy:"ipv4_only"}
            | if $x.kind == "endpoint" then
                .endpoints = [$x.object]
                | .route.rules = [{inbound:$tags, action:"resolve", server:"exit-dns", strategy:"ipv4_only"},
                                  {inbound:$tags, outbound:"exit"}]
              else
                .outbounds = [$x.object] + .outbounds
                | .route.rules = [{inbound:$tags, outbound:"exit"}]
              end
          end' > "$out"
}

# Собирает конфиг из slave.conf, проверяет и перезапускает службу.
# При любой ошибке возвращает прежние slave.conf и config.json.
# Вызывающий меняет переменные и передаёт копию прежнего slave.conf.
#   apply_slave_config [ПРЕЖНИЙ_SLAVE_CONF]
apply_slave_config() {
    local prev_conf="${1:-}" tmp backup
    tmp=$(mktemp)
    backup=$(mktemp)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup" 2>/dev/null || true

    _slave_rollback() {
        [ -n "$prev_conf" ] && [ -f "$prev_conf" ] && cp -a "$prev_conf" "$SLAVE_CONF"
        [ -s "$backup" ] && cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        rm -f "$tmp" "$backup"
        load_config
    }

    if ! ensure_proto_credentials || ! _slave_render "$tmp"; then
        _slave_rollback; return 1
    fi
    if ! sing-box check -c "$tmp" >/dev/null 2>&1; then
        echo -e "${RED}Собранный конфиг не прошёл проверку sing-box:${NC}" >&2
        sing-box check -c "$tmp" 2>&1 | tail -n 3 >&2 || true
        _slave_rollback; return 1
    fi

    save_config
    mkdir -p "$(dirname "$SINGBOX_SLAVE_CONF")"
    mv -f "$tmp" "$SINGBOX_SLAVE_CONF"
    chmod 600 "$SINGBOX_SLAVE_CONF"

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || \
       systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl restart "$SERVICE_NAME"
        sleep 2
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "${RED}Служба не запустилась с новым конфигом, откат.${NC}" >&2
            _slave_rollback
            systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    rm -f "$backup"
    return 0
}

# Копия текущего slave.conf для отката.
snapshot_slave_conf() {
    local snap
    snap=$(mktemp)
    cp -a "$SLAVE_CONF" "$snap" 2>/dev/null || true
    echo "$snap"
}

# ===== Выход трафика =====

# Разборщик ссылок и конфигов общий с WARPER. Обновлятор 1.1.x его
# не ставит, поэтому докачивается при первой надобности.
ensure_exit_parser() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}Нужен python3: apt-get install -y python3${NC}" >&2
        return 1
    fi
    [ -s "$EXIT_PARSER" ] && return 0
    download_file_safe "$REPO_URL/lib/outbound-parse.py" "$EXIT_PARSER" "outbound-parse.py" || return 1
    chmod 755 "$EXIT_PARSER"
}

ovpn_needs_auth() {
    grep -qiE '^[[:space:]]*auth-user-pass' "$1" 2>/dev/null
}

# Логин и пароль OpenVPN хранятся для каждого .ovpn (ключ — полный путь).
#   _exit_saved_auth ФАЙЛ username|password
_exit_saved_auth() {
    [ -s "$OVPN_AUTH_JSON" ] || return 0
    jq -r --arg f "$(realpath -m "$1")" --arg k "$2" '.[$f][$k] // empty' \
        "$OVPN_AUTH_JSON" 2>/dev/null
}

_exit_save_auth() {
    local tmp
    tmp=$(mktemp)
    { [ -s "$OVPN_AUTH_JSON" ] && cat "$OVPN_AUTH_JSON" || echo '{}'; } \
        | jq --arg f "$(realpath -m "$1")" --arg u "$2" --arg p "$3" \
            '.[$f] = {username: $u, password: $p}' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$OVPN_AUTH_JSON"
}

# Меняет выход донора.
#   set_exit direct|warp
#   set_exit wg ФАЙЛ | openvpn ФАЙЛ [ЛОГИН ПАРОЛЬ] | vless|hy2|ss ССЫЛКА
set_exit() {
    load_config
    local mode="${1:-}" src="${2:-}" user="${3:-}" pass="${4:-}"
    [ "$mode" = "hysteria2" ] && mode="hy2"
    case "$mode" in
        direct|warp|wg|openvpn|vless|hy2|ss) ;;
        *) echo -e "${RED}Выход: direct | warp | wg | openvpn | vless | hy2 | ss${NC}" >&2; return 1 ;;
    esac

    # Endpoint openvpn-client появился в sing-box 1.14
    if [ "$mode" = "openvpn" ] && ! singbox_at_least 1.14.0; then
        offer_singbox_upgrade "OpenVPN требует sing-box 1.14+" || return 1
    fi

    local parsed="" exit_backup=""
    if [ "$mode" != "direct" ] && [ "$mode" != "warp" ]; then
        if [ -z "$src" ]; then
            echo -e "${RED}Укажите файл конфига или ссылку.${NC}" >&2
            return 1
        fi
        ensure_exit_parser || return 1
        local -a args
        case "$mode" in
            wg) args=(wg "$src") ;;
            openvpn)
                args=(ovpn "$src")
                if [ -z "$user" ] && ovpn_needs_auth "$src"; then
                    user=$(_exit_saved_auth "$src" username)
                    pass=$(_exit_saved_auth "$src" password)
                fi
                [ -n "$user" ] && args+=(--user "$user")
                [ -n "$pass" ] && args+=(--pass "$pass")
                ;;
            ss) args=(ss "$src" --any-method) ;;
            *)  args=("$mode" "$src") ;;
        esac
        parsed=$(python3 "$EXIT_PARSER" "${args[@]}") || return 1
        local warning
        while IFS= read -r warning; do
            [ -n "$warning" ] && echo -e "${YELLOW}Предупреждение: ${warning}${NC}" >&2
        done < <(jq -r '.warnings[]?' <<< "$parsed")
        # Без ссылки в exit.json: в ней те же секреты, что и в object
        [ "$mode" != "openvpn" ] && [ "$mode" != "wg" ] && parsed=$(jq -c '.source = null' <<< "$parsed")
        if [ -f "$EXIT_JSON" ]; then
            exit_backup=$(mktemp)
            cp -a "$EXIT_JSON" "$exit_backup"
        fi
        (umask 077; printf '%s\n' "$parsed" > "$EXIT_JSON")
    fi

    local snap
    snap=$(snapshot_slave_conf)
    SLAVE_MODE="$mode"
    if apply_slave_config "$snap"; then
        rm -f "$snap" "$exit_backup"
        [ "$mode" = "openvpn" ] && [ -n "$user" ] && _exit_save_auth "$src" "$user" "$pass"
        echo -e "${GREEN}Выход: $(exit_label)${NC}"
        return 0
    fi
    rm -f "$snap"
    if [ -n "$parsed" ]; then
        if [ -n "$exit_backup" ]; then mv -f "$exit_backup" "$EXIT_JSON"; else rm -f "$EXIT_JSON"; fi
    fi
    echo -e "${RED}Не удалось сменить выход, остаётся: $(exit_label)${NC}" >&2
    return 1
}

exit_label() {
    case "$SLAVE_MODE" in
        direct) echo "Direct"; return ;;
        warp)   echo "WARP"; return ;;
    esac
    [ -s "$EXIT_JSON" ] || { echo "$SLAVE_MODE (не настроен)"; return; }
    jq -r '
        (if .protocol == "wg" then "WireGuard"
         elif .protocol == "openvpn" then "OpenVPN"
         elif .protocol == "vless" then
            (if .object.tls.reality.enabled then "VLESS+Reality" else "VLESS" end)
         elif .protocol == "hy2" then "Hysteria2"
         elif .protocol == "ss" then "Shadowsocks"
         else .protocol end)
        + " (" + ((.name // "") | if . != "" then . + ", " else "" end)
        + (.server | tostring) + ":" + (.port | tostring) + ")"' "$EXIT_JSON" 2>/dev/null \
        || echo "$SLAVE_MODE"
}

# Конфиги для выбора: WireGuard (*.conf с [Peer], кроме Cloudflare WARP)
# или OpenVPN (*.ovpn с remote) из /root и каталога донора.
#   scan_exit_configs wg|openvpn
scan_exit_configs() {
    local kind="$1" dir file
    for dir in /root "$SLAVE_DIR"; do
        [ -d "$dir" ] || continue
        if [ "$kind" = "wg" ]; then
            while IFS= read -r file; do
                grep -q '^\[Peer\]' "$file" 2>/dev/null || continue
                grep -q "$CF_WARP_PUBKEY" "$file" 2>/dev/null && continue
                echo "$file"
            done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
        else
            while IFS= read -r file; do
                grep -qiE '^[[:space:]]*remote[[:space:]]' "$file" 2>/dev/null && echo "$file"
            done < <(find "$dir" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | sort)
        fi
    done
}

# Интерактивный выбор файла. Путь — в stdout, меню — в stderr.
pick_exit_config() {
    local kind="$1" ext="conf" choice i=1 f
    [ "$kind" = "openvpn" ] && ext="ovpn"
    local -a files
    mapfile -t files < <(scan_exit_configs "$kind")
    if [ ${#files[@]} -gt 0 ]; then
        echo -e "${CYAN}Найдены конфиги:${NC}" >&2
        for f in "${files[@]}"; do
            echo -e " ${GREEN}${i}.${NC} $f" >&2
            ((i++))
        done
    else
        echo -e "${YELLOW}В /root и $SLAVE_DIR нет .$ext конфигов.${NC}" >&2
    fi
    read -r -e -p "Номер или путь к .$ext (Enter — отмена): " choice
    [ -z "$choice" ] && return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
        echo "${files[$((choice-1))]}"
    elif [ -f "$choice" ]; then
        realpath "$choice"
    else
        echo -e "${RED}Файл не найден: $choice${NC}" >&2
        return 1
    fi
}

exit_menu() {
    load_config
    echo -e "\n${CYAN}Текущий выход: ${YELLOW}$(exit_label)${NC}"
    echo -e " ${GREEN}1.${NC} Direct — IP этого сервера"
    echo -e " ${GREEN}2.${NC} WARP — Cloudflare"
    echo -e " ${GREEN}3.${NC} WireGuard — .conf (ProtonVPN и др.)"
    echo -e " ${GREEN}4.${NC} OpenVPN — .ovpn"
    echo -e " ${GREEN}5.${NC} VLESS — ссылка vless://"
    echo -e " ${GREEN}6.${NC} Hysteria2 — ссылка hy2://"
    echo -e " ${GREEN}7.${NC} Shadowsocks — ссылка ss://"
    echo -e " ${CYAN}0.${NC} Отмена"
    local c f link user="" pass=""
    read -r -p "Выбор: " c
    case "${c:-}" in
        1) set_exit direct ;;
        2) set_exit warp ;;
        3) f=$(pick_exit_config wg) && set_exit wg "$f" ;;
        4)
            f=$(pick_exit_config openvpn) || return 1
            if ovpn_needs_auth "$f"; then
                local saved
                saved=$(_exit_saved_auth "$f" username)
                read -r -p "Логин OpenVPN${saved:+ [$saved]}: " user
                if [ -z "$user" ] && [ -n "$saved" ]; then
                    user="$saved"
                    pass=$(_exit_saved_auth "$f" password)
                else
                    read -r -s -p "Пароль OpenVPN: " pass; echo
                fi
            fi
            set_exit openvpn "$f" "$user" "$pass"
            ;;
        5|6|7)
            local -A kinds=([5]=vless [6]=hy2 [7]=ss)
            read -r -p "Ссылка: " link
            [ -z "$link" ] && { echo -e "${YELLOW}Отмена.${NC}"; return 0; }
            set_exit "${kinds[$c]}" "$link"
            ;;
        *) echo -e "${YELLOW}Отмена.${NC}" ;;
    esac
}

# Локальный вход SOCKS5/HTTP на 127.0.0.1 — для программ на этом же
# сервере (Xray и т.п.). Трафик уходит в тот же выход, что и от master.
#   local_cmd [on [ПОРТ] | off]
local_cmd() {
    load_config
    local action="${1:-}" port="${2:-1080}" snap
    case "$action" in
        "")
            if [ -n "$LOCAL_PORT" ]; then
                echo "socks5://127.0.0.1:$LOCAL_PORT (HTTP-прокси на том же порту)"
            else
                echo "off"
            fi
            ;;
        on)
            if ! validate_port "$port" || [ "$port" = "$SLAVE_PORT" ]; then
                echo -e "${RED}Некорректный порт: $port${NC}" >&2; return 1
            fi
            if [ "$port" != "$LOCAL_PORT" ] && ! check_port_available "$port"; then
                echo -e "${RED}Порт $port уже занят!${NC}" >&2; return 1
            fi
            snap=$(snapshot_slave_conf)
            LOCAL_PORT="$port"
            apply_slave_config "$snap" || { rm -f "$snap"; return 1; }
            rm -f "$snap"
            echo -e "${GREEN}Локальный вход: socks5/http://127.0.0.1:$port → $(exit_label)${NC}"
            echo -e "${CYAN}Xray outbound: {\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":$port}]}}${NC}"
            ;;
        off)
            [ -z "$LOCAL_PORT" ] && { echo "Локальный вход уже выключен."; return 0; }
            snap=$(snapshot_slave_conf)
            LOCAL_PORT=""
            apply_slave_config "$snap" || { rm -f "$snap"; return 1; }
            rm -f "$snap"
            echo -e "${GREEN}Локальный вход выключен.${NC}"
            ;;
        *) echo "Usage: warperslave local [on [ПОРТ] | off]" >&2; return 1 ;;
    esac
}

local_menu() {
    load_config
    echo -e "\n${CYAN}Локальный вход: ${YELLOW}$(local_cmd)${NC}"
    echo -e " ${GREEN}1.${NC} Включить / сменить порт"
    echo -e " ${GREEN}2.${NC} Выключить"
    echo -e " ${CYAN}0.${NC} Отмена"
    local c port
    read -r -p "Выбор: " c
    case "${c:-}" in
        1)
            read -r -p "Порт [${LOCAL_PORT:-1080}]: " port
            local_cmd on "${port:-${LOCAL_PORT:-1080}}"
            ;;
        2) local_cmd off ;;
        *) echo -e "${YELLOW}Отмена.${NC}" ;;
    esac
}

# ===== Ссылка для master =====

# Внешний адрес донора: SLAVE_HOST из slave.conf, публичный IP интерфейса,
# а за NAT — адрес, который видят внешние сервисы.
slave_public_host() {
    if [ -n "$SLAVE_HOST" ]; then
        echo "$SLAVE_HOST"
        return 0
    fi
    get_local_public_ipv4 && return 0
    local ip url
    for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    hostname -I 2>/dev/null | awk '{print $1}'
}

_uri() {
    jq -rn --arg v "$1" '$v | @uri'
}

# Share-ссылка для подключения master: warper mode … '<ссылка>'.
slave_link() {
    local host
    host=$(slave_public_host)
    case "$SLAVE_PROTO" in
        ss)
            local userinfo
            userinfo=$(printf '2022-blake3-aes-128-gcm:%s' "$SS_PASSWORD" \
                | base64 -w0 | tr '+/' '-_' | tr -d '=')
            echo "ss://${userinfo}@${host}:${SLAVE_PORT}#warperslave"
            ;;
        vless)
            echo "vless://${VLESS_UUID}@${host}:${SLAVE_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(_uri "$SLAVE_SNI")&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#warperslave"
            ;;
        hy2)
            # pinSHA256 — отпечаток сертификата для сторонних клиентов,
            # spki — хэш публичного ключа для sing-box на master
            local cert_hex spki
            cert_hex=$(openssl x509 -in "$HY2_CERT" -noout -fingerprint -sha256 2>/dev/null \
                | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
            spki=$(openssl x509 -in "$HY2_CERT" -pubkey -noout 2>/dev/null \
                | openssl pkey -pubin -outform der 2>/dev/null \
                | openssl dgst -sha256 -binary | base64)
            echo "hy2://$(_uri "$HY2_PASSWORD")@${host}:${SLAVE_PORT}?sni=$(_uri "$SLAVE_SNI")&obfs=salamander&obfs-password=$(_uri "$HY2_OBFS_PASSWORD")&insecure=1&pinSHA256=${cert_hex}&spki=$(_uri "$spki")#warperslave"
            ;;
    esac
}

# Команда, которую нужно выполнить на master.
slave_master_command() {
    local mode
    case "$SLAVE_PROTO" in
        ss)    mode=slave ;;
        vless) mode=vless ;;
        hy2)   mode=hy2 ;;
    esac
    echo "warper mode $mode '$(slave_link)'"
}

proto_label() {
    case "$SLAVE_PROTO" in
        ss)    echo "Shadowsocks" ;;
        vless) echo "VLESS+Reality" ;;
        hy2)   echo "Hysteria2" ;;
        *)     echo "$SLAVE_PROTO" ;;
    esac
}

is_public_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
    (( o1 == 10 )) && return 1
    (( o1 == 127 )) && return 1
    (( o1 == 169 && o2 == 254 )) && return 1
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 1
    (( o1 == 192 && o2 == 168 )) && return 1
    (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 1
    (( o1 == 198 && (o2 == 18 || o2 == 19) )) && return 1
    (( o1 >= 224 )) && return 1
    return 0
}

get_local_public_ipv4() {
    local ip candidate

    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
        for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }
    }')
    if [ -n "$ip" ] && is_public_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    while IFS= read -r candidate; do
        if is_public_ipv4 "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)

    return 1
}

# Системный WARP-конфиг AntiZapret. Актуальные версии поднимают
# warp-vpn/warp-antizapret, старые — единый warp. Порядок = приоритет.
WARP_SYSTEM_CANDIDATES="/etc/wireguard/warp-vpn.conf /etc/wireguard/warp-antizapret.conf /etc/wireguard/warp.conf"
CF_WARP_PUBKEY='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='

# Печатает первый существующий системный WARP-конфиг Cloudflare.
resolve_warp_system_conf() {
    local candidate
    for candidate in $WARP_SYSTEM_CANDIDATES; do
        if [ -f "$candidate" ] && grep -q "$CF_WARP_PUBKEY" "$candidate" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

find_warp_keys() {
    local address="" private_key="" sys_conf=""

    # Приоритет 1: системный конфиг AntiZapret
    if sys_conf=$(resolve_warp_system_conf); then
        private_key=$(grep -m 1 '^PrivateKey' "$sys_conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        address=$(grep -m 1 '^Address' "$sys_conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$private_key" ]; then
            [ -z "$address" ] && address="172.16.0.2/32"
            [[ ! "$address" =~ / ]] && address="${address}/32"
            echo "$address"
            echo "$private_key"
            echo "$sys_conf"
            return 0
        fi
    fi

    # Приоритет 2: Локальный wgcf-profile
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
            address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            if [ -n "$private_key" ] && [ -n "$address" ]; then
                echo "$address"
                echo "$private_key"
                echo "$WGCF_DIR/wgcf-profile.conf"
                return 0
            fi
        fi
    fi

    # Приоритет 3: /root/wgcf-profile.conf
    if [ -f "/root/wgcf-profile.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
            address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
            if [ -n "$private_key" ] && [ -n "$address" ]; then
                echo "$address"
                echo "$private_key"
                echo "/root/wgcf-profile.conf"
                return 0
            fi
        fi
    fi

    return 1
}

get_warp_source() {
    local sys_conf=""
    if sys_conf=$(resolve_warp_system_conf); then
        local pk
        pk=$(grep -m 1 '^PrivateKey' "$sys_conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$pk" ]; then
            echo "$sys_conf"
            return 0
        fi
    fi
    if [ -f "$SLAVE_DIR/wgcf/wgcf-profile.conf" ]; then
        local pk
        pk=$(grep -m 1 '^PrivateKey = ' "$SLAVE_DIR/wgcf/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$pk" ]; then
            echo "$SLAVE_DIR/wgcf/wgcf-profile.conf"
            return 0
        fi
    fi
    if [ -f "/root/wgcf-profile.conf" ]; then
        local pk
        pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$pk" ]; then
            echo "/root/wgcf-profile.conf"
            return 0
        fi
    fi
    echo "не найдены"
    return 1
}

version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        local fetched
        fetched=$(curl -4 -sf --max-time 3 "$REPO_URL/versionslave" | tr -d '\r\n')
        if [[ "$fetched" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            REMOTE_VER_CACHE="$fetched"
        else
            REMOTE_VER_CACHE="$LOCAL_VER"
        fi
        REMOTE_VER_TIME=$now
    fi
    echo "$REMOTE_VER_CACHE"
}

download_file_safe() {
    local url="$1" dest="$2" desc="$3"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" "${url}?t=$(date +%s)"; then
        echo -e "${RED}Ошибка загрузки: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

syntax_check_bash_file() {
    local file="$1"
    local desc="$2"
    if ! bash -n "$file"; then
        echo -e "${RED}Ошибка синтаксиса в ${desc}${NC}"
        return 1
    fi
    return 0
}

validate_template_marker() {
    local file="$1"
    local marker="$2"
    local desc="$3"
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
        echo -e "${RED}Файл ${desc} повреждён или неполон.${NC}"
        return 1
    fi
    return 0
}

slave_backup_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

slave_restore_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

rollback_warperslave_update() {
    local backupdir="$1"

    slave_restore_if_exists "$backupdir/warperslave.sh" "$SLAVE_DIR/warperslave.sh"
    slave_restore_if_exists "$backupdir/uninstall-slave.sh" "$SLAVE_DIR/uninstall-slave.sh"
    slave_restore_if_exists "$backupdir/versionslave" "$SLAVE_DIR/versionslave"
    slave_restore_if_exists "$backupdir/outbound-parse.py" "$EXIT_PARSER"

    slave_restore_if_exists "$backupdir/sing-box-slave.service" "/etc/systemd/system/${SERVICE_NAME}.service"

    chmod +x "$SLAVE_DIR/warperslave.sh" "$SLAVE_DIR/uninstall-slave.sh" 2>/dev/null || true
    ln -sf "$SLAVE_DIR/warperslave.sh" /usr/local/bin/warperslave
    systemctl daemon-reload >/dev/null 2>&1 || true
}

update_warperslave() {
    load_config
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"

    local tmpdir backupdir
    local had_service=false

    tmpdir=$(mktemp -d /tmp/warperslave-update.XXXXXX) || {
        echo -e "${RED}Не удалось создать временную директорию.${NC}"
        return 1
    }

    backupdir=$(mktemp -d /tmp/warperslave-backup.XXXXXX) || {
        rm -rf "$tmpdir"
        echo -e "${RED}Не удалось создать директорию для backup.${NC}"
        return 1
    }

    # ===== Скачиваем всё во временную директорию =====
    download_file_safe "$REPO_URL/warperslave.sh" "$tmpdir/warperslave.sh" "warperslave.sh" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    download_file_safe "$REPO_URL/uninstall-slave.sh" "$tmpdir/uninstall-slave.sh" "uninstall-slave.sh" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    download_file_safe "$REPO_URL/versionslave" "$tmpdir/versionslave" "versionslave" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    download_file_safe "$REPO_URL/templates/sing-box-slave.service" "$tmpdir/sing-box-slave.service" "sing-box-slave.service" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    download_file_safe "$REPO_URL/lib/outbound-parse.py" "$tmpdir/outbound-parse.py" "outbound-parse.py" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    # ===== Проверяем синтаксис bash-скриптов =====
    syntax_check_bash_file "$tmpdir/warperslave.sh" "warperslave.sh" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    syntax_check_bash_file "$tmpdir/uninstall-slave.sh" "uninstall-slave.sh" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }


    # Проверяем unit-файл, если есть systemd-analyze
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$tmpdir/sing-box-slave.service" >/dev/null 2>&1 || {
            echo -e "${RED}Некорректный unit-файл sing-box-slave.service${NC}"
            rm -rf "$tmpdir" "$backupdir"
            return 1
        }
    fi

    # ===== Backup текущих файлов =====
    slave_backup_if_exists "$SLAVE_DIR/warperslave.sh" "$backupdir/warperslave.sh"
    slave_backup_if_exists "$SLAVE_DIR/uninstall-slave.sh" "$backupdir/uninstall-slave.sh"
    slave_backup_if_exists "$SLAVE_DIR/versionslave" "$backupdir/versionslave"
    slave_backup_if_exists "$EXIT_PARSER" "$backupdir/outbound-parse.py"

    slave_backup_if_exists "/etc/systemd/system/${SERVICE_NAME}.service" "$backupdir/sing-box-slave.service"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        had_service=true
    fi

    # ===== Устанавливаем новые файлы =====
    install -m 755 "$tmpdir/warperslave.sh" "$SLAVE_DIR/warperslave.sh" || {
        echo -e "${RED}Ошибка установки warperslave.sh, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 755 "$tmpdir/uninstall-slave.sh" "$SLAVE_DIR/uninstall-slave.sh" || {
        echo -e "${RED}Ошибка установки uninstall-slave.sh, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/versionslave" "$SLAVE_DIR/versionslave" || {
        echo -e "${RED}Ошибка установки versionslave, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 755 "$tmpdir/outbound-parse.py" "$EXIT_PARSER" || {
        echo -e "${RED}Ошибка установки outbound-parse.py, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/sing-box-slave.service" "/etc/systemd/system/${SERVICE_NAME}.service" || {
        echo -e "${RED}Ошибка установки sing-box-slave.service, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }


    chmod +x "$SLAVE_DIR/warperslave.sh" "$SLAVE_DIR/uninstall-slave.sh"
    ln -sf "$SLAVE_DIR/warperslave.sh" /usr/local/bin/warperslave

    if ! systemctl daemon-reload; then
        echo -e "${RED}Ошибка systemctl daemon-reload, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    fi

    # sing-box обновляется до версии из нового warperslave.sh
    local new_sb
    new_sb=$(grep -m1 '^SB_VERSION=' "$tmpdir/warperslave.sh" | cut -d'"' -f2)
    if [[ "$new_sb" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! singbox_at_least "$new_sb"; then
        echo -e "${CYAN}Обновление sing-box до $new_sb...${NC}"
        singbox_cmd upgrade "$new_sb" || echo -e "${YELLOW}sing-box не обновлён. Позже: warperslave singbox upgrade${NC}"
    fi

    # ===== Если служба была активна — проверяем, что она поднимется после обновления =====
    if [ "$had_service" = true ]; then
        echo -e "${CYAN}Перезапуск $SERVICE_NAME...${NC}"
        systemctl restart "$SERVICE_NAME"
        sleep 2

        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "${RED}Служба не запустилась после обновления, выполняется откат.${NC}"
            rollback_warperslave_update "$backupdir"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
            rm -rf "$tmpdir" "$backupdir"
            return 1
        fi

        echo -e "${GREEN}Служба перезапущена.${NC}"
    fi

    rm -rf "$tmpdir" "$backupdir"

    local new_ver
    new_ver=$(cat "$SLAVE_DIR/versionslave" 2>/dev/null | tr -d '\r\n' || echo "?")
    echo -e "${GREEN}Обновление завершено! Версия: ${new_ver}${NC}"
    read -r -e -p "Нажмите Enter для перезапуска warperslave..."
    exec /usr/local/bin/warperslave
}

status_cmd() {
    load_config
    local sb_run sb_en
    if systemctl is-active --quiet "$SERVICE_NAME"; then sb_run="running"; else sb_run="stopped"; fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then sb_en="enabled"; else sb_en="disabled"; fi
    local ext_ip
    ext_ip=$(get_local_public_ipv4 || echo "n/a")

    echo "=== WARPERSLAVE STATUS ==="
    echo "Version:     $LOCAL_VER"
    echo "Exit:        $(exit_label)"
    echo "Protocol:    $(proto_label)"
    echo "Port:        $SLAVE_PORT"
    [ "$SLAVE_PROTO" != "ss" ] && echo "SNI:         $SLAVE_SNI"
    echo "Service:     $sb_run"
    echo "Autostart:   $sb_en"
    [ "$SLAVE_PROTO" = "ss" ] && echo "SS key:      ${SS_PASSWORD:0:8}..."
    echo "Public IPv4: $ext_ip"
    echo "Local in:    $(local_cmd)"
    echo "Log level:   $(get_log_level)"
    local mtu_val
    mtu_val=$(get_mtu)
    [ -n "$mtu_val" ] && echo "MTU:         $mtu_val"
    if [ "$SLAVE_MODE" = "warp" ]; then
        echo "WARP keys:   $(get_warp_source)"
    fi
}

# Переключает выход донора: direct → warp, любой другой → direct.
switch_mode() {
    load_config
    if [ "$SLAVE_MODE" = "direct" ]; then
        echo -e " - ${GREEN}Источник WARP-ключей: $(get_warp_source)${NC}"
        set_exit warp
    else
        set_exit direct
    fi
}

change_port() {
    load_config
    local old_port="$SLAVE_PORT" new_port="${1:-}"

    if [ -z "$new_port" ]; then
        echo -e "${CYAN}Текущий порт: $old_port${NC}"
        read -r -p "Новый порт (или Enter для отмены): " new_port
        [ -z "$new_port" ] && { echo -e "${YELLOW}Отмена.${NC}"; return 0; }
    fi

    if ! validate_port "$new_port"; then
        echo -e "${RED}Некорректный порт! Допустимо: 1-65535.${NC}"
        return 1
    fi
    if [ "$new_port" = "$old_port" ]; then
        echo -e "${YELLOW}Порт не изменился.${NC}"
        return 0
    fi
    if ! check_port_available "$new_port"; then
        echo -e "${RED}Порт $new_port уже занят!${NC}"
        return 1
    fi

    local snap
    snap=$(snapshot_slave_conf)
    SLAVE_PORT="$new_port"
    ensure_port_open "$new_port"
    if ! apply_slave_config "$snap"; then
        rm -f "$snap"
        remove_port_rules "$new_port" 2>/dev/null || true
        return 1
    fi
    rm -f "$snap"
    remove_port_rules "$old_port" 2>/dev/null || true
    echo -e "${GREEN}Порт изменён: $old_port → $new_port${NC}"
    echo -e "${YELLOW}Обновите подключение на master:${NC}"
    echo -e "  ${CYAN}$(slave_master_command)${NC}"
}

# Перевыпускает учётные данные текущего протокола.
change_key() {
    load_config
    local manual_key="${1:-}"
    echo -e "${CYAN}Протокол: $(proto_label)${NC}"

    if [ -z "$manual_key" ] && is_interactive_slave; then
        echo -e " ${GREEN}1.${NC} Сгенерировать новые учётные данные"
        [ "$SLAVE_PROTO" = "ss" ] && echo -e " ${GREEN}2.${NC} Ввести ключ Shadowsocks вручную"
        echo -e " ${CYAN}0.${NC} Отмена"
        local key_action
        read -r -p "Выбор: " key_action
        case "${key_action:-}" in
            1) ;;
            2)
                [ "$SLAVE_PROTO" = "ss" ] || { echo -e "${RED}Неверный выбор.${NC}"; return 1; }
                read -r -p "Введите ключ: " manual_key
                [ -z "$manual_key" ] && { echo -e "${YELLOW}Отмена.${NC}"; return 0; }
                ;;
            *) echo -e "${YELLOW}Отмена.${NC}"; return 0 ;;
        esac
    fi

    local snap
    snap=$(snapshot_slave_conf)
    case "$SLAVE_PROTO" in
        ss)    SS_PASSWORD="$manual_key" ;;
        vless) VLESS_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID="" ;;
        hy2)   HY2_PASSWORD=""; HY2_OBFS_PASSWORD=""; rm -f "$HY2_CERT" "$HY2_KEY" ;;
    esac

    if ! apply_slave_config "$snap"; then
        rm -f "$snap"
        return 1
    fi
    rm -f "$snap"
    echo -e "${GREEN}Учётные данные обновлены.${NC}"
    echo -e "${YELLOW}Старая ссылка больше не работает. Выполните на master:${NC}"
    echo -e "  ${CYAN}$(slave_master_command)${NC}"
}

# Меняет протокол входа донора. SNI нужен VLESS+Reality (маскировка)
# и Hysteria2 (имя в сертификате).
#   change_proto ss|vless|hy2 [SNI]
change_proto() {
    load_config
    local new_proto="${1:-}" new_sni="${2:-}"

    if [ -z "$new_proto" ]; then
        echo -e "${CYAN}Текущий протокол: $(proto_label)${NC}"
        echo -e " ${GREEN}1.${NC} Shadowsocks"
        echo -e " ${GREEN}2.${NC} VLESS+Reality — рекомендуется, устойчив к DPI"
        echo -e " ${GREEN}3.${NC} Hysteria2 — QUIC, хорош на плохих каналах"
        echo -e " ${CYAN}0.${NC} Отмена"
        local c
        read -r -p "Выбор: " c
        case "${c:-}" in
            1) new_proto=ss ;;
            2) new_proto=vless ;;
            3) new_proto=hy2 ;;
            *) echo -e "${YELLOW}Отмена.${NC}"; return 0 ;;
        esac
        if [ "$new_proto" != "ss" ]; then
            read -r -p "SNI [${SLAVE_SNI}]: " new_sni
        fi
    fi

    case "$new_proto" in
        ss|vless|hy2) ;;
        *) echo -e "${RED}Протокол: ss | vless | hy2${NC}"; return 1 ;;
    esac

    local snap
    snap=$(snapshot_slave_conf)
    if [ -n "$new_sni" ] && [ "$new_sni" != "$SLAVE_SNI" ]; then
        SLAVE_SNI="$new_sni"
        # Сертификат Hysteria2 выпускается на SNI
        rm -f "$HY2_CERT" "$HY2_KEY"
    fi
    if [ "$new_proto" = "vless" ] && ! check_reality_sni "$SLAVE_SNI"; then
        echo -e "${RED}$SLAVE_SNI не отвечает по TLS 1.3 — для Reality нужен такой сайт.${NC}"
        rm -f "$snap"
        return 1
    fi
    SLAVE_PROTO="$new_proto"

    if ! apply_slave_config "$snap"; then
        rm -f "$snap"
        return 1
    fi
    rm -f "$snap"
    echo -e "${GREEN}Протокол: $(proto_label)${NC}"
    echo -e "${YELLOW}Выполните на master:${NC}"
    echo -e "  ${CYAN}$(slave_master_command)${NC}"
}

is_interactive_slave() {
    [ -t 0 ] && [ -t 1 ]
}

uninstall_cmd() {
    if [ -f "$SLAVE_DIR/uninstall-slave.sh" ]; then
        exec bash "$SLAVE_DIR/uninstall-slave.sh"
    else
        exec bash -c "curl -fsSL '$REPO_URL/uninstall-slave.sh?t=$(date +%s)' | bash"
    fi
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Логи $SERVICE_NAME...${NC}"
    echo -e "${GREEN}Ctrl+C для выхода${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u "$SERVICE_NAME" -n 30 -f
    trap - SIGINT
}

doctor_cmd() {
    load_config
    echo -e "${CYAN}==========================================${NC}"
    echo -e "      🩺 ${YELLOW}WARPERSLAVE DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"
    local failed=0

    check_item() {
        local label="$1" cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }

    echo -e " ${CYAN}!${NC} Версия: $LOCAL_VER"
    echo -e " ${CYAN}!${NC} Протокол: $(proto_label), выход: $(exit_label)"
    echo -e " ${CYAN}!${NC} Log level: $(get_log_level)"
    local doc_mtu
    doc_mtu=$(get_mtu)
    [ -n "$doc_mtu" ] && echo -e " ${CYAN}!${NC} MTU: $doc_mtu"

    if ! singbox_at_least "$SB_VERSION"; then
        echo -e " ${YELLOW}!${NC} sing-box $(get_singbox_version || echo '?') старее $SB_VERSION — выход OpenVPN недоступен. Обновить: warperslave singbox upgrade"
    fi
    check_item "Конфигурация slave существует" "[ -f '$SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave существует" "[ -f '$SINGBOX_SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave валиден" "validate_singbox_config"
    check_item "Служба $SERVICE_NAME активна" "systemctl is-active --quiet '$SERVICE_NAME'"
    check_item "Автозагрузка $SERVICE_NAME включена" "systemctl is-enabled --quiet '$SERVICE_NAME'"
    local listen_flags="-tln" listen_proto="TCP"
    [ "$SLAVE_PROTO" = "hy2" ] && { listen_flags="-uln"; listen_proto="UDP"; }
    local listening
    listening=$(ss $listen_flags 2>/dev/null || true)
    if grep -q ":${SLAVE_PORT} " <<< "$listening"; then
        echo -e " ${GREEN}✔${NC} Порт $SLAVE_PORT/$listen_proto слушается"
    else
        echo -e " ${RED}✘${NC} Порт $SLAVE_PORT/$listen_proto не слушается"
        failed=1
    fi
    case "$SLAVE_PROTO" in
        vless)
            if check_reality_sni "$SLAVE_SNI"; then
                echo -e " ${GREEN}✔${NC} SNI $SLAVE_SNI отвечает по TLS 1.3"
            else
                echo -e " ${RED}✘${NC} SNI $SLAVE_SNI не отвечает по TLS 1.3 — Reality не замаскируется"
                failed=1
            fi
            ;;
        hy2)
            check_item "Сертификат Hysteria2" "[ -s '$HY2_CERT' ] && [ -s '$HY2_KEY' ]"
            ;;
    esac
    check_item "Права $SLAVE_CONF (600)" "[ \"\$(stat -c %a '$SLAVE_CONF' 2>/dev/null)\" = '600' ]"
    check_item "Права $SINGBOX_SLAVE_CONF (600)" "[ \"\$(stat -c %a '$SINGBOX_SLAVE_CONF' 2>/dev/null)\" = '600' ]"

    if [ "$SLAVE_MODE" = "warp" ]; then
        local has_warp=false
        if find_warp_keys >/dev/null 2>&1; then has_warp=true; fi
        if [ "$has_warp" = true ]; then
            echo -e " ${GREEN}✔${NC} WARP-ключи доступны ($(get_warp_source))"
        else
            echo -e " ${RED}✘${NC} WARP-ключи не найдены (режим: warp)"
            failed=1
        fi
    fi

    case "$SLAVE_MODE" in
        wg|openvpn|vless|hy2|ss)
            check_item "Параметры выхода ($EXIT_JSON)" \
                "[ \"\$(jq -r .protocol '$EXIT_JSON' 2>/dev/null)\" = '$SLAVE_MODE' ]"
            ;;
    esac

    if [ -n "$LOCAL_PORT" ]; then
        local trace
        if grep -q "127.0.0.1:${LOCAL_PORT} " <<< "$(ss -tln 2>/dev/null)"; then
            echo -e " ${GREEN}✔${NC} Локальный вход 127.0.0.1:$LOCAL_PORT слушается"
            trace=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$LOCAL_PORT" \
                https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
            if grep -q '^ip=' <<< "$trace"; then
                echo -e " ${GREEN}✔${NC} Выход работает: IP $(sed -n 's/^ip=//p' <<< "$trace"), warp=$(sed -n 's/^warp=//p' <<< "$trace")"
            else
                echo -e " ${RED}✘${NC} Через выход $(exit_label) нет доступа в интернет"
                failed=1
            fi
        else
            echo -e " ${RED}✘${NC} Локальный вход 127.0.0.1:$LOCAL_PORT не слушается"
            failed=1
        fi
    fi

    local pub_ip
    pub_ip=$(get_local_public_ipv4 || echo "")
    if [ -n "$pub_ip" ]; then
        echo -e " ${GREEN}✔${NC} Публичный IPv4: $pub_ip"
    else
        echo -e " ${YELLOW}!${NC} Публичный IPv4 не обнаружен локально"
    fi

    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Проблем не обнаружено.${NC}"
    else
        echo -e "${YELLOW}Обнаружены проблемы.${NC}"
    fi
}

MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

show_menu() {
    load_config
    clear
    local sb_status mode_display pub_ip
    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        sb_status="${GREEN}🟢 запущен${NC}"
    else
        sb_status="${RED}🔴 остановлен${NC}"
    fi
    mode_display="${CYAN}$(exit_label)${NC}"
    pub_ip=$(get_local_public_ipv4 || echo "n/a")

    local VER_STR
    MENU_UPDATE_AVAILABLE=false
    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER${NC} (📦 Доступно: ${GREEN}$REMOTE_VER${NC})"
        MENU_UPDATE_AVAILABLE=true
        MENU_REMOTE_VER="$REMOTE_VER"
    else
        VER_STR="${GREEN}$LOCAL_VER${NC} (✅ актуальная)"
    fi

    echo -e "${CYAN}================================================${NC}"
    echo -e "    🔧 ${YELLOW}WARPERSLAVE — Панель управления${NC} 🔧"
    echo -e "${CYAN}================================================${NC}"
    echo -e ""
    echo -e " 📌 ${CYAN}Версия:${NC}   $VER_STR"
    echo -e " 📡 ${CYAN}Статус:${NC}   $sb_status"
    echo -e " 🔀 ${CYAN}Выход:${NC}    $mode_display"
    echo -e " 🔌 ${CYAN}Порт:${NC}     ${YELLOW}${SLAVE_PORT}${NC}"
    echo -e " 🔐 ${CYAN}Протокол:${NC} ${YELLOW}$(proto_label)${NC}"
    local log_level mtu_display
    log_level=$(get_log_level)
    mtu_display=$(get_mtu)
    [ -z "$mtu_display" ] && mtu_display="n/a"
    echo -e " 🌐 ${CYAN}IP:${NC}       ${YELLOW}${pub_ip}${NC}"
    echo -e " ⚙️  ${CYAN}Log:${NC}      ${YELLOW}${log_level}${NC} | MTU: ${YELLOW}${mtu_display}${NC}"
    [ -n "$LOCAL_PORT" ] && echo -e " 🏠 ${CYAN}Локально:${NC} ${YELLOW}127.0.0.1:${LOCAL_PORT}${NC} (SOCKS5/HTTP)"
    if [ "$SLAVE_MODE" = "warp" ]; then
        local warp_src
        warp_src=$(get_warp_source)
        echo -e " 🔑 ${CYAN}WARP:${NC}     ${YELLOW}${warp_src}${NC}"
    fi
    echo -e ""
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} 🔀 Выход трафика (Direct, WARP, WireGuard, OpenVPN, прокси)"
    echo -e " ${CYAN}2.${NC} 🔌 Изменить порт"
    echo -e " ${CYAN}P.${NC} 🔐 Протокол подключения (сейчас: $(proto_label))"
    echo -e " ${CYAN}3.${NC} 🔑 Перевыпустить ключи"
    echo -e " ${CYAN}4.${NC} 🔗 Ссылка для master"
    echo -e " ${CYAN}L.${NC} 🏠 Локальный вход для программ на этом сервере"
    echo -e " ${CYAN}5.${NC} 🔄 Перезапустить службу"
    echo -e " ${CYAN}6.${NC} 📄 Показать логи"
    echo -e " ${CYAN}7.${NC} ⚙️  Изменить log level"
    if [ -n "$(get_mtu)" ]; then
    echo -e " ${CYAN}8.${NC} ⚙️  Изменить MTU"
    fi
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика"
    echo -e " ${CYAN}S.${NC} 📊 Статус"
    echo -e "${CYAN}------------------------------------------------${NC}"
    if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}9.${NC} ⚡ Обновить до ${GREEN}$MENU_REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}9.${NC} 🔄 Проверить обновления"
    fi
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${RED}U.${NC} 🗑️  Удалить warperslave"
    echo -e " ${CYAN}0.${NC} 🚪 Выход"
    echo -e "${CYAN}================================================${NC}"
}

# Одноразовая миграция установок до 1.1.0: в slave.conf нет SLAVE_PROTO,
# а конфиг собран старыми heredoc'ами (tag ss-in, устаревший
# independent_cache). Старый update_warperslave исполняется кодом прежней
# версии и пересобрать не может — делаем это при первом запуске новой.
migrate_legacy_config() {
    [ -f "$SLAVE_CONF" ] || return 0
    grep -q '^SLAVE_PROTO=' "$SLAVE_CONF" 2>/dev/null && return 0
    case "${1:-}" in help|--help|-h|version|--version|-v|uninstall) return 0 ;; esac

    load_config
    local snap
    snap=$(snapshot_slave_conf)
    if apply_slave_config "$snap"; then
        echo -e "${CYAN}Конфиг донора пересобран в формате 1.1.0.${NC}" >&2
    else
        echo -e "${YELLOW}Не удалось пересобрать конфиг донора, оставлен прежний.${NC}" >&2
    fi
    rm -f "$snap"
}
migrate_legacy_config "${1:-}"

case "${1:-}" in
    status) load_config; status_cmd; exit $? ;;
    switch) switch_mode; exit $? ;;
    exit)
        if [ -z "${2:-}" ]; then load_config; exit_label; exit 0; fi
        [ "$2" = "select" ] && { exit_menu; exit $?; }
        set_exit "${2}" "${3:-}" "${4:-}" "${5:-}"; exit $?
        ;;
    local) local_cmd "${2:-}" "${3:-}"; exit $? ;;
    port) change_port "${2:-}"; exit $? ;;
    key) change_key "${2:-}"; exit $? ;;
    proto) change_proto "${2:-}" "${3:-}"; exit $? ;;
    link)
        load_config
        [ "${2:-}" = "--command" ] && { slave_master_command; exit 0; }
        echo "$(proto_label): $(slave_link)"
        echo ""
        echo "На master:"
        echo "  $(slave_master_command)"
        exit 0
        ;;
    rebuild)
        load_config
        _snap=$(snapshot_slave_conf)
        apply_slave_config "$_snap"; _rc=$?
        rm -f "$_snap"
        [ $_rc -eq 0 ] && echo -e "${GREEN}Конфигурация пересобрана (${SLAVE_PROTO}, ${SLAVE_MODE}).${NC}"
        exit $_rc
        ;;
    host)
        load_config
        if [ -z "${2:-}" ]; then slave_public_host; exit 0; fi
        _snap=$(snapshot_slave_conf)
        SLAVE_HOST="$2"
        [ "$2" = "auto" ] && SLAVE_HOST=""
        save_config
        rm -f "$_snap"
        echo "Адрес в ссылке: $(slave_public_host)"
        exit 0
        ;;
    doctor) doctor_cmd; exit $? ;;
    update) update_warperslave; exit $? ;;
    uninstall) uninstall_cmd; exit $? ;;
    singbox) singbox_cmd "${2:-}" "${3:-}"; exit $? ;;
    restart)
        systemctl restart "$SERVICE_NAME" || { echo "ERROR: restart failed" >&2; exit 1; }
        sleep 2
        echo "$SERVICE_NAME: $(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
        exit 0
        ;;
    loglevel)
        load_config
        if [ -z "${2:-}" ]; then get_log_level; exit 0; fi
        set_log_level "$2"; exit $?
        ;;
    mtu)
        load_config
        if [ -z "${2:-}" ]; then
            _mtu=$(get_mtu)
            if [ -n "$_mtu" ]; then
                echo "$_mtu"
            else
                # MTU есть только у wireguard-endpoint
                echo "n/a (выход $SLAVE_MODE)"
            fi
            exit 0
        fi
        set_mtu "$2"; exit $?
        ;;
    showkey)
        load_config
        if [ -z "$SS_PASSWORD" ]; then
            echo "ERROR: SS key is not set" >&2; exit 1
        fi
        echo "$SS_PASSWORD"
        exit 0
        ;;
    logs)
        _lines="${2:-50}"
        [[ "$_lines" =~ ^[0-9]+$ ]] || _lines=50
        journalctl -u "$SERVICE_NAME" -n "$_lines" --no-pager
        exit 0
        ;;
    version|--version|-v) echo "$LOCAL_VER"; exit 0 ;;
    help|--help|-h)
        echo "Использование: warperslave [команда]"
        echo ""
        echo "Команды:"
        echo "  status     Показать статус"
        echo "  exit [ВЫХОД]  Показать или сменить выход трафика:"
        echo "             direct | warp | wg ФАЙЛ.conf | openvpn ФАЙЛ.ovpn [ЛОГИН ПАРОЛЬ]"
        echo "             vless|hy2|ss 'ССЫЛКА' | select (интерактивный выбор)"
        echo "  switch     Переключить выход: Direct → WARP, иначе → Direct"
        echo "  local [on [ПОРТ] | off]  SOCKS5/HTTP на 127.0.0.1 для программ на этом сервере"
        echo "  port [ПОРТ]  Изменить порт"
        echo "  key [КЛЮЧ]   Перевыпустить учётные данные текущего протокола"
        echo "  doctor     Диагностика"
        echo "  update     Обновить warperslave"
        echo "  uninstall  Удалить warperslave"
        echo "  singbox    version | upgrade [ВЕРСИЯ] — версия sing-box"
        echo "  restart    Перезапустить службу"
        echo "  loglevel [УРОВЕНЬ]  Показать или изменить log level"
        echo "  mtu [ЗНАЧЕНИЕ]      Показать или изменить MTU"
        echo "  showkey    Показать полный SS-ключ"
        echo "  proto ss|vless|hy2 [SNI]  Протокол подключения master к донору"
        echo "  link [--command]  Ссылка и команда для master (--command — только команда)"
        echo "  host [АДРЕС|auto]  Адрес донора в ссылке (домен или IP)"
        echo "  rebuild    Пересобрать конфиг из slave.conf"
        echo "  logs [N]   Логи службы"
        echo "  help       Показать эту справку"
        echo ""
        echo "Без аргументов — интерактивное меню."
        exit 0
        ;;
    "")
        : # без аргументов — ниже откроется интерактивное меню
        ;;
    *)
        echo "Неизвестная команда: $1" >&2
        echo "Список команд: warperslave help" >&2
        exit 1
        ;;
esac

if [ -t 0 ] && [ -t 1 ] && ! singbox_at_least "$SB_VERSION"; then
    offer_singbox_upgrade "Доступно обновление sing-box" || true
fi

while true; do
    show_menu
    read -r -e -p "Выбор: " choice
    choice=$(echo "${choice:-}" | tr -d ' ')
    case "$choice" in
        1) exit_menu; read -r -p "Нажмите Enter..." ;;
        l|L) local_menu; read -r -p "Нажмите Enter..." ;;
        2) change_port; read -r -p "Нажмите Enter..." ;;
        3) change_key; read -r -p "Нажмите Enter..." ;;
        4)
            load_config
            echo -e "\n${CYAN}$(proto_label):${NC} ${YELLOW}$(slave_link)${NC}"
            echo -e "\n${CYAN}На master выполните:${NC}"
            echo -e "  ${GREEN}$(slave_master_command)${NC}"
            read -r -p "Нажмите Enter..."
            ;;
        p|P) change_proto; read -r -p "Нажмите Enter..." ;;
        5)
            echo -e "${YELLOW}Перезапуск $SERVICE_NAME...${NC}"
            systemctl restart "$SERVICE_NAME"
            sleep 2
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                echo -e "${GREEN}Перезапущено.${NC}"
            else
                echo -e "${RED}Ошибка перезапуска!${NC}"
                journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null || true
            fi
            read -r -p "Нажмите Enter..."
            ;;
        6) show_logs ;;
        7)
            echo -e "\n${CYAN}Доступные уровни логирования:${NC}"
            echo -e " ${CYAN}1.${NC} debug"
            echo -e " ${CYAN}2.${NC} info"
            echo -e " ${CYAN}3.${NC} warn"
            echo -e " ${CYAN}4.${NC} error"
            echo -e " ${CYAN}0.${NC} Отмена"
            read -r -e -p "Выбор [0-4]: " log_choice
            case "${log_choice:-}" in
                1) set_log_level "debug"; sleep 2 ;;
                2) set_log_level "info"; sleep 2 ;;
                3) set_log_level "warn"; sleep 2 ;;
                4) set_log_level "error"; sleep 2 ;;
                0) ;;
                *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
            esac
            ;;
        8)
            load_config
            if [ -z "$(get_mtu)" ]; then
                echo -e "${YELLOW}MTU доступен только для выходов WARP, WireGuard и OpenVPN.${NC}"
                sleep 1
            else
                current_mtu=$(get_mtu)
                echo -e "\n${CYAN}Текущий MTU: ${current_mtu:-n/a}${NC}"
                echo -e "${YELLOW}Допустимые значения: 1280-1500${NC}"
                read -r -e -p "Введите новый MTU (или Enter для отмены): " new_mtu
                if [ -n "$new_mtu" ]; then
                    set_mtu "$new_mtu"
                    sleep 2
                fi
            fi
            ;;
        9)
            if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                update_warperslave
            else
                echo -e "\n${CYAN}Проверка обновлений...${NC}"
                REMOTE_VER_CACHE=""
                REMOTE_VER_TIME=0
                rv=$(get_remote_version)
                if version_gt "$rv" "$LOCAL_VER"; then
                    echo -e "${GREEN}Доступно обновление: $rv${NC}"
                    read -r -p "Обновить сейчас? (Y/n): " upd_choice
                    if [[ -z "$upd_choice" || "$upd_choice" =~ ^[Yy]$ ]]; then
                        update_warperslave
                    fi
                else
                    echo -e "${GREEN}Версия актуальна: $LOCAL_VER${NC}"
                    sleep 2
                fi
            fi
            ;;            
        d|D) doctor_cmd; read -r -p "Нажмите Enter..." ;;
        s|S) status_cmd; read -r -p "Нажмите Enter..." ;;
        u|U) uninstall_cmd ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
