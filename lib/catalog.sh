#!/bin/bash
# warper lib: catalog.sh
# Каталог готовых списков доменов из v2fly/domain-list-community.
# Поиск, просмотр, добавление, удаление и обновление списков.
# Подключается через source из warper.sh

CATALOG_CACHE_FILE="$WARPER_DIR/catalog-cache.json"
CATALOG_STATE_FILE="$WARPER_DIR/catalog.json"
CATALOG_CACHE_TTL=86400  # 24 часа в секундах
CATALOG_REPO_API="https://api.github.com/repos/v2fly/domain-list-community/git/trees/master"
CATALOG_RAW_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"

# Популярные категории для пометки
CATALOG_POPULAR="amazon apple aws azure baidu bilibili bing cloudflare discord docker dropbox ebay epic facebook github gitlab google instagram linkedin microsoft netflix notion nvidia openai paypal pinterest reddit samsung signal slack snapchat sony spotify steam telegram tiktok twitch twitter uber whatsapp wikipedia xbox yahoo youtube zoom"

# ===== Кэш списка категорий =====

# Проверяет актуальность кэша (не старше CATALOG_CACHE_TTL)
catalog_cache_is_fresh() {
    [ ! -f "$CATALOG_CACHE_FILE" ] && return 1

    local cached_at
    cached_at=$(jq -r '.cached_at // 0' "$CATALOG_CACHE_FILE" 2>/dev/null)
    [ -z "$cached_at" ] || [ "$cached_at" = "null" ] && return 1

    local now diff
    now=$(date +%s)
    diff=$((now - cached_at))

    [ "$diff" -lt "$CATALOG_CACHE_TTL" ]
}

# Скачивает список всех категорий из GitHub API и кэширует.
# GitHub API git/trees возвращает все файлы из data/ одним запросом.
catalog_refresh_cache() {
    echo -e "${CYAN}Обновление каталога доменов...${NC}" >&2

    local tmp api_response
    tmp=$(mktemp)

    # Получаем дерево репозитория (рекурсивно)
    api_response=$(curl -sS --max-time 30 \
        -H "User-Agent: warper/1.0" \
        -H "Accept: application/vnd.github.v3+json" \
        "${CATALOG_REPO_API}?recursive=1" 2>/dev/null)

    if [ -z "$api_response" ]; then
        echo -e "${RED}Не удалось получить данные с GitHub API${NC}" >&2
        rm -f "$tmp"
        return 1
    fi

    # Проверяем что это валидный JSON с tree
    if ! echo "$api_response" | jq -e '.tree' >/dev/null 2>&1; then
        echo -e "${RED}Невалидный ответ GitHub API${NC}" >&2
        rm -f "$tmp"
        return 1
    fi

    local now
    now=$(date +%s)

    # Извлекаем только файлы из data/ (без поддиректорий)
    # Формат: имя файла = имя категории
    local popular_json
    popular_json=$(printf '%s\n' $CATALOG_POPULAR | jq -R . | jq -s .)

    echo "$api_response" | jq --argjson popular "$popular_json" --argjson ts "$now" '
    {
        cached_at: $ts,
        categories: [
            .tree[]
            | select(.path | startswith("data/"))
            | select(.path | contains("/") | . == ((.path | split("/") | length) == 2))
            | select(.type == "blob")
            | .name = (.path | split("/") | last)
            | select(.name | test("^[a-z0-9]"))
            | {
                name: .name,
                popular: ((.name | ascii_downcase) as $n | ($popular | any(. == $n)))
              }
        ] | sort_by(.name)
    }' > "$tmp" 2>/dev/null

    if [ ! -s "$tmp" ]; then
        echo -e "${RED}Ошибка обработки данных каталога${NC}" >&2
        rm -f "$tmp"
        return 1
    fi

    local count
    count=$(jq '.categories | length' "$tmp" 2>/dev/null)

    mv "$tmp" "$CATALOG_CACHE_FILE"
    chmod 644 "$CATALOG_CACHE_FILE"

    echo -e "${GREEN}Каталог обновлён: ${count} категорий${NC}" >&2
    return 0
}

# Гарантирует наличие актуального кэша
catalog_ensure_cache() {
    if ! catalog_cache_is_fresh; then
        catalog_refresh_cache || return 1
    fi
    return 0
}

# ===== Состояние установленных каталогов =====

catalog_ensure_state() {
    if [ ! -f "$CATALOG_STATE_FILE" ]; then
        echo '{"installed":{}}' > "$CATALOG_STATE_FILE"
        chmod 600 "$CATALOG_STATE_FILE"
    fi
}

# Проверяет установлен ли каталог
catalog_is_installed() {
    local name="$1"
    catalog_ensure_state
    jq -e --arg n "$name" '.installed[$n] != null' "$CATALOG_STATE_FILE" >/dev/null 2>&1
}

# Список установленных каталогов
catalog_list_installed() {
    catalog_ensure_state
    jq -r '.installed | keys[]' "$CATALOG_STATE_FILE" 2>/dev/null
}

# ===== Скачивание и парсинг файла домена =====

# Скачивает файл категории из GitHub.
# Возвращает содержимое через stdout.
catalog_download_file() {
    local name="$1"
    local url="${CATALOG_RAW_URL}/${name}"

    curl -sS --max-time 15 \
        -H "User-Agent: warper/1.0" \
        "$url" 2>/dev/null
}

# Рекурсивно парсит файл категории и извлекает домены.
# Обрабатывает include: директивы.
# Аргументы: имя_категории [глубина_рекурсии]
# Выводит: чистые домены (по одному на строку)
catalog_resolve_domains() {
    local name="$1"
    local depth="${2:-0}"

    # Защита от бесконечной рекурсии
    if [ "$depth" -gt 10 ]; then
        echo "# WARNING: max recursion depth for $name" >&2
        return 0
    fi

    local content
    content=$(catalog_download_file "$name")

    if [ -z "$content" ]; then
        echo "# WARNING: empty or not found: $name" >&2
        return 1
    fi

    local line trimmed rule_type rule_value

    while IFS= read -r line; do
        # Убираем комментарии
        trimmed="${line%%#*}"
        trimmed=$(echo "$trimmed" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$trimmed" ] && continue

        # Убираем атрибуты (@ads, @cn, и т.д.)
        trimmed=$(echo "$trimmed" | awk '{print $1}')

        # Парсим тип правила
        if [[ "$trimmed" == *:* ]]; then
            rule_type="${trimmed%%:*}"
            rule_value="${trimmed#*:}"
        else
            # Без префикса = domain
            rule_type="domain"
            rule_value="$trimmed"
        fi

        rule_type=$(echo "$rule_type" | tr '[:upper:]' '[:lower:]')

        case "$rule_type" in
            include)
                # Рекурсивно подгружаем включённый список
                catalog_resolve_domains "$rule_value" $((depth + 1))
                ;;
            domain|full)
                # Валидируем и выводим домен
                rule_value=$(echo "$rule_value" | tr '[:upper:]' '[:lower:]')
                # Базовая проверка формата
                if [[ "$rule_value" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] && \
                   [[ "$rule_value" == *.* ]]; then
                    echo "$rule_value"
                fi
                ;;
            keyword|regexp)
                # Пропускаем — не подходят для DNS-маршрутизации
                ;;
        esac
    done <<< "$content"
}

# Оптимизирует список доменов:
# - убирает дубликаты
# - убирает поддомены если есть родительский домен
#   (kresd при domain:example.com ловит и sub.example.com)
catalog_optimize_domains() {
    local tmp_all tmp_domains tmp_optimized
    tmp_all=$(mktemp)
    tmp_domains=$(mktemp)
    tmp_optimized=$(mktemp)

    # Читаем из stdin, сортируем, дедуплицируем
    sort -u > "$tmp_all"

    # Разделяем: сначала короткие домены (более общие)
    sort -t. -k1,1 "$tmp_all" > "$tmp_domains"

    # Для каждого домена проверяем: нет ли уже родительского
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue

        local dominated=false
        local parent="$domain"

        # Проверяем все возможные родительские домены
        while [[ "$parent" == *.* ]]; do
            parent="${parent#*.}"
            if grep -qxF "$parent" "$tmp_all" 2>/dev/null; then
                dominated=true
                break
            fi
        done

        if [ "$dominated" = false ]; then
            echo "$domain"
        fi
    done < "$tmp_domains" | sort -u > "$tmp_optimized"

    cat "$tmp_optimized"
    rm -f "$tmp_all" "$tmp_domains" "$tmp_optimized"
}

# ===== Операции с domains.txt =====

# Добавляет домены каталога в domains.txt.
# Не дублирует домены которые уже есть.
# Сохраняет метаданные в catalog.json.
catalog_add() {
    local name="$1"

    catalog_ensure_state

    if catalog_is_installed "$name"; then
        echo -e "${YELLOW}Каталог '$name' уже добавлен. Используйте 'warper catalog update $name' для обновления.${NC}"
        return 0
    fi

    echo -e "${CYAN}Загрузка и разрешение доменов для '$name'...${NC}"

    local domains_tmp resolved_tmp
    domains_tmp=$(mktemp)
    resolved_tmp=$(mktemp)

    # Рекурсивно резолвим все домены
    if ! catalog_resolve_domains "$name" > "$resolved_tmp" 2>/dev/null; then
        echo -e "${RED}Не удалось загрузить список '$name'${NC}"
        rm -f "$domains_tmp" "$resolved_tmp"
        return 1
    fi

    # Оптимизируем (дедуп + убираем поддомены)
    catalog_optimize_domains < "$resolved_tmp" > "$domains_tmp"
    rm -f "$resolved_tmp"

    local total
    total=$(wc -l < "$domains_tmp" | tr -d ' ')

    if [ "$total" -eq 0 ]; then
        echo -e "${RED}Список '$name' пуст или содержит только keyword/regexp правила${NC}"
        rm -f "$domains_tmp"
        return 1
    fi

    echo -e "${CYAN}Найдено доменов: $total (после оптимизации)${NC}"

    # Читаем существующие домены из domains.txt для дедупликации
    local existing_tmp
    existing_tmp=$(mktemp)
    if [ -f "$MASTER_FILE" ]; then
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MASTER_FILE" | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
            tr '[:upper:]' '[:lower:]' | sort -u > "$existing_tmp"
    else
        : > "$existing_tmp"
    fi

    # Фильтруем: только те домены которых ещё нет
    local new_domains_tmp
    new_domains_tmp=$(mktemp)
    comm -23 "$domains_tmp" "$existing_tmp" > "$new_domains_tmp"

    local new_count skipped_count
    new_count=$(wc -l < "$new_domains_tmp" | tr -d ' ')
    skipped_count=$((total - new_count))

    rm -f "$existing_tmp"

    if [ "$new_count" -eq 0 ]; then
        echo -e "${YELLOW}Все $total доменов из '$name' уже есть в списке.${NC}"

        # Всё равно сохраняем в catalog.json чтобы можно было обновлять
        local now_iso domains_json
        now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S")
        domains_json=$(jq -R . < "$domains_tmp" | jq -s .)

        local state_tmp
        state_tmp=$(mktemp)
        jq --arg n "$name" \
           --arg ts "$now_iso" \
           --argjson count "$total" \
           --argjson domains "$domains_json" \
           '.installed[$n] = {
               added_at: $ts,
               updated_at: $ts,
               domains_count: $count,
               domains: $domains
           }' "$CATALOG_STATE_FILE" > "$state_tmp"

        if [ -s "$state_tmp" ]; then
            mv "$state_tmp" "$CATALOG_STATE_FILE"
            chmod 600 "$CATALOG_STATE_FILE"
        else
            rm -f "$state_tmp"
        fi

        rm -f "$domains_tmp" "$new_domains_tmp"
        return 0
    fi

    # Добавляем в domains.txt
    local display_name
    display_name=$(echo "$name" | sed 's/\b\(.\)/\u\1/g' 2>/dev/null || echo "$name")

    {
        echo ""
        echo "# ${display_name} (catalog: ${name})"
        cat "$new_domains_tmp"
    } >> "$MASTER_FILE"

    # Сохраняем все домены (включая уже существовавшие) в catalog.json
    local now_iso domains_json
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%S")
    domains_json=$(jq -R . < "$domains_tmp" | jq -s .)

    local state_tmp
    state_tmp=$(mktemp)
    jq --arg n "$name" \
       --arg ts "$now_iso" \
       --argjson count "$total" \
       --argjson domains "$domains_json" \
       '.installed[$n] = {
           added_at: $ts,
           updated_at: $ts,
           domains_count: $count,
           domains: $domains
       }' "$CATALOG_STATE_FILE" > "$state_tmp"

    if [ -s "$state_tmp" ]; then
        mv "$state_tmp" "$CATALOG_STATE_FILE"
        chmod 600 "$CATALOG_STATE_FILE"
    else
        rm -f "$state_tmp"
    fi

    rm -f "$domains_tmp" "$new_domains_tmp"

    echo -e "${GREEN}Добавлено: ${new_count} доменов из '$name'${NC}"
    if [ "$skipped_count" -gt 0 ]; then
        echo -e "${YELLOW}Пропущено (уже были): ${skipped_count}${NC}"
    fi

    return 0
}

# Удаляет домены каталога из domains.txt.
catalog_remove() {
    local name="$1"

    catalog_ensure_state

    if ! catalog_is_installed "$name"; then
        echo -e "${RED}Каталог '$name' не установлен${NC}"
        return 1
    fi

    # Получаем список доменов этого каталога из state
    local domains_json
    domains_json=$(jq -r --arg n "$name" '.installed[$n].domains // [] | .[]' \
        "$CATALOG_STATE_FILE" 2>/dev/null)

    if [ -z "$domains_json" ]; then
        echo -e "${YELLOW}Нет данных о доменах каталога '$name'${NC}"
    else
        # Удаляем каждый домен из domains.txt
        local removed=0
        while IFS= read -r domain; do
            [ -z "$domain" ] && continue
            local escaped
            escaped=$(echo "$domain" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
            if grep -qx "[[:space:]]*${escaped}[[:space:]]*" "$MASTER_FILE" 2>/dev/null; then
                sed -i "/^[[:space:]]*${escaped}[[:space:]]*$/d" "$MASTER_FILE"
                ((removed+=1))
            fi
        done <<< "$domains_json"

        # Удаляем комментарий каталога
        sed -i "/^# .*(catalog: ${name})$/d" "$MASTER_FILE"

        # Убираем двойные пустые строки
        sed -i '/^$/N;/^\n$/d' "$MASTER_FILE"

        echo -e "${GREEN}Удалено доменов: ${removed} из каталога '$name'${NC}"
    fi

    # Удаляем из state
    local state_tmp
    state_tmp=$(mktemp)
    jq --arg n "$name" 'del(.installed[$n])' "$CATALOG_STATE_FILE" > "$state_tmp"

    if [ -s "$state_tmp" ]; then
        mv "$state_tmp" "$CATALOG_STATE_FILE"
        chmod 600 "$CATALOG_STATE_FILE"
    else
        rm -f "$state_tmp"
    fi

    return 0
}

# Обновляет конкретный каталог или все установленные.
catalog_update_installed() {
    local name="${1:-}"

    catalog_ensure_state

    local catalogs_to_update
    if [ -n "$name" ]; then
        if ! catalog_is_installed "$name"; then
            echo -e "${RED}Каталог '$name' не установлен${NC}"
            return 1
        fi
        catalogs_to_update="$name"
    else
        catalogs_to_update=$(catalog_list_installed)
        if [ -z "$catalogs_to_update" ]; then
            echo -e "${YELLOW}Нет установленных каталогов для обновления${NC}"
            return 0
        fi
    fi

    local updated=0 failed=0

    while IFS= read -r cat_name; do
        [ -z "$cat_name" ] && continue
        echo -e "\n${CYAN}Обновление '$cat_name'...${NC}"

        # Удаляем старые домены
        catalog_remove "$cat_name" >/dev/null 2>&1

        # Добавляем заново
        if catalog_add "$cat_name"; then
            ((updated+=1))
        else
            echo -e "${RED}Ошибка обновления '$cat_name'${NC}"
            ((failed+=1))
        fi
    done <<< "$catalogs_to_update"

    echo -e "\n${GREEN}Обновлено: ${updated}${NC}"
    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}Ошибок: ${failed}${NC}"
    fi

    return 0
}

# ===== Поиск и отображение =====

# Поиск категорий по имени
catalog_search() {
    local query="${1:-}"

    catalog_ensure_cache || return 1

    if [ -z "$query" ]; then
        # Без запроса — показываем популярные
        echo -e "${CYAN}Популярные категории:${NC}"
        jq -r '.categories[] | select(.popular == true) | .name' \
            "$CATALOG_CACHE_FILE" 2>/dev/null | while IFS= read -r name; do
            if catalog_is_installed "$name"; then
                echo -e "  ${GREEN}✓${NC} ${name} ${CYAN}(установлен)${NC}"
            else
                echo -e "  ${YELLOW}•${NC} ${name}"
            fi
        done
        return 0
    fi

    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    local results
    results=$(jq -r --arg q "$query_lower" \
        '.categories[] | select(.name | contains($q)) | .name' \
        "$CATALOG_CACHE_FILE" 2>/dev/null)

    if [ -z "$results" ]; then
        echo -e "${YELLOW}Ничего не найдено по запросу '$query'${NC}"
        return 0
    fi

    local count
    count=$(echo "$results" | wc -l)
    echo -e "${GREEN}Найдено: ${count} категорий по запросу '$query'${NC}"
    echo ""

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local popular_mark=""
        if jq -e --arg n "$name" '.categories[] | select(.name == $n and .popular == true)' \
            "$CATALOG_CACHE_FILE" >/dev/null 2>&1; then
            popular_mark=" ⭐"
        fi

        if catalog_is_installed "$name"; then
            echo -e "  ${GREEN}✓${NC} ${name}${popular_mark} ${CYAN}(установлен)${NC}"
        else
            echo -e "  ${YELLOW}•${NC} ${name}${popular_mark}"
        fi
    done <<< "$results"

    return 0
}

# Показать домены из категории (без добавления)
catalog_show() {
    local name="$1"

    echo -e "${CYAN}Загрузка доменов из '$name'...${NC}"

    local resolved_tmp domains_tmp
    resolved_tmp=$(mktemp)
    domains_tmp=$(mktemp)

    if ! catalog_resolve_domains "$name" > "$resolved_tmp" 2>/dev/null; then
        echo -e "${RED}Не удалось загрузить '$name'${NC}"
        rm -f "$resolved_tmp" "$domains_tmp"
        return 1
    fi

    catalog_optimize_domains < "$resolved_tmp" > "$domains_tmp"
    rm -f "$resolved_tmp"

    local total
    total=$(wc -l < "$domains_tmp" | tr -d ' ')

    echo -e "${GREEN}Домены в '$name' (${total}):${NC}"
    cat "$domains_tmp"

    rm -f "$domains_tmp"
    return 0
}

# ===== CLI =====

cli_catalog() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        search)
            catalog_search "$@"
            ;;
        show)
            local name="${1:-}"
            if [ -z "$name" ]; then
                echo "Использование: warper catalog show NAME" >&2
                return 1
            fi
            catalog_show "$name"
            ;;
        add)
            local name="${1:-}"
            if [ -z "$name" ]; then
                echo "Использование: warper catalog add NAME" >&2
                return 1
            fi
            catalog_add "$name"
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        remove)
            local name="${1:-}"
            if [ -z "$name" ]; then
                echo "Использование: warper catalog remove NAME" >&2
                return 1
            fi
            catalog_remove "$name"
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        update)
            catalog_update_installed "${1:-}"
            if is_warper_active; then
                patch_kresd >/dev/null 2>&1 || true
            else
                sync_domains
            fi
            ;;
        list)
            catalog_ensure_state
            local installed
            installed=$(catalog_list_installed)
            if [ -z "$installed" ]; then
                echo -e "${YELLOW}Нет установленных каталогов${NC}"
            else
                echo -e "${CYAN}Установленные каталоги:${NC}"
                while IFS= read -r name; do
                    local count updated
                    count=$(jq -r --arg n "$name" '.installed[$n].domains_count // 0' \
                        "$CATALOG_STATE_FILE" 2>/dev/null)
                    updated=$(jq -r --arg n "$name" '.installed[$n].updated_at // "?"' \
                        "$CATALOG_STATE_FILE" 2>/dev/null)
                    echo -e "  ${GREEN}✓${NC} ${name} (${count} доменов, обновлён: ${updated})"
                done <<< "$installed"
            fi
            ;;
        refresh)
            catalog_refresh_cache
            ;;
        json)
            # JSON-вывод для веб-панели
            local subaction="${1:-}"
            shift 2>/dev/null || true
            case "$subaction" in
                search)
                    catalog_ensure_cache || { echo '{"error":"cache failed"}'; return 1; }
                    local q="${1:-}"
                    local q_lower
                    q_lower=$(echo "$q" | tr '[:upper:]' '[:lower:]')

                    catalog_ensure_state

                    local installed_json
                    installed_json=$(jq '.installed | keys' "$CATALOG_STATE_FILE" 2>/dev/null || echo '[]')

                    if [ -z "$q" ]; then
                        # Популярные
                        jq --argjson inst "$installed_json" \
                            '[.categories[] | select(.popular == true) |
                             {name, popular, installed: ([.name] | inside($inst))}]' \
                            "$CATALOG_CACHE_FILE" 2>/dev/null
                    else
                        jq --arg q "$q_lower" --argjson inst "$installed_json" \
                            '[.categories[] | select(.name | contains($q)) |
                             {name, popular, installed: ([.name] | inside($inst))}]' \
                            "$CATALOG_CACHE_FILE" 2>/dev/null
                    fi
                    ;;
                installed)
                    catalog_ensure_state
                    jq '.installed | to_entries | map({
                        name: .key,
                        domains_count: .value.domains_count,
                        added_at: .value.added_at,
                        updated_at: .value.updated_at
                    })' "$CATALOG_STATE_FILE" 2>/dev/null || echo '[]'
                    ;;
                show)
                    local name="${1:-}"
                    [ -z "$name" ] && { echo '{"error":"name required"}'; return 1; }
                    local resolved_tmp domains_tmp
                    resolved_tmp=$(mktemp)
                    domains_tmp=$(mktemp)
                    catalog_resolve_domains "$name" > "$resolved_tmp" 2>/dev/null
                    catalog_optimize_domains < "$resolved_tmp" > "$domains_tmp"
                    rm -f "$resolved_tmp"
                    local total
                    total=$(wc -l < "$domains_tmp" | tr -d ' ')
                    local domains_arr
                    domains_arr=$(jq -R . < "$domains_tmp" | jq -s .)
                    rm -f "$domains_tmp"
                    jq -n --arg name "$name" --argjson count "$total" --argjson domains "$domains_arr" \
                        '{name: $name, count: $count, domains: $domains}'
                    ;;
                *)
                    echo '{"error":"unknown subaction"}' >&2
                    return 1
                    ;;
            esac
            ;;
        ""|help)
            echo "Использование:"
            echo "  warper catalog search [QUERY]  — поиск по имени"
            echo "  warper catalog show NAME       — показать домены"
            echo "  warper catalog add NAME        — добавить в WARPER"
            echo "  warper catalog remove NAME     — удалить из WARPER"
            echo "  warper catalog update [NAME]   — обновить (все или указанный)"
            echo "  warper catalog list            — установленные каталоги"
            echo "  warper catalog refresh         — обновить кэш категорий"
            ;;
        *)
            echo "Неизвестная команда: $action" >&2
            echo "Используйте: warper catalog help" >&2
            return 1
            ;;
    esac
}
