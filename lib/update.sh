#!/bin/bash
# warper lib: update.sh
# Безопасное обновление WARPER:
# скачивание во временную директорию → проверки → backup → установка → откат при ошибке.
# Подключается через source из warper.sh

# Откатывает обновление: восстанавливает все файлы из backup-директории.
rollback_warper_update() {
    local backupdir="$1"

    restore_if_exists "$backupdir/warper.sh" "$WARPER_DIR/warper.sh"
    restore_if_exists "$backupdir/uninstaller.sh" "$WARPER_DIR/uninstaller.sh"
    restore_if_exists "$backupdir/version" "$WARPER_DIR/version"

    restore_if_exists "$backupdir/config.json.template" "$SINGBOX_TEMPLATE"
    restore_if_exists "$backupdir/config-slave-master.json.template" "$SLAVE_TEMPLATE"
    restore_if_exists "$backupdir/config-wg.json.template" "$WG_TEMPLATE"

    restore_if_exists "$backupdir/gemini.txt" "$DOWNLOAD_DIR/gemini.txt"
    restore_if_exists "$backupdir/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt"

    restore_if_exists "$backupdir/sing-box.service" \
        "/etc/systemd/system/sing-box.service"
    restore_if_exists "$backupdir/warper-autopatch.service" \
        "/etc/systemd/system/warper-autopatch.service"

    restore_if_exists "$backupdir/config.json" "$SINGBOX_CONF"
    restore_if_exists "$backupdir/domains.txt" "$MASTER_FILE"

    # Откатываем модули
    if [ -d "$backupdir/lib" ]; then
        rm -rf "$WARPER_DIR/lib"
        cp -a "$backupdir/lib" "$WARPER_DIR/lib"
    fi
    if [ -d "$backupdir/menus" ]; then
        rm -rf "$WARPER_DIR/menus"
        cp -a "$backupdir/menus" "$WARPER_DIR/menus"
    fi

    chmod +x "$WARPER_DIR/warper.sh" "$WARPER_DIR/uninstaller.sh" 2>/dev/null || true
    ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# Выполняет полное безопасное обновление WARPER с GitHub.
# Этапы:
#   1. Скачать все файлы во временную директорию
#   2. Проверить синтаксис bash-скриптов
#   3. Проверить маркеры в шаблонах
#   4. Проверить unit-файлы через systemd-analyze
#   5. Сделать backup текущих файлов
#   6. Установить новые файлы
#   7. Пересобрать config.json
#   8. Перезапустить sing-box и проверить
#   9. Обновить домены и IP-маршруты
#  При любой ошибке — откат к backup.
update_warper() {
    echo -e "\n${CYAN}Скачивание обновления с GitHub...${NC}"
    mkdir -p "$DOWNLOAD_DIR"

    local tmpdir backupdir
    local had_singbox=false

    tmpdir=$(mktemp -d /tmp/warper-update.XXXXXX) || {
        echo -e "${RED}Не удалось создать временную директорию.${NC}"
        return 1
    }

    backupdir=$(mktemp -d /tmp/warper-backup.XXXXXX) || {
        rm -rf "$tmpdir"
        echo -e "${RED}Не удалось создать директорию для backup.${NC}"
        return 1
    }

    # ===== Скачиваем файлы =====

    # Основные скрипты
    download_file_safe "$REPO_URL/warper.sh" \
        "$tmpdir/warper.sh" "warper.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/uninstaller.sh" \
        "$tmpdir/uninstaller.sh" "uninstaller.sh" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/version" \
        "$tmpdir/version" "version" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Systemd unit-файлы
    download_file_safe "$REPO_URL/templates/sing-box.service" \
        "$tmpdir/sing-box.service" "sing-box.service" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/warper-autopatch.service" \
        "$tmpdir/warper-autopatch.service" "warper-autopatch.service" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Шаблоны конфигурации
    download_file_safe "$REPO_URL/templates/config.json.template" \
        "$tmpdir/config.json.template" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/config-slave-master.json.template" \
        "$tmpdir/config-slave-master.json.template" "config-slave-master.json.template" || \
        { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/templates/config-wg.json.template" \
        "$tmpdir/config-wg.json.template" "config-wg.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Списки доменов
    download_file_safe "$REPO_URL/download/gemini.txt" \
        "$tmpdir/gemini.txt" "gemini.txt" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    download_file_safe "$REPO_URL/download/chatgpt.txt" \
        "$tmpdir/chatgpt.txt" "chatgpt.txt" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Модули lib/
    mkdir -p "$tmpdir/lib"
    for _libfile in utils config domains singbox kresd warp-keys wg ip-routes diagnostics update; do
        download_file_safe "$REPO_URL/lib/${_libfile}.sh" \
            "$tmpdir/lib/${_libfile}.sh" "lib/${_libfile}.sh" || \
            { rm -rf "$tmpdir" "$backupdir"; return 1; }
    done

    # Модули menus/
    mkdir -p "$tmpdir/menus"
    for _menufile in main settings singbox-menu ip-menu; do
        download_file_safe "$REPO_URL/menus/${_menufile}.sh" \
            "$tmpdir/menus/${_menufile}.sh" "menus/${_menufile}.sh" || \
            { rm -rf "$tmpdir" "$backupdir"; return 1; }
    done

    # ===== Проверка синтаксиса bash =====
    syntax_check_bash_file "$tmpdir/warper.sh" "warper.sh" || \
        { rm -rf "$tmpdir" "$backupdir"; return 1; }
    syntax_check_bash_file "$tmpdir/uninstaller.sh" "uninstaller.sh" || \
        { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # Проверяем синтаксис модулей
    for _libfile in "$tmpdir"/lib/*.sh "$tmpdir"/menus/*.sh; do
        syntax_check_bash_file "$_libfile" "$(basename "$_libfile")" || \
            { rm -rf "$tmpdir" "$backupdir"; return 1; }
    done

    # ===== Проверка шаблонов =====
    validate_template_marker "$tmpdir/config.json.template" \
        "__WARP_ADDRESS__" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    validate_template_marker "$tmpdir/config.json.template" \
        "__SUBNET__" "config.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    validate_template_marker "$tmpdir/config-slave-master.json.template" \
        "__SLAVE_SERVER__" "config-slave-master.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }
    validate_template_marker "$tmpdir/config-wg.json.template" \
        "__WG_ENDPOINT_HOST__" "config-wg.json.template" || { rm -rf "$tmpdir" "$backupdir"; return 1; }

    # ===== Проверка unit-файлов =====
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$tmpdir/sing-box.service" >/dev/null 2>&1 || {
            echo -e "${RED}Некорректный unit-файл sing-box.service${NC}"
            rm -rf "$tmpdir" "$backupdir"; return 1
        }
        systemd-analyze verify "$tmpdir/warper-autopatch.service" >/dev/null 2>&1 || {
            echo -e "${RED}Некорректный unit-файл warper-autopatch.service${NC}"
            rm -rf "$tmpdir" "$backupdir"; return 1
        }
    fi

    # ===== Backup текущих файлов =====
    backup_if_exists "$WARPER_DIR/warper.sh"         "$backupdir/warper.sh"
    backup_if_exists "$WARPER_DIR/uninstaller.sh"    "$backupdir/uninstaller.sh"
    backup_if_exists "$WARPER_DIR/version"           "$backupdir/version"
    backup_if_exists "$SINGBOX_TEMPLATE"             "$backupdir/config.json.template"
    backup_if_exists "$SLAVE_TEMPLATE"               "$backupdir/config-slave-master.json.template"
    backup_if_exists "$WG_TEMPLATE"                  "$backupdir/config-wg.json.template"
    backup_if_exists "$DOWNLOAD_DIR/gemini.txt"      "$backupdir/gemini.txt"
    backup_if_exists "$DOWNLOAD_DIR/chatgpt.txt"     "$backupdir/chatgpt.txt"
    backup_if_exists "/etc/systemd/system/sing-box.service" \
        "$backupdir/sing-box.service"
    backup_if_exists "/etc/systemd/system/warper-autopatch.service" \
        "$backupdir/warper-autopatch.service"
    backup_if_exists "$SINGBOX_CONF"  "$backupdir/config.json"
    backup_if_exists "$MASTER_FILE"   "$backupdir/domains.txt"
    # Backup модулей
    if [ -d "$WARPER_DIR/lib" ]; then
        cp -a "$WARPER_DIR/lib" "$backupdir/lib"
    fi
    if [ -d "$WARPER_DIR/menus" ]; then
        cp -a "$WARPER_DIR/menus" "$backupdir/menus"
    fi

    if systemctl is-active --quiet sing-box; then
        had_singbox=true
    fi

    # ===== Установка новых файлов =====

    install -m 755 "$tmpdir/warper.sh" "$WARPER_DIR/warper.sh" || {
        echo -e "${RED}Ошибка установки warper.sh, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 755 "$tmpdir/uninstaller.sh" "$WARPER_DIR/uninstaller.sh" || {
        echo -e "${RED}Ошибка установки uninstaller.sh, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/version" "$WARPER_DIR/version" || {
        echo -e "${RED}Ошибка установки version, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/config.json.template" "$SINGBOX_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/config-slave-master.json.template" "$SLAVE_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config-slave-master.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/config-wg.json.template" "$WG_TEMPLATE" || {
        echo -e "${RED}Ошибка установки config-wg.json.template, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/gemini.txt" "$DOWNLOAD_DIR/gemini.txt" || {
        echo -e "${RED}Ошибка установки gemini.txt, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/chatgpt.txt" "$DOWNLOAD_DIR/chatgpt.txt" || {
        echo -e "${RED}Ошибка установки chatgpt.txt, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/sing-box.service" \
        "/etc/systemd/system/sing-box.service" || {
        echo -e "${RED}Ошибка установки sing-box.service, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }
    install -m 644 "$tmpdir/warper-autopatch.service" \
        "/etc/systemd/system/warper-autopatch.service" || {
        echo -e "${RED}Ошибка установки warper-autopatch.service, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    }

    # Устанавливаем модули lib/ и menus/
    mkdir -p "$WARPER_DIR/lib" "$WARPER_DIR/menus"
    for _libfile in "$tmpdir"/lib/*.sh; do
        install -m 644 "$_libfile" "$WARPER_DIR/lib/$(basename "$_libfile")" || {
            echo -e "${RED}Ошибка установки $(basename "$_libfile"), откат.${NC}"
            rollback_warper_update "$backupdir"
            rm -rf "$tmpdir" "$backupdir"
            return 1
        }
    done
    for _menufile in "$tmpdir"/menus/*.sh; do
        install -m 644 "$_menufile" "$WARPER_DIR/menus/$(basename "$_menufile")" || {
            echo -e "${RED}Ошибка установки $(basename "$_menufile"), откат.${NC}"
            rollback_warper_update "$backupdir"
            rm -rf "$tmpdir" "$backupdir"
            return 1
        }
    done

    ln -sf "$WARPER_DIR/warper.sh" /usr/local/bin/warper

    if ! systemctl daemon-reload; then
        echo -e "${RED}Ошибка systemctl daemon-reload, откат.${NC}"
        rollback_warper_update "$backupdir"; rm -rf "$tmpdir" "$backupdir"; return 1
    fi

    systemctl enable warper-autopatch >/dev/null 2>&1 || true

    # ===== Пересборка конфига sing-box =====
    echo -e "${CYAN}Обновление конфигурации sing-box...${NC}"
    if ! rebuild_config "$SINGBOX_TEMPLATE"; then
        echo -e "${RED}Ошибка пересборки config.json, откат.${NC}"
        rollback_warper_update "$backupdir"
        if [ "$had_singbox" = true ]; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
        rm -rf "$tmpdir" "$backupdir"; return 1
    fi

    if [ "$had_singbox" = true ]; then
        systemctl restart sing-box
        if ! ensure_singbox_running; then
            echo -e "${RED}Новая версия sing-box не запустилась, откат.${NC}"
            rollback_warper_update "$backupdir"
            systemctl restart sing-box >/dev/null 2>&1 || true
            rm -rf "$tmpdir" "$backupdir"; return 1
        fi
        echo -e "${GREEN}Служба sing-box перезапущена.${NC}"
    fi

    systemctl restart kresd@1 >/dev/null 2>&1 || true

    # ===== Обновление доменов и маршрутов =====
    rebuild_master_file
    update_list_blocks

    if is_warper_active; then
        patch_kresd >/dev/null 2>&1 || {
            echo -e "${YELLOW}Предупреждение: патч DNS не удалось переприменить.${NC}"
        }
    else
        sync_domains >/dev/null 2>&1 || true
    fi

    # Пересинхронизируем IP-маршруты уже новым экземпляром warper
    if is_warper_active && [ "$(count_ip_ranges)" -gt 0 ]; then
        echo -e "${CYAN}Синхронизация IP-маршрутов...${NC}"
        /usr/local/bin/warper ipsync >/dev/null 2>&1 || true
    fi

    rm -rf "$tmpdir" "$backupdir"

    echo -e "${GREEN}Утилита и списки успешно обновлены!${NC}"
    read -r -e -p "Нажмите Enter для перезапуска WARPER..."
    exec /usr/local/bin/warper
}
