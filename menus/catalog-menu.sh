#!/bin/bash
# warper menu: catalog-menu.sh
# Интерактивное меню каталога доменов.
# Те же операции, что у `warper catalog`, но с подсказками и подтверждениями.
# Подключается через source из warper.sh

catalog_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${NC}"
        echo -e "        📚 ${YELLOW}КАТАЛОГ ДОМЕНОВ${NC}"
        echo -e "${CYAN}================================================${NC}"

        local installed
        installed=$(catalog_list_installed 2>/dev/null | grep -c '' || echo 0)
        echo -e " ${CYAN}Установлено каталогов:${NC} $installed"
        echo -e "${CYAN}------------------------------------------------${NC}"
        echo -e " ${GREEN}1.${NC} 🔍 Поиск категорий"
        echo -e " ${CYAN}2.${NC} 👁  Предпросмотр категории"
        echo -e " ${GREEN}3.${NC} ➕ Установить категорию"
        echo -e " ${RED}4.${NC} ➖ Удалить категорию"
        echo -e " ${CYAN}5.${NC} 🔄 Обновить установленные"
        echo -e " ${CYAN}6.${NC} 📋 Список установленных"
        echo -e " ${CYAN}7.${NC} ♻️  Обновить кэш категорий"
        echo -e " ${CYAN}0.${NC} ⬅️  Назад"
        echo -e "${CYAN}================================================${NC}"

        local choice name
        read -r -e -p "Выбор: " choice
        choice=$(echo "${choice:-}" | tr -d ' ')

        case "$choice" in
            1)
                read -r -e -p "Запрос (Enter — популярные): " name
                echo ""
                catalog_search "$name"
                read -r -p "Нажмите Enter..."
                ;;
            2)
                read -r -e -p "Имя категории: " name
                [ -z "$name" ] && continue
                echo ""
                catalog_show "$name"
                read -r -p "Нажмите Enter..."
                ;;
            3)
                read -r -e -p "Имя категории: " name
                [ -z "$name" ] && continue
                echo ""
                catalog_add "$name"
                read -r -p "Нажмите Enter..."
                ;;
            4)
                read -r -e -p "Имя категории: " name
                [ -z "$name" ] && continue
                if prompt_confirm; then
                    echo ""
                    catalog_remove "$name"
                fi
                read -r -p "Нажмите Enter..."
                ;;
            5)
                read -r -e -p "Имя категории (Enter — все): " name
                echo ""
                catalog_update_installed "$name"
                read -r -p "Нажмите Enter..."
                ;;
            6)
                echo ""
                local list
                list=$(catalog_list_installed 2>/dev/null)
                if [ -n "$list" ]; then
                    echo "$list"
                else
                    echo -e "${YELLOW}Каталоги не установлены.${NC}"
                fi
                read -r -p "Нажмите Enter..."
                ;;
            7)
                echo ""
                catalog_refresh_cache
                read -r -p "Нажмите Enter..."
                ;;
            0) return ;;
            *) ;;
        esac
    done
}
