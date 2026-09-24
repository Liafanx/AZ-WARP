#!/bin/bash
# warper lib: domains-resolve.sh
# Авто-резолв доменов из domains.txt в IP-маршруты.
# Результат — накопительный блок RESOLVED внутри ip-ranges.txt,
# каждая строка аннотирована доменом-источником.
# Подключается через source из warper.sh

RESOLVED_MARKER="# --- RESOLVED ---"
RESOLVED_END_MARKER="# --- END RESOLVED ---"

# ===== Чтение существующего блока =====

# Печатает содержимое блока RESOLVED без маркеров.
extract_resolved_block() {
    local file="${1:-$IP_RANGES_FILE}"
    [ -f "$file" ] || return 0
    awk -v start="$RESOLVED_MARKER" -v end="$RESOLVED_END_MARKER" '
    $0 == start { in_block=1; next }
    $0 == end   { in_block=0; next }
    in_block    { print }
    ' "$file"
}

# Печатает файл без блока RESOLVED (пользовательская часть).
extract_user_ip_block() {
    local file="${1:-$IP_RANGES_FILE}"
    [ -f "$file" ] || return 0
    awk -v start="$RESOLVED_MARKER" -v end="$RESOLVED_END_MARKER" '
    $0 == start { in_block=1; next }
    $0 == end   { in_block=0; next }
    !in_block   { print }
    ' "$file"
}

# ===== Резолв =====

# Резолвит домены из domains.txt и печатает строки "CIDR<TAB>домен".
# Использует getent: уважает системный резолвер и /etc/hosts.
resolve_domains_to_cidrs() {
    local domain ip
    local domains_tmp
    domains_tmp=$(mktemp)
    filter_valid_domains_file "$MASTER_FILE" "$domains_tmp"

    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            validate_cidr "${ip}/32" >/dev/null 2>&1 || continue
            printf '%s/32\t%s\n' "$ip" "$domain"
        done < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    done < "$domains_tmp"

    rm -f "$domains_tmp"
}

# ===== Сборка блока =====

# Объединяет старый блок с новым резолвом и печатает итоговый блок.
# Адреса НЕ удаляются: CDN отдаёт разные IP в разные моменты, и потеря
# прошлого адреса означала бы обрыв уже установленных соединений.
merge_resolved_block() {
    local fresh_file="$1"
    local old_file
    old_file=$(mktemp)
    extract_resolved_block > "$old_file"

    {
        # Старые строки: "CIDR #домены"
        sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' "$old_file" \
            | grep -vE '^$' \
            | awk -F'#' '{
                cidr=$1; sub(/[[:space:]]+$/, "", cidr)
                if (cidr == "") next
                doms = (NF > 1) ? $2 : ""
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", doms)
                n = split(doms, parts, /,[[:space:]]*/)
                if (n == 0 || doms == "") { print cidr "\t" ; next }
                for (i = 1; i <= n; i++) if (parts[i] != "") print cidr "\t" parts[i]
            }'
        # Свежий резолв
        cat "$fresh_file"
    } | awk -F'\t' '
    {
        cidr = $1; dom = $2
        if (!(cidr in seen)) { order[++n] = cidr; seen[cidr] = "" }
        if (dom != "" && index("," seen[cidr] ",", "," dom ",") == 0) {
            seen[cidr] = (seen[cidr] == "") ? dom : seen[cidr] "," dom
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            c = order[i]
            if (seen[c] == "") print c
            else print c " #" seen[c]
        }
    }' | sort -V

    rm -f "$old_file"
}

# ===== Запись =====

# Переписывает ip-ranges.txt: пользовательская часть + блок RESOLVED.
write_resolved_block() {
    local block_file="$1"
    local tmp
    tmp=$(mktemp)
    {
        extract_user_ip_block | _trim_trailing_blank_lines
        echo ""
        echo "$RESOLVED_MARKER"
        echo "# Заполняется автоматически: warper resolvesync"
        echo "# Адреса накапливаются, вручную не редактируйте."
        cat "$block_file"
        echo "$RESOLVED_END_MARKER"
    } > "$tmp"
    mv "$tmp" "$IP_RANGES_FILE"
    chmod 600 "$IP_RANGES_FILE" 2>/dev/null || true
}

# ===== CLI =====

# CLI: резолвит домены и, если блок изменился, синхронизирует маршруты.
cli_resolve_sync() {
    local force="${1:-}"
    local fresh_file block_file old_hash new_hash
    fresh_file=$(mktemp)
    block_file=$(mktemp)

    resolve_domains_to_cidrs > "$fresh_file"
    if [ ! -s "$fresh_file" ] && [ "$force" != "--force" ]; then
        echo "Nothing resolved (no domains or DNS unavailable)" >&2
        rm -f "$fresh_file" "$block_file"
        return 1
    fi

    old_hash=$(extract_resolved_block | sha256sum | awk '{print $1}')
    merge_resolved_block "$fresh_file" > "$block_file"
    new_hash=$(sha256sum < "$block_file" | awk '{print $1}')

    local count
    count=$(grep -c '' < "$block_file")

    if [ "$old_hash" = "$new_hash" ] && [ "$force" != "--force" ]; then
        echo "No changes ($count addresses)"
        rm -f "$fresh_file" "$block_file"
        return 0
    fi

    write_resolved_block "$block_file"
    rm -f "$fresh_file" "$block_file"

    echo "Resolved block updated ($count addresses)"
    if is_warper_active; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi
    return 0
}

# CLI: очищает блок RESOLVED целиком или записи одного домена.
cli_resolve_clean() {
    local domain="${1:-}"
    grep -qxF "$RESOLVED_MARKER" "$IP_RANGES_FILE" 2>/dev/null || {
        echo "Resolved block is empty"
        return 0
    }

    if [ -z "$domain" ]; then
        local tmp
        tmp=$(mktemp)
        extract_user_ip_block | _trim_trailing_blank_lines > "$tmp"
        mv "$tmp" "$IP_RANGES_FILE"
        chmod 600 "$IP_RANGES_FILE" 2>/dev/null || true
        echo "Resolved block removed"
    else
        local block_file
        block_file=$(mktemp)
        # Убираем домен из аннотаций; строки без источников отбрасываем
        extract_resolved_block | awk -v d="$domain" -F'#' '
        /^[[:space:]]*#/ { next }
        {
            cidr=$1; sub(/[[:space:]]+$/, "", cidr)
            if (cidr == "") next
            doms = (NF > 1) ? $2 : ""
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", doms)
            n = split(doms, parts, /,[[:space:]]*/)
            out = ""
            for (i = 1; i <= n; i++) {
                if (parts[i] == "" || parts[i] == d) continue
                out = (out == "") ? parts[i] : out "," parts[i]
            }
            if (out != "") print cidr " #" out
        }' > "$block_file"
        write_resolved_block "$block_file"
        rm -f "$block_file"
        echo "Removed entries of $domain"
    fi

    if is_warper_active; then
        sync_ip_ranges >/dev/null 2>&1 || true
    fi
    return 0
}

# CLI: включает/выключает таймер авто-резолва.
cli_resolve() {
    case "${1:-}" in
        on|enable)
            systemctl enable --now warper-resolve.timer >/dev/null 2>&1 || {
                echo "ERROR: failed to enable warper-resolve.timer" >&2; return 1; }
            echo "Auto-resolve enabled (hourly)"
            ;;
        off|disable)
            systemctl disable --now warper-resolve.timer >/dev/null 2>&1 || true
            echo "Auto-resolve disabled"
            ;;
        status)
            if systemctl is-enabled --quiet warper-resolve.timer 2>/dev/null; then
                echo "enabled"
            else
                echo "disabled"
            fi
            ;;
        *)
            echo "Usage: warper resolve on|off|status" >&2
            return 1
            ;;
    esac
}
