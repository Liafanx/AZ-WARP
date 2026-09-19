#!/bin/bash
# warper lib: utils.sh
# Вспомогательные функции без внешних зависимостей.
# Используются всеми остальными модулями.
# Подключается через source из warper.sh

# ===== Интерактивный режим =====

# Проверяет: запущен ли скрипт в интерактивном терминале
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# ===== Работа со строками =====

# Экранирует спецсимволы для использования в regex
escape_regex() {
    printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

# ===== Валидация =====

# Проверяет корректность доменного имени.
# Возвращает нормализованный домен или код ошибки 1.
validate_domain() {
    local domain="$1"
    domain=$(echo "$domain" | xargs)
    domain="${domain%.}"
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    if [ -z "$domain" ]; then return 1; fi
    if [[ ! "$domain" =~ \. ]]; then return 1; fi
    if [[ "$domain" =~ \.\. ]]; then return 1; fi
    if [[ "$domain" =~ ^- || "$domain" =~ -$ ]]; then return 1; fi
    if [[ ! "$domain" =~ ^[a-z0-9._-]+$ ]]; then return 1; fi
    local labels
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        if [ -z "$label" ] || [ ${#label} -gt 63 ]; then return 1; fi
        if [[ "$label" =~ ^- || "$label" =~ -$ ]]; then return 1; fi
        if [[ ! "$label" =~ ^[a-z0-9_-]+$ ]]; then return 1; fi
    done
    echo "$domain"
    return 0
}

# Проверяет корректность подсети формата X.X.X.0/XX
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

# Проверяет корректность CIDR (A.B.C.D/M).
# Отклоняет loopback, link-local, multicast, нулевой октет.
# Возвращает нормализованный CIDR или код ошибки 1.
validate_cidr() {
    local cidr="$1"
    cidr=$(echo "$cidr" | tr -d '[:space:]')
    [ -z "$cidr" ] && return 1

    if [[ ! "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        return 1
    fi

    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" mask="${BASH_REMATCH[5]}"

    if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then return 1; fi
    if (( mask < 1 || mask > 32 )); then return 1; fi
    (( o1 == 127 || o1 == 0 || o1 >= 224 )) && return 1
    (( o1 == 169 && o2 == 254 )) && return 1

    echo "$cidr"
    return 0
}

# Проверяет допустимость значения MTU (1280-1500)
validate_mtu() {
    local mtu="$1"
    if [[ ! "$mtu" =~ ^[0-9]+$ ]]; then return 1; fi
    if (( mtu < 1280 || mtu > 1500 )); then return 1; fi
    return 0
}

# Проверяет допустимость номера порта (1-65535)
validate_port_simple() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# ===== Сетевые утилиты =====

# Вычисляет TUN IP из подсети (X.X.X.0/M → X.X.X.1/M)
calculate_tun_ip() {
    local subnet="$1"
    local base="${subnet%.*}"
    local mask="${subnet##*/}"
    echo "${base}.1/${mask}"
}

# Проверяет конфликт fake-подсети с существующими адресами,
# маршрутами и Docker-сетями
subnet_conflicts() {
    local subnet="$1"
    local line iface route_net

    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        route_net=$(echo "$line" | awk '{print $4}')
        [ "$route_net" = "$subnet" ] || continue
        [ "$iface" = "singbox-tun" ] && continue
        return 0
    done < <(ip -o -4 addr show 2>/dev/null)

    while IFS= read -r line; do
        route_net=$(echo "$line" | awk '{print $1}')
        [ "$route_net" = "$subnet" ] || continue
        grep -q "dev singbox-tun" <<< "$line" && continue
        return 0
    done < <(ip route 2>/dev/null)

    if command -v docker >/dev/null 2>&1; then
        local ids
        ids=$(docker network ls -q 2>/dev/null || true)
        if [ -n "$ids" ]; then
            local -a id_array
            mapfile -t id_array <<< "$ids"
            if [ ${#id_array[@]} -gt 0 ]; then
                local nets
                nets=$(docker network inspect "${id_array[@]}" 2>/dev/null || true)
                grep -qF "\"Subnet\": \"$subnet\"" <<< "$nets" && return 0
            fi
        fi
    fi

    return 1
}

# ===== Файловые операции =====

# Удаляет дубликаты и пустые строки из файла
normalize_include_ips() {
    local file="$1"
    local tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp)
    awk 'NF && !seen[$0]++' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Безопасно копирует файл если источник существует
backup_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

# Безопасно восстанавливает файл из резервной копии
restore_if_exists() {
    local src="$1"
    local dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
    fi
}

# ===== Версионирование =====

# Сравнивает версии: возвращает 0 если $1 > $2
version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

# ===== Загрузка файлов =====

# Безопасно скачивает файл во временную директорию,
# проверяет что он не пустой, затем перемещает на место
download_file_safe() {
    local url="$1" dest="$2" desc="$3"
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL -o "$tmp" "${url}?t=$(date +%s)"; then
        echo -e "${RED}Ошибка загрузки: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Загруженный файл пуст: ${desc}${NC}"
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$dest"
    return 0
}

# Проверяет синтаксис bash-скрипта перед установкой
syntax_check_bash_file() {
    local file="$1"
    local desc="$2"
    if ! bash -n "$file"; then
        echo -e "${RED}Ошибка синтаксиса в ${desc}${NC}"
        return 1
    fi
    return 0
}

# Проверяет наличие обязательного маркера в шаблоне конфигурации
validate_template_marker() {
    local file="$1"
    local marker="$2"
    local desc="$3"
    if ! grep -qF "$marker" "$file" 2>/dev/null; then
        echo -e "${RED}Файл ${desc} повреждён или неполон.${NC}"
        return 1
    fi
    return 0
}

# ===== Безопасные проверки вывода =====

# Проверяет, содержит ли вывод команды подстроку.
# Прямой конвейер `cmd | grep -q` ненадёжен при `set -o pipefail`:
# grep выходит по первому совпадению, писатель получает SIGPIPE,
# и конвейер возвращает 141 даже когда совпадение было.
output_has() {
    local pattern="$1"; shift
    local out
    out=$("$@" 2>/dev/null || true)
    [ -n "$out" ] || return 1
    grep -qE -- "$pattern" <<< "$out"
}

# ===== WARP-конфиг AntiZapret =====

# Возвращает первый существующий системный WARP-конфиг AntiZapret.
# Если ни одного нет — печатает последний кандидат и возвращает 1,
# чтобы вызывающий код мог показать осмысленный путь в сообщении.
resolve_warp_system_conf() {
    local candidate last=""
    for candidate in $WARP_SYSTEM_CANDIDATES; do
        last="$candidate"
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "$last"
    return 1
}

# ===== Управление iptables =====

# Добавляет правило iptables если оно ещё не существует
ensure_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null || \
        iptables -I "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

# Удаляет правило iptables если оно существует
remove_iptables_rule() {
    local chain="$1" iface_flag="$2" iface_name="$3"
    iptables -C "$chain" "$iface_flag" "$iface_name" -j ACCEPT 2>/dev/null && \
        iptables -D "$chain" "$iface_flag" "$iface_name" -j ACCEPT
}

# ===== Проверки файлов =====

# Проверяет что права доступа к файлу равны 600
file_mode_is_600() {
    local file="$1"
    [ -f "$file" ] || return 1
    [ "$(stat -c %a "$file" 2>/dev/null || true)" = "600" ]
}
