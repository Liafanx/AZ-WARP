#!/bin/bash

set -u

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
REPO_URL="https://raw.githubusercontent.com/Liafanx/AZ-WARP/main"
LOCAL_VER=$(cat "$WARPER_DIR/version" 2>/dev/null | tr -d '\r\n' || echo "0.0.0")
CONF_FILE="$WARPER_DIR/warper.conf"

SUBNET="198.18.0.0/24"
TUN_IP="198.18.0.1/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REMOTE_VER_CACHE=""
REMOTE_VER_TIME=0

if [ ! -f "$MASTER_FILE" ]; then
cat << 'EOF' > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте маркеры вида # --- GEMINI ---
#    Они используются для управления списками.
# ==========================================

# Пользовательские домены:
EOF
fi

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
}

escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    domain="${domain%.}"

    if [ -z "$domain" ]; then
        return 1
    fi
    if [[ ! "$domain" =~ \. ]]; then
        return 1
    fi
    if [[ "$domain" =~ \.\. ]]; then
        return 1
    fi
    if [[ "$domain" =~ ^- || "$domain" =~ -$ ]]; then
        return 1
    fi
    if [[ ! "$domain" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    local label
    for label in "${labels[@]}"; do
        if [ -z "$label" ] || [ ${#label} -gt 63 ]; then
            return 1
        fi
        if [[ "$label" =~ ^- || "$label" =~ -$ ]]; then
            return 1
        fi
        if [[ ! "$label" =~ ^[A-Za-z0-9_-]+$ ]]; then
            return 1
        fi
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
    if (( o1 > 255 || o2 > 255 || o3 > 255 || mask < 1 || mask > 32 )); then
        return 1
    fi
    return 0
}

calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
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

    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    return 0
}

get_clean_domains() {
    grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u
}

filter_valid_domains_file() {
    local input="$1"
    local output="$2"
    : > "$output"

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
    local tmp
    tmp=$(mktemp /tmp/warper_sync.XXXXXX)

    filter_valid_domains_file "$MASTER_FILE" "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

domains_in_sync() {
    local tmp_master tmp_active
    tmp_master=$(mktemp /tmp/warper_master_compare.XXXXXX)
    tmp_active=$(mktemp /tmp/warper_active_compare.XXXXXX)

    filter_valid_domains_file "$MASTER_FILE" "$tmp_master"
    if [ -f "$ACTIVE_FILE" ]; then
        filter_valid_domains_file "$ACTIVE_FILE" "$tmp_active"
    else
        : > "$tmp_active"
    fi

    local result=1
    if cmp -s "$tmp_master" "$tmp_active"; then
        result=0
    fi

    rm -f "$tmp_master" "$tmp_active"
    return "$result"
}

validate_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box не найден.${NC}"
        return 1
    fi
    if ! sing-box check -c "$SINGBOX_CONF" >/dev/null 2>&1; then
        echo -e "${RED}Конфигурация sing-box не прошла проверку.${NC}"
        return 1
    fi
    return 0
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

get_warp_credentials() {
    local address="" private_key=""

    if [ -f "$SINGBOX_CONF" ]; then
        address=$(grep -o '"address": \[ "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        private_key=$(grep -o '"private_key": "[^"]*"' "$SINGBOX_CONF" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
    fi

    if [ -z "$address" ] || [ -z "$private_key" ] || [ "$address" = "__WARP_ADDRESS__" ]; then
        local wgcf_profile="$WGCF_DIR/wgcf-profile.conf"
        if [ -f "$wgcf_profile" ]; then
            address=$(grep -m 1 '^Address = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
            private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        fi
    fi

    if [ -z "$address" ] || [ -z "$private_key" ]; then
        return 1
    fi

    echo "$address"
    echo "$private_key"
    return 0
}

rebuild_config() {
    local template="$1"

    local creds
    creds=$(get_warp_credentials) || {
        echo -e "${RED}Ошибка: Не удалось извлечь WARP-ключи!${NC}"
        echo -e "${YELLOW}Проверьте наличие файла $WGCF_DIR/wgcf-profile.conf${NC}"
        return 1
    }

    local warp_address warp_private_key
    warp_address=$(echo "$creds" | sed -n '1p')
    warp_private_key=$(echo "$creds" | sed -n '2p')

    sed \
        -e "s|__WARP_ADDRESS__|$warp_address|g" \
        -e "s|__WARP_PRIVATE_KEY__|$warp_private_key|g" \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        "$template" > "$SINGBOX_CONF"

    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box успешно обновлена.${NC}"
    return 0
}

backup_kresd() {
    if [ -f "$KRESD_CONF" ] && [ ! -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_CONF" "$KRESD_BACKUP" || return 1
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi
    return 0
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

prompt_apply() {
    echo -e "\n${YELLOW}Применить изменения и перезапустить DNS?${NC}"
    read -r -e -p "Выбор [Y/n] (по умолчанию Y): " apply_choice
    if [[ -z "$apply_choice" || "$apply_choice" == "Y" || "$apply_choice" == "y" ]]; then
        if patch_kresd > /dev/null 2>&1; then
            echo -e "${GREEN}Изменения успешно применены!${NC}"
        else
            echo -e "${RED}Не удалось применить изменения к DNS.${NC}"
        fi
    else
        echo -e "${YELLOW}Домены сохранены в файл, но НЕ применены к DNS.${NC}"
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

prompt_confirm() {
    read -r -e -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0; else return 1; fi
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

patch_kresd() {
    sync_domains

    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}"
        return 1
    fi

    if grep -q "WARP-MOD-START" "$KRESD_CONF"; then
        systemctl restart kresd@1 kresd@2 || return 1
        return 0
    fi

    backup_kresd || {
        echo -e "${RED}Не удалось создать backup $KRESD_CONF.${NC}"
        return 1
    }

    local tmpfile
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)

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
    ' "$KRESD_CONF" > "$tmpfile"
    local awk_rc=$?

    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 42 ]; then
            echo -e "${RED}Не удалось найти точки вставки в $KRESD_CONF.${NC}"
        else
            echo -e "${RED}Ошибка при патчинге $KRESD_CONF.${NC}"
        fi
        return 1
    fi

    if ! mv "$tmpfile" "$KRESD_CONF"; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось записать обновлённый $KRESD_CONF.${NC}"
        return 1
    fi

    chmod 644 "$KRESD_CONF"

    if ! systemctl restart kresd@1 kresd@2; then
        echo -e "${RED}Не удалось перезапустить kresd.${NC}"
        return 1
    fi

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
    return 0
}

doctor() {
    echo -e "${CYAN}==========================================${NC}"
    echo -e "        🩺 ${YELLOW}WARPER DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"

    local failed=0

    check_item() {
        local label="$1"
        local cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }

    check_item "AntiZapret установлен" "[ -x /root/antizapret/doall.sh ] && [ -f /root/antizapret/config/include-ips.txt ]"
    check_item "Файл конфигурации warper существует" "[ -f '$CONF_FILE' ]"
    check_item "Файл списка доменов существует" "[ -f '$MASTER_FILE' ]"
    check_item "Активный список доменов существует" "[ -f '$ACTIVE_FILE' ]"
    check_item "Конфиг sing-box существует" "[ -f '$SINGBOX_CONF' ]"
    check_item "Конфиг sing-box валиден" "validate_singbox_config"
    check_item "Служба sing-box активна" "systemctl is-active --quiet sing-box"
    check_item "Автозагрузка sing-box включена" "systemctl is-enabled --quiet sing-box"
    check_item "Автопатч warper включен" "systemctl is-enabled --quiet warper-autopatch"
    check_item "kresd.conf пропатчен" "grep -q 'WARP-MOD-START' '$KRESD_CONF'"
    check_item "Резервная копия kresd.conf существует" "[ -f '$KRESD_BACKUP' ]"
    check_item "Домены синхронизированы" "domains_in_sync"
    check_item "Подсеть $SUBNET есть в include-ips.txt" "grep -qF '$SUBNET' '$AZ_INC'"
    check_item "Интерфейс singbox-tun существует" "ip link show singbox-tun"
    check_item "Правило iptables FORWARD -o singbox-tun существует" "iptables -C FORWARD -o singbox-tun -j ACCEPT"
    check_item "Правило iptables FORWARD -i singbox-tun существует" "iptables -C FORWARD -i singbox-tun -j ACCEPT"

    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Диагностика завершена: проблем не обнаружено.${NC}"
        return 0
    else
        echo -e "${YELLOW}Диагностика завершена: обнаружены проблемы. Проверьте статусы выше.${NC}"
        return 1
    fi
}

toggle_warper() {
    local action="ВКЛЮЧИТЬ"
    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        action="ВЫКЛЮЧИТЬ"
    fi

    if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
        echo -e "\n${YELLOW}Вы уверены что хотите выключить warper? (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}Вы уверены что хотите включить warper? (Y/n)${NC}"
    fi

    read -r -e -p "Выбор: " conf
    if [[ -z "$conf" || "$conf" == "Y" || "$conf" == "y" ]]; then
        if [ "$action" == "ВЫКЛЮЧИТЬ" ]; then
            echo -e "${YELLOW}Отключение WARPER...${NC}"
            systemctl stop sing-box
            systemctl disable sing-box 2>/dev/null
            systemctl disable warper-autopatch 2>/dev/null
            remove_iptables_rule FORWARD -o singbox-tun
            remove_iptables_rule FORWARD -i singbox-tun
            unpatch_kresd || {
                echo -e "${RED}Ошибка при удалении патча DNS.${NC}"
                sleep 2
                return
            }
            echo -e "${GREEN}WARPER успешно отключен! Трафик идет по умолчанию.${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            if ! validate_singbox_config; then
                sleep 2
                return
            fi
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            if ! ensure_singbox_running; then
                sleep 2
                return
            fi
            systemctl enable warper-autopatch 2>/dev/null
            ensure_iptables_rule FORWARD -o singbox-tun
            ensure_iptables_rule FORWARD -i singbox-tun
            if ! patch_kresd >/dev/null 2>&1; then
                echo -e "${RED}Не удалось применить патч DNS.${NC}"
                sleep 2
                return
            fi
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi
}

toggle_list() {
    local list_name=$1
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден! Пожалуйста, обновите списки через меню.${NC}"
        sleep 2
        return
    fi

    local valid_tmp
    valid_tmp=$(mktemp /tmp/warper_valid_list.XXXXXX)
    filter_valid_domains_file "$list_file" "$valid_tmp"

    if grep -q "$marker" "$MASTER_FILE"; then
        sed -i "/$marker/,/$end_marker/d" "$MASTER_FILE"
        echo -e "${YELLOW}Домены ${list_name^^} выключены.${NC}"
    else
        if [ -s "$valid_tmp" ]; then
            local master_tmp
            master_tmp=$(mktemp /tmp/warper_master.XXXXXX)
            local in_block=false
            while IFS= read -r line; do
                if [[ "$line" =~ ^#\ ---\ .+\ ---$ ]] && [[ ! "$line" =~ END ]]; then
                    in_block=true
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                if [[ "$line" =~ ^#\ ---\ END\ .+\ ---$ ]]; then
                    in_block=false
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                if [ "$in_block" = true ]; then
                    echo "$line" >> "$master_tmp"
                    continue
                fi
                local clean_line normalized_line
                clean_line=$(echo "$line" | xargs)
                normalized_line=$(validate_domain "$clean_line" 2>/dev/null || true)
                if [ -n "$normalized_line" ] && grep -qxF "$normalized_line" "$valid_tmp"; then
                    continue
                fi
                echo "$line" >> "$master_tmp"
            done < "$MASTER_FILE"
            mv "$master_tmp" "$MASTER_FILE"
        fi

        echo "$marker" >> "$MASTER_FILE"
        cat "$valid_tmp" >> "$MASTER_FILE"
        echo "$end_marker" >> "$MASTER_FILE"
        echo -e "${GREEN}Домены ${list_name^^} включены.${NC}"
    fi

    rm -f "$valid_tmp"
    prompt_apply
}

update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        local marker="# --- ${list_name^^} ---"
        local end_marker="# --- END ${list_name^^} ---"
        local list_file="$DOWNLOAD_DIR/${list_name}.txt"

        if grep -q "$marker" "$MASTER_FILE"; then
            if [ ! -f "$list_file" ]; then
                echo -e "${RED}Файл $list_file не найден, пропускаем ${list_name}${NC}"
                continue
            fi

            local valid_tmp
            valid_tmp=$(mktemp /tmp/warper_update_list.XXXXXX)
            filter_valid_domains_file "$list_file" "$valid_tmp"

            sed -i "/$marker/,/$end_marker/d" "$MASTER_FILE"
            echo "$marker" >> "$MASTER_FILE"
            cat "$valid_tmp" >> "$MASTER_FILE"
            echo "$end_marker" >> "$MASTER_FILE"

            rm -f "$valid_tmp"
        fi
    done
}

update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"

    download_file_safe "$REPO_URL/warper.sh" "$WARPER_DIR/warper.sh" "warper.sh" || return 1
    download_file_safe "$REPO_URL/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" "uninstaller.sh" || return 1
    download_file_safe "$REPO_URL/sing-box.service" "/etc/systemd/system/sing-box.service" "sing-box.service" || return 1
    download_file_safe "$REPO_URL/warper-autopatch.service" "/etc/systemd/system/warper-autopatch.service" "warper-autopatch.service" || return 1
    download_file_safe "$REPO_URL/version" "$WARPER_DIR/version" "version" || return 1
    download_file_safe "$REPO_URL/config.json.template" "$SINGBOX_TEMPLATE" "config.json.template" || return 1
    download_file_safe "$REPO_URL/download/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" "gemini.txt" || return 1
    download_file_safe "$REPO_URL/download/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" "chatgpt.txt" || return 1

    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh"
    systemctl daemon-reload
    systemctl enable warper-autopatch >/dev/null 2>&1

    if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
        echo -e "${CYAN}Обновление конфигурации sing-box из шаблона...${NC}"
        if rebuild_config "$SINGBOX_TEMPLATE"; then
            systemctl restart sing-box
            if ensure_singbox_running; then
                echo -e "${GREEN}Служба sing-box перезапущена с обновлённым конфигом.${NC}"
            else
                echo -e "${YELLOW}Конфиг обновлён, но служба sing-box не запустилась корректно.${NC}"
            fi
        else
            echo -e "${YELLOW}Конфигурация sing-box не обновлена (ошибка извлечения ключей или валидации).${NC}"
        fi
    fi

    update_list_blocks

    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -r -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
}

settings_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "          ⚙️  ${YELLOW}НАСТРОЙКИ WARPER${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"

        local AP_STAT GEM_STAT GPT_STAT
        if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else AP_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if grep -q "# --- GEMINI ---" "$MASTER_FILE"; then GEM_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GEM_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi
        if grep -q "# --- CHATGPT ---" "$MASTER_FILE"; then GPT_STAT="${GREEN}ВКЛЮЧЕНО${NC}"; else GPT_STAT="${RED}ВЫКЛЮЧЕНО${NC}"; fi

        echo -e " ${CYAN}1.${NC} Автопатч DNS при перезагрузке:  [$AP_STAT]"
        echo -e " ${CYAN}2.${NC} Интеграция доменов Gemini:      [$GEM_STAT]"
        echo -e " ${CYAN}3.${NC} Интеграция доменов ChatGPT:     [$GPT_STAT]"
        echo -e " ${CYAN}4.${NC} Изменить фейковую подсеть:      [Текущая: $SUBNET]"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-4]: " set_choice
        case "${set_choice:-}" in
            1)
                if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then
                    systemctl disable warper-autopatch >/dev/null 2>&1
                    echo -e "${YELLOW}Автопатч отключен.${NC}"; sleep 1
                else
                    systemctl enable warper-autopatch >/dev/null 2>&1
                    echo -e "${GREEN}Автопатч включен.${NC}"; sleep 1
                fi
                ;;
            2) toggle_list "gemini" ;;
            3) toggle_list "chatgpt" ;;
            4)
                echo -e "\n${YELLOW}Внимание! Изменение подсети обновит конфигурации и перезапустит службы.${NC}"
                read -r -e -p "Вы уверены? [y/N]: " conf_sub
                if [[ "$conf_sub" == "y" || "$conf_sub" == "Y" ]]; then
                    while true; do
                        read -r -e -p "Введите новую подсеть (X.X.X.0/XX) или оставьте пустым для отмены: " new_subnet
                        if [ -z "$new_subnet" ]; then
                            echo -e "${YELLOW}Отмена.${NC}"; sleep 1; break
                        elif validate_subnet "$new_subnet"; then
                            local old_subnet old_tun new_tun
                            old_subnet="$SUBNET"
                            old_tun="$TUN_IP"
                            new_tun=$(calculate_tun_ip "$new_subnet")

                            SUBNET="$new_subnet"
                            TUN_IP="$new_tun"

                            if [ -f "$SINGBOX_TEMPLATE" ] && [ -s "$SINGBOX_TEMPLATE" ]; then
                                if ! rebuild_config "$SINGBOX_TEMPLATE"; then
                                    SUBNET="$old_subnet"
                                    TUN_IP="$old_tun"
                                    echo -e "${RED}Не удалось пересобрать конфиг sing-box.${NC}"
                                    sleep 2
                                    break
                                fi
                            else
                                sed -i "s|\"$old_subnet\"|\"$new_subnet\"|g" "$SINGBOX_CONF"
                                sed -i "s|\"$old_tun\"|\"$new_tun\"|g" "$SINGBOX_CONF"
                                if ! validate_singbox_config; then
                                    sed -i "s|\"$new_subnet\"|\"$old_subnet\"|g" "$SINGBOX_CONF"
                                    sed -i "s|\"$new_tun\"|\"$old_tun\"|g" "$SINGBOX_CONF"
                                    SUBNET="$old_subnet"
                                    TUN_IP="$old_tun"
                                    echo -e "${RED}Получился некорректный конфиг sing-box, откат выполнен.${NC}"
                                    sleep 2
                                    break
                                fi
                            fi

                            sed -i "\|$old_subnet|d" "$AZ_INC" 2>/dev/null
                            grep -qxF "$new_subnet" "$AZ_INC" 2>/dev/null || echo "$new_subnet" >> "$AZ_INC"

                            {
                                echo "SUBNET=$new_subnet"
                                echo "TUN_IP=$new_tun"
                            } > "$CONF_FILE"
                            chmod 600 "$CONF_FILE"

                            echo -e "${YELLOW}⏳ Обновление маршрутов AntiZapret (подождите)...${NC}"
                            export DEBIAN_FRONTEND=noninteractive
                            export SYSTEMD_PAGER=""
                            bash /root/antizapret/doall.sh </dev/null >/dev/null 2>&1

                            echo -e "${CYAN}Перезапуск службы sing-box для применения правил...${NC}"
                            systemctl restart sing-box
                            if ! ensure_singbox_running; then
                                echo -e "${RED}Служба sing-box не запустилась после смены подсети.${NC}"
                                sleep 2
                                break
                            fi

                            ensure_iptables_rule FORWARD -o singbox-tun
                            ensure_iptables_rule FORWARD -i singbox-tun

                            echo -e "${GREEN}Подсеть успешно изменена!${NC}"
                            sleep 2
                            break
                        else
                            echo -e "${RED}Некорректная подсеть! Ожидается формат X.X.X.0/XX с валидными октетами (0-255) и маской (1-32).${NC}"
                        fi
                    done
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
        if systemctl is-active --quiet sing-box; then echo -e "Текущий статус: ${GREEN}ЗАПУЩЕН 🟢${NC}"; else echo -e "Текущий статус: ${RED}ОСТАНОВЛЕН 🔴${NC}"; fi
        if systemctl is-enabled --quiet sing-box 2>/dev/null; then echo -e "Автозагрузка: ${GREEN}ВКЛЮЧЕНА${NC}"; else echo -e "Автозагрузка: ${RED}ВЫКЛЮЧЕНА${NC}"; fi
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} Запустить службу"
        echo -e " ${RED}2.${NC} Остановить службу"
        echo -e " ${GREEN}3.${NC} Включить в автозагрузку"
        echo -e " ${RED}4.${NC} Выключить из автозагрузки"
        echo -e " ${YELLOW}5.${NC} Посмотреть логи"
        echo -e " ${CYAN}0.${NC} Назад в главное меню"
        echo -e "${CYAN}==========================================${NC}"
        read -r -e -p "Выбор [0-5]: " sb_choice
        case "${sb_choice:-}" in
            1)
                if prompt_confirm; then
                    if ! validate_singbox_config; then
                        sleep 2
                        continue
                    fi
                    systemctl start sing-box
                    if ensure_singbox_running; then
                        echo -e "${GREEN}Запущено.${NC}"
                    fi
                    sleep 1
                fi
                ;;
            2)
                if prompt_confirm; then
                    systemctl stop sing-box
                    echo -e "${YELLOW}Остановлено.${NC}"
                    sleep 1
                fi
                ;;
            3)
                if prompt_confirm; then
                    systemctl enable sing-box
                    echo -e "${GREEN}Добавлено в автозапуск.${NC}"
                    sleep 1
                fi
                ;;
            4)
                if prompt_confirm; then
                    systemctl disable sing-box
                    echo -e "${YELLOW}Убрано из автозапуска.${NC}"
                    sleep 1
                fi
                ;;
            5) show_logs ;;
            0) return ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    local REMOTE_VER
    REMOTE_VER=$(get_remote_version)

    echo -e "${CYAN}==========================================${NC}"
    echo -e "       🚀 ${YELLOW}Панель управления Warper${NC} 🚀"
    echo -e "${CYAN}==========================================${NC}"

    local VER_STR SB_RUN SB_EN KR_STAT DOM_STAT AZ_STAT AP_STAT UPDATE_AVAILABLE
    UPDATE_AVAILABLE=false

    if version_gt "$REMOTE_VER" "$LOCAL_VER"; then
        VER_STR="${YELLOW}$LOCAL_VER (Доступно: $REMOTE_VER)${NC}"
        UPDATE_AVAILABLE=true
    else
        VER_STR="${GREEN}$LOCAL_VER (Актуальная)${NC}"
    fi

    if systemctl is-active --quiet sing-box; then SB_RUN="${GREEN}запущен${NC}"; else SB_RUN="${RED}выключен${NC}"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then SB_EN="${GREEN}включена автозагрузка${NC}"; else SB_EN="${RED}отключена автозагрузка${NC}"; fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then KR_STAT="${GREEN}пропатчен${NC}"; else KR_STAT="${RED}не пропатчен${NC}"; fi
    if domains_in_sync; then DOM_STAT="${GREEN}синхронизированы${NC}"; else DOM_STAT="${RED}не синхронизированы${NC}"; fi
    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then AZ_STAT="${GREEN}добавлена${NC}"; else AZ_STAT="${RED}не добавлена${NC}"; fi
    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then AP_STAT="${GREEN}включено${NC}"; else AP_STAT="${RED}отключено${NC}"; fi

    echo -e " - Версия: $VER_STR"
    echo -e " - Sing-box ($SB_RUN, $SB_EN)"
    echo -e " - Kresd.conf ($KR_STAT)"
    echo -e " - 📁 Домены: $MASTER_FILE ($DOM_STAT)"
    echo -e " - Fake подсеть $SUBNET в include-ips ($AZ_STAT)"
    echo -e " - Автовосстановление DNS ($AP_STAT)"

    echo -e "${CYAN}------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Добавить домен в WARP"
    echo -e " ${RED}2.${NC} Удалить домен из WARP"
    echo -e " ${YELLOW}3.${NC} Посмотреть список доменов"
    echo -e " ${CYAN}4.${NC} Отредактировать список (через nano)"
    echo -e " ${CYAN}5.${NC} 🔧 Пропатчить DNS / Синхронизация"
    echo -e " ${CYAN}6.${NC} ⚙️ Управление sing-box"
    echo -e " ${CYAN}7.${NC} 📄 Показать логи"
    echo -e " ${CYAN}D.${NC} 🩺 Диагностика (doctor)"

    if systemctl is-active --quiet sing-box || grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        echo -e " ${RED}8. ⏹ Отключить WARPER${NC}"
    else
        echo -e " ${GREEN}8. ▶ Включить WARPER${NC}"
    fi

    echo -e " ${CYAN}9. 🛠 Настройки (Автопатч, Подсеть, Списки)${NC}"

    if [ "$UPDATE_AVAILABLE" = true ]; then
        echo -e " ${YELLOW}10. ⚡ Обновить WARPER до $REMOTE_VER${NC}"
    else
        echo -e " ${CYAN}10.${NC} 🔄 Проверить и обновить списки доменов"
    fi

    echo -e " ${RED}U. Удалить warper полностью${NC}"
    echo -e " ${CYAN}0.${NC} Выход"
    echo -e "${CYAN}==========================================${NC}"

    MENU_UPDATE_AVAILABLE=$UPDATE_AVAILABLE
    MENU_REMOTE_VER=$REMOTE_VER
}

load_config

if [ "${1:-}" == "patch" ]; then
    patch_kresd >/dev/null 2>&1
    exit $?
fi

if [ "${1:-}" == "doctor" ]; then
    doctor
    exit $?
fi

MENU_UPDATE_AVAILABLE=false
MENU_REMOTE_VER="$LOCAL_VER"

while true; do
    show_main_menu
    read -r -e -p "Выбор: " choice

    choice=$(echo "${choice:-}" | tr -d ' ')

    case "$choice" in
        1)
            echo -e "\n${CYAN}Введите домен (например, openai.com):${NC}"
            read -r -e -p "> " raw_domain
            new_domain=$(validate_domain "${raw_domain:-}") || {
                echo -e "${RED}Некорректный формат домена! Домен должен содержать точку (например, openai.com).${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$new_domain" "$MASTER_FILE"; then
                echo -e "${YELLOW}Домен уже есть в списке!${NC}"
                sleep 1
            else
                echo "$new_domain" >> "$MASTER_FILE"
                echo -e "${GREEN}Домен '$new_domain' добавлен!${NC}"
                prompt_apply
            fi
            ;;
        2)
            echo -e "\n${CYAN}Введите домен для удаления:${NC}"
            read -r -e -p "> " raw_del_domain
            del_domain=$(validate_domain "${raw_del_domain:-}") || {
                echo -e "${RED}Некорректный формат домена!${NC}"
                sleep 2
                continue
            }
            if grep -qxF "$del_domain" "$MASTER_FILE"; then
                escaped=$(escape_regex "$del_domain")
                sed -i "/^${escaped}$/d" "$MASTER_FILE"
                echo -e "${GREEN}Домен '$del_domain' удалён!${NC}"
                prompt_apply
            else
                echo -e "${RED}Домен не найден в списке!${NC}"
                sleep 1
            fi
            ;;
        3)
            echo -e "\n${CYAN}--- Домены в WARP ---${NC}"
            if [ -s "$MASTER_FILE" ]; then cat "$MASTER_FILE"; else echo -e "${YELLOW}Список пуст.${NC}"; fi
            echo -e "${CYAN}---------------------${NC}"
            read -r -p "Нажмите Enter..."
            ;;
        4)
            nano "$MASTER_FILE"
            prompt_apply
            ;;
        5)
            echo -e "\n${YELLOW}Запуск синхронизации...${NC}"
            if patch_kresd; then
                echo -e "${GREEN}Готово!${NC}"
            else
                echo -e "${RED}Синхронизация завершилась с ошибкой.${NC}"
            fi
            sleep 1
            ;;
        6) singbox_menu ;;
        7) show_logs ;;
        8) toggle_warper ;;
        9) settings_menu ;;
        10)
            if [ "$MENU_UPDATE_AVAILABLE" = true ]; then
                update_warper
            else
                echo -e "\n${CYAN}Проверка обновлений списков...${NC}"
                mkdir -p "$DOWNLOAD_DIR"

                download_file_safe "$REPO_URL/download/gemini.txt" "/tmp/gemini.txt" "gemini.txt" || {
                    echo -e "${RED}Не удалось обновить gemini.txt${NC}"
                    sleep 2
                    continue
                }
                download_file_safe "$REPO_URL/download/chatgpt.txt" "/tmp/chatgpt.txt" "chatgpt.txt" || {
                    echo -e "${RED}Не удалось обновить chatgpt.txt${NC}"
                    rm -f /tmp/gemini.txt
                    sleep 2
                    continue
                }

                LISTS_CHANGED=false

                if ! cmp -s /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt" 2>/dev/null; then
                    mv /tmp/gemini.txt "$DOWNLOAD_DIR/gemini.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/gemini.txt
                fi

                if ! cmp -s /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt" 2>/dev/null; then
                    mv /tmp/chatgpt.txt "$DOWNLOAD_DIR/chatgpt.txt"
                    LISTS_CHANGED=true
                else
                    rm -f /tmp/chatgpt.txt
                fi

                if [ "$LISTS_CHANGED" = true ]; then
                    update_list_blocks
                    echo -e "${GREEN}Найдены новые домены! Списки успешно обновлены.${NC}"
                    prompt_apply
                else
                    echo -e "${GREEN}Версия и файлы актуальны, обновление не требуется.${NC}"
                    sleep 2
                fi
            fi
            ;;
        d|D)
            doctor
            read -r -p "Нажмите Enter..."
            ;;
        u|U)
            if [ -f "$WARPER_DIR/uninstaller.sh" ]; then
                exec bash "$WARPER_DIR/uninstaller.sh"
            else
                exec curl -fsSL "$REPO_URL/uninstaller.sh?t=$(date +%s)" | bash
            fi
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор.${NC}"
            sleep 1
            ;;
    esac
done