#!/bin/bash

set -uo pipefail

SLAVE_DIR="/root/warperslave"
SLAVE_CONF="$SLAVE_DIR/slave.conf"
WGCF_DIR="$SLAVE_DIR/wgcf"
SINGBOX_SLAVE_CONF="/etc/sing-box-slave/config.json"
SERVICE_NAME="sing-box-slave"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/dev"
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

SLAVE_MODE=""
SLAVE_PORT=""
SS_PASSWORD=""

load_config() {
    if [ ! -f "$SLAVE_CONF" ]; then
        echo -e "${RED}Конфигурация warperslave не найдена: $SLAVE_CONF${NC}"
        echo -e "${YELLOW}Запустите установщик:${NC}"
        echo -e "  ${GREEN}curl -fsSL $REPO_URL/install-slave.sh | bash${NC}"
        exit 1
    fi
    SLAVE_MODE=$(load_config_value "SLAVE_MODE" | tr -d '[:space:]')
    SLAVE_PORT=$(load_config_value "SLAVE_PORT" | tr -d '[:space:]')
    SS_PASSWORD=$(load_config_value "SS_PASSWORD")
}

save_config() {
    {
        echo "SLAVE_MODE=$SLAVE_MODE"
        echo "SLAVE_PORT=$SLAVE_PORT"
        echo "SS_PASSWORD=$SS_PASSWORD"
    } > "$SLAVE_CONF"
    chmod 600 "$SLAVE_CONF"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

check_port_available() {
    local port="$1"
    local current_pid
    current_pid=$(systemctl show -p MainPID "$SERVICE_NAME" 2>/dev/null | cut -d= -f2)
    if [ -n "$current_pid" ] && [ "$current_pid" != "0" ]; then
        if ss -tlnp 2>/dev/null | grep ":${port} " | grep -v "pid=${current_pid}" | grep -q .; then
            return 1
        fi
        return 0
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
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
        echo -e "${RED}MTU недоступен (режим Direct не использует endpoints).${NC}"; return 1
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
    echo -e "${GREEN}MTU изменён: ${old_mtu} → ${new_mtu}${NC}"
    return 0
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then return 1; fi
    sing-box check -c "$SINGBOX_SLAVE_CONF" >/dev/null 2>&1
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

find_warp_keys() {
    local address="" private_key=""

    # Приоритет 1: /etc/wireguard/warp.conf
    if [ -f "/etc/wireguard/warp.conf" ]; then
        if grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/etc/wireguard/warp.conf" 2>/dev/null; then
            private_key=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            address=$(grep -m 1 '^Address' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            if [ -n "$private_key" ]; then
                [ -z "$address" ] && address="172.16.0.2/32"
                [[ ! "$address" =~ / ]] && address="${address}/32"
                echo "$address"
                echo "$private_key"
                echo "/etc/wireguard/warp.conf"
                return 0
            fi
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
    if [ -f "/etc/wireguard/warp.conf" ]; then
        local pk
        pk=$(grep -m 1 '^PrivateKey' "/etc/wireguard/warp.conf" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$pk" ]; then
            echo "/etc/wireguard/warp.conf"
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

    slave_restore_if_exists "$backupdir/sing-box-slave.service" "/etc/systemd/system/${SERVICE_NAME}.service"
    slave_restore_if_exists "$backupdir/config-slave-direct.json.template" "$SLAVE_DIR/config-slave-direct.json.template"
    slave_restore_if_exists "$backupdir/config-slave-warp.json.template" "$SLAVE_DIR/config-slave-warp.json.template"

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
    download_file_safe "$REPO_URL/templates/config-slave-direct.json.template" "$tmpdir/config-slave-direct.json.template" "шаблон direct" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    download_file_safe "$REPO_URL/templates/config-slave-warp.json.template" "$tmpdir/config-slave-warp.json.template" "шаблон warp" || {
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

    # ===== Проверяем шаблоны =====
    validate_template_marker "$tmpdir/config-slave-direct.json.template" "__SLAVE_PORT__" "config-slave-direct.json.template" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    validate_template_marker "$tmpdir/config-slave-direct.json.template" "__SLAVE_PASSWORD__" "config-slave-direct.json.template" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    validate_template_marker "$tmpdir/config-slave-warp.json.template" "__WARP_ADDRESS__" "config-slave-warp.json.template" || {
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }
    validate_template_marker "$tmpdir/config-slave-warp.json.template" "__SLAVE_PASSWORD__" "config-slave-warp.json.template" || {
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

    slave_backup_if_exists "/etc/systemd/system/${SERVICE_NAME}.service" "$backupdir/sing-box-slave.service"
    slave_backup_if_exists "$SLAVE_DIR/config-slave-direct.json.template" "$backupdir/config-slave-direct.json.template"
    slave_backup_if_exists "$SLAVE_DIR/config-slave-warp.json.template" "$backupdir/config-slave-warp.json.template"

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

    install -m 644 "$tmpdir/sing-box-slave.service" "/etc/systemd/system/${SERVICE_NAME}.service" || {
        echo -e "${RED}Ошибка установки sing-box-slave.service, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/config-slave-direct.json.template" "$SLAVE_DIR/config-slave-direct.json.template" || {
        echo -e "${RED}Ошибка установки шаблона direct, откат.${NC}"
        rollback_warperslave_update "$backupdir"
        rm -rf "$tmpdir" "$backupdir"
        return 1
    }

    install -m 644 "$tmpdir/config-slave-warp.json.template" "$SLAVE_DIR/config-slave-warp.json.template" || {
        echo -e "${RED}Ошибка установки шаблона warp, откат.${NC}"
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
    echo "Mode:        $SLAVE_MODE"
    echo "Port:        $SLAVE_PORT"
    echo "Service:     $sb_run"
    echo "Autostart:   $sb_en"
    echo "SS key:      ${SS_PASSWORD:0:8}..."
    echo "Public IPv4: $ext_ip"
    echo "Log level:   $(get_log_level)"
    local mtu_val
    mtu_val=$(get_mtu)
    [ -n "$mtu_val" ] && echo "MTU:         $mtu_val"
    if [ "$SLAVE_MODE" = "warp" ]; then
        echo "WARP keys:   $(get_warp_source)"
    fi
}

switch_mode() {
    load_config
    local new_mode backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if [ "$SLAVE_MODE" = "direct" ]; then
        new_mode="warp"
        echo -e "${YELLOW}Переключение на режим WARP...${NC}"

        local warp_address="" warp_private_key=""
        if existing_keys=$(find_warp_keys); then
            warp_address=$(echo "$existing_keys" | sed -n '1p')
            warp_private_key=$(echo "$existing_keys" | sed -n '2p')
        else
            echo -e "${RED}WARP-ключи не найдены!${NC}"
            echo -e "${YELLOW}Положите wgcf-profile.conf в $SLAVE_DIR/wgcf/ и попробуйте снова.${NC}"
            rm -f "$backup"
            return 1
        fi
        
        local warp_src
        warp_src=$(get_warp_source)
        echo -e " - ${GREEN}Источник WARP-ключей: ${warp_src}${NC}"
        
        cat > "$SINGBOX_SLAVE_CONF" << WARPEOF
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "warp-dns",
        "type": "udp",
        "server": "1.1.1.1",
        "detour": "warp"
      },
      {
        "tag": "local",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": $SLAVE_PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD"
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "name": "warp-tun",
      "system": false,
      "mtu": 1420,
      "address": [ "$warp_address" ],
      "private_key": "$warp_private_key",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0"],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "ss-in",
        "outbound": "warp"
      }
    ],
    "default_domain_resolver": "local",
    "final": "direct"
  }
}
WARPEOF
    else
        new_mode="direct"
        echo -e "${YELLOW}Переключение на режим Direct...${NC}"

        cat > "$SINGBOX_SLAVE_CONF" << DIRECTEOF
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "direct-dns",
        "type": "udp",
        "server": "1.1.1.1"
      }
    ],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "listen_port": $SLAVE_PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "ss-in",
        "outbound": "direct"
      }
    ],
    "default_domain_resolver": "direct-dns",
    "final": "direct"
  }
}
DIRECTEOF
    fi

    chmod 600 "$SINGBOX_SLAVE_CONF"

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации конфига! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    SLAVE_MODE="$new_mode"
    save_config

    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Режим переключен на: $new_mode${NC}"
        rm -f "$backup"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        SLAVE_MODE=$([ "$new_mode" = "warp" ] && echo "direct" || echo "warp")
        save_config
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"
        return 1
    fi
}

change_port() {
    load_config
    local old_port="$SLAVE_PORT"

    echo -e "${CYAN}Текущий порт: $old_port${NC}"
    read -r -p "Новый порт (или Enter для отмены): " new_port

    if [ -z "$new_port" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        return 0
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
        ss -tlnp 2>/dev/null | grep ":${new_port} " || true
        return 1
    fi

    local backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        if ! jq --argjson port "$new_port" '.inbounds[0].listen_port = $port' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка обработки JSON!${NC}"
            return 1
        fi
        mv "$tmp" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
    else
        sed -i "s|\"listen_port\": $old_port|\"listen_port\": $new_port|g" "$SINGBOX_SLAVE_CONF"
    fi

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    remove_port_rules "$old_port" 2>/dev/null || true
    ensure_port_open "$new_port"

    SLAVE_PORT="$new_port"
    save_config

    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Порт изменён: $old_port → $new_port${NC}"
        rm -f "$backup"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        remove_port_rules "$new_port" 2>/dev/null || true
        ensure_port_open "$old_port"
        SLAVE_PORT="$old_port"
        save_config
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"
    fi
}

change_key() {
    load_config
    echo -e "${CYAN}Текущий ключ: ${SS_PASSWORD:0:8}...${NC}"
    echo -e ""
    echo -e " ${GREEN}1.${NC} Сгенерировать новый"
    echo -e " ${GREEN}2.${NC} Ввести вручную"
    echo -e " ${CYAN}0.${NC} Отмена"

    read -r -p "Выбор: " key_action

    local new_key=""
    case "${key_action:-}" in
        1) new_key=$(openssl rand -base64 16) ;;
        2)
            read -r -p "Введите ключ: " new_key
            if [ -z "$new_key" ]; then
                echo -e "${YELLOW}Отмена.${NC}"
                return 0
            fi
            ;;
        0) return 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; return 1 ;;
    esac

    local backup
    backup=$(mktemp /tmp/slave_config_backup.XXXXXX)
    cp -a "$SINGBOX_SLAVE_CONF" "$backup"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp)
        if ! jq --arg pwd "$new_key" '.inbounds[0].password = $pwd' "$SINGBOX_SLAVE_CONF" > "$tmp"; then
            rm -f "$backup" "$tmp"
            echo -e "${RED}Ошибка обработки JSON!${NC}"
            return 1
        fi
        mv "$tmp" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
    else
        local old_escaped new_escaped
        old_escaped=$(printf '%s\n' "$SS_PASSWORD" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
        new_escaped=$(printf '%s\n' "$new_key" | sed 's/[&/\]/\\&/g')
        sed -i "s|\"password\": \"$old_escaped\"|\"password\": \"$new_escaped\"|g" "$SINGBOX_SLAVE_CONF"
    fi

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        rm -f "$backup"
        return 1
    fi

    SS_PASSWORD="$new_key"
    save_config

    systemctl restart "$SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Ключ обновлён!${NC}"
        echo -e "${YELLOW}Новый ключ: ${new_key}${NC}"
        echo -e ""
        echo -e "${RED}================================================${NC}"
        echo -e "${RED}⚠️  Не забудьте обновить ключ на основном${NC}"
        echo -e "${RED}   WARPER-сервере! (warper → Настройки →${NC}"
        echo -e "${RED}   Режим маршрутизации → Slave)${NC}"
        echo -e "${RED}================================================${NC}"
        rm -f "$backup"
    else
        echo -e "${RED}Ошибка перезапуска! Откат...${NC}"
        cp -a "$backup" "$SINGBOX_SLAVE_CONF"
        chmod 600 "$SINGBOX_SLAVE_CONF"
        SS_PASSWORD=$(load_config_value "SS_PASSWORD")
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "$backup"
    fi
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
    echo -e " ${CYAN}!${NC} Log level: $(get_log_level)"
    if [ "$SLAVE_MODE" = "warp" ]; then
        local doc_mtu
        doc_mtu=$(get_mtu)
        echo -e " ${CYAN}!${NC} MTU: ${doc_mtu:-n/a}"
    fi

    check_item "Конфигурация slave существует" "[ -f '$SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave существует" "[ -f '$SINGBOX_SLAVE_CONF' ]"
    check_item "Конфиг sing-box-slave валиден" "validate_singbox_config"
    check_item "Служба $SERVICE_NAME активна" "systemctl is-active --quiet '$SERVICE_NAME'"
    check_item "Автозагрузка $SERVICE_NAME включена" "systemctl is-enabled --quiet '$SERVICE_NAME'"
    check_item "Порт $SLAVE_PORT слушается" "ss -tlnp 2>/dev/null | grep -q ':${SLAVE_PORT} '"
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
    if [ "$SLAVE_MODE" = "warp" ]; then
        mode_display="${CYAN}WARP${NC}"
    else
        mode_display="${GREEN}Direct${NC}"
    fi
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
    echo -e " 🔀 ${CYAN}Режим:${NC}    $mode_display"
    echo -e " 🔌 ${CYAN}Порт:${NC}     ${YELLOW}${SLAVE_PORT}${NC}"
    echo -e " 🔑 ${CYAN}Ключ:${NC}     ${YELLOW}${SS_PASSWORD:0:8}...${NC}"
    local log_level mtu_display
    log_level=$(get_log_level)
    mtu_display=$(get_mtu)
    [ -z "$mtu_display" ] && mtu_display="n/a"
    echo -e " 🌐 ${CYAN}IP:${NC}       ${YELLOW}${pub_ip}${NC}"
    echo -e " ⚙️  ${CYAN}Log:${NC}      ${YELLOW}${log_level}${NC} | MTU: ${YELLOW}${mtu_display}${NC}"
    if [ "$SLAVE_MODE" = "warp" ]; then
        local warp_src
        warp_src=$(get_warp_source)
        echo -e " 🔑 ${CYAN}WARP:${NC}     ${YELLOW}${warp_src}${NC}"
    fi
    echo -e ""
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} 🔀 Переключить режим (Direct ↔ WARP)"
    echo -e " ${CYAN}2.${NC} 🔌 Изменить порт"
    echo -e " ${CYAN}3.${NC} 🔑 Изменить ключ Shadowsocks"
    echo -e " ${CYAN}4.${NC} 👁️  Показать полный ключ"
    echo -e " ${CYAN}5.${NC} 🔄 Перезапустить службу"
    echo -e " ${CYAN}6.${NC} 📄 Показать логи"
    echo -e " ${CYAN}7.${NC} ⚙️  Изменить log level"
    if [ "$SLAVE_MODE" = "warp" ]; then
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

case "${1:-}" in
    status) load_config; status_cmd; exit $? ;;
    switch) switch_mode; exit $? ;;
    port) change_port; exit $? ;;
    key) change_key; exit $? ;;
    doctor) doctor_cmd; exit $? ;;
    update) update_warperslave; exit $? ;;
    uninstall) uninstall_cmd; exit $? ;;
    help|--help|-h)
        echo "Использование: warperslave [команда]"
        echo ""
        echo "Команды:"
        echo "  status     Показать статус"
        echo "  switch     Переключить режим (Direct ↔ WARP)"
        echo "  port       Изменить порт"
        echo "  key        Изменить ключ Shadowsocks"
        echo "  doctor     Диагностика"
        echo "  update     Обновить warperslave"
        echo "  uninstall  Удалить warperslave"
        echo "  help       Показать эту справку"
        echo ""
        echo "Без аргументов — интерактивное меню."
        exit 0
        ;;
esac

while true; do
    show_menu
    read -r -e -p "Выбор: " choice
    choice=$(echo "${choice:-}" | tr -d ' ')
    case "$choice" in
        1) switch_mode; read -r -p "Нажмите Enter..." ;;
        2) change_port; read -r -p "Нажмите Enter..." ;;
        3) change_key; read -r -p "Нажмите Enter..." ;;
        4) load_config; echo -e "\n${CYAN}Полный ключ Shadowsocks:${NC} ${YELLOW}${SS_PASSWORD}${NC}"; read -r -p "Нажмите Enter..." ;;
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
            if [ "$SLAVE_MODE" != "warp" ]; then
                echo -e "${YELLOW}MTU доступен только в режиме WARP.${NC}"
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
