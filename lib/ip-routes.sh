#!/bin/bash
# warper lib: ip-routes.sh
# Маршрутизация по IP-подсетям (CIDR):
# управление ip-ranges.txt, синхронизация с kernel routes,
# policy routing (ip rule + table 100), ipset antizapret-forward,
# экспорт в AntiZapret через warper-include-ips.txt.
# Подключается через source из warper.sh

# ===== Чтение и запись =====

# Читает валидные CIDR из ip-ranges.txt (без комментариев и пустых строк).
# Сортирует лексикографически для совместимости с comm.
extract_ip_ranges() {
    local file="${1:-$IP_RANGES_FILE}"
    [ -f "$file" ] || return 0
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$file" | while IFS= read -r line; do
        local trimmed
        trimmed=$(echo "$line" | tr -d '[:space:]')
        if validate_cidr "$trimmed" >/dev/null 2>&1; then
            echo "$trimmed"
        fi
    done
}

# Читает последнее применённое состояние маршрутов из ip-ranges.applied.
# Используется для вычисления diff при синхронизации.
get_applied_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    [ -f "$applied_file" ] || return 0
    cat "$applied_file"
}

# Сохраняет текущее желаемое состояние в ip-ranges.applied.
# Вызывается после успешной синхронизации.
save_applied_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    local _raw_tmp
    _raw_tmp=$(mktemp)
    extract_ip_ranges > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$applied_file"
    rm -f "$_raw_tmp"
}

# ===== Чтение реальных маршрутов ядра =====

# Читает реально применённые WARPER-маршруты из ядра Linux.
# В режиме policy routing — из table 100.
# В режиме "all" — из main table, исключая fake-подсеть WARPER.
get_current_kernel_ip_routes() {
    local source_net
    source_net=$(get_rule_source_net)

    local raw_routes
    if [ -z "$source_net" ]; then
        raw_routes=$(ip route show dev singbox-tun 2>/dev/null | awk '{print $1}')
    else
        raw_routes=$(ip route show table "$IP_ROUTE_TABLE" dev singbox-tun 2>/dev/null | awk '{print $1}')
    fi

    echo "$raw_routes" | while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        [ "$cidr" = "$SUBNET" ] && continue
        # Ядро Linux отбрасывает /32 при отображении — добавляем обратно
        [[ "$cidr" =~ / ]] || cidr="${cidr}/32"
        echo "$cidr"
    done
}

# Алиас для get_current_kernel_ip_routes.
# Используется в меню для отображения активных маршрутов.
get_current_tun_routes() {
    get_current_kernel_ip_routes
}

# ===== Счётчики =====

# Возвращает количество подсетей в ip-ranges.txt
count_ip_ranges() {
    local _raw_tmp _count
    _raw_tmp=$(mktemp)
    extract_ip_ranges > "$_raw_tmp"
    _count=$(LC_ALL=C sort -u "$_raw_tmp" | wc -l | tr -d ' ')
    rm -f "$_raw_tmp"
    echo "$_count"
}

# Возвращает количество подсетей в ip-ranges.applied
count_applied_routes() {
    local _raw_tmp _count
    _raw_tmp=$(mktemp)
    get_applied_ip_routes > "$_raw_tmp"
    _count=$(LC_ALL=C sort -u "$_raw_tmp" | wc -l | tr -d ' ')
    rm -f "$_raw_tmp"
    echo "$_count"
}

# Алиас для count_applied_routes.
# Используется в меню для отображения "маршрутов активно".
count_tun_routes() {
    count_applied_routes
}

# ===== Статус синхронизации =====

# Проверяет: совпадает ли желаемое состояние (ip-ranges.txt)
# с реальными kernel routes. Возвращает 0 если синхронизировано.
ip_ranges_in_sync() {
    local desired_tmp kernel_tmp _raw_tmp
    desired_tmp=$(mktemp)
    kernel_tmp=$(mktemp)
    _raw_tmp=$(mktemp)

    extract_ip_ranges > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$desired_tmp"

    get_current_kernel_ip_routes > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$kernel_tmp"

    rm -f "$_raw_tmp"

    cmp -s "$desired_tmp" "$kernel_tmp"
    local result=$?

    rm -f "$desired_tmp" "$kernel_tmp"
    return $result
}

# ===== Добавление / удаление из файла =====

# Добавляет CIDR в ip-ranges.txt с валидацией.
# Не добавляет дубликаты и fake-подсеть WARPER.
add_ip_range() {
    local raw="$1"
    local cidr
    cidr=$(validate_cidr "$raw") || {
        echo -e "${RED}Некорректный формат CIDR: $raw${NC}"
        echo -e "${YELLOW}Ожидается: A.B.C.D/M (например 91.108.4.0/22 или 5.255.255.242/32)${NC}"
        return 1
    }

    if [ "$cidr" = "$SUBNET" ]; then
        echo -e "${RED}Нельзя добавить fake-подсеть WARPER ($SUBNET)!${NC}"
        return 1
    fi

    # Проверка дубликата — ищем точную строку с CIDR (без пробелов вокруг)
    if grep -qE "^[[:space:]]*${cidr}[[:space:]]*$" "$IP_RANGES_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Подсеть $cidr уже есть в списке.${NC}"
        return 0
    fi

    # Просто дописываем в конец файла - комментарии и форматирование не трогаем
    echo "$cidr" >> "$IP_RANGES_FILE"
    echo -e "${GREEN}Подсеть $cidr добавлена.${NC}"
    return 0
}

# Удаляет CIDR из ip-ranges.txt с валидацией.
remove_ip_range() {
    local raw="$1"
    local cidr
    cidr=$(validate_cidr "$raw") || {
        echo -e "${RED}Некорректный формат CIDR: $raw${NC}"
        return 1
    }

    if ! grep -qE "^[[:space:]]*${cidr}[[:space:]]*$" "$IP_RANGES_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Подсеть $cidr не найдена в списке.${NC}"
        return 0
    fi

    # Удаляем только строку с этим CIDR, комментарии не трогаем
    local escaped
    escaped=$(echo "$cidr" | sed 's/[][\\/.^$*+?(){}|]/\\&/g')
    sed -i "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$IP_RANGES_FILE"
    echo -e "${GREEN}Подсеть $cidr удалена из списка.${NC}"
    return 0
}

# ===== Policy routing =====

# Возвращает source-подсеть для ip rule на основе текущего IP_ROUTE_MODE.
# antizapret → AZ_CLIENT_NET
# all_vpn    → ALL_CLIENT_NET
# all        → "" (пустая строка = без ip rule, main table)
get_rule_source_net() {
    detect_client_subnets
    case "$IP_ROUTE_MODE" in
        antizapret) echo "$AZ_CLIENT_NET" ;;
        all_vpn)    echo "$ALL_CLIENT_NET" ;;
        all)        echo "" ;;
        *)          echo "$AZ_CLIENT_NET" ;;
    esac
}

# Добавляет ip rule если он ещё не существует.
# Связывает source-подсеть с таблицей маршрутизации WARPER.
ensure_ip_rule() {
    local source_net="$1"
    [ -z "$source_net" ] && return 0
    if ! ip rule show 2>/dev/null | grep -q "from ${source_net} lookup ${IP_ROUTE_TABLE}"; then
        ip rule add from "$source_net" lookup "$IP_ROUTE_TABLE" \
            priority "$IP_ROUTE_PRIO" 2>/dev/null || true
    fi
}

# Удаляет ip rule для указанной source-подсети.
remove_ip_rule() {
    local source_net="$1"
    [ -z "$source_net" ] && return 0
    while ip rule show 2>/dev/null | grep -q "from ${source_net} lookup ${IP_ROUTE_TABLE}"; do
        ip rule del from "$source_net" lookup "$IP_ROUTE_TABLE" \
            priority "$IP_ROUTE_PRIO" 2>/dev/null || break
    done
}

# Удаляет все ip rule созданные WARPER для всех возможных source-подсетей.
# Вызывается при смене режима, выключении WARPER и деинсталляции.
remove_all_ip_rules() {
    detect_client_subnets
    remove_ip_rule "$AZ_CLIENT_NET"
    remove_ip_rule "$ALL_CLIENT_NET"
    for prefix in 10 172; do
        remove_ip_rule "${prefix}.29.0.0/16"
        remove_ip_rule "${prefix}.28.0.0/15"
    done
}

# ===== Основная синхронизация =====

# Синхронизирует ip-ranges.txt с реальными kernel routes.
# Алгоритм:
#   desired = extract_ip_ranges()
#   kernel  = get_current_kernel_ip_routes()
#   applied = get_applied_ip_routes()
#   add_tmp = desired - kernel  (добавить в ядро)
#   del_tmp = applied - desired (удалить из ядра как WARPER-owned)
# Также синхронизирует ipset antizapret-forward и экспорт в AntiZapret.
sync_ip_ranges() {
    if ! ip link show singbox-tun >/dev/null 2>&1; then
        echo -e "${RED}Интерфейс singbox-tun не найден. Sing-box запущен?${NC}"
        return 1
    fi

    detect_client_subnets

    local desired_tmp applied_tmp kernel_tmp add_tmp del_tmp
    desired_tmp=$(mktemp)
    applied_tmp=$(mktemp)
    kernel_tmp=$(mktemp)
    add_tmp=$(mktemp)
    del_tmp=$(mktemp)

    # Принудительная сортировка всех трёх источников одним методом
    local _raw_tmp
    _raw_tmp=$(mktemp)

    extract_ip_ranges > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$desired_tmp"

    get_applied_ip_routes > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$applied_tmp"

    get_current_kernel_ip_routes > "$_raw_tmp"
    LC_ALL=C sort -u "$_raw_tmp" > "$kernel_tmp"

    rm -f "$_raw_tmp"

    # Что добавить: есть в файле, нет в kernel
    LC_ALL=C comm -23 "$desired_tmp" "$kernel_tmp" > "$add_tmp"

    # Что удалить: было применено WARPER, но уже удалено из файла
    LC_ALL=C comm -23 "$applied_tmp" "$desired_tmp" > "$del_tmp"

    local added=0 removed=0 errors=0
    local source_net
    source_net=$(get_rule_source_net)

    local use_ipset=false
    if command -v ipset >/dev/null 2>&1 && \
       ipset list antizapret-forward >/dev/null 2>&1; then
        use_ipset=true
    fi

    # Чистим stale routes из предыдущего режима
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        if [ -z "$source_net" ]; then
            # Сейчас main table — удаляем старые из table 100
            ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null || true
        else
            # Сейчас table 100 — удаляем старые из main и table 13335
            ip route del "$cidr" dev singbox-tun 2>/dev/null || true
            ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
        fi
    done < "$applied_tmp"

    # Удаляем лишние маршруты (были в applied, удалены из файла)
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue
        ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun 2>/dev/null || true
        ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
        ((removed+=1))

        if [ "$use_ipset" = true ]; then
            ipset del antizapret-forward "$cidr" 2>/dev/null || true
        fi
    done < "$del_tmp"

    # Добавляем недостающие маршруты
    while IFS= read -r cidr; do
        [ -z "$cidr" ] && continue

        if [ -z "$source_net" ]; then
            # Режим "all/server" — main table
            if ip route replace "$cidr" dev singbox-tun 2>/dev/null; then
                ((added+=1))
            else
                echo -e "${YELLOW}Не удалось добавить маршрут: $cidr${NC}"
                ((errors+=1))
            fi
            # При VPN_WARP=y — добавляем ещё и в table 13335
            if ip route show table 13335 2>/dev/null | grep -q "dev"; then
                ip route replace "$cidr" dev singbox-tun table 13335 2>/dev/null || true
            fi
        else
            # Режим policy routing — отдельная таблица
            if ip route replace "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null; then
                ((added+=1))
            else
                echo -e "${YELLOW}Не удалось добавить маршрут: $cidr${NC}"
                ((errors+=1))
            fi
        fi
    done < "$add_tmp"

    # Управляем ip rule
    local total
    total=$(wc -l < "$desired_tmp" | tr -d ' ')

    if [ "$total" -gt 0 ] && [ -n "$source_net" ]; then
        remove_all_ip_rules
        ensure_ip_rule "$source_net"
    elif [ "$total" -eq 0 ]; then
        remove_all_ip_rules
    fi

    # ipset: добавляем ВСЕ желаемые CIDR (не только новые).
    # Важно при перезагрузке ipset через doall.sh / up.sh.
    if [ "$use_ipset" = true ]; then
        while IFS= read -r cidr; do
            [ -z "$cidr" ] && continue
            ipset add antizapret-forward "$cidr" -exist 2>/dev/null || true
        done < "$desired_tmp"
    fi

    # Сохраняем applied-state
    save_applied_ip_routes

    # Экспорт в AntiZapret если включён
    sync_ip_ranges_to_antizapret || true

    rm -f "$desired_tmp" "$applied_tmp" "$kernel_tmp" "$add_tmp" "$del_tmp"

    if (( added == 0 && removed == 0 )); then
        echo -e "${GREEN}IP-маршруты синхронизированы (${total} подсетей, изменений нет).${NC}"
    else
        echo -e "${GREEN}IP-маршруты синхронизированы: +${added} -${removed} (всего ${total}).${NC}"
    fi

    if [ "$use_ipset" = true ]; then
        echo -e "${CYAN}antizapret-forward синхронизирован.${NC}"
    fi

    if [ -n "$source_net" ]; then
        echo -e "${CYAN}Режим: ${IP_ROUTE_MODE} (source: ${source_net})${NC}"
    else
        echo -e "${CYAN}Режим: Весь трафик сервера (Beta)${NC}"
    fi

    if (( errors > 0 )); then
        echo -e "${YELLOW}Ошибок: ${errors}${NC}"
        return 1
    fi
    return 0
}

# Удаляет все WARPER-маршруты из ядра и очищает ip-ranges.applied.
# Вызывается при выключении WARPER и деинсталляции.
remove_all_ip_routes() {
    local applied_file="$WARPER_DIR/ip-ranges.applied"
    local removed=0

    local use_ipset=false
    if command -v ipset >/dev/null 2>&1 && \
       ipset list antizapret-forward >/dev/null 2>&1; then
        use_ipset=true
    fi

    if [ -f "$applied_file" ]; then
        while IFS= read -r cidr; do
            [ -z "$cidr" ] && continue
            ip route del "$cidr" dev singbox-tun table "$IP_ROUTE_TABLE" 2>/dev/null && ((removed+=1))
            ip route del "$cidr" dev singbox-tun 2>/dev/null && ((removed+=1))
            ip route del "$cidr" dev singbox-tun table 13335 2>/dev/null || true
            if [ "$use_ipset" = true ]; then
                ipset del antizapret-forward "$cidr" 2>/dev/null || true
            fi
        done < "$applied_file"
        : > "$applied_file"
    fi

    remove_all_ip_rules
    echo -e "${GREEN}Удалено маршрутов: ${removed}${NC}"
}

# ===== Интеграция с AntiZapret =====

# Создаёт файл warper-include-ips.txt с текущими CIDR из ip-ranges.txt.
# Файл автоматически подхватывается AntiZapret через config/*include-ips.txt.
render_antizapret_include_ips_file() {
    local output_file="$1"
    {
        cat << 'EOF'
# Добавлено WARPER
# Этот файл автоматически создаётся WARPER.
# Не редактируйте его вручную — изменения будут перезаписаны.
#
# CIDR из этого файла попадают в AntiZapret route-ips через parse.sh,
# потому что AntiZapret читает config/*include-ips.txt.
EOF
        extract_ip_ranges
    } > "$output_file"
}

# Синхронизирует экспорт CIDR в AntiZapret.
# Если IP_EXPORT_TO_ANTIZAPRET=y:
#   - создаёт warper-include-ips.txt
#   - запускает doall.sh ip (только если файл изменился)
# Если IP_EXPORT_TO_ANTIZAPRET=n:
#   - удаляет warper-include-ips.txt и запускает doall.sh ip
sync_ip_ranges_to_antizapret() {
    local changed=0
    local tmp
    tmp=$(mktemp)

    if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
        render_antizapret_include_ips_file "$tmp"
        if [ ! -f "$AZ_WARPER_INCLUDE_IPS" ] || \
           ! cmp -s "$tmp" "$AZ_WARPER_INCLUDE_IPS"; then
            mv "$tmp" "$AZ_WARPER_INCLUDE_IPS"
            changed=1
        else
            rm -f "$tmp"
        fi
    else
        rm -f "$tmp"
        if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
            rm -f "$AZ_WARPER_INCLUDE_IPS"
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        echo -e "${CYAN}Обновление маршрутов AntiZapret (doall.sh ip)...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        export SYSTEMD_PAGER=""
        if bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1; then
            echo -e "${GREEN}AntiZapret маршруты обновлены.${NC}"
            echo -e "${YELLOW}Для части клиентов может потребоваться переподключение.${NC}"
        else
            echo -e "${RED}Не удалось обновить маршруты AntiZapret через doall.sh ip${NC}"
            return 1
        fi
    fi

    return 0
}
