#!/bin/bash

set -u

WARPER_DIR="/root/warper"
DOWNLOAD_DIR="$WARPER_DIR/download"
WGCF_DIR="$WARPER_DIR/wgcf"
MASTER_FILE="$WARPER_DIR/domains.txt"
EXCLUDE_FILE="$WARPER_DIR/exclude_domains.txt"
ACTIVE_FILE="/etc/knot-resolver/warper-domains.txt"
ACTIVE_EXCLUDE_FILE="/etc/knot-resolver/warper-exclude-domains.txt"
KRESD_CONF="/etc/knot-resolver/kresd.conf"
KRESD_BACKUP="/etc/knot-resolver/kresd.conf.warper.bak"
AZ_INC="/root/antizapret/config/include-ips.txt"
SINGBOX_CONF="/etc/sing-box/config.json"
SINGBOX_TEMPLATE="$WARPER_DIR/config.json.template"
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"

SUBNET="198.18.0.0/24"
TUN_IP="198.18.0.1/24"
MODE="selective"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

ensure_base_files() {
    if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ РЕЖИМА SELECTIVE
# ==========================================

# Пользовательские домены:
EOF
    fi

    if [ ! -f "$EXCLUDE_FILE" ]; then
cat << 'EOF' > "$EXCLUDE_FILE"
# ==========================================
# СПИСОК ИСКЛЮЧЕНИЙ ДЛЯ РЕЖИМА GLOBAL-EXCEPT
# Всё идёт через WARP, кроме доменов отсюда
# ==========================================

# Пользовательские исключения:
EOF
    fi
}

load_config() {
    [ -f "$CONF_FILE" ] || return 0

    local value
    value=$(grep -E '^SUBNET=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    [ -n "$value" ] && SUBNET="$value"

    value=$(grep -E '^TUN_IP=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    [ -n "$value" ] && TUN_IP="$value"

    value=$(grep -E '^MODE=' "$CONF_FILE" | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]')
    if [ "$value" = "selective" ] || [ "$value" = "global-except" ]; then
        MODE="$value"
    fi
}

save_config() {
    {
        echo "SUBNET=$SUBNET"
        echo "TUN_IP=$TUN_IP"
        echo "MODE=$MODE"
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    domain="${domain%.}"
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')

    [ -n "$domain" ] || return 1
    [[ "$domain" =~ \. ]] || return 1
    [[ ! "$domain" =~ \.\. ]] || return 1
    [[ ! "$domain" =~ ^- && ! "$domain" =~ -$ ]] || return 1
    [[ "$domain" =~ ^[a-z0-9._-]+$ ]] || return 1

    IFS='.' read -r -a labels <<< "$domain"
    local label
    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ ${#label} -le 63 ] || return 1
        [[ ! "$label" =~ ^- && ! "$label" =~ -$ ]] || return 1
        [[ "$label" =~ ^[a-z0-9_-]+$ ]] || return 1
    done

    echo "$domain"
    return 0
}

validate_subnet() {
    local subnet="$1"
    if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" mask="${BASH_REMATCH[4]}"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && mask >= 1 && mask <= 32 ))
}

calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
}

escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        REMOTE_VER_CACHE=$(curl -s --max-time 2 "$REPO_URL/version?t=$now" | tr -d '\r\n')
        REMOTE_VER_TIME=$now
    fi
    echo "${REMOTE_VER_CACHE:-$LOCAL_VER}"
}

download_file_safe() {
    local url="$1" dest="$2" desc="$3"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" "${url}?t=$(date +%s)"; then
        echo -e "${RED}Ошибка загрузки: ${desc}${NC}"
        rm -f "$tmp"
        return 1
    fi
    [ -s "$tmp" ] || {
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$dest"
}

filter_valid_domains_file() {
    local input="$1" output="$2"
    : > "$output"
    [ -f "$input" ] || return 0

    while IFS= read -r line; do
        local trimmed clean
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" =~ ^# ]] && continue
        clean=$(validate_domain "$trimmed" 2>/dev/null || true)
        [ -n "$clean" ] && echo "$clean" >> "$output"
    done < "$input"

    sort -u -o "$output" "$output"
}

sync_domains() {
    local tmp_main tmp_ex
    tmp_main=$(mktemp /tmp/warper_sync_main.XXXXXX)
    tmp_ex=$(mktemp /tmp/warper_sync_ex.XXXXXX)

    filter_valid_domains_file "$MASTER_FILE" "$tmp_main"
    filter_valid_domains_file "$EXCLUDE_FILE" "$tmp_ex"

    mv "$tmp_main" "$ACTIVE_FILE"
    mv "$tmp_ex" "$ACTIVE_EXCLUDE_FILE"

    chmod 644 "$ACTIVE_FILE" "$ACTIVE_EXCLUDE_FILE"
}

domains_in_sync() {
    local tmp1 tmp2 tmp3 tmp4
    tmp1=$(mktemp)
    tmp2=$(mktemp)
    tmp3=$(mktemp)
    tmp4=$(mktemp)

    filter_valid_domains_file "$MASTER_FILE" "$tmp1"
    filter_valid_domains_file "$ACTIVE_FILE" "$tmp2"
    filter_valid_domains_file "$EXCLUDE_FILE" "$tmp3"
    filter_valid_domains_file "$ACTIVE_EXCLUDE_FILE" "$tmp4"

    cmp -s "$tmp1" "$tmp2" && cmp -s "$tmp3" "$tmp4"
    local rc=$?

    rm -f "$tmp1" "$tmp2" "$tmp3" "$tmp4"
    return $rc
}

validate_singbox_config() {
    command -v sing-box >/dev/null 2>&1 || return 1
    sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1
}

ensure_singbox_running() {
    if ! systemctl is-active --quiet sing-box; then
        echo -e "${RED}Служба sing-box не запустилась.${NC}"
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
        return 1
    fi
    return 0
}

ensure_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null || \
        iptables -I "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

subnet_conflicts() {
    local subnet="$1"
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | grep -qxF "$subnet" && return 0
    ip route 2>/dev/null | grep -qF "${subnet%/*}" && return 0

    if command -v docker >/dev/null 2>&1; then
        local ids
        ids=$(docker network ls -q 2>/dev/null || true)
        if [ -n "$ids" ]; then
            docker network inspect $ids 2>/dev/null | grep -qF "\"Subnet\": \"$subnet\"" && return 0
        fi
    fi
    return 1
}

get_warp_credentials() {
    local address="" private_key=""

    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        address=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' "$SINGBOX_CONF" 2>/dev/null || true)
        private_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    if [ -z "$address" ] || [ -z "$private_key" ]; then
        local wgcf_profile="$WGCF_DIR/wgcf-profile.conf"
        if [ -f "$wgcf_profile" ]; then
            address=$(grep -m 1 '^Address = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        fi
    fi

    [ -n "$address" ] && [ -n "$private_key" ] || return 1
    echo "$address"
    echo "$private_key"
}

rebuild_config() {
    local creds warp_address warp_private_key
    creds=$(get_warp_credentials) || return 1
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')

    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$SINGBOX_TEMPLATE" > "$SINGBOX_CONF"

    chmod 600 "$SINGBOX_CONF"
    validate_singbox_config
}

backup_kresd() {
    if [ -f "$KRESD_CONF" ] && [ ! -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_CONF" "$KRESD_BACKUP" || return 1
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi
}

restore_kresd_backup() {
    if [ -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_BACKUP" "$KRESD_CONF" || return 1
        chmod 644 "$KRESD_CONF" 2>/dev/null || true
        systemctl restart kresd@1 kresd@2 || return 1
        return 0
    fi
    return 1
}

file_mode_is_600() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$(stat -c %a "$file" 2>/dev/null || true)" = "600" ]
}

status_cmd() {
    load_config
    local sb_run sb_en kr_stat dom_stat az_stat ap_stat subnet_conflict
    systemctl is-active --quiet sing-box && sb_run="running" || sb_run="stopped"
    systemctl is-enabled --quiet sing-box 2>/dev/null && sb_en="enabled" || sb_en="disabled"
    grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null && kr_stat="patched" || kr_stat="not patched"
    domains_in_sync && dom_stat="synced" || dom_stat="not synced"
    grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null && az_stat="present" || az_stat="missing"
    systemctl is-enabled --quiet warper-autopatch 2>/dev/null && ap_stat="enabled" || ap_stat="disabled"
    subnet_conflicts "$SUBNET" && subnet_conflict="yes" || subnet_conflict="no"

    echo "Version: $LOCAL_VER"
    echo "Mode: $MODE"
    echo "sing-box: $sb_run"
    echo "sing-box autostart: $sb_en"
    echo "kresd patch: $kr_stat"
    echo "domains: $dom_stat"
    echo "subnet in AntiZapret: $az_stat"
    echo "autopatch: $ap_stat"
    echo "subnet conflict: $subnet_conflict"
}

prompt_apply() {
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -r -e -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        if patch_kresd > /dev/null 2>&1; then
            echo -e "${GREEN}Изменения успешно применены!${NC}"
        else
            echo -e "${RED}Не удалось применить изменения к DNS.${NC}"
        fi
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

show_logs() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Чтение логов sing-box...${NC}"
    echo -e "${GREEN}Для выхода обратно в меню нажмите Ctrl+C${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u sing-box -n 20 -f
    trap - SIGINT
}

build_selective_patch() {
    awk '
    BEGIN { found=0 }
    /-- Resolve non-blocked domains/ || /-- Resolve blocked domains/ {
        found=1
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_domains = {}"
        print "\tlocal wfile = io.open(\"/etc/knot-resolver/warper-domains.txt\", \"r\")"
        print "\tif wfile then"
        print "\t\tfor line in wfile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" and clean:sub(1,1) ~= \"#\" then table.insert(warp_domains, clean .. \".\") end"
        print "\t\tend"
        print "\t\twfile:close()"
        print "\t\tif #warp_domains > 0 then"
        print "\t\t\tpolicy.add(policy.suffix(policy.STUB(\"127.0.0.1@40000\"), policy.todnames(warp_domains)))"
        print "\t\tend"
        print "\tend"
        print "\t-- [WARP-MOD-END]"
    }
    { print }
    END { if (found == 0) exit 42 }
    ' "$KRESD_CONF"
}

build_global_except_patch() {
    awk '
    BEGIN { found=0 }
    /-- Resolve blocked domains/ {
        found=1
        print "\t-- [WARP-MOD-START]"
        print "\tlocal warp_exclude_domains = {}"
        print "\tlocal efile = io.open(\"/etc/knot-resolver/warper-exclude-domains.txt\", \"r\")"
        print "\tif efile then"
        print "\t\tfor line in efile:lines() do"
        print "\t\t\tlocal clean = line:gsub(\"%s+\", \"\")"
        print "\t\t\tif clean ~= \"\" and clean:sub(1,1) ~= \"#\" then table.insert(warp_exclude_domains, clean .. \".\") end"
        print "\t\tend"
        print "\t\tefile:close()"
        print "\tend"
        print "\tif #warp_exclude_domains > 0 then"
        print "\t\tpolicy.add(policy.suffix(policy.PASS, policy.todnames(warp_exclude_domains)))"
        print "\tend"
        print "\tpolicy.add(policy.all(policy.STUB(\"127.0.0.1@40000\")))"
        print "\t-- [WARP-MOD-END]"
        print
    }
    { print }
    END { if (found == 0) exit 42 }
    ' "$KRESD_CONF"
}

patch_kresd() {
    sync_domains

    [ -f "$KRESD_CONF" ] || {
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}"
        return 1
    }

    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        if ! restore_kresd_backup; then
            sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        fi
    else
        backup_kresd || return 1
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)

    if [ "$MODE" = "global-except" ]; then
        build_global_except_patch > "$tmpfile"
    else
        build_selective_patch > "$tmpfile"
    fi

    local rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось подготовить патч kresd.conf.${NC}"
        return 1
    fi

    mv "$tmpfile" "$KRESD_CONF" || return 1
    chmod 644 "$KRESD_CONF"
    systemctl restart kresd@1 kresd@2 || return 1
    return 0
}

unpatch_kresd() {
    if [ -f "$KRESD_BACKUP" ]; then
        restore_kresd_backup && return 0
    fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2 || return 1
    fi
}

doctor() {
    load_config
    echo -e "${CYAN}==========================================${NC}"
    echo -e "        🩺 ${YELLOW}WARPER DOCTOR${NC}"
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

    check_item "AntiZapret установлен" "[ -x /root/antizapret/doall.sh ] && [ -f /root/antizapret/config/include-ips.txt ]"
    check_item "Конфиг warper существует" "[ -f '$CONF_FILE' ]"
    check_item "Конфиг sing-box существует" "[ -f '$SINGBOX_CONF' ]"
    check_item "Конфиг sing-box валиден" "validate_singbox_config"
    check_item "sing-box активен" "systemctl is-active --quiet sing-box"
    check_item "kresd@1 и kresd@2 активны" "systemctl is-active --quiet kresd@1 && systemctl is-active --quiet kresd@2"
    check_item "kresd.conf пропатчен" "grep -q 'WARP-MOD-START' '$KRESD_CONF'"
    check_item "Домены синхронизированы" "domains_in_sync"
    check_item "Подсеть есть в include-ips.txt" "grep -qF '$SUBNET' '$AZ_INC'"
    check_item "Интерфейс singbox-tun существует" "ip link show singbox-tun"
    check_item "iptables FORWARD -o singbox-tun есть" "iptables -C FORWARD -o singbox-tun -j ACCEPT"
    check_item "iptables FORWARD -i singbox-tun есть" "iptables -C FORWARD -i singbox-tun -j ACCEPT"
    check_item "Права config.json ограничены" "file_mode_is_600 '$SINGBOX_CONF'"
    check_item "Права warper.conf ограничены" "file_mode_is_600 '$CONF_FILE'"

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        check_item "Права wgcf-profile.conf ограничены" "file_mode_is_600 '$WGCF_DIR/wgcf-profile.conf'"
    fi

    if subnet_conflicts "$SUBNET"; then
        echo -e " ${YELLOW}!${NC} Обнаружен возможный конфликт fake-подсети $SUBNET"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Конфликт fake-подсети не обнаружен"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Диагностика завершена: проблем не обнаружено.${NC}"
    else
        echo -e "${YELLOW}Диагностика завершена: обнаружены проблемы.${NC}"
    fi
    return "$failed"
}

enable_disable_list() {
    local action="$1" list_name="$2"
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    if [ "$MODE" != "selective" ]; then
        echo -e "${YELLOW}Списки Gemini/ChatGPT доступны только в режиме selective.${NC}"
        return 1
    fi

    [ -f "$list_file" ] || {
        echo -e "${RED}Файл списка $list_file не найден!${NC}"
        return 1
    }

    local valid_tmp
    valid_tmp=$(mktemp /tmp/warper_valid_list.XXXXXX)
    filter_valid_domains_file "$list_file" "$valid_tmp"

    if [ "$action" = "enable" ]; then
        grep -q "^${marker}$" "$MASTER_FILE" && {
            rm -f "$valid_tmp"
            echo -e "${YELLOW}Список ${list_name^^} уже включен.${NC}"
            return 0
        }
        echo "$marker" >> "$MASTER_FILE"
        cat "$valid_tmp" >> "$MASTER_FILE"
        echo "$end_marker" >> "$MASTER_FILE"
        rm -f "$valid_tmp"
        echo -e "${GREEN}Список ${list_name^^} включен.${NC}"
        return 0
    fi

    if [ "$action" = "disable" ]; then
        rm -f "$valid_tmp"
        sed -i "/^${marker}$/, /^${end_marker}$/d" "$MASTER_FILE"
        echo -e "${YELLOW}Список ${list_name^^} выключен.${NC}"
        return 0
    fi

    rm -f "$valid_tmp"
    return 1
}

toggle_mode() {
    echo -e "\n${YELLOW}Текущий режим: $MODE${NC}"
    echo "1) selective"
    echo "2) global-except"
    read -r -e -p "Выберите новый режим [1-2]: " mode_choice
    case "${mode_choice:-}" in
        1) MODE="selective" ;;
        2) MODE="global-except" ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1; return ;;
    esac

    save_config
    if patch_kresd >/dev/null 2>&1; then
        echo -e "${GREEN}Режим успешно переключен на $MODE.${NC}"
    else
        echo -e "${RED}Не удалось переприменить патч после смены режима.${NC}"
    fi
    sleep 2
}

settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"

        local AP_STAT
        systemctl is-enabled --quiet warper-autopatch 2>/dev/null && AP_STAT="${GREEN}ВКЛЮЧЕНО${NC}" || AP_STAT="${RED}ВЫКЛЮЧЕНО${NC}"

        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке:  [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Переключить режим работы:       [Текущий: $MODE]"
        echo -e " ${CYAN}3.${NC} Вкл/выкл Gemini (только selective)"
        echo -e " ${CYAN}4.${NC} Вкл/выкл ChatGPT (только selective)"
        echo -e " ${CYAN}5.${NC} Изменить fake-подсеть:          [Текущая: $SUBNET]"
        echo -e " ${CYAN}0.${NC} Назад"
        echo -e "${CYAN}==========================================${NC}"

        read -r -e -p "Выбор [0-5]: " set_choice
        case "${set_choice:-}" in
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
            2) toggle_mode ;;
            3)
                if grep -q "^# --- GEMINI ---$" "$MASTER_FILE"; then
                    enable_disable_list disable gemini
                else
                    enable_disable_list enable gemini
                fi
                sleep 1
                ;;
            4)
                if grep -q "^# --- CHATGPT ---$" "$MASTER_FILE"; then
                    enable_disable_list disable chatgpt
                else
                    enable_disable_list enable chatgpt
                fi
                sleep 1
                ;;
            5)
                echo -e "\n${YELLOW}Изменение подсети обновит конфигурацию и перезапустит службы.${NC}"
                read -r -e -p "Введите новую подсеть (X.X.X.0/XX) или пусто для отмены: " new_subnet
                if [ -n "$new_subnet" ]; then
                    if validate_subnet "$new_subnet"; then
                        local old_subnet old_tun
                        old_subnet="$SUBNET"
                        old_tun="$TUN_IP"
                        SUBNET="$new_subnet"
                        TUN_IP=$(calculate_tun_ip "$new_subnet")

                        if ! rebuild_config "$SINGBOX_TEMPLATE"; then
                            SUBNET="$old_subnet"
                            TUN_IP="$old_tun"
                            echo -e "${RED}Не удалось обновить конфиг sing-box.${NC}"
                            sleep 2
                            continue
                        fi

                        sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
                        grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || echo "$new_subnet" >> "$AZ_INC"

                        save_config
                        export DEBIAN_FRONTEND=noninteractive
                        export SYSTEMD_PAGER=""
                        bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1
                        systemctl restart sing-box
                        ensure_singbox_running || true
                        patch_kresd >/dev/null 2>&1 || true
                        echo -e "${GREEN}Подсеть успешно изменена.${NC}"
                    else
                        echo -e "${RED}Некорректная подсеть.${NC}"
                    fi
                    sleep 2
                fi
                ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

singbox_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "       ⚙️  ${YELLOW}УПРАВЛЕНИЕ SING-BOX${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"
        systemctl is-active --quiet sing-box && echo -e "Статус: ${GREEN}ЗАПУЩЕН${NC}" || echo -e "Статус: ${RED}ОСТАНОВЛЕН${NC}"
        systemctl is-enabled --quiet sing-box 2>/dev/null && echo -e "Автозагрузка: ${GREEN}ВКЛЮЧЕНА${NC}" || echo -e "Автозагрузка: ${RED}ВЫКЛЮЧЕНА${NC}"
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} Запустить"
        echo -e " ${RED}2.${NC} Остановить"
        echo -e " ${GREEN}3.${NC} Включить автозагрузку"
        echo -e " ${RED}4.${NC} Выключить автозагрузку"
        echo -e " ${YELLOW}5.${NC} Логи"
        echo -e " ${CYAN}0.${NC} Назад"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-5]: " sb_choice
        case "${sb_choice:-}" in
            1) systemctl start sing-box; ensure_singbox_running || true; sleep 1 ;;
            2) systemctl stop sing-box; sleep 1 ;;
            3) systemctl enable sing-box; sleep 1 ;;
            4) systemctl disable sing-box; sleep 1 ;;
            5) show_logs ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    local REMOTE_VER UPDATE_AVAILABLE=false VER_STR
    REMOTE_VER=$(get_remote_version)

    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"
    fi

    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления Warper${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"
    echo -e " - Версия: $VER_STR"
    echo -e " - Режим: ${GREEN}$MODE${NC}"
    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен (selective)"
    echo -e " ${RED}2.${NC} Удалить домен (selective)"
    echo -e " ${GREEN}3.${NC} Добавить исключение (global-except)"
    echo -e " ${RED}4.${NC} Удалить исключение (global-except)"
    echo -e " ${CYAN}5.${NC} Пропатчить DNS / Синхронизация"
    echo -e " ${CYAN}6.${NC} Управление sing-box"
    echo -e " ${CYAN}7.${NC} Логи"
    echo -e " ${CYAN}8.${NC} Вкл/выкл WARPER"
    echo -e " ${CYAN}9.${NC} Настройки"
    echo -e " ${CYAN}D.${NC} Doctor"
    echo -e " ${CYAN}S.${NC} Status"
    echo -e " ${RED}U.${NC} Удалить warper"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"
}

cli_add_domain() {
    [ "$MODE" = "selective" ] || {
        echo -e "${YELLOW}Команда add доступна только в режиме selective.${NC}"
        return 1
    }
    local domain
    domain=$(validate_domain "$1") || {
        echo -e "${RED}Некорректный домен.${NC}"
        return 1
    }
    grep -qxF "$domain" "$MASTER_FILE" || echo "$domain" >> "$MASTER_FILE"
    patch_kresd >/dev/null 2>&1 || true
    echo -e "${GREEN}Домен добавлен: $domain${NC}"
}

cli_remove_domain() {
    [ "$MODE" = "selective" ] || {
        echo -e "${YELLOW}Команда remove доступна только в режиме selective.${NC}"
        return 1
    }
    local domain escaped
    domain=$(validate_domain "$1") || return 1
    escaped=$(escape_regex "$domain")
    sed -i "/^${escaped}$/d" "$MASTER_FILE"
    patch_kresd >/dev/null 2>&1 || true
    echo -e "${GREEN}Домен удален: $domain${NC}"
}

cli_add_exclude() {
    [ "$MODE" = "global-except" ] || {
        echo -e "${YELLOW}Команда exclude-add доступна только в режиме global-except.${NC}"
        return 1
    }
    local domain
    domain=$(validate_domain "$1") || return 1
    grep -qxF "$domain" "$EXCLUDE_FILE" || echo "$domain" >> "$EXCLUDE_FILE"
    patch_kresd >/dev/null 2>&1 || true
    echo -e "${GREEN}Исключение добавлено: $domain${NC}"
}

cli_remove_exclude() {
    [ "$MODE" = "global-except" ] || {
        echo -e "${YELLOW}Команда exclude-remove доступна только в режиме global-except.${NC}"
        return 1
    }
    local domain escaped
    domain=$(validate_domain "$1") || return 1
    escaped=$(escape_regex "$domain")
    sed -i "/^${escaped}$/d" "$EXCLUDE_FILE"
    patch_kresd >/dev/null 2>&1 || true
    echo -e "${GREEN}Исключение удалено: $domain${NC}"
}

toggle_warper() {
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        systemctl stop sing-box
        systemctl disable sing-box 2>/dev/null
        systemctl disable warper-autopatch 2>/dev/null
        remove_iptables_rule FORWARD -o singbox-tun
        remove_iptables_rule FORWARD -i singbox-tun
        unpatch_kresd || true
        echo -e "${GREEN}WARPER отключен.${NC}"
    else
        validate_singbox_config || return
        systemctl enable sing-box 2>/dev/null
        systemctl start sing-box
        ensure_singbox_running || return
        systemctl enable warper-autopatch 2>/dev/null
        ensure_iptables_rule FORWARD -o singbox-tun
        ensure_iptables_rule FORWARD -i singbox-tun
        patch_kresd >/dev/null 2>&1 || true
        echo -e "${GREEN}WARPER включен.${NC}"
    fi
    sleep 2
}

ensure_base_files
load_config

case "${1:-}" in
    patch) patch_kresd >/dev/null 2>&1; exit $? ;;
    sync) patch_kresd; exit $? ;;
    doctor) doctor; exit $? ;;
    status) status_cmd; exit $? ;;
    add) [ -n "${2:-}" ] || { echo "Использование: warper add DOMAIN"; exit 1; }; cli_add_domain "$2"; exit $? ;;
    remove) [ -n "${2:-}" ] || { echo "Использование: warper remove DOMAIN"; exit 1; }; cli_remove_domain "$2"; exit $? ;;
    exclude-add) [ -n "${2:-}" ] || { echo "Использование: warper exclude-add DOMAIN"; exit 1; }; cli_add_exclude "$2"; exit $? ;;
    exclude-remove) [ -n "${2:-}" ] || { echo "Использование: warper exclude-remove DOMAIN"; exit 1; }; cli_remove_exclude "$2"; exit $? ;;
    enable) [ -n "${2:-}" ] || exit 1; enable_disable_list enable "$2"; patch_kresd >/dev/null 2>&1 || true; exit $? ;;
    disable) [ -n "${2:-}" ] || exit 1; enable_disable_list disable "$2"; patch_kresd >/dev/null 2>&1 || true; exit $? ;;
esac

while true; do
    show_main_menu
    read -r -e -p "Выбор: " choice
    choice=$(echo "${choice:-}" | tr -d ' ')
    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен:${NC}"
            read -r -e -p "> " raw_domain
            cli_add_domain "${raw_domain:-}"
            read -r -p "Нажмите Enter..."
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -r -e -p "> " raw_domain
            cli_remove_domain "${raw_domain:-}"
            read -r -p "Нажмите Enter..."
            ;;
        3)
            echo -e "\n${CYAN}Введите домен-исключение:${NC}"
            read -r -e -p "> " raw_domain
            cli_add_exclude "${raw_domain:-}"
            read -r -p "Нажмите Enter..."
            ;;
        4)
            echo -e "\n${CYAN}Введите домен-исключение для удаления:${NC}"
            read -r -e -p "> " raw_domain
            cli_remove_exclude "${raw_domain:-}"
            read -r -p "Нажмите Enter..."
            ;;
        5)
            patch_kresd && echo -e "${GREEN}Готово!${NC}" || echo -e "${RED}Ошибка.${NC}"
            sleep 1
            ;;
        6) singbox_menu ;;
        7) show_logs ;;
        8) toggle_warper ;;
        9) settings_menu ;;
        d|D) doctor; read -r -p "Нажмите Enter..." ;;
        s|S) status_cmd; read -r -p "Нажмите Enter..." ;;
        u|U)
            if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                exec bash "$WARPER_DIR/uninstaller.sh"
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
    esac
done
