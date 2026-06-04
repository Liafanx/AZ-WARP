#!/bin/bash
# warper menus: web-menu.sh
# Меню управления веб-панелью: установка, удаление, смена пароля, логи.
# Подключается через source из warper.sh

WEB_DIR="/root/warper/web"
WEB_SERVICE="warper-web"

# Проверка установлена ли веб-панель
web_is_installed() {
    [ -d "$WEB_DIR" ] && [ -f "$WEB_DIR/app.py" ]
}

web_is_running() {
    systemctl is-active --quiet "$WEB_SERVICE" 2>/dev/null
}

web_get_port() {
    if [ -f "$WEB_DIR/.env" ]; then
        grep -E '^PORT=' "$WEB_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2
    fi
}

web_get_public_ip() {
    curl -s -4 --connect-timeout 3 ifconfig.me 2>/dev/null \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || echo "0.0.0.0"
}

web_get_https_status_field() {
    local key="$1"
    cli_web_https status 2>/dev/null | awk -F= -v k="$key" '
        $1 == k {
            print substr($0, length($1) + 2)
            exit
        }
    '
}

web_get_https_mode() {
    web_get_https_status_field "mode"
}

web_get_https_domain() {
    web_get_https_status_field "domain"
}

web_get_https_mode_label() {
    local mode domain
    mode=$(web_get_https_mode)
    domain=$(web_get_https_domain)

    case "$mode" in
        letsencrypt)
            if [ -n "$domain" ]; then
                echo -e "${GREEN}Let's Encrypt${NC} ${CYAN}(${domain})${NC}"
            else
                echo -e "${GREEN}Let's Encrypt${NC}"
            fi
            ;;
        selfsigned)
            echo -e "${YELLOW}Самоподписанный${NC}"
            ;;
        http|"")
            echo -e "${CYAN}HTTP${NC}"
            ;;
        *)
            echo -e "${YELLOW}${mode}${NC}"
            ;;
    esac
}

web_get_external_port() {
    local port
    port=$(web_get_https_status_field "port")
    if [ -n "$port" ]; then
        echo "$port"
        return
    fi

    local nginx_conf="/etc/nginx/sites-available/warper-web"
    [ -f "$nginx_conf" ] || { echo ""; return; }

    port=$(awk '/^[[:space:]]*listen[[:space:]]+[0-9]+[[:space:]]+ssl/ {
        for(i=1; i<=NF; i++) if($i ~ /^[0-9]+$/) { print $i; exit }
    }' "$nginx_conf")

    if [ -z "$port" ]; then
        port=$(awk '/^[[:space:]]*listen[[:space:]]+[0-9]+/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9]+$/ && $i != "80") { print $i; exit }
            }
        }' "$nginx_conf")
    fi

    echo "$port"
}

web_get_external_url() {
    local mode port domain ip
    mode=$(web_get_https_mode)
    port=$(web_get_external_port)
    domain=$(web_get_https_domain)
    ip=$(web_get_public_ip)

    [ -z "$port" ] && { echo "не определён"; return; }

    case "$mode" in
        letsencrypt)
            if [ -n "$domain" ]; then
                echo "https://${domain}:${port}/"
            else
                echo "https://${ip}:${port}/"
            fi
            ;;
        selfsigned)
            echo "https://${ip}:${port}/"
            ;;
        http|*)
            echo "http://${ip}:${port}/"
            ;;
    esac
}

# ===== Меню =====

web_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "      🌐 ${YELLOW}УПРАВЛЕНИЕ ВЕБ-ПАНЕЛЬЮ${NC} 🌐"
        echo -e "${CYAN}==========================================${NC}"

        if web_is_installed; then
            echo -e " Статус:       ${GREEN}УСТАНОВЛЕНА${NC}"

            if web_is_running; then
                echo -e " Сервис:       ${GREEN}ЗАПУЩЕН 🟢${NC}"
            else
                echo -e " Сервис:       ${RED}ОСТАНОВЛЕН 🔴${NC}"
            fi

            if systemctl is-enabled --quiet "$WEB_SERVICE" 2>/dev/null; then
                echo -e " Автозагрузка: ${GREEN}ВКЛ${NC}"
            else
                echo -e " Автозагрузка: ${RED}ВЫКЛ${NC}"
            fi
            echo -e " HTTPS:       ${https_mode}"
            
            local port external_url https_mode
            port=$(web_get_external_port)
            external_url=$(web_get_external_url)
            https_mode=$(web_get_https_mode_label)
            echo -e " Внешний порт: ${CYAN}${port:-?}${NC}"
            echo -e " URL:          ${YELLOW}${external_url}${NC}"
            echo -e "${CYAN}------------------------------------------${NC}"
            echo -e " ${CYAN}1.${NC} 🔑 Сменить логин/пароль (интерактивно)"
            echo -e " ${CYAN}2.${NC} 🔄 Сбросить пароль (admin + случайный)"
            echo -e " ${CYAN}3.${NC} 🚫 Сбросить блокировки IP"
            echo -e " ${CYAN}4.${NC} 🔌 Изменить внешний порт"
            echo -e " ${CYAN}5.${NC} 🔒 HTTPS / SSL"
            echo -e " ${YELLOW}6.${NC} ▶️  Запустить / ⏹️  Остановить"
            echo -e " ${YELLOW}7.${NC} ⟳  Перезапустить"
            echo -e " ${CYAN}8.${NC} 📄 Логи веб-панели"
            echo -e " ${CYAN}9.${NC} 📋 Лог авторизаций"
            echo -e " ${RED}10.${NC} 🗑️  Удалить веб-панель"
            echo -e " ${CYAN}0.${NC} ↩️  Назад"
            echo -e ""
            echo -e " ${YELLOW}ℹ Обновление веб-панели:${NC} автоматически вместе с WARPER"
            echo -e "   через пункт ${CYAN}10${NC} в главном меню или ${CYAN}warper update${NC}"
            echo -e "${CYAN}==========================================${NC}"

            read -r -e -p "Выбор: " choice
            case "${choice:-}" in
                1) web_action_change_password ;;
                2) web_action_reset_password ;;
                3) web_action_unblock ;;
                4) web_action_change_port ;;
                5) web_https_menu ;;
                6) web_action_toggle ;;
                7) web_action_restart ;;
                8) web_action_logs ;;
                9) web_action_auth_log ;;
                10) web_action_uninstall ;;
                0) return ;;
                *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
            esac
        else
            echo -e " Статус: ${RED}НЕ УСТАНОВЛЕНА${NC}"
            echo -e "${CYAN}------------------------------------------${NC}"
            echo -e " Веб-панель — удобный браузерный интерфейс"
            echo -e " для управления WARPER. Возможности:"
            echo -e "  • Управление доменами и IP-подсетями"
            echo -e "  • Включение/отключение sing-box"
            echo -e "  • Просмотр логов и диагностика"
            echo -e "  • Изменение всех настроек"
            echo -e "  • Защита авторизацией"
            echo -e "${CYAN}------------------------------------------${NC}"
            echo -e " ${GREEN}1.${NC} 📥 Установить веб-панель"
            echo -e " ${CYAN}0.${NC} ↩️  Назад"
            echo -e "${CYAN}==========================================${NC}"

            read -r -e -p "Выбор [0-1]: " choice
            case "${choice:-}" in
                1) web_action_install ;;
                0) return ;;
                *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
            esac
        fi
    done
}

web_https_menu() {
    while true; do
        clear

        local mode domain port cert_expiry cert_issuer url
        mode=$(web_get_https_mode)
        domain=$(web_get_https_domain)
        port=$(web_get_external_port)
        cert_expiry=$(web_get_https_status_field "cert_expiry")
        cert_issuer=$(web_get_https_status_field "cert_issuer")
        url=$(web_get_external_url)

        echo -e "${CYAN}==========================================${NC}"
        echo -e "         🔒 ${YELLOW}HTTPS / SSL${NC} 🔒"
        echo -e "${CYAN}==========================================${NC}"
        echo -e ""

        case "$mode" in
            letsencrypt)
                echo -e " Режим:        ${GREEN}Let's Encrypt${NC}"
                ;;
            selfsigned)
                echo -e " Режим:        ${YELLOW}Самоподписанный${NC}"
                ;;
            http|*)
                echo -e " Режим:        ${CYAN}HTTP${NC}"
                ;;
        esac

        echo -e " Порт:         ${CYAN}${port:-?}${NC}"
        echo -e " URL:          ${YELLOW}${url}${NC}"

        if [ -n "$domain" ]; then
            echo -e " Домен:        ${CYAN}${domain}${NC}"
        fi
        if [ -n "$cert_expiry" ]; then
            echo -e " Истекает:     ${CYAN}${cert_expiry}${NC}"
        fi
        if [ -n "$cert_issuer" ]; then
            echo -e " Issuer:       ${CYAN}${cert_issuer}${NC}"
        fi

        echo -e ""
        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${CYAN}1.${NC} Включить HTTPS (самоподписанный)"
        echo -e " ${CYAN}2.${NC} Включить HTTPS (Let's Encrypt)"
        echo -e " ${CYAN}3.${NC} Переключить на HTTP"
        echo -e " ${CYAN}4.${NC} Обновить сертификат Let's Encrypt"
        echo -e " ${CYAN}0.${NC} Назад"
        echo -e "${CYAN}==========================================${NC}"

        read -r -e -p "Выбор: " choice
        case "${choice:-}" in
            1)
                if [ "$mode" = "selfsigned" ]; then
                    echo -e "${YELLOW}Уже включён самоподписанный HTTPS.${NC}"
                else
                    echo ""
                    if prompt_confirm; then
                        local output
                        if output=$(cli_web_https enable-selfsigned 2>&1); then
                            echo -e "${GREEN}${output}${NC}"
                            echo -e "${CYAN}Новый URL:${NC} ${YELLOW}$(web_get_external_url)${NC}"
                        else
                            echo -e "${RED}${output}${NC}"
                        fi
                    fi
                fi
                echo ""
                read -r -p "Нажмите Enter..."
                ;;

            2)
                echo ""
                read -r -e -p "Введите домен (например protomoto.duckdns.org): " new_domain
                if [ -z "$new_domain" ]; then
                    echo -e "${YELLOW}Отмена.${NC}"
                    sleep 1
                    continue
                fi

                if prompt_confirm; then
                    local output
                    if output=$(cli_web_https enable-letsencrypt "$new_domain" 2>&1); then
                        echo -e "${GREEN}${output}${NC}"
                        echo -e "${CYAN}Новый URL:${NC} ${YELLOW}$(web_get_external_url)${NC}"
                    else
                        echo -e "${RED}${output}${NC}"
                    fi
                fi
                echo ""
                read -r -p "Нажмите Enter..."
                ;;

            3)
                if [ "$mode" = "http" ] || [ -z "$mode" ]; then
                    echo -e "${YELLOW}Панель уже работает по HTTP.${NC}"
                else
                    echo ""
                    if prompt_confirm; then
                        local output
                        if output=$(cli_web_https disable 2>&1); then
                            echo -e "${GREEN}${output}${NC}"
                            echo -e "${CYAN}Новый URL:${NC} ${YELLOW}$(web_get_external_url)${NC}"
                        else
                            echo -e "${RED}${output}${NC}"
                        fi
                    fi
                fi
                echo ""
                read -r -p "Нажмите Enter..."
                ;;

            4)
                if [ "$mode" != "letsencrypt" ]; then
                    echo -e "${YELLOW}Обновление доступно только для сертификатов Let's Encrypt.${NC}"
                else
                    echo ""
                    local output
                    if output=$(cli_web_https renew 2>&1); then
                        echo -e "${GREEN}${output}${NC}"
                    else
                        echo -e "${RED}${output}${NC}"
                    fi
                fi
                echo ""
                read -r -p "Нажмите Enter..."
                ;;

            0)
                return
                ;;

            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ===== Действия =====

web_action_install() {
    echo ""
    echo -e "${CYAN}Установка веб-панели...${NC}"
    if [ -f "/tmp/warper-install-web.sh" ]; then
        rm -f /tmp/warper-install-web.sh
    fi
    if ! curl -sfSL "$REPO_URL/web/install-web.sh?t=$(date +%s)" -o /tmp/warper-install-web.sh; then
        echo -e "${RED}Не удалось скачать установщик.${NC}"
        read -r -p "Нажмите Enter..."
        return 1
    fi
    chmod +x /tmp/warper-install-web.sh
    bash /tmp/warper-install-web.sh
    rm -f /tmp/warper-install-web.sh
    echo ""
    read -r -p "Нажмите Enter для возврата в меню..."
}

web_action_change_password() {
    echo ""
    cli_webpass
    echo ""
    read -r -p "Нажмите Enter..."
}

web_action_reset_password() {
    echo ""
    echo -e "${YELLOW}Внимание! Будет создан пользователь admin со случайным паролем.${NC}"
    if prompt_confirm; then
        cli_webpass --reset
        echo ""
        read -r -p "Сохраните пароль, затем нажмите Enter..."
    fi
}

web_action_unblock() {
    echo ""
    cli_webpass --unblock
    echo ""
    sleep 1
}

web_action_change_port() {
    echo ""
    local current_port new_port new_backend
    current_port=$(web_get_external_port)
    echo -e "${CYAN}Текущий внешний порт:${NC} ${YELLOW}${current_port:-?}${NC}"
    echo ""
    read -r -e -p "Новый внешний порт (Enter = отмена): " new_port

    if [ -z "$new_port" ]; then
        echo -e "${YELLOW}Отмена.${NC}"
        sleep 1
        return
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        echo -e "${RED}Некорректный порт.${NC}"
        sleep 2
        return
    fi

    if [ "$new_port" = "$current_port" ]; then
        echo -e "${YELLOW}Порт не изменился.${NC}"
        sleep 1
        return
    fi

    # Проверка занятости порта
    if ss -tlnp 2>/dev/null | grep -qE ":${new_port}\s"; then
        echo -e "${RED}Порт $new_port уже занят другим процессом!${NC}"
        ss -tlnp 2>/dev/null | grep -E ":${new_port}\s"
        sleep 3
        return
    fi

    # Меняем порт в nginx
    local nginx_conf="/etc/nginx/sites-available/warper-web"
    if [ ! -f "$nginx_conf" ]; then
        echo -e "${RED}Конфиг nginx не найден: $nginx_conf${NC}"
        sleep 2
        return
    fi

    sed -i "s/listen\s\+${current_port}/listen ${new_port}/g" "$nginx_conf"

    if ! nginx -t >/dev/null 2>&1; then
        # Откат
        sed -i "s/listen\s\+${new_port}/listen ${current_port}/g" "$nginx_conf"
        echo -e "${RED}Ошибка конфигурации nginx, откат.${NC}"
        sleep 2
        return
    fi

    systemctl reload nginx
    echo -e "${GREEN}✓ Порт изменён: $current_port → $new_port${NC}"
    echo -e "${CYAN}Новый URL:${NC} ${YELLOW}$(web_get_external_url)${NC}"
    sleep 2
}

web_action_toggle() {
    echo ""
    if web_is_running; then
        if prompt_confirm; then
            systemctl stop "$WEB_SERVICE"
            echo -e "${YELLOW}Сервис остановлен.${NC}"
        fi
    else
        if prompt_confirm; then
            systemctl start "$WEB_SERVICE"
            sleep 2
            if web_is_running; then
                echo -e "${GREEN}Сервис запущен.${NC}"
            else
                echo -e "${RED}Не удалось запустить сервис.${NC}"
                journalctl -u "$WEB_SERVICE" -n 10 --no-pager
            fi
        fi
    fi
    sleep 1
}

web_action_restart() {
    echo ""
    if prompt_confirm; then
        systemctl restart "$WEB_SERVICE"
        sleep 2
        if web_is_running; then
            echo -e "${GREEN}Сервис перезапущен.${NC}"
        else
            echo -e "${RED}Не удалось перезапустить сервис.${NC}"
            journalctl -u "$WEB_SERVICE" -n 10 --no-pager
        fi
    fi
    sleep 1
}

web_action_logs() {
    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Логи warper-web (Ctrl+C для выхода)${NC}"
    echo -e "${CYAN}==========================================${NC}"
    trap 'echo -e "\n${CYAN}Возврат в меню...${NC}"' SIGINT
    journalctl -u "$WEB_SERVICE" -n 50 -f
    trap - SIGINT
}

web_action_auth_log() {
    echo ""
    local auth_log="$WEB_DIR/data/auth.log"
    if [ ! -f "$auth_log" ]; then
        echo -e "${YELLOW}Лог авторизаций пуст ($auth_log не существует).${NC}"
        read -r -p "Нажмите Enter..."
        return
    fi

    echo -e "${CYAN}==========================================${NC}"
    echo -e "${YELLOW}Последние 30 событий авторизации${NC}"
    echo -e "${CYAN}------------------------------------------${NC}"
    tail -30 "$auth_log"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}Полный лог: ${YELLOW}$auth_log${NC}"
    echo ""
    read -r -p "Нажмите Enter..."
}

web_action_uninstall() {
    echo ""
    echo -e "${RED}⚠ ВНИМАНИЕ! Будут удалены:${NC}"
    echo -e "  • Сервис warper-web и его конфигурация systemd"
    echo -e "  • Конфиг nginx /etc/nginx/sites-{available,enabled}/warper-web"
    echo -e "  • Самоподписанные SSL-сертификаты /etc/nginx/ssl/warper-web.* (если есть)"
    echo -e "  • Папка $WEB_DIR (включая БД пользователей)"
    echo ""
    echo -e "${CYAN}НЕ будут затронуты:${NC}"
    echo -e "  • Сертификаты Let's Encrypt в /etc/letsencrypt/"
    echo -e "    (могут использоваться другими сервисами)"
    echo ""
    read -r -e -p "Точно удалить? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Отмена.${NC}"
        sleep 1
        return
    fi

    # Удаляем встроенным способом (без скачивания uninstall-web.sh)
    echo ""
    echo -e "${CYAN}Останавливаю сервис...${NC}"
    systemctl stop "$WEB_SERVICE" 2>/dev/null || true
    systemctl disable "$WEB_SERVICE" 2>/dev/null || true

    echo -e "${CYAN}Удаляю systemd-юнит...${NC}"
    rm -f "/etc/systemd/system/${WEB_SERVICE}.service"
    systemctl daemon-reload

    echo -e "${CYAN}Удаляю nginx-конфиг...${NC}"
    rm -f /etc/nginx/sites-enabled/warper-web
    rm -f /etc/nginx/sites-available/warper-web
    rm -f /etc/nginx/ssl/warper-web.crt
    rm -f /etc/nginx/ssl/warper-web.key

    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    fi

    echo -e "${CYAN}Удаляю файлы веб-панели...${NC}"
    rm -rf "$WEB_DIR"

    echo ""
    echo -e "${GREEN}✓ Веб-панель удалена${NC}"
    echo ""
    read -r -p "Нажмите Enter..."
}
