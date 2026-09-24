#!/bin/bash
# warper lib: wg.sh
# Управление WireGuard-режимом: поиск конфигов, парсинг,
# интерактивный выбор, ручной ввод, пересборка config.json.
# Подключается через source из warper.sh

# ===== Валидация WG-конфигов =====

# Проверяет что файл является валидным WG-конфигом,
# но НЕ является конфигом Cloudflare WARP.
# Требует: [Peer], Endpoint, PublicKey.
# Отклоняет: файлы с признаками Cloudflare WARP.
is_valid_wg_conf() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -q '^\[Peer\]' "$file" || return 1
    grep -q '^Endpoint' "$file" || return 1
    grep -q '^PublicKey' "$file" || return 1
    grep -q 'engage.cloudflareclient.com' "$file" 2>/dev/null && return 1
    grep -q '162.159.192.1' "$file" 2>/dev/null && return 1
    grep -q '162.159.193.1' "$file" 2>/dev/null && return 1
    grep -q 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' "$file" 2>/dev/null && return 1
    return 0
}

# ===== Парсинг =====

# Читает значение параметра из WG-конфига.
# Устойчив к отсутствию пробелов вокруг "=" и к inline-комментариям.
wg_conf_value() {
    local file="$1" key="$2"
    grep -m 1 -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//" \
        | tr -d '\r'
}

# Разбирает WG-конфиг и заполняет глобальные переменные WG_*.
# Обязательны: Address, PrivateKey, PublicKey, Endpoint.
# PresharedKey опционален (ProtonVPN и многие другие его не выдают).
# MTU и DNS подхватываются из файла, если заданы.
parse_wg_conf() {
    local file="$1"
    [ -f "$file" ] || return 1

    WG_CONF_FILE="$file"
    WG_PRIVATE_KEY=$(wg_conf_value "$file" "PrivateKey")
    WG_ADDRESS=$(wg_conf_value "$file" "Address")
    WG_ADDRESS=$(echo "${WG_ADDRESS%%,*}" | tr -d '[:space:]')
    WG_PUBLIC_KEY=$(wg_conf_value "$file" "PublicKey")
    WG_PRESHARED_KEY=$(wg_conf_value "$file" "PresharedKey")
    WG_MTU=$(wg_conf_value "$file" "MTU")
    WG_DNS=$(wg_conf_value "$file" "DNS")
    WG_DNS=$(echo "${WG_DNS%%,*}" | tr -d '[:space:]')

    local endpoint
    endpoint=$(wg_conf_value "$file" "Endpoint" | tr -d '[:space:]')
    if [[ "$endpoint" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        # IPv6 в квадратных скобках
        WG_ENDPOINT_HOST="${BASH_REMATCH[1]}"
        WG_ENDPOINT_PORT="${BASH_REMATCH[2]}"
    else
        WG_ENDPOINT_HOST="${endpoint%:*}"
        WG_ENDPOINT_PORT="${endpoint##*:}"
    fi

    local missing=()
    [ -z "$WG_ADDRESS" ]        && missing+=("Address")
    [ -z "$WG_PRIVATE_KEY" ]    && missing+=("PrivateKey")
    [ -z "$WG_PUBLIC_KEY" ]     && missing+=("PublicKey")
    [ -z "$WG_ENDPOINT_HOST" ]  && missing+=("Endpoint")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}В файле отсутствуют обязательные параметры: ${missing[*]}${NC}"
        return 1
    fi
    return 0
}

# Ищет валидные WG-конфиги в /root/ и /root/warper/.
# Возвращает список путей (по одному на строку).
scan_wg_configs() {
    local -a found_files=()
    local file
    for dir in /root /root/warper; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' file; do
                if is_valid_wg_conf "$file"; then
                    found_files+=("$file")
                fi
            done < <(find "$dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null)
        fi
    done

    if [ ${#found_files[@]} -gt 0 ]; then
        printf '%s\n' "${found_files[@]}"
    fi
}

# ===== Интерактивный выбор =====

# Показывает список найденных WG-конфигов и предлагает выбрать один.
# Поддерживает ручной ввод (M) и обновление списка (R).
# Сохраняет результат через save_wg_config().
select_wg_config() {
    local -a configs
    local choice

    while true; do
        echo -e "\n${CYAN}Поиск WireGuard-конфигов в /root/ и /root/warper/...${NC}"

        mapfile -t configs < <(scan_wg_configs)

        # Фильтруем пустые элементы без word splitting
        local filtered_configs=()
        local cfg_item
        for cfg_item in "${configs[@]}"; do
            [[ -n "$cfg_item" ]] && filtered_configs+=("$cfg_item")
        done
        configs=("${filtered_configs[@]+"${filtered_configs[@]}"}")

        if [ ${#configs[@]} -gt 0 ]; then
            echo -e "${GREEN}Найдено конфигов: ${#configs[@]}${NC}"
            echo -e ""
            local i=1
            for f in "${configs[@]}"; do
                local ep
                ep=$(grep -m 1 '^Endpoint' "$f" 2>/dev/null \
                    | awk -F'= ' '{print $2}' | tr -d ' \r\n')
                echo -e " ${GREEN}${i}.${NC} ${YELLOW}${f}${NC} (${CYAN}${ep}${NC})"
                ((i++))
            done
            echo -e ""
            echo -e " ${CYAN}M.${NC} Ввести данные вручную"
            echo -e " ${CYAN}R.${NC} Обновить список"
            echo -e " ${CYAN}0.${NC} Отмена"
            echo -e ""
            read -r -p "Выбор: " choice

            case "$choice" in
                0) return 1 ;;
                [0-9]*)
                    if (( choice >= 1 && choice <= ${#configs[@]} )); then
                        if parse_wg_conf "${configs[$((choice-1))]}"; then
                            save_wg_config
                            echo -e "${GREEN}Выбран: ${configs[$((choice-1))]}${NC}"
                            return 0
                        else
                            echo -e "${YELLOW}Выберите другой файл или введите данные вручную.${NC}"
                        fi
                    else
                        echo -e "${RED}Неверный номер.${NC}"
                    fi
                    ;;
                m|M) input_wg_manually; return $? ;;
                r|R)
                    echo -e "${CYAN}Повторный поиск...${NC}"
                    continue
                    ;;
                *) echo -e "${RED}Неверный выбор.${NC}" ;;
            esac
        else
            echo -e "${YELLOW}WireGuard-конфиги не найдены.${NC}"
            echo -e ""
            echo -e " ${GREEN}1.${NC} Ввести данные вручную"
            echo -e " ${CYAN}2.${NC} Положить .conf файл в /root/ или /root/warper/ и обновить"
            echo -e " ${CYAN}0.${NC} Отмена (выбрать другой режим)"
            echo -e ""
            read -r -p "Выбор: " choice

            case "$choice" in
                1) input_wg_manually; return $? ;;
                2)
                    echo -e "${YELLOW}Положите .conf файл и нажмите Enter...${NC}"
                    read -r -p ""
                    continue
                    ;;
                0) return 1 ;;
                *) echo -e "${RED}Неверный выбор.${NC}" ;;
            esac
        fi
    done
}

# Интерактивный ручной ввод всех параметров WG-соединения.
# Обязательные: Endpoint, Address, PrivateKey, PublicKey.
# Опциональные: PresharedKey, MTU, DNS, PersistentKeepalive (по умолчанию 15).
input_wg_manually() {
    echo -e "\n${CYAN}Ввод данных WireGuard вручную${NC}"

    while true; do
        read -r -p "Endpoint (IP:порт, например 1.2.3.4:51820): " ep_input
        if [[ "$ep_input" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
            WG_ENDPOINT_HOST="${ep_input%:*}"
            WG_ENDPOINT_PORT="${ep_input##*:}"
            break
        fi
        echo -e "${RED}Формат: IP:порт или домен:порт${NC}"
    done

    while true; do
        read -r -p "Address (например 172.28.8.3/32): " WG_ADDRESS
        [ -n "$WG_ADDRESS" ] && break
        echo -e "${RED}Address обязателен!${NC}"
    done

    while true; do
        read -r -p "PrivateKey: " WG_PRIVATE_KEY
        [ -n "$WG_PRIVATE_KEY" ] && break
        echo -e "${RED}PrivateKey обязателен!${NC}"
    done

    while true; do
        read -r -p "PublicKey (сервера): " WG_PUBLIC_KEY
        [ -n "$WG_PUBLIC_KEY" ] && break
        echo -e "${RED}PublicKey обязателен!${NC}"
    done

    read -r -p "PresharedKey (Enter — нет): " WG_PRESHARED_KEY

    read -r -p "MTU [1420]: " WG_MTU
    read -r -p "DNS [1.1.1.1]: " WG_DNS

    read -r -p "PersistentKeepalive [15]: " WG_KEEPALIVE
    WG_KEEPALIVE="${WG_KEEPALIVE:-15}"

    WG_CONF_FILE="manual"
    save_wg_config
    echo -e "${GREEN}Данные WG сохранены.${NC}"
    return 0
}

# ===== Пересборка конфигурации =====

# Пересобирает config.json для режима WG из шаблона config-wg.json.template.
# Загружает параметры из wg_mode.conf через load_wg_config().
# PresharedKey, MTU и DNS опциональны.
rebuild_config_wg() {
    load_wg_config

    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WG_PUBLIC_KEY" ] || [ -z "$WG_ENDPOINT_HOST" ]; then
        echo -e "${RED}Не настроены параметры WG-соединения!${NC}"
        return 1
    fi

    if [ ! -f "$WG_TEMPLATE" ]; then
        download_file_safe "$REPO_URL/templates/config-wg.json.template" \
            "$WG_TEMPLATE" "шаблон WG" || return 1
    fi

    local tmp
    tmp=$(mktemp)

    # Значения из импортированного конфига, иначе разумные умолчания
    local wg_mtu="${WG_MTU:-1420}" wg_dns="${WG_DNS:-1.1.1.1}"

    sed \
        -e "s|__SUBNET__|$SUBNET|g" \
        -e "s|__TUN_IP__|$TUN_IP|g" \
        -e "s|__WG_ADDRESS__|$WG_ADDRESS|g" \
        -e "s|__WG_PRIVATE_KEY__|$WG_PRIVATE_KEY|g" \
        -e "s|__WG_PUBLIC_KEY__|$WG_PUBLIC_KEY|g" \
        -e "s|__WG_PRESHARED_KEY__|$WG_PRESHARED_KEY|g" \
        -e "s|__WG_ENDPOINT_HOST__|$WG_ENDPOINT_HOST|g" \
        -e "s|__WG_ENDPOINT_PORT__|$WG_ENDPOINT_PORT|g" \
        -e "s|__WG_KEEPALIVE__|$WG_KEEPALIVE|g" \
        "$WG_TEMPLATE" > "$tmp"

    # pre_shared_key опционален: пустое значение sing-box не принимает,
    # поэтому строку убираем целиком
    if [ -z "$WG_PRESHARED_KEY" ]; then
        sed -i '/"pre_shared_key"/d' "$tmp"
    fi

    # MTU и DNS ставятся через jq: шаблон должен оставаться валидным JSON
    # для обновлятора 1.4.x, который про эти поля не знает
    local wg_tmp
    wg_tmp=$(mktemp)
    if ! jq --argjson mtu "$wg_mtu" --arg dns "$wg_dns" '
            .endpoints[0].mtu = $mtu
            | .dns.servers |= map(if .tag == "real-dns" then .server = $dns else . end)' \
            "$tmp" > "$wg_tmp"; then
        rm -f "$tmp" "$wg_tmp"
        echo -e "${RED}Некорректные MTU или DNS WG: $wg_mtu / $wg_dns${NC}" >&2
        return 1
    fi
    mv -f "$wg_tmp" "$tmp"

    if ! install_singbox_config "$tmp"; then
        echo -e "${RED}Ошибка валидации конфига WG!${NC}"
        return 1
    fi

    echo -e "${GREEN}Конфигурация sing-box (WG) успешно обновлена.${NC}"
    return 0
}
