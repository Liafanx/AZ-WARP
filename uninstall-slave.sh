#!/bin/bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SLAVE_DIR="/root/warperslave"
SLAVE_CONF="$SLAVE_DIR/slave.conf"
SINGBOX_SLAVE_CONF_DIR="/etc/sing-box-slave"
SERVICE_NAME="sing-box-slave"

echo -e "${RED}================================================${NC}"
echo -e " 🗑️  УДАЛЕНИЕ WARPERSLAVE"
echo -e "${RED}================================================${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите скрипт от имени root.${NC}"
    exit 1
fi

load_config_value() {
    local key="$1"
    local file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'\''[:space:]'
}

remove_port_rules() {
    local port="$1"
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT
}

# Подтверждение
while true; do
    read -r -p "Вы уверены, что хотите полностью удалить warperslave? (N/y): " conf < /dev/tty
    if [[ -z "$conf" || "$conf" =~ ^[Nn]$ ]]; then
        echo -e "${GREEN}Отмена. Ничего не изменено.${NC}"
        exit 0
    elif [[ "$conf" =~ ^[Yy]$ ]]; then
        break
    else
        echo -e "${RED}Введите y или N.${NC}"
    fi
done

# Сохраняем ли настройки
KEEP_CONFIG=false
while true; do
    read -r -p "Сохранить WARP-ключи и настройки в $SLAVE_DIR? (Y/n): " keep < /dev/tty
    if [[ -z "$keep" || "$keep" =~ ^[Yy]$ ]]; then
        KEEP_CONFIG=true
        break
    elif [[ "$keep" =~ ^[Nn]$ ]]; then
        KEEP_CONFIG=false
        break
    else
        echo -e "${RED}Введите Y или n.${NC}"
    fi
done

# Загружаем порт для очистки iptables
SLAVE_PORT="8444"
if [ -f "$SLAVE_CONF" ]; then
    loaded_port=$(load_config_value "SLAVE_PORT" "$SLAVE_CONF")
    if [ -n "$loaded_port" ]; then
        SLAVE_PORT="$loaded_port"
    fi
fi

echo -e "\n${YELLOW}1. Остановка и удаление службы...${NC}"
echo -e " - ${CYAN}Остановка $SERVICE_NAME...${NC}"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
echo -e " - ${CYAN}Удаление из автозагрузки...${NC}"
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
echo -e " - ${CYAN}Удаление файла службы...${NC}"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/usr/lib/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

echo -e "\n${YELLOW}2. Удаление конфигурации sing-box-slave...${NC}"
rm -rf "$SINGBOX_SLAVE_CONF_DIR"
echo -e " - ${GREEN}Директория $SINGBOX_SLAVE_CONF_DIR удалена.${NC}"

echo -e "\n${YELLOW}3. Удаление правил firewall...${NC}"
remove_port_rules "$SLAVE_PORT"
echo -e " - ${GREEN}Правила для порта $SLAVE_PORT удалены.${NC}"

echo -e "\n${YELLOW}4. Удаление утилиты...${NC}"
rm -f /usr/local/bin/warperslave
echo -e " - ${GREEN}Ярлык /usr/local/bin/warperslave удалён.${NC}"

echo -e "\n${YELLOW}5. Очистка файлов...${NC}"
if [ "$KEEP_CONFIG" = true ]; then
    echo -e " - ${CYAN}Очистка $SLAVE_DIR (с сохранением настроек и ключей)...${NC}"
    # Удаляем всё кроме конфига, ключей и шаблонов
    find "$SLAVE_DIR" -type f \
        -not -name 'slave.conf' \
        -not -name 'uninstall-slave.sh' \
        -not -path '*/wgcf/*' \
        -delete 2>/dev/null || true
    echo -e " - ${GREEN}Настройки и WARP-ключи сохранены в $SLAVE_DIR${NC}"
else
    echo -e " - ${CYAN}Полное удаление $SLAVE_DIR...${NC}"
    rm -rf "$SLAVE_DIR"
    echo -e " - ${GREEN}Директория $SLAVE_DIR полностью удалена.${NC}"
fi

# Проверяем, используется ли sing-box другими сервисами
echo -e "\n${YELLOW}6. Проверка sing-box...${NC}"
if systemctl is-active --quiet sing-box 2>/dev/null; then
    echo -e " - ${GREEN}sing-box используется другим сервисом (warper). Бинарник не удаляем.${NC}"
elif systemctl is-enabled --quiet sing-box 2>/dev/null; then
    echo -e " - ${GREEN}sing-box в автозагрузке (warper). Бинарник не удаляем.${NC}"
else
    echo -e " - ${CYAN}sing-box не используется другими сервисами.${NC}"
    while true; do
        read -r -p "Удалить бинарник sing-box? (y/N): " del_sb < /dev/tty
        if [[ -z "$del_sb" || "$del_sb" =~ ^[Nn]$ ]]; then
            echo -e " - ${GREEN}sing-box оставлен.${NC}"
            break
        elif [[ "$del_sb" =~ ^[Yy]$ ]]; then
            rm -f /usr/bin/sing-box /usr/local/bin/sing-box
            echo -e " - ${GREEN}sing-box удалён.${NC}"
            break
        else
            echo -e "${RED}Введите y или N.${NC}"
        fi
    done
fi

echo -e "\n${GREEN}================================================${NC}"
echo -e " ✅ WARPERSLAVE успешно удалён!"
echo -e "${GREEN}================================================${NC}"
if [ "$KEEP_CONFIG" = true ]; then
    echo -e "${CYAN}Настройки сохранены в: $SLAVE_DIR${NC}"
    echo -e "${CYAN}Для полного удаления: rm -rf $SLAVE_DIR${NC}"
fi
