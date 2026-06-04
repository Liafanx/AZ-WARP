#!/bin/bash
# warper lib: traffic.sh
# Подсчёт трафика через singbox-tun:
# чтение счётчиков ядра, хранение истории в traffic.json (через jq),
# почасовая агрегация, вывод статистики за период.
# Подключается через source из warper.sh

TRAFFIC_FILE="$WARPER_DIR/traffic.json"
TRAFFIC_MAX_SESSIONS=100
TRAFFIC_MAX_HOURLY_HOURS=744  # 31 день

# ===== Чтение счётчиков ядра =====

traffic_read_tun_counters() {
    local rx_file="/sys/class/net/singbox-tun/statistics/rx_bytes"
    local tx_file="/sys/class/net/singbox-tun/statistics/tx_bytes"

    if [ ! -f "$rx_file" ] || [ ! -f "$tx_file" ]; then
        echo ""
        return 1
    fi

    local rx tx
    rx=$(cat "$rx_file" 2>/dev/null || echo "0")
    tx=$(cat "$tx_file" 2>/dev/null || echo "0")
    echo "$rx $tx"
    return 0
}

# ===== Инициализация =====

traffic_ensure_file() {
    if [ ! -f "$TRAFFIC_FILE" ]; then
        echo '{"sessions":[],"hourly":{},"last_snapshot":null}' > "$TRAFFIC_FILE"
        chmod 600 "$TRAFFIC_FILE"
    fi
}

# ===== Snapshot =====

traffic_take_snapshot() {
    local counters
    counters=$(traffic_read_tun_counters) || return 1
    [ -z "$counters" ] && return 1

    local cur_rx cur_tx
    cur_rx=$(echo "$counters" | awk '{print $1}')
    cur_tx=$(echo "$counters" | awk '{print $2}')

    traffic_ensure_file

    local now_iso now_hour
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S")
    now_hour=$(date -u +"%Y-%m-%dT%H")

    local prev_rx=0 prev_tx=0 delta_rx=0 delta_tx=0
    local has_prev="false"

    if jq -e '.last_snapshot != null' "$TRAFFIC_FILE" >/dev/null 2>&1; then
        prev_rx=$(jq -r '.last_snapshot.rx // 0' "$TRAFFIC_FILE")
        prev_tx=$(jq -r '.last_snapshot.tx // 0' "$TRAFFIC_FILE")
        has_prev="true"
    fi

    if [ "$has_prev" = "true" ]; then
        # Считаем дельту только если счётчики не сбросились (рестарт интерфейса)
        if [ "$cur_rx" -ge "$prev_rx" ] && [ "$cur_tx" -ge "$prev_tx" ]; then
            delta_rx=$((cur_rx - prev_rx))
            delta_tx=$((cur_tx - prev_tx))
        fi
    else
        # Первый snapshot: записываем весь накопленный трафик текущей сессии
        # (счётчики ядра считают с момента создания интерфейса)
        delta_rx=$cur_rx
        delta_tx=$cur_tx
    fi

    # Атомарное обновление через jq
    local tmp
    tmp=$(mktemp)

    jq --arg hour "$now_hour" \
       --argjson drx "$delta_rx" \
       --argjson dtx "$delta_tx" \
       --argjson crx "$cur_rx" \
       --argjson ctx "$cur_tx" \
       --arg ts "$now_iso" \
       --argjson max_h "$TRAFFIC_MAX_HOURLY_HOURS" \
       '
       # Добавляем дельту в hourly
       (if ($drx > 0 or $dtx > 0) then
           .hourly[$hour].rx = ((.hourly[$hour].rx // 0) + $drx) |
           .hourly[$hour].tx = ((.hourly[$hour].tx // 0) + $dtx)
        else . end) |

       # Ротация hourly
       (if (.hourly | length) > $max_h then
           .hourly = (.hourly | to_entries | sort_by(.key) | .[-$max_h:] | from_entries)
        else . end) |

       # Обновляем snapshot
       .last_snapshot = {rx: $crx, tx: $ctx, ts: $ts}
       ' "$TRAFFIC_FILE" > "$tmp" 2>/dev/null

    if [ -s "$tmp" ]; then
        chmod 600 "$tmp"
        mv "$tmp" "$TRAFFIC_FILE"
    else
        rm -f "$tmp"
    fi
}

# ===== Фиксация сессии =====

traffic_finalize_session() {
    local counters
    counters=$(traffic_read_tun_counters) || return 0
    [ -z "$counters" ] && return 0

    local cur_rx cur_tx
    cur_rx=$(echo "$counters" | awk '{print $1}')
    cur_tx=$(echo "$counters" | awk '{print $2}')

    # Финальный snapshot
    traffic_take_snapshot 2>/dev/null || true

    traffic_ensure_file

    local now_iso started_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S")

    started_iso=$(systemctl show sing-box --property=ActiveEnterTimestamp 2>/dev/null \
        | sed 's/ActiveEnterTimestamp=//' \
        | xargs -I{} date -u -d "{}" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || true)
    [ -z "$started_iso" ] && started_iso="$now_iso"

    # Не записываем пустые сессии
    if [ "$cur_rx" -eq 0 ] && [ "$cur_tx" -eq 0 ]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)

    jq --arg started "$started_iso" \
       --arg stopped "$now_iso" \
       --argjson rx "$cur_rx" \
       --argjson tx "$cur_tx" \
       --argjson max_s "$TRAFFIC_MAX_SESSIONS" \
       '
       .sessions += [{started: $started, stopped: $stopped, rx: $rx, tx: $tx}] |
       (if (.sessions | length) > $max_s then
           .sessions = .sessions[-$max_s:]
        else . end) |
       .last_snapshot = null
       ' "$TRAFFIC_FILE" > "$tmp" 2>/dev/null

    if [ -s "$tmp" ]; then
        chmod 600 "$tmp"
        mv "$tmp" "$TRAFFIC_FILE"
    else
        rm -f "$tmp"
    fi
}

# ===== Форматирование =====

traffic_format_bytes() {
    local bytes="${1:-0}"
    if [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi

    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk "BEGIN{printf \"%.1f GB\", $bytes/1073741824}")"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}")"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(awk "BEGIN{printf \"%.1f KB\", $bytes/1024}")"
    else
        echo "${bytes} B"
    fi
}

# ===== Статистика за период =====

traffic_get_period() {
    local period="${1:-today}"

    traffic_ensure_file
    traffic_take_snapshot 2>/dev/null || true

    local now_date cutoff_key

    case "$period" in
        today)
            # Все ключи, начинающиеся с сегодняшней даты
            now_date=$(date -u +"%Y-%m-%dT")
            jq -r --arg prefix "$now_date" '
                [.hourly | to_entries[] | select(.key | startswith($prefix))]
                | {rx: (map(.value.rx) | add // 0), tx: (map(.value.tx) | add // 0)}
                | "\(.rx) \(.tx)"
            ' "$TRAFFIC_FILE" 2>/dev/null || echo "0 0"
            ;;
        week)
            cutoff_key=$(date -u -d "7 days ago" +"%Y-%m-%dT%H" 2>/dev/null || date -u +"%Y-%m-%dT%H")
            jq -r --arg cutoff "$cutoff_key" '
                [.hourly | to_entries[] | select(.key >= $cutoff)]
                | {rx: (map(.value.rx) | add // 0), tx: (map(.value.tx) | add // 0)}
                | "\(.rx) \(.tx)"
            ' "$TRAFFIC_FILE" 2>/dev/null || echo "0 0"
            ;;
        month)
            cutoff_key=$(date -u -d "30 days ago" +"%Y-%m-%dT%H" 2>/dev/null || date -u +"%Y-%m-%dT%H")
            jq -r --arg cutoff "$cutoff_key" '
                [.hourly | to_entries[] | select(.key >= $cutoff)]
                | {rx: (map(.value.rx) | add // 0), tx: (map(.value.tx) | add // 0)}
                | "\(.rx) \(.tx)"
            ' "$TRAFFIC_FILE" 2>/dev/null || echo "0 0"
            ;;
        all)
            jq -r '
                [.hourly | to_entries[]]
                | {rx: (map(.value.rx) | add // 0), tx: (map(.value.tx) | add // 0)}
                | "\(.rx) \(.tx)"
            ' "$TRAFFIC_FILE" 2>/dev/null || echo "0 0"
            ;;
        *)
            echo "0 0"
            ;;
    esac
}

# ===== CLI =====

cli_traffic() {
    local period="${1:-today}"
    local show_json="${2:-}"

    if [ "$period" = "json" ]; then
        show_json="json"
        period="today"
    fi

    traffic_ensure_file
    traffic_take_snapshot 2>/dev/null || true

    # Текущая сессия
    local counters cur_rx=0 cur_tx=0
    counters=$(traffic_read_tun_counters 2>/dev/null || true)
    if [ -n "$counters" ]; then
        cur_rx=$(echo "$counters" | awk '{print $1}')
        cur_tx=$(echo "$counters" | awk '{print $2}')
    fi

    # Аптайм
    local uptime_str="не запущен"
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        local started_raw
        started_raw=$(systemctl show sing-box --property=ActiveEnterTimestamp 2>/dev/null \
            | sed 's/ActiveEnterTimestamp=//')
        if [ -n "$started_raw" ]; then
            local started_epoch now_epoch diff_sec
            started_epoch=$(date -d "$started_raw" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            diff_sec=$((now_epoch - started_epoch))
            [ "$diff_sec" -lt 0 ] && diff_sec=0
            local days=$((diff_sec / 86400))
            local hours=$(( (diff_sec % 86400) / 3600 ))
            local mins=$(( (diff_sec % 3600) / 60 ))
            local parts=""
            [ "$days" -gt 0 ] && parts="${days}д "
            ([ "$hours" -gt 0 ] || [ "$days" -gt 0 ]) && parts="${parts}${hours}ч "
            parts="${parts}${mins}м"
            uptime_str="$parts"
        fi
    fi

    # Данные за запрошенный период
    local period_data period_rx=0 period_tx=0
    period_data=$(traffic_get_period "$period")
    period_rx=$(echo "$period_data" | awk '{print $1}')
    period_tx=$(echo "$period_data" | awk '{print $2}')

    # Данные за сегодня
    local today_data today_rx=0 today_tx=0
    today_data=$(traffic_get_period "today")
    today_rx=$(echo "$today_data" | awk '{print $1}')
    today_tx=$(echo "$today_data" | awk '{print $2}')

    if [ "$show_json" = "json" ]; then
        jq -n \
            --argjson cur_rx "$cur_rx" \
            --argjson cur_tx "$cur_tx" \
            --arg uptime "$uptime_str" \
            --arg period "$period" \
            --argjson period_rx "$period_rx" \
            --argjson period_tx "$period_tx" \
            --argjson today_rx "$today_rx" \
            --argjson today_tx "$today_tx" \
            '{
                current_session: {rx: $cur_rx, tx: $cur_tx},
                uptime: $uptime,
                period: $period,
                period_rx: $period_rx,
                period_tx: $period_tx,
                today_rx: $today_rx,
                today_tx: $today_tx
            }'
        return 0
    fi

    local period_label
    case "$period" in
        today) period_label="Сегодня" ;;
        week)  period_label="За неделю" ;;
        month) period_label="За месяц" ;;
        all)   period_label="За всё время" ;;
        *)     period_label="$period" ;;
    esac

    echo -e "${CYAN}==========================================${NC}"
    echo -e "       📊 ${YELLOW}СТАТИСТИКА ТРАФИКА${NC} 📊"
    echo -e "${CYAN}==========================================${NC}"
    echo -e ""
    echo -e " ${CYAN}Аптайм sing-box:${NC}   ${GREEN}${uptime_str}${NC}"
    echo -e ""
    echo -e " ${CYAN}Текущая сессия:${NC}"
    echo -e "   ↓ Получено:      ${GREEN}$(traffic_format_bytes "$cur_rx")${NC}"
    echo -e "   ↑ Отправлено:    ${GREEN}$(traffic_format_bytes "$cur_tx")${NC}"
    echo -e ""
    echo -e " ${CYAN}${period_label}:${NC}"
    echo -e "   ↓ Получено:      ${YELLOW}$(traffic_format_bytes "$period_rx")${NC}"
    echo -e "   ↑ Отправлено:    ${YELLOW}$(traffic_format_bytes "$period_tx")${NC}"
    echo -e "${CYAN}==========================================${NC}"
}

# ===== Краткая строка для status/doctor =====

traffic_today_summary() {
    traffic_take_snapshot 2>/dev/null || true

    local data rx=0 tx=0
    data=$(traffic_get_period "today" 2>/dev/null || echo "0 0")
    rx=$(echo "$data" | awk '{print $1}')
    tx=$(echo "$data" | awk '{print $2}')

    echo "↑ $(traffic_format_bytes "$tx") ↓ $(traffic_format_bytes "$rx")"
}
