#!/bin/bash
# warper lib: config.sh
# Загрузка, сохранение и разбор конфигурационных файлов WARPER.
# Подключается через source из warper.sh

# ===== Основная конфигурация =====

# Загружает warper.conf: подсеть, TUN IP, режим IP-маршрутов,
# флаг экспорта в AntiZapret
load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        return 0
    fi
    local value

    value=$(grep -E '^SUBNET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ] && validate_subnet "$value"; then
        SUBNET="$value"
    fi

    value=$(grep -E '^TUN_IP=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        TUN_IP="$value"
    else
        TUN_IP=$(calculate_tun_ip "$SUBNET")
    fi

    value=$(grep -E '^IP_ROUTE_MODE=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        IP_ROUTE_MODE="$value"
    fi

    value=$(grep -E '^IP_EXPORT_TO_ANTIZAPRET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        IP_EXPORT_TO_ANTIZAPRET="$value"
    fi

    value=$(grep -E '^FULLVPN_WARP_RESOLVE=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ -n "$value" ]; then
        FULLVPN_WARP_RESOLVE="$value"
    fi
}

# Сохраняет основную конфигурацию в warper.conf
save_main_config() {
    {
        echo "SUBNET=$SUBNET"
        echo "TUN_IP=$TUN_IP"
        echo "IP_ROUTE_MODE=$IP_ROUTE_MODE"
        echo "IP_EXPORT_TO_ANTIZAPRET=$IP_EXPORT_TO_ANTIZAPRET"
        echo "FULLVPN_WARP_RESOLVE=$FULLVPN_WARP_RESOLVE"
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

# ===== Конфигурация режима исходящего соединения =====

# Загружает slave_mode.conf: режим (warp/slave/wg),
# адрес и ключ slave-сервера
load_slave_config() {
    CURRENT_OUTBOUND_MODE="warp"
    SLAVE_SERVER=""
    SLAVE_PORT="8444"
    SLAVE_PASSWORD=""
    if [ -f "$SLAVE_MODE_FILE" ]; then
        local val
        val=$(grep -E '^OUTBOUND_MODE=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && CURRENT_OUTBOUND_MODE="$val"
        val=$(grep -E '^SLAVE_SERVER=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && SLAVE_SERVER="$val"
        val=$(grep -E '^SLAVE_PORT=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
        [ -n "$val" ] && SLAVE_PORT="$val"
        val=$(grep -E '^SLAVE_PASSWORD=' "$SLAVE_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
        [ -n "$val" ] && SLAVE_PASSWORD="$val"
    fi
}

# Сохраняет режим и параметры slave/warp в slave_mode.conf
save_slave_config() {
    {
        echo "OUTBOUND_MODE=$CURRENT_OUTBOUND_MODE"
        echo "SLAVE_SERVER=$SLAVE_SERVER"
        echo "SLAVE_PORT=$SLAVE_PORT"
        echo "SLAVE_PASSWORD=$SLAVE_PASSWORD"
    } > "$SLAVE_MODE_FILE"
    chmod 600 "$SLAVE_MODE_FILE"
}

# ===== Конфигурация WireGuard =====

# Загружает параметры WG-соединения из wg_mode.conf
load_wg_config() {
    WG_CONF_FILE=""
    WG_ADDRESS=""
    WG_PRIVATE_KEY=""
    WG_PUBLIC_KEY=""
    WG_PRESHARED_KEY=""
    WG_ENDPOINT_HOST=""
    WG_ENDPOINT_PORT=""
    WG_KEEPALIVE="15"
    if [ -f "$WG_MODE_FILE" ]; then
        local val
        val=$(grep -E '^WG_CONF_FILE=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
        [ -n "$val" ] && WG_CONF_FILE="$val"
        val=$(grep -E '^WG_ADDRESS=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ADDRESS="$val"
        val=$(grep -E '^WG_PRIVATE_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PRIVATE_KEY="$val"
        val=$(grep -E '^WG_PUBLIC_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PUBLIC_KEY="$val"
        val=$(grep -E '^WG_PRESHARED_KEY=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_PRESHARED_KEY="$val"
        val=$(grep -E '^WG_ENDPOINT_HOST=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ENDPOINT_HOST="$val"
        val=$(grep -E '^WG_ENDPOINT_PORT=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_ENDPOINT_PORT="$val"
        val=$(grep -E '^WG_KEEPALIVE=' "$WG_MODE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]')
        [ -n "$val" ] && WG_KEEPALIVE="$val"
    fi
}

# Сохраняет параметры WG-соединения в wg_mode.conf
save_wg_config() {
    {
        echo "WG_CONF_FILE=$WG_CONF_FILE"
        echo "WG_ADDRESS=$WG_ADDRESS"
        echo "WG_PRIVATE_KEY=$WG_PRIVATE_KEY"
        echo "WG_PUBLIC_KEY=$WG_PUBLIC_KEY"
        echo "WG_PRESHARED_KEY=$WG_PRESHARED_KEY"
        echo "WG_ENDPOINT_HOST=$WG_ENDPOINT_HOST"
        echo "WG_ENDPOINT_PORT=$WG_ENDPOINT_PORT"
        echo "WG_KEEPALIVE=$WG_KEEPALIVE"
    } > "$WG_MODE_FILE"
    chmod 600 "$WG_MODE_FILE"
}

# ===== Определение клиентских подсетей AntiZapret =====

# Читает /root/antizapret/setup и определяет:
# AZ_CLIENT_NET   — подсеть AntiZapret-клиентов (*.29.0.0/16)
# FULLVPN_CLIENT_NET — подсеть FullVPN-клиентов (*.28.0.0/16)
# ALL_CLIENT_NET  — объединённая подсеть (*.28.0.0/15)
detect_client_subnets() {
    local setup_file="/root/antizapret/setup"
    local client_prefix="10"

    if [ -f "$setup_file" ]; then
        local alt_client_ip=""
        alt_client_ip=$(grep -E '^ALTERNATIVE_CLIENT_IP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')

        local custom_client_ip=""
        custom_client_ip=$(grep -E '^CLIENT_IP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')

        if [ "$alt_client_ip" = "y" ]; then
            client_prefix="${custom_client_ip:-172}"
        else
            client_prefix="${custom_client_ip:-10}"
        fi
    fi

    AZ_CLIENT_NET="${client_prefix}.29.0.0/16"
    FULLVPN_CLIENT_NET="${client_prefix}.28.0.0/16"
    ALL_CLIENT_NET="${client_prefix}.28.0.0/15"
}
