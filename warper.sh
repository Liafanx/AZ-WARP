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
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/1.3.1pre"
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
FULLVPN_WARP_RESOLVE="n"           # включать ли WARP-резолвинг для FullVPN
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
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}Другой экземпляр warper уже запущен.${NC}" >&2
        exit 1
    fi
}
release_lock() { rm -f "$LOCK_FILE"; }
trap 'release_lock' EXIT
acquire_lock

# ===== Подключение модулей =====
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

    for _libfile in utils config domains singbox kresd warp-keys wg ip-routes diagnostics update; do
        _fetch_module "$REPO_URL/lib/${_libfile}.sh" "$WARPER_LIB/${_libfile}.sh" "lib/${_libfile}.sh" || exit 1
    done

    for _menufile in main settings singbox-menu ip-menu; do
        _fetch_module "$REPO_URL/menus/${_menufile}.sh" "$WARPER_MENUS/${_menufile}.sh" "menus/${_menufile}.sh" || exit 1
    done

    echo -e "${GREEN}Модули успешно загружены. Перезапустите WARPER.${NC}"
    exit 0
fi

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
    "$WARPER_MENUS/settings.sh" \
    "$WARPER_MENUS/singbox-menu.sh" \
    "$WARPER_MENUS/ip-menu.sh" \
    "$WARPER_MENUS/main.sh"
do
    if [ ! -f "$_lib" ]; then
        echo -e "${RED}Отсутствует модуль: $_lib${NC}" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$_lib"
done
unset _lib

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
    status)   status_cmd; exit $? ;;
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
esac

# ===== Главное меню =====
run_main_menu
