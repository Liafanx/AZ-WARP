#!/bin/bash
# warper lib: kresd.sh
# Управление конфигурацией DNS-резолвера kresd:
# патчинг, восстановление из backup, применение WARP-блока.
# Подключается через source из warper.sh

# ===== Backup =====

# Создаёт резервную копию kresd.conf перед первым патчингом.
# Повторно не перезаписывает если backup уже существует.
backup_kresd() {
    if [ -f "$KRESD_CONF" ] && [ ! -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_CONF" "$KRESD_BACKUP" || return 1
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi
    return 0
}

# Восстанавливает kresd.conf из резервной копии и перезапускает kresd
restore_kresd_backup() {
    if [ -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_BACKUP" "$KRESD_CONF" || return 1
        chmod 644 "$KRESD_CONF" 2>/dev/null || true
        systemctl restart kresd@1 kresd@2 || return 1
        return 0
    fi
    return 1
}

# ===== Патчинг =====

# Вставляет WARP-блок в kresd.conf для kresd@1.
# Блок читает warper-domains.txt и направляет DNS-запросы
# для этих доменов на 127.0.0.1:40000 (sing-box DNS-in).
# Перед патчингом синхронизирует домены и создаёт backup.
patch_kresd() {
    if check_antizapret_warp; then
        echo -e "${RED}ANTIZAPRET_WARP=y — патч kresd.conf не может быть применён.${NC}" >&2
        return 1
    fi

    if needs_down_sh; then
        echo -e "${RED}Активны правила от up.sh — сначала выполните /root/antizapret/down.sh${NC}" >&2
        return 1
    fi

    sync_domains

    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}" >&2
        return 1
    fi

    backup_kresd || {
        echo -e "${RED}Не удалось создать backup $KRESD_CONF.${NC}" >&2
        return 1
    }

    local clean_tmp tmpfile
    clean_tmp=$(mktemp /tmp/kresd.clean.XXXXXX)
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)

    # Удаляем старый WARP-блок если был
    sed '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF" > "$clean_tmp"

    # Вставляем новый блок перед точкой вставки в секции kresd@1
    awk '
    BEGIN { in_inst1=0; inserted1=0 }
    function print_warp_block() {
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
        print ""
    }
    /^if string.match\(systemd_instance, .?\^1.?\) then$/ { in_inst1=1; print; next }
    /^elseif string.match\(systemd_instance, .?\^2.?\) then$/ { in_inst1=0; print; next }
    in_inst1 && /Resolve blocked domains using Proxy Resolver/ && inserted1==0 {
        print_warp_block()
        inserted1=1
        print
        next
    }
    { print }
    END { if (inserted1 == 0) exit 42 }
    ' "$clean_tmp" > "$tmpfile"

    local awk_rc=$?
    rm -f "$clean_tmp"

    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 42 ]; then
            echo -e "${RED}Не удалось найти точку вставки в kresd@1.${NC}" >&2
        else
            echo -e "${RED}Ошибка при патчинге $KRESD_CONF.${NC}" >&2
        fi
        return 1
    fi

    if ! mv "$tmpfile" "$KRESD_CONF"; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось записать $KRESD_CONF.${NC}" >&2
        return 1
    fi

    chmod 644 "$KRESD_CONF"

    if ! systemctl restart kresd@1 kresd@2; then
        echo -e "${RED}Не удалось перезапустить kresd.${NC}" >&2
        return 1
    fi

    return 0
}

# Удаляет WARP-блок из kresd.conf.
# Сначала пробует восстановить из backup, затем — через sed.
unpatch_kresd() {
    if [ -f "$KRESD_BACKUP" ]; then
        restore_kresd_backup && return 0
    fi
    if grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' "$KRESD_CONF"
        sed -i '/^$/N;/^\n$/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2 || return 1
    fi
    return 0
}

# Включает WARP-резолвинг для FullVPN-клиентов (kresd@2)
patch_kresd_fullvpn() {
    if check_vpn_warp; then
        echo -e "${RED}VPN_WARP=y — нельзя включить FullVPN WARP-резолвинг!${NC}" >&2
        return 1
    fi

    sync_domains
    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}" >&2
        return 1
    fi

    backup_kresd || return 1

    local clean_tmp tmpfile
    clean_tmp=$(mktemp /tmp/kresd.fullvpn.clean.XXXXXX)
    tmpfile=$(mktemp /tmp/kresd.fullvpn.conf.XXXXXX)

    # Удаляем старый блок FULLVPN-WARP, если был
    sed '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' "$KRESD_CONF" > "$clean_tmp"

    awk '
    BEGIN { in_inst2=0; inserted2=0 }
    function print_warp_block() {
        print "\t-- [FULLVPN-WARP-START]"
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
        print "\t-- [FULLVPN-WARP-END]"
        print ""
    }
    /^elseif string.match\(systemd_instance, .?\^2.?\) then$/ { in_inst2=1; print; next }
    /^end$/ { if (in_inst2) in_inst2=0; print; next }
    in_inst2 && /Resolve blocked domains/ && inserted2==0 {
        print_warp_block()
        inserted2=1
    }
    { print }
    END { if (inserted2 == 0) exit 43 }
    ' "$clean_tmp" > "$tmpfile"

    local awk_rc=$?
    rm -f "$clean_tmp"

    if [ "$awk_rc" -ne 0 ]; then
        rm -f "$tmpfile"
        if [ "$awk_rc" -eq 43 ]; then
            echo -e "${RED}Не удалось найти точку вставки в kresd@2.${NC}" >&2
        else
            echo -e "${RED}Ошибка при патчинге $KRESD_CONF (FullVPN).${NC}" >&2
        fi
        return 1
    fi

    if ! mv "$tmpfile" "$KRESD_CONF"; then
        rm -f "$tmpfile"
        echo -e "${RED}Не удалось записать $KRESD_CONF.${NC}" >&2
        return 1
    fi

    chmod 644 "$KRESD_CONF"
    systemctl restart kresd@2 || {
        echo -e "${RED}Не удалось перезапустить kresd@2.${NC}" >&2
        return 1
    }
    return 0
}

# Выключает WARP-резолвинг для FullVPN-клиентов
unpatch_kresd_fullvpn() {
    if grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' "$KRESD_CONF"
        sed -i '/^$/N;/^\n$/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@2 || return 1
    fi
    return 0
}
