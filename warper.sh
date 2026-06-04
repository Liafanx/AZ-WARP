#!/bin/bash
# WARPER – точечная маршрутизация доменов и IP-подсетей через WARP/Slave/WG
# Подробности: https://github.com/Liafanx/AZ-WARP

set -uo pipefail

# ===== Пути =====
WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"
AZ_INC="/root/antizapret/config/include-ips.txt"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"
SLAVE_TEMPLATE="$WARPER_DIR/config-slave-master.json.template"
SLAVE_MODE_FILE="$WARPER_DIR/slave_mode.conf"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"
WARP_SYSTEM_CONF="/etc/wireguard/warp.conf"
LOCK_FILE="/var/run/warper.lock"
WG_TEMPLATE="$WARPER_DIR/config-wg.json.template"
WG_MODE_FILE="$WARPER_DIR/wg_mode.conf"
IP_RANGES_FILE="$WARPER_DIR/ip-ranges.txt"
AZ_WARPER_INCLUDE_IPS="/root/antizapret/config/warper-include-ips.txt"
IP_ROUTE_TABLE=100
IP_ROUTE_PRIO=500

# ===== Цвета =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Глобальные переменные состояния =====
SUBNET="198.20.0.0/24"
TUN_IP="198.20.0.1/24"
FULLVPN_WARP_RESOLVE="n"
CURRENT_OUTBOUND_MODE="warp"
SLAVE_SERVER=""
SLAVE_PORT="8444"
SLAVE_PASSWORD=""
WG_CONF_FILE=""
WG_ADDRESS=""
WG_PRIVATE_KEY=""
WG_PUBLIC_KEY=""
WG_PRESHARED_KEY=""
WG_ENDPOINT_HOST=""
WG_ENDPOINT_PORT=""
WG_KEEPALIVE="15"
IP_ROUTE_MODE="antizapret"
IP_EXPORT_TO_ANTIZAPRET="y"
AZ_CLIENT_NET=""
FULLVPN_CLIENT_NET=""
ALL_CLIENT_NET=""
REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0
MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

# ===== Lock-файл =====
# Lock берётся ТОЛЬКО для тяжёлых команд (toggle, sync, ipsync, mode, subnet, patch, update).
# Все остальные команды (включая TUI-меню без аргументов) работают БЕЗ блокировки,
# чтобы веб-панель могла параллельно вызывать warper.

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -w 30 9; then
        echo -e "${RED}Не удалось получить блокировку (другая операция > 30 сек)${NC}" >&2
        exit 1
    fi
}

release_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

trap 'release_lock' EXIT

# Lock берём ТОЛЬКО для тяжёлых команд по первому аргументу
case "${1:-}" in
    toggle|sync|ipsync|patch|mode|subnet|update)
        acquire_lock
        ;;
    *)
        :  # без lock - TUI и быстрые команды
        ;;
esac

# ===== Подключение модулей =====
WARPER_LIB="$WARPER_DIR/lib"
WARPER_MENUS="$WARPER_DIR/menus"

# Автоматическое восстановление модулей после обновления со старой версии
if [ ! -d "$WARPER_LIB" ] || [ ! -f "$WARPER_LIB/utils.sh" ]; then
    echo -e "${YELLOW}Обнаружена старая версия WARPER. Загружаю модули...${NC}"
    mkdir -p "$WARPER_LIB" "$WARPER_MENUS"

    _fetch_module() {
        local url="$1" dest="$2" desc="$3"
        if curl -fsSL --retry 3 --connect-timeout 10 "${url}?t=$(date +%s)" -o "$dest"; then
            if [ -s "$dest" ]; then
                return 0
            fi
        fi
        echo -e "${RED}Не удалось загрузить ${desc}${NC}" >&2
        return 1
    }

    for _libfile in utils config domains singbox kresd warp-keys wg ip-routes diagnostics update cli traffic; do
        _fetch_module "$REPO_URL/lib/${_libfile}.sh" "$WARPER_LIB/${_libfile}.sh" "lib/${_libfile}.sh" || exit 1
    done

    for _menufile in main settings singbox-menu ip-menu web-menu; do
        _fetch_module "$REPO_URL/menus/${_menufile}.sh" "$WARPER_MENUS/${_menufile}.sh" "menus/${_menufile}.sh" || exit 1
    done

    echo -e "${GREEN}Модули успешно загружены. Перезапустите WARPER.${NC}"
    exit 0
fi

# Обязательные модули - без них warper не работает.
# Если модуль отсутствует - пытаемся скачать (для обновления со старых версий).
for _lib in \
    "$WARPER_LIB/utils.sh" \
    "$WARPER_LIB/config.sh" \
    "$WARPER_LIB/domains.sh" \
    "$WARPER_LIB/singbox.sh" \
    "$WARPER_LIB/kresd.sh" \
    "$WARPER_LIB/warp-keys.sh" \
    "$WARPER_LIB/wg.sh" \
    "$WARPER_LIB/ip-routes.sh" \
    "$WARPER_LIB/diagnostics.sh" \
    "$WARPER_LIB/update.sh" \
    "$WARPER_LIB/cli.sh" \
    "$WARPER_LIB/traffic.sh" \
    "$WARPER_MENUS/settings.sh" \
    "$WARPER_MENUS/singbox-menu.sh" \
    "$WARPER_MENUS/ip-menu.sh" \
    "$WARPER_MENUS/main.sh"
do
    if [ ! -f "$_lib" ]; then
        # Пытаемся скачать недостающий модуль (тихо)
        _rel_path="${_lib#$WARPER_DIR/}"  # lib/cli.sh или menus/main.sh
        echo -e "${YELLOW}Отсутствует модуль: $_lib — пытаюсь скачать...${NC}" >&2
        mkdir -p "$(dirname "$_lib")"
        if ! curl -fsSL --connect-timeout 10 \
            "${REPO_URL}/${_rel_path}?t=$(date +%s)" \
            -o "$_lib" 2>/dev/null; then
            echo -e "${RED}Не удалось скачать $_rel_path${NC}" >&2
            echo -e "${RED}Проверьте интернет и REPO_URL в warper.sh${NC}" >&2
            exit 1
        fi
        chmod 644 "$_lib"
        echo -e "${GREEN}✓ $_rel_path скачан${NC}" >&2
    fi
    # shellcheck disable=SC1090
    source "$_lib"
done
unset _lib _rel_path

# Опциональные модули
for _opt_module in "$WARPER_MENUS/web-menu.sh"; do
    if [ ! -f "$_opt_module" ]; then
        local_name=$(basename "$_opt_module" .sh)
        if curl -fsSL --connect-timeout 5 \
            "$REPO_URL/menus/${local_name}.sh?t=$(date +%s)" \
            -o "$_opt_module" 2>/dev/null; then
            chmod 644 "$_opt_module"
        fi
    fi
    if [ -f "$_opt_module" ]; then
        # shellcheck disable=SC1090
        source "$_opt_module"
    fi
done
unset _opt_module

# ===== Инициализация файлов =====
if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF
fi

if [ ! -f "$IP_RANGES_FILE" ]; then
cat << 'IPEOF' > "$IP_RANGES_FILE"
# Добавление IPv4-адресов для маршрутизации через Warper (Sing-box tun)
#
# Формат записи: A.B.C.D/M
# Примеры: 5.255.255.242/32  66.22.192.0/18  104.24.0.0/14
#
# Строки начинающиеся с # - комментарии, не обрабатываются.
# После изменения файла выполните: warper ipsync
IPEOF
fi

# ===== Загрузка настроек =====
load_config
load_wg_config
rebuild_master_file
check_and_sync_warp_keys

# ===== CLI-обработка =====
case "${1:-}" in
    patch)    patch_kresd >/dev/null 2>&1; exit $? ;;
    doctor)   doctor; exit $? ;;
    status)
        if [ "${2:-}" = "json" ]; then
            cli_status_json; exit $?
        else
            status_cmd; exit $?
        fi
        ;;
    sync)
        if is_warper_active; then patch_kresd
        else sync_domains; echo -e "${GREEN}Домены синхронизированы.${NC}"; fi
        exit $?
        ;;
    add)      [ -n "${2:-}" ] || { echo "Использование: warper add DOMAIN"; exit 1; }
              cli_add_domain "$2"; exit $? ;;
    remove)   [ -n "${2:-}" ] || { echo "Использование: warper remove DOMAIN"; exit 1; }
              cli_remove_domain "$2"; exit $? ;;
    enable)   [ -n "${2:-}" ] || { echo "Использование: warper enable gemini|chatgpt"; exit 1; }
              cli_enable_list "$2"; exit $? ;;
    disable)  [ -n "${2:-}" ] || { echo "Использование: warper disable gemini|chatgpt"; exit 1; }
              cli_disable_list "$2"; exit $? ;;
    ipadd)    [ -n "${2:-}" ] || { echo "Использование: warper ipadd A.B.C.D/M"; exit 1; }
              add_ip_range "$2"
              if is_warper_active; then sync_ip_ranges; fi
              exit $? ;;
    ipremove) [ -n "${2:-}" ] || { echo "Использование: warper ipremove A.B.C.D/M"; exit 1; }
              remove_ip_range "$2"
              if is_warper_active; then sync_ip_ranges; fi
              exit $? ;;
    ipsync)   sync_ip_ranges; exit $? ;;
    iplist)   extract_ip_ranges; exit $? ;;
    iproutes) get_current_tun_routes; exit $? ;;
    warpkeysync)
        auto_sync_warp_keys_on_boot
        exit $?
        ;;
    trafficfinalize)
        traffic_finalize_session 2>/dev/null || true
        exit $?
        ;;    

    # ===== Команды для веб-панели =====
    toggle)   cli_toggle_warper; exit $? ;;
    mode)
        case "${2:-}" in
            warp)  cli_mode_warp "${3:-}"; exit $? ;;
            slave) cli_mode_slave "${3:-}" "${4:-}" "${5:-}"; exit $? ;;
            wg)    cli_mode_wg "${3:-}"; exit $? ;;
            *)
                echo "Использование: warper mode warp [system|wgcf|root|generate]"
                echo "               warper mode slave SERVER PORT PASSWORD"
                echo "               warper mode wg /path/to.conf"
                exit 1
                ;;
        esac
        ;;
    update)
        update_warper
        exit $?
        ;;
    logs)        cli_logs "${2:-100}"; exit $? ;;
    config)
        case "${2:-}" in
            get) cli_config_get "${3:-}"; exit $? ;;
            *)   echo "Использование: warper config get KEY"; exit 1 ;;
        esac
        ;;
    subnet)      cli_subnet "${2:-}"; exit $? ;;
    loglevel)    cli_loglevel "${2:-}"; exit $? ;;
    mtu)         cli_mtu "${2:-}"; exit $? ;;
    autopatch)   cli_autopatch "${2:-}"; exit $? ;;
    fullvpn)     cli_fullvpn "${2:-}"; exit $? ;;
    iproutemode) cli_iproutemode "${2:-}"; exit $? ;;
    ipexport)    cli_ipexport "${2:-}"; exit $? ;;
    traffic)
        cli_traffic "${2:-today}" "${3:-}"
        exit $?
        ;;
    warpkey)
        case "${2:-}" in
            list)     cli_warpkey_list; exit $? ;;
            generate) cli_generate_warp_key; exit $? ;;
            *)        echo "Использование: warper warpkey list|generate"; exit 1 ;;
        esac
        ;;
    wgconfig)
        case "${2:-}" in
            list) cli_wg_list; exit $? ;;
            *)    echo "Использование: warper wgconfig list"; exit 1 ;;
        esac
        ;;
    domainslist) cli_domains_list; exit $? ;;
    ipranges)
        case "${2:-}" in
            list) cli_ip_ranges_content; exit $? ;;
            save) cli_ip_ranges_save; exit $? ;;
            *)    echo "Использование: warper ipranges list|save"; exit 1 ;;
        esac
        ;;
    webpass)
        shift
        cli_webpass "$@"
        exit $?
        ;;
    webupdate)
        cli_web_update
        exit $?
        ;;
    webhttps)
        shift
        cli_web_https "$@"
        exit $?
        ;;        
esac

# ===== Главное меню =====
run_main_menu
