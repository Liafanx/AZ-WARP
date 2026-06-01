#!/bin/bash
# warper lib: domains.sh
# Работа со списком доменов: чтение, запись, синхронизация,
# включение/выключение встроенных списков (Gemini, ChatGPT).
# Сохраняет пользовательские комментарии и пустые строки в domains.txt.
# Подключается через source из warper.sh

# ===== Проверка блоков =====

# Проверяет наличие маркера встроенного списка в domains.txt
has_list_block() {
    local list_name="$1"
    grep -qxF "# --- ${list_name^^} ---" "$MASTER_FILE" 2>/dev/null
}

# ===== Извлечение данных =====

# Извлекает только валидные домены из пользовательского блока.
# Без комментариев, без пустых строк, для применения в DNS.
# Возвращает уникальный отсортированный список.
extract_user_domains() {
    local input="$1"
    extract_user_block_raw "$input" | while IFS= read -r line; do
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" == \#* ]] && continue
        validate_domain "$trimmed" 2>/dev/null || true
    done | sort -u
}

# Извлекает пользовательский блок "как есть" — со всеми комментариями
# и пустыми строками. Исключает только:
#   - шапку файла (до маркера "# Пользовательские домены:")
#   - блоки GEMINI/CHATGPT целиком
extract_user_block_raw() {
    local input="$1"
    [ -f "$input" ] || return 0

    awk '
    BEGIN {
        skip_header = 1
        in_block = 0
    }
    {
        # Шапка: пропускаем до маркера "# Пользовательские домены:"
        if (skip_header) {
            if ($0 ~ /^# Пользовательские домены:/) {
                skip_header = 0
            }
            next
        }
        # Маркеры встроенных блоков
        if ($0 ~ /^# --- [A-Z0-9_]+ ---$/) {
            in_block = 1
            next
        }
        if ($0 ~ /^# --- END [A-Z0-9_]+ ---$/) {
            in_block = 0
            next
        }
        if (in_block) next
        # Всё остальное (включая комментарии и пустые строки) - сохраняем
        print
    }
    ' "$input" | _trim_trailing_blank_lines
}

# Убирает хвостовые пустые строки из stdin
_trim_trailing_blank_lines() {
    awk '
    /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
    { printf "%s", blanks; blanks = ""; print }
    '
}

# Извлекает блок встроенного списка (GEMINI или CHATGPT) вместе с маркерами
extract_block() {
    local input="$1"
    local list_name="$2"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"
    awk -v start="$marker" -v end="$end_marker" '
    $0 == start { in_block=1 }
    in_block { print }
    $0 == end { in_block=0 }
    ' "$input"
}

# ===== Пересборка master-файла =====

# Пересобирает domains.txt из трёх частей:
# 1) шапка
# 2) пользовательский блок "как есть" (с комментариями и пустыми строками)
# 3) блок GEMINI (если был)
# 4) блок CHATGPT (если был)
# При этом валидирует домены в пользовательском блоке — невалидные молча выбрасываются.
rebuild_master_file() {
    local source_file="${1:-$MASTER_FILE}"
    local output_file="${2:-$MASTER_FILE}"

    local tmp user_raw_tmp user_clean_tmp gemini_tmp chatgpt_tmp
    tmp=$(mktemp)
    user_raw_tmp=$(mktemp)
    user_clean_tmp=$(mktemp)
    gemini_tmp=$(mktemp)
    chatgpt_tmp=$(mktemp)

    # Извлекаем пользовательский блок как есть
    extract_user_block_raw "$source_file" > "$user_raw_tmp"

    # Фильтруем: пустые и комментарии - сохраняем, домены - валидируем
    # Дубликаты доменов убираем (первое вхождение сохраняем).
    awk '
    /^[[:space:]]*$/ { print; next }      # пустая строка
    /^[[:space:]]*#/ { print; next }      # комментарий
    {
        # Триммим и нижний регистр
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length == 0) next
        line = tolower($0)
        if (!seen[line]++) {
            print line
        }
    }
    ' "$user_raw_tmp" > "$user_clean_tmp"

    # Удалим в Python-стиле потенциальные строки с не-доменами
    # (для надёжности — используем bash + validate_domain)
    local _verified_tmp
    _verified_tmp=$(mktemp)
    while IFS= read -r line; do
        # Сохраняем комментарии и пустые строки как есть
        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >> "$_verified_tmp"
            continue
        fi
        # Домены валидируем
        local clean
        clean=$(validate_domain "$line" 2>/dev/null || true)
        if [ -n "$clean" ]; then
            echo "$clean" >> "$_verified_tmp"
        fi
        # Невалидные молча выбрасываем
    done < "$user_clean_tmp"
    mv "$_verified_tmp" "$user_clean_tmp"

    extract_block "$source_file" "gemini" > "$gemini_tmp"
    extract_block "$source_file" "chatgpt" > "$chatgpt_tmp"

    {
        cat << 'EOF'
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
EOF
        if [ -s "$user_clean_tmp" ]; then
            cat "$user_clean_tmp"
        fi
        if [ -s "$gemini_tmp" ]; then
            echo ""
            cat "$gemini_tmp"
        fi
        if [ -s "$chatgpt_tmp" ]; then
            echo ""
            cat "$chatgpt_tmp"
        fi
    } > "$tmp"

    mv "$tmp" "$output_file"
    rm -f "$user_raw_tmp" "$user_clean_tmp" "$gemini_tmp" "$chatgpt_tmp"
}

# Вычисляет канонический хэш domains.txt после нормализации.
# Используется для определения изменений при редактировании в nano.
canonical_master_hash() {
    local tmp result
    tmp=$(mktemp)
    rebuild_master_file "$MASTER_FILE" "$tmp"
    result=$(sha256sum "$tmp" | awk '{print $1}')
    rm -f "$tmp"
    echo "$result"
}

# Добавляет домен в пользовательский блок ПОСЛЕ маркера "# Пользовательские домены:".
# Сохраняет существующие комментарии и пустые строки.
insert_user_domain() {
    local domain="$1"

    # Проверка дубликата (без учёта регистра, среди валидных доменов)
    local existing
    existing=$(extract_user_domains "$MASTER_FILE")
    if echo "$existing" | grep -qxF "$domain"; then
        return 0
    fi

    # Если файла нет — создаём минимальный
    if [ ! -f "$MASTER_FILE" ]; then
        cat << EOF > "$MASTER_FILE"
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP
# Строки, начинающиеся с '#', игнорируются.
# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT
# ==========================================

# Пользовательские домены:
$domain
EOF
        return 0
    fi

    # Если в файле нет маркера "# Пользовательские домены:" — пересобираем целиком
    if ! grep -qxF "# Пользовательские домены:" "$MASTER_FILE"; then
        rebuild_master_file
        # Добавляем домен в конец пользовательского блока (перед первым "# --- ")
        local tmp
        tmp=$(mktemp)
        awk -v d="$domain" '
        BEGIN { inserted=0 }
        /^# --- [A-Z0-9_]+ ---$/ && !inserted {
            print d
            print ""
            inserted=1
        }
        { print }
        END {
            if (!inserted) {
                print d
            }
        }
        ' "$MASTER_FILE" > "$tmp"
        mv "$tmp" "$MASTER_FILE"
        return 0
    fi

    # Вставляем строку сразу после маркера "# Пользовательские домены:"
    local tmp
    tmp=$(mktemp)
    awk -v d="$domain" '
    {
        print
        if (!inserted && $0 == "# Пользовательские домены:") {
            print d
            inserted=1
        }
    }
    ' "$MASTER_FILE" > "$tmp"
    mv "$tmp" "$MASTER_FILE"
}

# ===== Фильтрация и синхронизация =====

# Фильтрует файл доменов: оставляет только валидные домены (без комментариев и дубликатов)
# Используется для генерации warper-domains.txt
filter_valid_domains_file() {
    local input="$1" output="$2"
    : > "$output"
    while IFS= read -r line; do
        local trimmed clean
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" =~ ^# ]] && continue
        clean=$(validate_domain "$trimmed" 2>/dev/null || true)
        [ -n "$clean" ] && echo "$clean" >> "$output"
    done < "$input"
    sort -u -o "$output" "$output"
}

# Синхронизирует domains.txt → warper-domains.txt (активный список для kresd)
sync_domains() {
    local tmp
    tmp=$(mktemp /tmp/warper_sync.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
}

# Проверяет: соответствует ли активный список (warper-domains.txt)
# текущему содержимому domains.txt
domains_in_sync() {
    local tmp_master tmp_active
    tmp_master=$(mktemp /tmp/warper_master_compare.XXXXXX)
    tmp_active=$(mktemp /tmp/warper_active_compare.XXXXXX)
    filter_valid_domains_file "$MASTER_FILE" "$tmp_master"
    if [ -f "$ACTIVE_FILE" ]; then
        filter_valid_domains_file "$ACTIVE_FILE" "$tmp_active"
    else
        : > "$tmp_active"
    fi
    local result=1
    if cmp -s "$tmp_master" "$tmp_active"; then result=0; fi
    rm -f "$tmp_master" "$tmp_active"
    return "$result"
}

# ===== Управление встроенными списками =====

# Включает или выключает встроенный список доменов (gemini/chatgpt).
# Сохраняет пользовательский блок (с комментариями) нетронутым.
enable_disable_list() {
    local action="$1" list_name="$2"
    local list_file="$DOWNLOAD_DIR/${list_name}.txt"
    local marker="# --- ${list_name^^} ---"
    local end_marker="# --- END ${list_name^^} ---"

    if [ ! -f "$list_file" ]; then
        echo -e "${RED}Файл списка $list_file не найден!${NC}"
        return 1
    fi

    local valid_tmp
    valid_tmp=$(mktemp /tmp/warper_valid_list.XXXXXX)
    filter_valid_domains_file "$list_file" "$valid_tmp"

    if [ "$action" = "enable" ]; then
        if has_list_block "$list_name"; then
            rm -f "$valid_tmp"
            echo -e "${YELLOW}Список ${list_name^^} уже включен.${NC}"
            return 0
        fi
        # Добавляем блок в конец файла, не трогая остальное
        {
            echo ""
            echo "$marker"
            cat "$valid_tmp"
            echo "$end_marker"
        } >> "$MASTER_FILE"
        rm -f "$valid_tmp"
        echo -e "${GREEN}Список ${list_name^^} включен.${NC}"
        return 0
    fi

    if [ "$action" = "disable" ]; then
        if ! has_list_block "$list_name"; then
            rm -f "$valid_tmp"
            echo -e "${YELLOW}Список ${list_name^^} уже выключен.${NC}"
            return 0
        fi
        # Вырезаем блок целиком, не трогая остальное
        local tmp
        tmp=$(mktemp)
        awk -v start="$marker" -v end="$end_marker" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
        ' "$MASTER_FILE" > "$tmp"
        # Убираем двойные пустые строки которые могли остаться
        awk 'BEGIN{prev_blank=0} /^[[:space:]]*$/{if(!prev_blank)print; prev_blank=1; next} {print; prev_blank=0}' "$tmp" > "${tmp}.norm"
        mv "${tmp}.norm" "$MASTER_FILE"
        rm -f "$valid_tmp" "$tmp"
        echo -e "${YELLOW}Список ${list_name^^} выключен.${NC}"
        return 0
    fi

    rm -f "$valid_tmp"
    return 1
}

# Переключает состояние встроенного списка (вкл↔выкл)
# и предлагает применить изменения к DNS
toggle_list() {
    local list_name=$1
    if has_list_block "$list_name"; then
        enable_disable_list disable "$list_name"
    else
        enable_disable_list enable "$list_name"
    fi
    prompt_apply
}

# Обновляет содержимое включённых встроенных списков
# (пересоздаёт блоки из актуальных файлов в download/)
update_list_blocks() {
    for list_name in "gemini" "chatgpt"; do
        if has_list_block "$list_name"; then
            enable_disable_list disable "$list_name" >/dev/null 2>&1 || true
            enable_disable_list enable "$list_name" >/dev/null 2>&1 || true
        fi
    done
}

# ===== CLI-команды =====

# CLI: добавить домен в список маршрутизации
cli_add_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1
    }
    # Проверяем не существует ли уже (среди валидных)
    if extract_user_domains "$MASTER_FILE" | grep -qxF "$domain"; then
        echo -e "${YELLOW}Домен уже есть: $domain${NC}"; return 0
    fi
    insert_user_domain "$domain"
    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || true
    else
        sync_domains
    fi
    echo -e "${GREEN}Домен добавлен: $domain${NC}"
    return 0
}

# CLI: удалить домен из списка маршрутизации.
# Удаляет ТОЛЬКО строку с этим доменом, комментарии и другие домены не трогает.
cli_remove_domain() {
    local raw="$1"
    local domain
    domain=$(validate_domain "$raw") || {
        echo -e "${RED}Некорректный домен: $raw${NC}" >&2; return 1
    }

    if ! extract_user_domains "$MASTER_FILE" | grep -qxF "$domain"; then
        echo -e "${YELLOW}Домен не найден: $domain${NC}"
        return 0
    fi

    # Удаляем строку с доменом (точное совпадение, без учёта пробелов вокруг)
    local escaped
    escaped=$(escape_regex "$domain")
    sed -i "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$MASTER_FILE"

    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || true
    else
        sync_domains
    fi
    echo -e "${GREEN}Домен удалён: $domain${NC}"
    return 0
}

# CLI: включить встроенный список (gemini/chatgpt)
cli_enable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list enable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}

# CLI: выключить встроенный список (gemini/chatgpt)
cli_disable_list() {
    local list_name="$1"
    case "$list_name" in
        gemini|chatgpt)
            enable_disable_list disable "$list_name" || return 1
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        *) echo -e "${RED}Неизвестный список: $list_name${NC}" >&2; return 1 ;;
    esac
}
