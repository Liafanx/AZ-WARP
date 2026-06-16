#!/bin/bash
# warper lib: diagnostics.sh
# Проверки состояния AntiZapret, WARPER и sing-box.
# Команды status и doctor. Вспомогательные проверки.
# Подключается через source из warper.sh

# ===== Проверки AntiZapret =====

# Проверяет: включён ли ANTIZAPRET_WARP=y в /root/antizapret/setup.
# При включённом ANTIZAPRET_WARP WARPER работать не может.
check_antizapret_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local az_warp
        az_warp=$(grep -E '^ANTIZAPRET_WARP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$az_warp" = "y" ]; then
            return 0
        fi
    fi
    return 1
}

# Проверяет: включён ли VPN_WARP=y в /root/antizapret/setup.
check_vpn_warp() {
    local setup_file="/root/antizapret/setup"
    if [ -f "$setup_file" ]; then
        local vpn_warp
        vpn_warp=$(grep -E '^VPN_WARP=' "$setup_file" 2>/dev/null \
            | cut -d'=' -f2 | tr -d '"'\''[:space:]')
        if [ "$vpn_warp" = "y" ]; then
            return 0
        fi
    fi
    return 1
}

# Проверяет: активны ли правила от up.sh AntiZapret
# (интерфейс warp или ip rule lookup 13335 при VPN_WARP=n).
check_warp_rules_active() {
    if ip link show warp >/dev/null 2>&1; then
        return 0
    fi
    if ip rule show 2>/dev/null | grep -q "lookup 13335"; then
        return 0
    fi
    return 1
}

# Проверяет: нужно ли выполнить down.sh + up.sh.
# Возвращает 0 если правила от up.sh активны при выключенном VPN/AZ WARP.
needs_down_sh() {
    if ! check_vpn_warp && ! check_antizapret_warp; then
        if check_warp_rules_active; then
            return 0
        fi
    fi
    return 1
}

# ===== Предупреждения =====

# Выводит предупреждение о необходимости перезапустить правила AntiZapret
show_down_sh_warning() {
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}⚠️  Обнаружены активные правила от AntiZapret WARP!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}VPN_WARP и ANTIZAPRET_WARP выключены, но правила${NC}"
    echo -e "${YELLOW}от предыдущего запуска up.sh ещё активны.${NC}"
    echo -e ""
    echo -e "${CYAN}Для корректной работы WARPER выполните последовательно:${NC}"
    echo -e "  ${GREEN}/root/antizapret/down.sh${NC}"
    echo -e "  ${GREEN}/root/antizapret/up.sh${NC}"
    echo -e ""
    echo -e "${YELLOW}Это перезапустит правила AntiZapret и позволит${NC}"
    echo -e "${YELLOW}WARPER использовать локальные ключи.${NC}"
    echo -e "${RED}================================================${NC}"
}

# Выводит предупреждение о конфликте с ANTIZAPRET_WARP=y
show_antizapret_warp_warning() {
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}⚠️  ANTIZAPRET_WARP=y включён!${NC}"
    echo -e "${RED}================================================${NC}"
    echo -e "${YELLOW}WARPER не может работать при включённом ANTIZAPRET_WARP,${NC}"
    echo -e "${YELLOW}так как встроенный WARP AntiZapret конфликтует с WARPER.${NC}"
    echo -e ""
    echo -e "${CYAN}Для использования WARPER:${NC}"
    echo -e "1. Установите ANTIZAPRET_WARP=n в /root/antizapret/setup"
    echo -e "2. Выполните: /root/antizapret/down.sh"
    echo -e "3. Выполните: /root/antizapret/up.sh"
    echo -e "4. Запустите: warper"
    echo -e "${RED}================================================${NC}"
}

# ===== Состояние WARPER =====

# Проверяет что WARPER полностью активен:
# sing-box запущен И kresd.conf пропатчен.
is_warper_active() {
    if systemctl is-active --quiet sing-box && \
       grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ===== Управление =====

# Предлагает применить изменения к DNS после редактирования доменов.
# Учитывает: ANTIZAPRET_WARP, needs_down_sh, is_warper_active.
prompt_apply() {
    if check_antizapret_warp; then
        echo -e "\n${RED}⚠️  ANTIZAPRET_WARP=y — изменения НЕ будут применены к DNS.${NC}"
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    if needs_down_sh; then
        show_down_sh_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    if ! is_warper_active; then
        echo -e "\n${YELLOW}WARPER выключен. Домены сохранены, но патч DNS не применяется.${NC}"
        echo -e "${CYAN}Синхронизация списка доменов...${NC}"
        sync_domains
        echo -e "${GREEN}Домены синхронизированы.${NC}"
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
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
        sync_domains
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

# Запрашивает подтверждение опасного действия (y/N)
prompt_confirm() {
    read -r -e -p "Вы уверены? [y/N] (по умолчанию N): " conf_choice
    if [[ "$conf_choice" == "y" || "$conf_choice" == "Y" ]]; then return 0
    else return 1; fi
}

# ===== Включение / выключение WARPER =====

# Переключает WARPER: включить или выключить.
# При включении: запускает sing-box, патчит kresd, синхронизирует IP-маршруты.
# При выключении: останавливает sing-box, удаляет патч, удаляет IP-маршруты.
toggle_warper() {

    if check_antizapret_warp; then
        show_antizapret_warp_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi
    
    if needs_down_sh; then
        show_down_sh_warning
        read -r -p "Нажмите Enter для продолжения..."
        return
    fi

    # Автоотключение FullVPN WARP-резолвинга при включённом VPN_WARP
    if [ "$FULLVPN_WARP_RESOLVE" = "y" ] && check_vpn_warp; then
        echo -e "${RED}FullVPN WARP-резолвинг несовместим с VPN_WARP=y. Автоматическое отключение.${NC}"
        unpatch_kresd_fullvpn
        FULLVPN_WARP_RESOLVE="n"
        save_main_config
    fi   
    
    check_and_sync_warp_keys || return

    local action="ВКЛЮЧИТЬ"
    if systemctl is-active --quiet sing-box || \
       grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        action="ВЫКЛЮЧИТЬ"
    fi

    if [ "$action" = "ВЫКЛЮЧИТЬ" ]; then
        echo -e "\n${YELLOW}Вы уверены что хотите выключить warper? (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}Вы уверены что хотите включить warper? (Y/n)${NC}"
    fi
    read -r -e -p "Выбор: " conf

    if [[ -z "$conf" || "$conf" == "Y" || "$conf" == "y" ]]; then
        if [ "$action" = "ВЫКЛЮЧИТЬ" ]; then
            echo -e "${YELLOW}Отключение WARPER...${NC}"
              # Фиксируем трафик текущей сессии
            traffic_finalize_session 2>/dev/null || true          
            systemctl stop sing-box
            systemctl disable sing-box 2>/dev/null
            systemctl disable warper-autopatch 2>/dev/null
            remove_iptables_rule FORWARD -o singbox-tun
            remove_iptables_rule FORWARD -i singbox-tun
            unpatch_kresd || {
                echo -e "${RED}Ошибка при удалении патча DNS.${NC}"
                sleep 2; return
            }

            # Удаляем IP-маршруты и ip rule
            if [ "$(count_ip_ranges)" -gt 0 ]; then
                remove_all_ip_routes || true
            fi

            # Удаляем экспорт в AntiZapret и обновляем маршруты
            if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
                echo -e "${CYAN}Удаление экспорта WARPER из AntiZapret...${NC}"
                rm -f "$AZ_WARPER_INCLUDE_IPS"
                export DEBIAN_FRONTEND=noninteractive
                export SYSTEMD_PAGER=""
                if bash /root/antizapret/doall.sh ip </dev/null >/dev/null 2>&1; then
                    echo -e "${GREEN}Маршруты AntiZapret обновлены.${NC}"
                else
                    echo -e "${YELLOW}Предупреждение: не удалось обновить маршруты AntiZapret.${NC}"
                fi
            fi

            echo -e "${GREEN}WARPER успешно отключен!${NC}"
        else
            echo -e "${YELLOW}Включение WARPER...${NC}"
            if ! validate_singbox_config; then sleep 2; return; fi
            systemctl enable sing-box 2>/dev/null
            systemctl start sing-box
            if ! ensure_singbox_running; then sleep 2; return; fi
            systemctl enable warper-autopatch 2>/dev/null
            ensure_iptables_rule FORWARD -o singbox-tun
            ensure_iptables_rule FORWARD -i singbox-tun
            if ! patch_kresd >/dev/null 2>&1; then
                echo -e "${RED}Не удалось применить патч DNS.${NC}"
                sleep 2; return
            fi
            if [ "$(count_ip_ranges)" -gt 0 ]; then
                echo -e "${CYAN}Синхронизация IP-маршрутов...${NC}"
                sync_ip_ranges || true
            fi
            echo -e "${GREEN}WARPER успешно включен!${NC}"
        fi
        sleep 2
    fi 
}

# ===== Версионирование =====

# Получает актуальную версию WARPER с GitHub.
# Кэширует результат на 5 минут. Валидирует формат X.Y.Z.
get_remote_version() {
    local now
    now=$(date +%s)
    if (( now - REMOTE_VER_TIME > 300 )) || [ -z "$REMOTE_VER_CACHE" ]; then
        local fetched
        fetched=$(curl -4 -sf --max-time 2 "$REPO_URL/version" | tr -d '\r\n')
        if [[ "$fetched" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            REMOTE_VER_CACHE="$fetched"
        else
            REMOTE_VER_CACHE="$LOCAL_VER"
        fi
        REMOTE_VER_TIME=$now
    fi
    echo "${REMOTE_VER_CACHE:-$LOCAL_VER}"
}

# ===== Команды doctor и status =====

# Выводит краткий статус всех компонентов WARPER в машиночитаемом формате.
status_cmd() {
    load_config
    load_slave_config

    local sb_run="" sb_en="" kr_stat="" dom_stat="" az_stat=""
    local ap_stat="" subnet_conflict="" log_level="" mtu=""
    local az_warp_stat="" warp_rules_stat=""

    if systemctl is-active --quiet sing-box; then sb_run="running"
    else sb_run="stopped"; fi

    if systemctl is-enabled --quiet sing-box 2>/dev/null; then sb_en="enabled"
    else sb_en="disabled"; fi

    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then kr_stat="patched"
    else kr_stat="not patched"; fi

    if domains_in_sync_cached; then dom_stat="synced"
    else dom_stat="not synced"; fi

    if grep -qF "$SUBNET" "$AZ_INC" 2>/dev/null; then az_stat="present"
    else az_stat="missing"; fi

    if systemctl is-enabled --quiet warper-autopatch 2>/dev/null; then ap_stat="enabled"
    else ap_stat="disabled"; fi

    if subnet_conflicts "$SUBNET"; then subnet_conflict="yes"
    else subnet_conflict="no"; fi

    if check_antizapret_warp; then az_warp_stat="ENABLED (conflict!)"
    else az_warp_stat="disabled"; fi

    if needs_down_sh; then warp_rules_stat="active (run down.sh + up.sh!)"
    else warp_rules_stat="ok"; fi

    log_level=$(get_log_level)
    mtu=$(get_mtu)

    echo "Version: $LOCAL_VER"
    echo "ANTIZAPRET_WARP: $az_warp_stat"
    echo "VPN_WARP: $(check_vpn_warp && echo "enabled" || echo "disabled")"
    echo "WARP rules from up.sh: $warp_rules_stat"
    echo "outbound mode: $CURRENT_OUTBOUND_MODE"

    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo "slave server: $SLAVE_SERVER:$SLAVE_PORT"
        echo "slave key: $SLAVE_PASSWORD"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        load_wg_config
        echo "wg endpoint: $WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT"
        echo "wg address: $WG_ADDRESS"
        if [ "$WG_CONF_FILE" = "manual" ] || [ -z "$WG_CONF_FILE" ]; then
            echo "wg source: manual"
        else
            echo "wg source: $WG_CONF_FILE"
        fi
    fi

    echo "sing-box: $sb_run"
    echo "sing-box autostart: $sb_en"
    echo "sing-box log level: $log_level"
    echo "sing-box MTU: $mtu"
    echo "kresd patch: $kr_stat"
    local fullvpn_resolve_status
    if [ "$FULLVPN_WARP_RESOLVE" = "y" ]; then
        if check_vpn_warp; then
            fullvpn_resolve_status="enabled (CONFLICT: VPN_WARP=y)"
        else
            fullvpn_resolve_status="enabled"
        fi
    else
        fullvpn_resolve_status="disabled"
    fi
    echo "FullVPN WARP resolve: $fullvpn_resolve_status"
    echo "domains: $dom_stat"
    echo "subnet in AntiZapret: $az_stat"
    echo "autopatch: $ap_stat"
    echo "subnet conflict: $subnet_conflict"
    echo "warp keys source: $([ -f "$WARP_SYSTEM_CONF" ] && echo "$WARP_SYSTEM_CONF" || echo "local")"

    local ip_count route_count ip_sync_stat
    ip_count=$(count_ip_ranges)
    route_count=$(count_tun_routes)
    if ip_ranges_in_sync; then ip_sync_stat="synced"
    else ip_sync_stat="not synced"; fi

    echo "ip ranges in file: $ip_count"
    echo "ip routes active: $route_count"
    echo "ip routes sync: $ip_sync_stat"
    echo "ip route mode: $IP_ROUTE_MODE"
    echo "ip export to AntiZapret: $IP_EXPORT_TO_ANTIZAPRET"

    # Трафик за сегодня
    local traffic_summary
    traffic_summary=$(traffic_today_summary 2>/dev/null || echo "нет данных")
    echo "traffic: $traffic_summary"
}

# Выполняет полную диагностику всех компонентов WARPER.
# Выводит ✔ / ✘ / ! для каждой проверки.
doctor() {
    load_config
    load_slave_config

    echo -e "${CYAN}==========================================${NC}"
    echo -e "        🩺 ${YELLOW}WARPER DOCTOR${NC}"
    echo -e "${CYAN}==========================================${NC}"

    local failed=0

    # Вспомогательная функция для проверки одного условия
    check_item() {
        local label="$1" cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            echo -e " ${GREEN}✔${NC} $label"
        else
            echo -e " ${RED}✘${NC} $label"
            failed=1
        fi
    }

    # ANTIZAPRET_WARP
    if check_antizapret_warp; then
        echo -e " ${RED}✘${NC} ANTIZAPRET_WARP=n (сейчас: ANTIZAPRET_WARP=y — WARPER не работает!)"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} ANTIZAPRET_WARP=n"
    fi

    # Правила от up.sh
    if needs_down_sh; then
        echo -e " ${RED}✘${NC} Правила от up.sh неактивны (сейчас: активны — выполните down.sh!)"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Правила от up.sh неактивны"
    fi
    
    # Проверка конфликта FullVPN WARP-резолвинга
    if [ "$FULLVPN_WARP_RESOLVE" = "y" ] && check_vpn_warp; then
        echo -e " ${RED}✘${NC} FullVPN WARP resolve: CONFLICT (VPN_WARP=y включён)"
        failed=1
    fi    

    # Режим маршрутизации
    load_wg_config
    if [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}!${NC} Режим: Slave ($SLAVE_SERVER:$SLAVE_PORT)"
    elif [ "$CURRENT_OUTBOUND_MODE" = "wg" ]; then
        echo -e " ${CYAN}!${NC} Режим: WG ($WG_ENDPOINT_HOST:$WG_ENDPOINT_PORT)"
    else
        echo -e " ${GREEN}✔${NC} Режим: WARP (локальный)"
    fi

    check_item "AntiZapret установлен" "[ -x /root/antizapret/doall.sh ]"
    check_item "Файл конфигурации warper существует" "[ -f '$CONF_FILE' ]"
    check_item "Файл списка доменов существует" "[ -f '$MASTER_FILE' ]"
    check_item "Активный список доменов существует" "[ -f '$ACTIVE_FILE' ]"
    check_item "Конфиг sing-box существует" "[ -f '$SINGBOX_CONF' ]"
    check_item "Конфиг sing-box валиден" "validate_singbox_config"
    check_item "Служба sing-box активна" "systemctl is-active --quiet sing-box"
    check_item "Автозагрузка sing-box включена" "systemctl is-enabled --quiet sing-box"
    check_item "Службы kresd активны" \
        "systemctl is-active --quiet kresd@1 && systemctl is-active --quiet kresd@2"
    check_item "Автопатч warper включен" "systemctl is-enabled --quiet warper-autopatch"
    check_item "kresd.conf пропатчен" "grep -q 'WARP-MOD-START' '$KRESD_CONF'"
    check_item "В kresd.conf ровно 1 WARP-блок" \
        "[ \"\$(grep -c 'WARP-MOD-START' '$KRESD_CONF' 2>/dev/null)\" -eq 1 ]"
    check_item "Права config.json ограничены" "file_mode_is_600 '$SINGBOX_CONF'"
    check_item "Права warper.conf ограничены" "file_mode_is_600 '$CONF_FILE'"
    check_item "Резервная копия kresd.conf существует" "[ -f '$KRESD_BACKUP' ]"
    check_item "Домены синхронизированы" "domains_in_sync"
    check_item "Подсеть $SUBNET в include-ips.txt" "grep -qF '$SUBNET' '$AZ_INC'"
    check_item "Интерфейс singbox-tun существует" "ip link show singbox-tun"
    check_item "iptables FORWARD -o singbox-tun" \
        "iptables -C FORWARD -o singbox-tun -j ACCEPT"
    check_item "iptables FORWARD -i singbox-tun" \
        "iptables -C FORWARD -i singbox-tun -j ACCEPT"

    if [ -f "$WGCF_DIR/wgcf-profile.conf" ]; then
        check_item "Права wgcf-profile.conf ограничены" \
            "file_mode_is_600 '$WGCF_DIR/wgcf-profile.conf'"
    fi

    # WARP-ключи
    if [ -f "$WARP_SYSTEM_CONF" ]; then
        echo -e " ${GREEN}✔${NC} Используются ключи из $WARP_SYSTEM_CONF"
    elif [ "$CURRENT_OUTBOUND_MODE" = "slave" ]; then
        echo -e " ${CYAN}!${NC} Режим Slave — WARP-ключи не используются"
    else
        echo -e " ${YELLOW}!${NC} Системный файл $WARP_SYSTEM_CONF не найден, используются локальные ключи"
    fi

    # IP-маршруты
    local ip_cnt route_cnt
    ip_cnt=$(count_ip_ranges)
    route_cnt=$(count_tun_routes)
    if [ "$ip_cnt" -gt 0 ] || [ "$route_cnt" -gt 0 ]; then
        echo -e " ${CYAN}!${NC} IP-подсетей в файле: $ip_cnt, маршрутов активно: $route_cnt"
        if ip_ranges_in_sync; then
            echo -e " ${GREEN}✔${NC} IP-маршруты синхронизированы"
        else
            echo -e " ${YELLOW}!${NC} IP-маршруты не синхронизированы (выполните warper ipsync)"
            failed=1
        fi
    fi

    # ip rule
    if [ "$ip_cnt" -gt 0 ]; then
        detect_client_subnets
        local rule_net
        rule_net=$(get_rule_source_net)
        if [ -n "$rule_net" ]; then
            if ip rule show 2>/dev/null | \
               grep -q "from ${rule_net} lookup ${IP_ROUTE_TABLE}"; then
                echo -e " ${GREEN}✔${NC} ip rule для ${rule_net} → table ${IP_ROUTE_TABLE} активно"
            else
                echo -e " ${RED}✘${NC} ip rule для ${rule_net} → table ${IP_ROUTE_TABLE} отсутствует"
                failed=1
            fi
        else
            echo -e " ${CYAN}!${NC} Режим IP-маршрутов: Весь трафик сервера (без ip rule)"
        fi
    fi

    # Экспорт в AntiZapret
    if [ "$IP_EXPORT_TO_ANTIZAPRET" = "y" ]; then
        if [ -f "$AZ_WARPER_INCLUDE_IPS" ]; then
            echo -e " ${GREEN}✔${NC} Экспорт WARPER CIDR в AntiZapret включён"
        else
            echo -e " ${YELLOW}!${NC} Экспорт в AntiZapret включён, но файл $AZ_WARPER_INCLUDE_IPS отсутствует"
            echo -e " Это нормально если не пользуетесь модулем IP подсети в Warper"
            failed=1
        fi
    else
        echo -e " ${CYAN}!${NC} Экспорт WARPER CIDR в AntiZapret выключен"
    fi

    # Конфликт fake-подсети
    if subnet_conflicts "$SUBNET"; then
        echo -e " ${YELLOW}!${NC} Возможный конфликт fake-подсети $SUBNET"
        failed=1
    else
        echo -e " ${GREEN}✔${NC} Конфликт fake-подсети не обнаружен"
    fi

    # Трафик
    local traffic_info
    traffic_info=$(traffic_today_summary 2>/dev/null || echo "нет данных")
    echo -e " ${CYAN}!${NC} Трафик: $traffic_info"

    echo -e "${CYAN}------------------------------------------${NC}"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Диагностика завершена: проблем не обнаружено.${NC}"
        return 0
    else
        echo -e "${YELLOW}Диагностика завершена: обнаружены проблемы.${NC}"
        return 1
    fi
}
