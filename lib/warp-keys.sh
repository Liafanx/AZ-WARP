#!/bin/bash
# warper lib: warp-keys.sh
# Получение, синхронизация и управление WARP-ключами.
# Источники: /etc/wireguard/warp.conf, локальный wgcf-profile, конфиг sing-box.
# Подключается через source из warper.sh

# ===== Получение ключей =====

# Возвращает адрес и приватный ключ WARP из первого доступного источника.
# Порядок приоритета:
#   1. /etc/wireguard/warp.conf (системный, от AntiZapret VPN_WARP)
#   2. текущий config.json sing-box
#   3. /root/warper/wgcf/wgcf-profile.conf
get_warp_credentials() {
    local address="" private_key=""

    # Приоритет 1: системный warp.conf
    if [ -f "$WARP_SYSTEM_CONF" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WARP_SYSTEM_CONF" 2>/dev/null; then
        private_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        address=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$private_key" ]; then
            [ -z "$address" ] && address="172.16.0.2/32"
            [[ ! "$address" =~ / ]] && address="${address}/32"
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    # Приоритет 2: текущий config.json (через jq)
    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        address=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
        private_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
        if [ -n "$address" ] && [ -n "$private_key" ] && \
           [ "$address" != "__WARP_ADDRESS__" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    # Приоритет 2b: текущий config.json (fallback через grep)
    if [ -f "$SINGBOX_CONF" ] && grep -q '"tag": "warp"' "$SINGBOX_CONF" 2>/dev/null; then
        address=$(grep -o '"address": \[ "[^"]*"' "$SINGBOX_CONF" | head -1 \
            | sed 's/.*"\([^"]*\)".*/\1/' || true)
        private_key=$(grep -o '"private_key": "[^"]*"' "$SINGBOX_CONF" | head -1 \
            | sed 's/.*"\([^"]*\)".*/\1/' || true)
        if [ -n "$address" ] && [ -n "$private_key" ] && \
           [ "$address" != "__WARP_ADDRESS__" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    # Приоритет 3: локальный wgcf-profile.conf
    local wgcf_profile="$WGCF_DIR/wgcf-profile.conf"
    if [ -f "$wgcf_profile" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$wgcf_profile" 2>/dev/null; then
        address=$(grep -m 1 '^Address = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        private_key=$(grep -m 1 '^PrivateKey = ' "$wgcf_profile" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$address" ] && [ -n "$private_key" ]; then
            echo "$address"
            echo "$private_key"
            return 0
        fi
    fi

    return 1
}

# Определяет источник приватного ключа, который сейчас используется в sing-box.
# Сравнивает ключ из config.json с ключами из известных файлов.
get_current_warp_key_source() {
    local cur_pk=""
    local src="local"

    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    [ -z "$cur_pk" ] && { echo "$src"; return 0; }

    # Проверяем системный warp.conf
    if [ -f "$WARP_SYSTEM_CONF" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WARP_SYSTEM_CONF" 2>/dev/null; then
        local sys_pk=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null \
            | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ] && [ "$sys_pk" = "$cur_pk" ]; then
            echo "$WARP_SYSTEM_CONF"
            return 0
        fi
    fi

    # Проверяем локальный wgcf
    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        local wgcf_pk=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" \
            | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
            echo "$WGCF_DIR/wgcf-profile.conf"
            return 0
        fi
    fi

    # Проверяем /root/wgcf-profile.conf
    if [ -f "/root/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        local root_pk=""
        root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" \
            | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$root_pk" ] && [ "$root_pk" = "$cur_pk" ]; then
            echo "/root/wgcf-profile.conf"
            return 0
        fi
    fi

    echo "$src"
    return 0
}

# ===== Автосинхронизация =====

# При запуске warper проверяет: изменились ли ключи в системном warp.conf.
# Если да — предлагает переключиться на новые ключи (интерактивно)
# или переключает молча (в CLI-режиме).
# В slave/wg режиме — пропускает.
check_and_sync_warp_keys() {
    if needs_down_sh; then
        if is_interactive; then
            show_down_sh_warning
            read -r -p "Нажмите Enter для продолжения..."
        else
            echo "WARNING: Active WARP rules detected. Run: /root/antizapret/down.sh && /root/antizapret/up.sh" >&2
        fi
        return 1
    fi

    load_slave_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ] || [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        return 0
    fi

    if [ ! -f "$WARP_SYSTEM_CONF" ]; then
        return 0
    fi

    local sys_key="" sys_addr="" current_key="" current_addr=""
    sys_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')
    sys_addr=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" | awk -F'= ' '{print $2}' | tr -d ' \r\n')

    if [ -z "$sys_key" ] || [ -z "$sys_addr" ]; then
        return 0
    fi

    [[ ! "$sys_addr" =~ / ]] && sys_addr="${sys_addr}/32"

    if [ -f "$SINGBOX_CONF" ] && command -v jq >/dev/null 2>&1; then
        current_key=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
        current_addr=$(jq -r '.endpoints[] | select(.tag=="warp") | .address[0] // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    if [ "$sys_key" != "$current_key" ] || [ "$sys_addr" != "$current_addr" ]; then
        if is_interactive; then
            echo -e "${YELLOW}Обнаружены другие WARP-ключи в $WARP_SYSTEM_CONF.${NC}"
            echo -e "${CYAN}Текущие: ${current_addr:-n/a}${NC}"
            echo -e "${CYAN}Новые:   ${sys_addr}${NC}"
            read -r -p "Переключиться на ключи из $WARP_SYSTEM_CONF? (y/N): " sync_choice
            if [[ ! "$sync_choice" =~ ^[Yy]$ ]]; then
                return 0
            fi
        fi
        echo -e "${YELLOW}Синхронизация WARP-ключей...${NC}"
        if [ -f "$SINGBOX_TEMPLATE" ]; then
            local saved_mode="$CURRENT_OUTBOUND_MODE"
            CURRENT_OUTBOUND_MODE="warp"
            if rebuild_config "$SINGBOX_TEMPLATE"; then
                if systemctl is-active --quiet sing-box; then
                    systemctl restart sing-box
                    ensure_iptables_rule FORWARD -o singbox-tun
                    ensure_iptables_rule FORWARD -i singbox-tun
                fi
                systemctl restart kresd@1 >/dev/null 2>&1 || true
                echo -e "${GREEN}Ключи WARP синхронизированы.${NC}"
            fi
            CURRENT_OUTBOUND_MODE="$saved_mode"
        fi
    fi
}

# ===== Интерактивное управление ключами =====

# Меню управления WARP-ключами: выбор источника (системный/локальный/генерация).
# Доступно только в режиме WARP.
manage_warp_keys() {
    load_slave_config
    if [ "$CURRENT_OUTBOUND_MODE" != "warp" ]; then
        echo -e "${YELLOW}Управление WARP-ключами доступно только в режиме WARP.${NC}"
        sleep 2
        return
    fi

    echo -e "\n${CYAN}================================================${NC}"
    echo -e "       ${YELLOW}Управление WARP-ключами${NC}"
    echo -e "${CYAN}================================================${NC}"

    # Определяем текущий источник
    local current_source="неизвестно"
    local cur_pk=""
    if command -v jq >/dev/null 2>&1 && [ -f "$SINGBOX_CONF" ]; then
        cur_pk=$(jq -r '.endpoints[] | select(.tag=="warp") | .private_key // empty' \
            "$SINGBOX_CONF" 2>/dev/null || true)
    fi

    if [ -f "$WARP_SYSTEM_CONF" ]; then
        local sys_pk=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null \
            | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ] && [ "$sys_pk" = "$cur_pk" ]; then
            current_source="$WARP_SYSTEM_CONF"
        fi
    fi
    if [ "$current_source" = "неизвестно" ] && [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        local wgcf_pk=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" \
            | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ] && [ "$wgcf_pk" = "$cur_pk" ]; then
            current_source="$WGCF_DIR/wgcf-profile.conf"
        fi
    fi
    if [ "$current_source" = "неизвестно" ]; then
        current_source="конфиг sing-box"
    fi

    echo -e ""
    echo -e " ${CYAN}Текущий источник:${NC} ${YELLOW}${current_source}${NC}"
    echo -e ""

    # Строим список доступных источников
    local -a sources=()
    local -a source_labels=()
    local idx=1

    if [ -f "$WARP_SYSTEM_CONF" ]; then
        local sys_pk="" sys_addr=""
        sys_pk=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" 2>/dev/null \
            | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        sys_addr=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" 2>/dev/null \
            | awk -F'= ' '{print $2}' | tr -d ' \r\n')
        if [ -n "$sys_pk" ]; then
            sources+=("system")
            source_labels+=("$WARP_SYSTEM_CONF (${sys_addr:-без адреса}) — рекомендуется")
            echo -e " ${GREEN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$WGCF_DIR/wgcf-profile.conf" 2>/dev/null; then
        local wgcf_pk="" wgcf_addr=""
        wgcf_pk=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        wgcf_addr=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$wgcf_pk" ]; then
            sources+=("wgcf")
            source_labels+=("$WGCF_DIR/wgcf-profile.conf ($wgcf_addr)")
            echo -e " ${CYAN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    if [ -f "/root/wgcf-profile.conf" ] && \
       grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "/root/wgcf-profile.conf" 2>/dev/null; then
        local root_pk="" root_addr=""
        root_pk=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        root_addr=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" | awk '{print $3}' | tr -d '\r\n')
        if [ -n "$root_pk" ]; then
            sources+=("root")
            source_labels+=("/root/wgcf-profile.conf ($root_addr)")
            echo -e " ${CYAN}${idx}.${NC} ${source_labels[$((idx-1))]}"
            ((idx++))
        fi
    fi

    sources+=("generate")
    source_labels+=("Сгенерировать новый ключ WARP")
    echo -e " ${YELLOW}${idx}.${NC} ${source_labels[$((idx-1))]}"
    ((idx++))

    echo -e " ${CYAN}0.${NC} Отмена"
    echo -e ""

    read -r -p "Выбор: " key_choice

    if [ "$key_choice" = "0" ] || [ -z "$key_choice" ]; then
        return
    fi

    if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || \
       (( key_choice < 1 || key_choice > ${#sources[@]} )); then
        echo -e "${RED}Неверный выбор.${NC}"
        sleep 1
        return
    fi

    local selected="${sources[$((key_choice-1))]}"
    local new_address="" new_private_key=""

    case "$selected" in
        system)
            new_private_key=$(grep -m 1 '^PrivateKey' "$WARP_SYSTEM_CONF" \
                | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            new_address=$(grep -m 1 '^Address' "$WARP_SYSTEM_CONF" \
                | awk -F'= ' '{print $2}' | tr -d ' \r\n')
            [ -z "$new_address" ] && new_address="172.16.0.2/32"
            [[ ! "$new_address" =~ / ]] && new_address="${new_address}/32"
            echo -e "${CYAN}Используем ключи из $WARP_SYSTEM_CONF${NC}"
            ;;
        wgcf)
            new_private_key=$(grep -m 1 '^PrivateKey = ' "$WGCF_DIR/wgcf-profile.conf" \
                | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' "$WGCF_DIR/wgcf-profile.conf" \
                | awk '{print $3}' | tr -d '\r\n')
            echo -e "${CYAN}Используем ключи из $WGCF_DIR/wgcf-profile.conf${NC}"
            ;;
        root)
            new_private_key=$(grep -m 1 '^PrivateKey = ' "/root/wgcf-profile.conf" \
                | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' "/root/wgcf-profile.conf" \
                | awk '{print $3}' | tr -d '\r\n')
            echo -e "${CYAN}Используем ключи из /root/wgcf-profile.conf${NC}"
            ;;
        generate)
            echo -e "${YELLOW}Генерация нового ключа WARP...${NC}"
            mkdir -p "$WGCF_DIR"
            cd "$WGCF_DIR" || { echo -e "${RED}Ошибка перехода в $WGCF_DIR${NC}"; return 1; }

            if [ ! -f "/usr/local/bin/wgcf" ]; then
                local sys_arch
                sys_arch=$(uname -m)
                case "$sys_arch" in
                    x86_64)  sys_arch="amd64" ;;
                    aarch64) sys_arch="arm64" ;;
                    armv7l)  sys_arch="armv7" ;;
                    *) echo -e "${RED}Неподдерживаемая архитектура.${NC}"; return 1 ;;
                esac
                echo -e " - ${CYAN}Скачивание wgcf...${NC}"
                if ! wget -qO wgcf \
                    "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${sys_arch}"; then
                    echo -e "${RED}Ошибка загрузки wgcf!${NC}"
                    return 1
                fi
                chmod +x wgcf
                mv wgcf /usr/local/bin/wgcf
            fi

            echo -e " - ${CYAN}Регистрация WARP...${NC}"
            /usr/local/bin/wgcf register --accept-tos > /dev/null 2>&1
            /usr/local/bin/wgcf generate > /dev/null 2>&1

            if [ ! -f "wgcf-profile.conf" ]; then
                echo -e "${RED}Ошибка: wgcf-profile.conf не создан!${NC}"
                echo -e "${YELLOW}Cloudflare мог заблокировать регистрацию с этого IP.${NC}"
                return 1
            fi

            chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true
            new_private_key=$(grep -m 1 '^PrivateKey = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            new_address=$(grep -m 1 '^Address = ' wgcf-profile.conf | awk '{print $3}' | tr -d '\r\n')
            echo -e "${GREEN}Новый ключ WARP сгенерирован!${NC}"
            ;;
    esac

    if [ -z "$new_private_key" ] || [ -z "$new_address" ]; then
        echo -e "${RED}Не удалось получить ключи.${NC}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}Пересборка конфигурации...${NC}"

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

    if ! validate_singbox_config; then
        echo -e "${RED}Ошибка валидации! Откат...${NC}"
        return 1
    fi

    if restart_singbox_full; then
        echo -e "${GREEN}WARP-ключи успешно обновлены!${NC}"
    else
        echo -e "${RED}Ошибка перезапуска sing-box.${NC}"
    fi
    sleep 2
}
