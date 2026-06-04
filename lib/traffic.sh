#!/bin/bash
# warper lib: traffic.sh
# Подсчёт трафика через singbox-tun:
# чтение счётчиков ядра, хранение истории в traffic.json,
# почасовая агрегация, вывод статистики за период.
# Подключается через source из warper.sh

TRAFFIC_FILE="$WARPER_DIR/traffic.json"
TRAFFIC_MAX_SESSIONS=100
TRAFFIC_MAX_HOURLY_HOURS=744  # 31 день

# ===== Чтение счётчиков ядра =====

# Читает текущие RX/TX байты с интерфейса singbox-tun.
# Возвращает "rx tx" через stdout, или "" если интерфейс не существует.
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

# ===== Инициализация traffic.json =====

traffic_ensure_file() {
    if [ ! -f "$TRAFFIC_FILE" ]; then
        echo '{"sessions":[],"hourly":{},"last_snapshot":null}' > "$TRAFFIC_FILE"
        chmod 600 "$TRAFFIC_FILE"
    fi
}

# ===== Snapshot: снимок текущих счётчиков + агрегация =====

# Снимает текущие счётчики, обновляет hourly-агрегацию и last_snapshot.
# Вызывается при каждом обращении к статистике.
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

    # Используем Python для атомарного обновления JSON
    python3 - "$TRAFFIC_FILE" "$cur_rx" "$cur_tx" "$now_iso" "$now_hour" \
        "$TRAFFIC_MAX_HOURLY_HOURS" <<'PYEOF'
import json, sys, os
from pathlib import Path

traffic_file = sys.argv[1]
cur_rx = int(sys.argv[2])
cur_tx = int(sys.argv[3])
now_iso = sys.argv[4]
now_hour = sys.argv[5]
max_hourly = int(sys.argv[6])

try:
    with open(traffic_file, "r") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {"sessions": [], "hourly": {}, "last_snapshot": None}

if "hourly" not in data or not isinstance(data["hourly"], dict):
    data["hourly"] = {}
if "sessions" not in data or not isinstance(data["sessions"], list):
    data["sessions"] = []

last = data.get("last_snapshot")

if last and isinstance(last, dict):
    prev_rx = last.get("rx", 0)
    prev_tx = last.get("tx", 0)

    # Если счётчики меньше предыдущих — интерфейс пересоздан (рестарт)
    if cur_rx >= prev_rx and cur_tx >= prev_tx:
        delta_rx = cur_rx - prev_rx
        delta_tx = cur_tx - prev_tx

        if delta_rx > 0 or delta_tx > 0:
            h = data["hourly"].get(now_hour, {"rx": 0, "tx": 0})
            h["rx"] = h.get("rx", 0) + delta_rx
            h["tx"] = h.get("tx", 0) + delta_tx
            data["hourly"][now_hour] = h

# Ротация hourly: оставляем только последние N часов
if len(data["hourly"]) > max_hourly:
    keys = sorted(data["hourly"].keys())
    excess = len(keys) - max_hourly
    for k in keys[:excess]:
        del data["hourly"][k]

# Обновляем snapshot
data["last_snapshot"] = {
    "rx": cur_rx,
    "tx": cur_tx,
    "ts": now_iso,
}

tmp = traffic_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, separators=(",", ":"))
os.chmod(tmp, 0o600)
os.replace(tmp, traffic_file)
PYEOF
}

# ===== Фиксация сессии при остановке sing-box =====

# Вызывается перед остановкой sing-box.
# Записывает финальные счётчики текущей сессии.
traffic_finalize_session() {
    local counters
    counters=$(traffic_read_tun_counters) || return 0
    [ -z "$counters" ] && return 0

    local cur_rx cur_tx
    cur_rx=$(echo "$counters" | awk '{print $1}')
    cur_tx=$(echo "$counters" | awk '{print $2}')

    # Сначала делаем финальный snapshot (чтобы hourly был актуален)
    traffic_take_snapshot 2>/dev/null || true

    traffic_ensure_file

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S")

    # Определяем время старта sing-box
    local started_iso=""
    started_iso=$(systemctl show sing-box --property=ActiveEnterTimestamp 2>/dev/null \
        | sed 's/ActiveEnterTimestamp=//' | xargs -I{} date -u -d "{}" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || true)
    [ -z "$started_iso" ] && started_iso="$now_iso"

    python3 - "$TRAFFIC_FILE" "$cur_rx" "$cur_tx" "$started_iso" "$now_iso" \
        "$TRAFFIC_MAX_SESSIONS" <<'PYEOF'
import json, sys, os

traffic_file = sys.argv[1]
rx = int(sys.argv[2])
tx = int(sys.argv[3])
started = sys.argv[4]
stopped = sys.argv[5]
max_sessions = int(sys.argv[6])

try:
    with open(traffic_file, "r") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {"sessions": [], "hourly": {}, "last_snapshot": None}

if not isinstance(data.get("sessions"), list):
    data["sessions"] = []

# Не записываем пустые сессии
if rx > 0 or tx > 0:
    data["sessions"].append({
        "started": started,
        "stopped": stopped,
        "rx": rx,
        "tx": tx,
    })

# Ротация сессий
if len(data["sessions"]) > max_sessions:
    data["sessions"] = data["sessions"][-max_sessions:]

# Сбрасываем snapshot (интерфейс скоро умрёт)
data["last_snapshot"] = None

tmp = traffic_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, separators=(",", ":"))
os.chmod(tmp, 0o600)
os.replace(tmp, traffic_file)
PYEOF
}

# ===== Форматирование размера =====

traffic_format_bytes() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi

    python3 -c "
b = $bytes
for u in ['B','KB','MB','GB','TB']:
    if b < 1024:
        print(f'{b:.1f} {u}' if b != int(b) else f'{int(b)} {u}')
        break
    b /= 1024
"
}

# ===== Получение статистики за период =====

# Возвращает суммарный трафик за указанный период.
# Аргументы: period = today | week | month | all
# Выводит: "rx_bytes tx_bytes"
traffic_get_period() {
    local period="${1:-today}"

    traffic_ensure_file
    traffic_take_snapshot 2>/dev/null || true

    python3 - "$TRAFFIC_FILE" "$period" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta

traffic_file = sys.argv[1]
period = sys.argv[2]

try:
    with open(traffic_file, "r") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    print("0 0")
    sys.exit(0)

hourly = data.get("hourly", {})
if not isinstance(hourly, dict):
    print("0 0")
    sys.exit(0)

now = datetime.utcnow()

if period == "today":
    prefix = now.strftime("%Y-%m-%dT")
elif period == "week":
    start = now - timedelta(days=7)
    prefix = None
    cutoff = start.strftime("%Y-%m-%dT%H")
elif period == "month":
    start = now - timedelta(days=30)
    prefix = None
    cutoff = start.strftime("%Y-%m-%dT%H")
elif period == "all":
    prefix = None
    cutoff = ""
else:
    print("0 0")
    sys.exit(0)

total_rx = 0
total_tx = 0

for hour_key, vals in hourly.items():
    if prefix is not None:
        if hour_key.startswith(prefix):
            total_rx += vals.get("rx", 0)
            total_tx += vals.get("tx", 0)
    else:
        if hour_key >= cutoff:
            total_rx += vals.get("rx", 0)
            total_tx += vals.get("tx", 0)

print(f"{total_rx} {total_tx}")
PYEOF
}

# ===== CLI: warper traffic =====

cli_traffic() {
    local period="${1:-today}"
    local show_json="${2:-}"

    if [ "$period" = "json" ]; then
        show_json="json"
        period="today"
    fi

    traffic_ensure_file

    # Снимаем актуальный snapshot
    traffic_take_snapshot 2>/dev/null || true

    # Текущая сессия
    local counters cur_rx=0 cur_tx=0
    counters=$(traffic_read_tun_counters 2>/dev/null || true)
    if [ -n "$counters" ]; then
        cur_rx=$(echo "$counters" | awk '{print $1}')
        cur_tx=$(echo "$counters" | awk '{print $2}')
    fi

    # Аптайм sing-box
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
            if [ "$diff_sec" -lt 0 ]; then diff_sec=0; fi
            local days=$((diff_sec / 86400))
            local hours=$(( (diff_sec % 86400) / 3600 ))
            local mins=$(( (diff_sec % 3600) / 60 ))
            local parts=""
            [ "$days" -gt 0 ] && parts="${days}д "
            [ "$hours" -gt 0 ] || [ "$days" -gt 0 ] && parts="${parts}${hours}ч "
            parts="${parts}${mins}м"
            uptime_str="$parts"
        fi
    fi

    # Данные за период
    local period_data period_rx=0 period_tx=0
    period_data=$(traffic_get_period "$period")
    period_rx=$(echo "$period_data" | awk '{print $1}')
    period_tx=$(echo "$period_data" | awk '{print $2}')

    # Данные за сегодня (для status/doctor)
    local today_data today_rx=0 today_tx=0
    today_data=$(traffic_get_period "today")
    today_rx=$(echo "$today_data" | awk '{print $1}')
    today_tx=$(echo "$today_data" | awk '{print $2}')

    if [ "$show_json" = "json" ]; then
        python3 -c "
import json
print(json.dumps({
    'current_session': {'rx': $cur_rx, 'tx': $cur_tx},
    'uptime': '$uptime_str',
    'period': '$period',
    'period_rx': $period_rx,
    'period_tx': $period_tx,
    'today_rx': $today_rx,
    'today_tx': $today_tx,
}))
"
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

# Возвращает строку вида "Сегодня: ↑ 1.2 GB ↓ 3.4 GB"
traffic_today_summary() {
    traffic_take_snapshot 2>/dev/null || true

    local data rx=0 tx=0
    data=$(traffic_get_period "today" 2>/dev/null || echo "0 0")
    rx=$(echo "$data" | awk '{print $1}')
    tx=$(echo "$data" | awk '{print $2}')

    echo "Сегодня: ↑ $(traffic_format_bytes "$tx") ↓ $(traffic_format_bytes "$rx")"
}
