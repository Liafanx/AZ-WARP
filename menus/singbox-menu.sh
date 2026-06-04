#!/bin/bash
# warper menus: singbox-menu.sh
# Меню управления службой sing-box:
# запуск, остановка, автозагрузка, просмотр логов.
# Подключается через source из warper.sh

# Интерактивное меню управления sing-box.
# При запуске автоматически пересинхронизирует IP-маршруты.
# При остановке очищает маршруты перед shutdown.
singbox_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================${NC}"
        echo -e "       ⚙️  ${YELLOW}УПРАВЛЕНИЕ SING-BOX${NC} ⚙️"
        echo -e "${CYAN}==========================================${NC}"

        if systemctl is-active --quiet sing-box; then
            echo -e "Статус:       ${GREEN}ЗАПУЩЕН 🟢${NC}"
        else
            echo -e "Статус:       ${RED}ОСТАНОВЛЕН 🔴${NC}"
        fi

        if systemctl is-enabled --quiet sing-box 2>/dev/null; then
            echo -e "Автозагрузка: ${GREEN}ВКЛ${NC}"
        else
            echo -e "Автозагрузка: ${RED}ВЫКЛ${NC}"
        fi

        echo -e "${CYAN}------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} ▶️  Запустить службу"
        echo -e " ${RED}2.${NC} ⏹️  Остановить службу"
        echo -e " ${GREEN}3.${NC} ✅ Включить автозагрузку"
        echo -e " ${RED}4.${NC} ❌ Выключить автозагрузку"
        echo -e " ${YELLOW}5.${NC} 📄 Посмотреть логи"
        echo -e " ${CYAN}0.${NC} ↩️  Назад"
        echo -e "${CYAN}==========================================${NC}"

        read -r -e -p "Выбор [0-5]: " sb_choice
        case "${sb_choice:-}" in

            # ── Запустить ─────────────────────────────────────────────────
            1)
                if prompt_confirm; then
                    if needs_down_sh; then
                        show_down_sh_warning
                        sleep 2
                        continue
                    fi
                    check_and_sync_warp_keys || continue
                    if ! validate_singbox_config; then sleep 2; continue; fi
                    systemctl start sing-box
                    if ensure_singbox_running; then
                        echo -e "${GREEN}Служба запущена.${NC}"
                        resync_ip_routes_if_needed
                    fi
                    sleep 1
                fi
                ;;

            # ── Остановить ────────────────────────────────────────────────
            2)
                if prompt_confirm; then
                    # Очищаем IP-маршруты перед остановкой
                    if [ "$(count_ip_ranges)" -gt 0 ]; then
                        remove_all_ip_routes >/dev/null 2>&1 || true
                    fi
                    traffic_finalize_session 2>/dev/null || true                    
                    systemctl stop sing-box
                    echo -e "${YELLOW}Служба остановлена.${NC}"
                    sleep 1
                fi
                ;;

            # ── Включить автозагрузку ─────────────────────────────────────
            3)
                if prompt_confirm; then
                    systemctl enable sing-box
                    echo -e "${GREEN}Добавлено в автозапуск.${NC}"
                    sleep 1
                fi
                ;;

            # ── Выключить автозагрузку ────────────────────────────────────
            4)
                if prompt_confirm; then
                    systemctl disable sing-box
                    echo -e "${YELLOW}Убрано из автозапуска.${NC}"
                    sleep 1
                fi
                ;;

            # ── Логи ──────────────────────────────────────────────────────
            5) show_logs ;;

            # ── Назад ─────────────────────────────────────────────────────
            0) return ;;

            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}
