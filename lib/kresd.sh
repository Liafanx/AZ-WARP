#!/bin/bash
# warper lib: kresd.sh
# Управление конфигурацией DNS-резолвера kresd:
# патчинг, восстановление из backup, применение WARP-блока.
# Подключается через source из warper.sh

# ===== Backup =====

# Строит "чистую" версию kresd.conf без WARPER-блоков.
# Это позволяет:
#  - безопасно обновлять backup после апдейта AntiZapret
#  - не откатывать kresd на устаревшую версию при disable/uninstall
strip_warper_blocks_from_kresd() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || return 1

    sed \
        -e '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' \
        -e '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' \
        "$src" | _squeeze_blank_lines > "$dst"
}

# Вырезает один блок (WARP-MOD или FULLVPN-WARP) в stdout.
# Блок вставляется с пустой строкой после себя — без схлопывания каждый
# повторный патч добавлял бы в kresd.conf ещё одну.
_kresd_strip_block() {
    sed "/-- \[${1}-START\]/,/-- \[${1}-END\]/d" "$2" | _squeeze_blank_lines
}

_squeeze_blank_lines() {
    awk '
        BEGIN {
            seen_nonblank = 0
            prev_blank = 0
        }
        /^[[:space:]]*$/ {
            if (seen_nonblank && !prev_blank) {
                print ""
            }
            prev_blank = 1
            next
        }
        {
            print
            seen_nonblank = 1
            prev_blank = 0
        }
    '
}

# Создаёт или ОБНОВЛЯЕТ резервную копию kresd.conf.
# Backup всегда должен содержать актуальный "чистый" kresd без WARPER-блоков.
backup_kresd() {
    [ -f "$KRESD_CONF" ] || return 1

    local clean_tmp
    clean_tmp=$(mktemp /tmp/kresd.clean.XXXXXX) || return 1

    if ! strip_warper_blocks_from_kresd "$KRESD_CONF" "$clean_tmp"; then
        rm -f "$clean_tmp"
        return 1
    fi

    if [ ! -f "$KRESD_BACKUP" ] || ! cmp -s "$clean_tmp" "$KRESD_BACKUP"; then
        cp -a "$clean_tmp" "$KRESD_BACKUP" || {
            rm -f "$clean_tmp"
            return 1
        }
        chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
    fi

    rm -f "$clean_tmp"
    return 0
}

# Восстанавливает kresd.conf.
# Если backup совпадает с "очищенным" текущим файлом — восстанавливаем backup.
# Если НЕ совпадает — backup устарел, используем очищенный текущий файл
# и одновременно обновляем backup.
restore_kresd_backup() {
    local clean_tmp
    clean_tmp=$(mktemp /tmp/kresd.restore.XXXXXX) || return 1

    if strip_warper_blocks_from_kresd "$KRESD_CONF" "$clean_tmp"; then
        if [ -f "$KRESD_BACKUP" ] && cmp -s "$clean_tmp" "$KRESD_BACKUP"; then
            cp -a "$KRESD_BACKUP" "$KRESD_CONF" || {
                rm -f "$clean_tmp"
                return 1
            }
        else
            cp -a "$clean_tmp" "$KRESD_CONF" || {
                rm -f "$clean_tmp"
                return 1
            }
            cp -a "$clean_tmp" "$KRESD_BACKUP" 2>/dev/null || true
            chmod 644 "$KRESD_BACKUP" 2>/dev/null || true
        fi
    elif [ -f "$KRESD_BACKUP" ]; then
        cp -a "$KRESD_BACKUP" "$KRESD_CONF" || {
            rm -f "$clean_tmp"
            return 1
        }
    else
        rm -f "$clean_tmp"
        return 1
    fi

    chmod 644 "$KRESD_CONF" 2>/dev/null || true
    rm -f "$clean_tmp"

    systemctl restart kresd@1 kresd@2 || return 1
    return 0
}

# ===== Патчинг kresd.conf (AntiZapret без custom*.lua) =====

# Вставляет WARP-блок в kresd.conf для kresd@1.
# Блок читает warper-domains.txt и направляет DNS-запросы
# для этих доменов на 127.0.0.1:40000 (sing-box DNS-in).
# Перед патчингом синхронизирует домены и создаёт/обновляет backup.
# kresd читает список только при старте, а перезапуск занимает несколько
# секунд — если ни список, ни kresd.conf не изменились, он пропускается.
#   _patch_kresd_legacy [--force]
_patch_kresd_legacy() {
    local force="${1:-}"
    if needs_down_sh; then
        echo -e "${RED}Активны правила от up.sh — сначала выполните /root/antizapret/down.sh${NC}" >&2
        return 1
    fi

    local domains_before
    domains_before=$(cksum < "$ACTIVE_FILE" 2>/dev/null)
    sync_domains

    if [ ! -f "$KRESD_CONF" ]; then
        echo -e "${RED}Файл $KRESD_CONF не найден.${NC}" >&2
        return 1
    fi

    backup_kresd || {
        echo -e "${RED}Не удалось создать/обновить backup $KRESD_CONF.${NC}" >&2
        return 1
    }

    local clean_tmp tmpfile
    clean_tmp=$(mktemp /tmp/kresd.clean.XXXXXX)
    tmpfile=$(mktemp /tmp/kresd.conf.XXXXXX)

    # Удаляем старый WARP-блок если был
    _kresd_strip_block WARP-MOD "$KRESD_CONF" > "$clean_tmp"

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
    in_inst1 && (/-- Resolve WARP domains/ || /-- Resolve blocked domains/) && inserted1==0 {
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

    if [ "$force" != "--force" ] && cmp -s "$tmpfile" "$KRESD_CONF" \
        && [ "$domains_before" = "$(cksum < "$ACTIVE_FILE")" ] \
        && systemctl is-active --quiet kresd@1; then
        rm -f "$tmpfile"
        KRESD_RESTART_SKIPPED=1
        return 0
    fi
    KRESD_RESTART_SKIPPED=0

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
# Сначала пробует безопасное восстановление из backup/текущего clean-state.
_unpatch_kresd_legacy() {
    if [ -f "$KRESD_BACKUP" ]; then
        restore_kresd_backup && return 0
    fi

    if grep -qE "WARP-MOD-START|FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i \
            -e '/-- \[WARP-MOD-START\]/,/-- \[WARP-MOD-END\]/d' \
            -e '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' \
            "$KRESD_CONF"
        sed -i '/^$/N;/^\n$/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@1 kresd@2 || return 1
    fi
    return 0
}

# Включает WARP-резолвинг для FullVPN-клиентов (kresd@2)
_patch_kresd_fullvpn_legacy() {
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
    _kresd_strip_block FULLVPN-WARP "$KRESD_CONF" > "$clean_tmp"

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
    /^(elseif|else|end)/ { in_inst2=0; print; next }
    in_inst2 && (/-- Resolve (WARP|blocked) domains/ || /-- Resolve (blocked and )?full VPN domains/) && inserted2==0 {
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
_unpatch_kresd_fullvpn_legacy() {
    if grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; then
        sed -i '/-- \[FULLVPN-WARP-START\]/,/-- \[FULLVPN-WARP-END\]/d' "$KRESD_CONF"
        sed -i '/^$/N;/^\n$/d' "$KRESD_CONF"
        chmod 644 "$KRESD_CONF"
        systemctl restart kresd@2 || return 1
    fi
    return 0
}

# ===== custom*.lua (AntiZapret с августа 2026) =====
#
# kresd.conf перезаписывается при обновлении AntiZapret, а custom*.lua
# сохраняются (и попадают в его бэкап). Свой код WARPER держит в отдельных
# custom_az-warp.lua / custom2_az-warp.lua, в custom.lua / custom2.lua —
# только подключение между маркерами [AZ-WARP-START]/[AZ-WARP-END].

KRESD_DIR="${KRESD_DIR:-/etc/knot-resolver}"

# custom.lua AntiZapret для инстанса 1|2
_kresd_custom() {
    if [ "$1" = 1 ]; then echo "$KRESD_DIR/custom.lua"
    else echo "$KRESD_DIR/custom$1.lua"; fi
}

# Файл WARPER для инстанса 1|2
_kresd_azw_lua() {
    if [ "$1" = 1 ]; then echo "$KRESD_DIR/custom_az-warp.lua"
    else echo "$KRESD_DIR/custom${1}_az-warp.lua"; fi
}

# kresd.conf подключает custom.lua и custom2.lua
kresd_uses_custom() {
    grep -qE "dofile\('[^']*/custom\.lua'\)" "$KRESD_CONF" 2>/dev/null \
        && grep -qE "dofile\('[^']*/custom2\.lua'\)" "$KRESD_CONF" 2>/dev/null
}

_azw_lua_body() {
    cat <<LUA
-- AZ-WARP (WARPER): домены из warper-domains.txt резолвятся через sing-box.
-- Файл перезаписывается WARPER, правки в нём не сохранятся.
local warp_domains = {}
local wfile = io.open('$ACTIVE_FILE', 'r')
if wfile then
	for line in wfile:lines() do
		local clean = line:gsub('%s+', '')
		if clean ~= '' and clean:sub(1, 1) ~= '#' then table.insert(warp_domains, clean .. '.') end
	end
	wfile:close()
	if #warp_domains > 0 then
		policy.add(policy.suffix(policy.STUB('127.0.0.1@40000'), policy.todnames(warp_domains)))
	end
end
LUA
}

_azw_include() {
    local f
    f=$(_kresd_azw_lua "$1")
    printf -- "-- [AZ-WARP-START]\ndo local f = io.open('%s', 'r') if f then f:close() dofile('%s') end end\n-- [AZ-WARP-END]\n" "$f" "$f"
}

# custom.lua без блока AZ-WARP (и без пустых строк в конце) в stdout
_azw_strip_custom() {
    [ -f "$1" ] || return 0
    sed '/-- \[AZ-WARP-START\]/,/-- \[AZ-WARP-END\]/d' "$1"
}

# Записывает текст в файл, если он изменился, и ставит _KRESD_CHANGED=1.
# Не вызывать в конвейере — флаг потеряется в подоболочке.
#   _kresd_write FILE TEXT
_kresd_write() {
    local dst="$1" tmp
    tmp=$(mktemp "$KRESD_DIR/.azw.XXXXXX") || return 1
    [ -n "$2" ] && printf '%s\n' "$2" > "$tmp"
    if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return 0
    fi
    chmod 644 "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    _KRESD_CHANGED=1
}

_azw_active() {
    [ -f "$(_kresd_azw_lua "$1")" ] \
        && grep -q '\[AZ-WARP-START\]' "$(_kresd_custom "$1")" 2>/dev/null
}

_azw_install() {
    local custom body
    custom=$(_kresd_custom "$1")
    _kresd_write "$(_kresd_azw_lua "$1")" "$(_azw_lua_body)" || return 1
    body=$(_azw_strip_custom "$custom")
    [ -n "$body" ] && body+=$'\n\n'
    _kresd_write "$custom" "$body$(_azw_include "$1")"
}

_azw_remove() {
    local custom lua body
    custom=$(_kresd_custom "$1")
    lua=$(_kresd_azw_lua "$1")
    if grep -q '\[AZ-WARP-START\]' "$custom" 2>/dev/null; then
        body=$(_azw_strip_custom "$custom")
        _kresd_write "$custom" "$body" || return 1
    fi
    if [ -f "$lua" ]; then
        rm -f "$lua" || return 1
        _KRESD_CHANGED=1
    fi
}

# Переносит блоки из kresd.conf (WARPER до 1.5.6) в custom*.lua.
# _KRESD_MIGRATED=1, если что-то перенесено.
_kresd_migrate_legacy() {
    _KRESD_MIGRATED=0
    grep -qE "WARP-MOD-START|FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null || {
        rm -f "$KRESD_BACKUP"
        return 0
    }
    local had1=0 had2=0 tmp
    grep -q "WARP-MOD-START" "$KRESD_CONF" && had1=1
    grep -q "FULLVPN-WARP-START" "$KRESD_CONF" && had2=1
    [ "$had1" = 1 ] && { _azw_install 1 || return 1; }
    [ "$had2" = 1 ] && { _azw_install 2 || return 1; }
    tmp=$(mktemp "$KRESD_DIR/.azw.XXXXXX") || return 1
    strip_warper_blocks_from_kresd "$KRESD_CONF" "$tmp" \
        && chmod 644 "$tmp" && mv "$tmp" "$KRESD_CONF" || { rm -f "$tmp"; return 1; }
    rm -f "$KRESD_BACKUP"
    _KRESD_CHANGED=1
    _KRESD_MIGRATED=1
}

_kresd_fail() {
    echo -e "${RED}Не удалось записать ${1:-custom*.lua} в $KRESD_DIR.${NC}" >&2
    return 1
}

# ===== Публичные функции =====

# WARP-блок для kresd@1 применён
kresd_patched() {
    if kresd_uses_custom; then _azw_active 1
    else grep -q "WARP-MOD-START" "$KRESD_CONF" 2>/dev/null; fi
}

# WARP-блок для FullVPN (kresd@2) применён
kresd_fullvpn_patched() {
    if kresd_uses_custom; then _azw_active 2
    else grep -q "FULLVPN-WARP-START" "$KRESD_CONF" 2>/dev/null; fi
}

# Блок kresd@1 ровно один и нет остатков старой схемы
kresd_patch_unique() {
    if kresd_uses_custom; then
        [ "$(grep -c '\[AZ-WARP-START\]' "$(_kresd_custom 1)" 2>/dev/null)" = 1 ] \
            && ! grep -qE "WARP-MOD-START|FULLVPN-WARP-START" "$KRESD_CONF"
    else
        [ "$(grep -c 'WARP-MOD-START' "$KRESD_CONF" 2>/dev/null)" = 1 ]
    fi
}

# Включает WARP-резолвинг для kresd@1.
# Перед патчингом синхронизирует домены. kresd читает список только
# при старте, а перезапуск занимает несколько секунд — если ни список,
# ни файлы не изменились, он пропускается.
#   patch_kresd [--force]
patch_kresd() {
    kresd_uses_custom || { _patch_kresd_legacy "$@"; return; }
    local force="${1:-}"
    if needs_down_sh; then
        echo -e "${RED}Активны правила от up.sh — сначала выполните /root/antizapret/down.sh${NC}" >&2
        return 1
    fi

    local domains_before
    domains_before=$(cksum < "$ACTIVE_FILE" 2>/dev/null)
    sync_domains

    _KRESD_CHANGED=0
    _kresd_migrate_legacy || { _kresd_fail "$KRESD_CONF"; return 1; }
    _azw_install 1 || { _kresd_fail; return 1; }

    if [ "$force" != "--force" ] && [ "$_KRESD_CHANGED" = 0 ] \
        && [ "$domains_before" = "$(cksum < "$ACTIVE_FILE")" ] \
        && systemctl is-active --quiet kresd@1; then
        KRESD_RESTART_SKIPPED=1
        return 0
    fi
    KRESD_RESTART_SKIPPED=0

    if ! systemctl restart kresd@1 kresd@2; then
        echo -e "${RED}Не удалось перезапустить kresd.${NC}" >&2
        return 1
    fi
}

# Убирает WARP-резолвинг из kresd@1 и kresd@2
unpatch_kresd() {
    kresd_uses_custom || { _unpatch_kresd_legacy; return; }
    _KRESD_CHANGED=0
    _kresd_migrate_legacy || return 1
    _azw_remove 1 || return 1
    _azw_remove 2 || return 1
    [ "$_KRESD_CHANGED" = 1 ] || return 0
    systemctl restart kresd@1 kresd@2
}

# Включает WARP-резолвинг для FullVPN-клиентов (kresd@2)
patch_kresd_fullvpn() {
    kresd_uses_custom || { _patch_kresd_fullvpn_legacy; return; }
    sync_domains
    _KRESD_CHANGED=0
    _kresd_migrate_legacy || { _kresd_fail "$KRESD_CONF"; return 1; }
    _azw_install 2 || { _kresd_fail; return 1; }
    _kresd_restart_fullvpn
}

# Выключает WARP-резолвинг для FullVPN-клиентов
unpatch_kresd_fullvpn() {
    kresd_uses_custom || { _unpatch_kresd_fullvpn_legacy; return; }
    _KRESD_CHANGED=0
    _kresd_migrate_legacy || return 1
    _azw_remove 2 || return 1
    [ "$_KRESD_CHANGED" = 1 ] || return 0
    _kresd_restart_fullvpn
}

# После переноса из kresd.conf изменился и kresd@1
_kresd_restart_fullvpn() {
    local units="kresd@2"
    [ "$_KRESD_MIGRATED" = 1 ] && units="kresd@1 kresd@2"
    # shellcheck disable=SC2086
    systemctl restart $units || {
        echo -e "${RED}Не удалось перезапустить kresd@2.${NC}" >&2
        return 1
    }
}

# Сбрасывает кэш обоих инстансов kresd.
# Нужен после смены fake-подсети: иначе клиенты продолжают получать
# адреса из старого пула, которые больше никуда не маршрутизируются.
flush_kresd_cache() {
    local inst
    for inst in 1 2; do
        [ -S "/run/knot-resolver/control/$inst" ] || continue
        echo 'cache.clear()' \
            | socat - "/run/knot-resolver/control/$inst" >/dev/null 2>&1 || true
    done
}
