#!/bin/bash
set -uo pipefail

# Если запущено через "curl ... | bash" — переключаем stdin на терминал
if [ ! -t 0 ]; then
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        exec </dev/tty
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_BRANCH="${WARPER_WEB_BRANCH:-main}"
REPO_RAW="https://raw.githubusercontent.com/Liafanx/AZ-WARP/${REPO_BRANCH}"
REPO_GIT="https://github.com/Liafanx/AZ-WARP.git"

WARPER_DIR="/root/warper"
WEB_DIR="${WARPER_DIR}/web"
SERVICE_NAME="warper-web"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_AVAIL="/etc/nginx/sites-available/warper-web"
NGINX_LINK="/etc/nginx/sites-enabled/warper-web"

DEFAULT_PORT=6060
DEFAULT_BACKEND_PORT=16060

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

if [ ! -d "$WARPER_DIR" ] || [ ! -f "$WARPER_DIR/warper.sh" ]; then
    echo -e "${RED}WARPER не установлен в $WARPER_DIR${NC}"
    exit 1
fi

clear
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}     AZ-WARP Web Panel - установщик${NC}"
echo -e "${CYAN}=================================================${NC}"
echo ""

# ===== Параметры =====

# ===== Функции проверки портов =====
_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH "sport = :$port" 2>/dev/null | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}\s"
    else
        return 1
    fi
}

_port_owner() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnpH "sport = :$port" 2>/dev/null | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "?"
    else
        echo "?"
    fi
}

_validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# ===== Внешний порт =====
while true; do
    read -r -e -p "Внешний порт веб-панели [$DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"

    if ! _validate_port "$PORT"; then
        echo -e "${RED}Порт должен быть числом 1-65535${NC}"
        continue
    fi

    if _port_in_use "$PORT"; then
        owner=$(_port_owner "$PORT")
        echo -e "${RED}⚠ Порт $PORT уже занят процессом: ${YELLOW}$owner${NC}"
        echo -e "${YELLOW}Выберите другой порт или освободите этот.${NC}"
        continue
    fi

    echo -e "${GREEN}✓ Порт $PORT свободен${NC}"
    break
done

# ===== Внутренний порт =====
while true; do
    read -r -e -p "Внутренний порт (gunicorn) [$DEFAULT_BACKEND_PORT]: " BACKEND_PORT
    BACKEND_PORT="${BACKEND_PORT:-$DEFAULT_BACKEND_PORT}"

    if ! _validate_port "$BACKEND_PORT"; then
        echo -e "${RED}Порт должен быть числом 1-65535${NC}"
        continue
    fi

    if [ "$BACKEND_PORT" = "$PORT" ]; then
        echo -e "${RED}⚠ Внутренний порт не может совпадать с внешним ($PORT)${NC}"
        continue
    fi

    if _port_in_use "$BACKEND_PORT"; then
        owner=$(_port_owner "$BACKEND_PORT")
        echo -e "${RED}⚠ Порт $BACKEND_PORT уже занят процессом: ${YELLOW}$owner${NC}"
        echo -e "${YELLOW}Выберите другой порт или освободите этот.${NC}"
        continue
    fi

    echo -e "${GREEN}✓ Порт $BACKEND_PORT свободен${NC}"
    break
done

# ===== Логин =====
while true; do
    read -r -e -p "Логин администратора [admin]: " ADMIN_USER
    ADMIN_USER=$(echo "${ADMIN_USER:-admin}" | xargs)  # обрезать пробелы

    if [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_-]{3,32}$ ]]; then
        break
    fi
    echo -e "${RED}Логин: 3-32 символа, латиница, цифры, _ или - ${NC}"
done

# ===== Пароль =====
# Генератор безопасного пароля
_generate_password() {
    local p
    p=$(openssl rand -base64 16 2>/dev/null | tr -d '=+/' | cut -c1-12)
    if [ -z "$p" ] || [ ${#p} -lt 10 ]; then
        p=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-12)
    fi
    echo "$p"
}

PASSWORD_GENERATED="n"

echo ""
echo -e "${CYAN}Пароль администратора:${NC}"
echo -e "  - Нажмите Enter для генерации случайного безопасного пароля"
echo -e "  - Или введите свой (минимум 6 символов, не отображается)"
echo ""

while true; do
    read -r -s -p "Пароль: " ADMIN_PASSWORD
    echo ""

    # Пустой ввод - генерируем
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(_generate_password)
        PASSWORD_GENERATED="y"
        echo -e "${GREEN}✓ Сгенерирован случайный пароль (будет показан в конце)${NC}"
        break
    fi

    # Валидация длины
    if [ ${#ADMIN_PASSWORD} -lt 6 ]; then
        echo -e "${RED}Пароль слишком короткий (минимум 6 символов).${NC}"
        continue
    fi

    if [ ${#ADMIN_PASSWORD} -gt 256 ]; then
        echo -e "${RED}Пароль слишком длинный (максимум 256 символов).${NC}"
        continue
    fi

    # Подтверждение
    read -r -s -p "Подтвердите пароль: " ADMIN_PASSWORD_CONFIRM
    echo ""

    if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
        echo -e "${RED}Пароли не совпадают, попробуйте ещё раз.${NC}"
        continue
    fi

    echo -e "${GREEN}✓ Пароль установлен${NC}"
    break
done

unset ADMIN_PASSWORD_CONFIRM

# ===== HTTPS =====
ENABLE_HTTPS="n"
DOMAIN=""

while true; do
    read -r -e -p "Включить HTTPS? (y/N): " enable_https_input
    enable_https_input="${enable_https_input,,}"  # в нижний регистр

    if [ -z "$enable_https_input" ] || [ "$enable_https_input" = "n" ] || [ "$enable_https_input" = "no" ]; then
        ENABLE_HTTPS="n"
        break
    elif [ "$enable_https_input" = "y" ] || [ "$enable_https_input" = "yes" ]; then
        ENABLE_HTTPS="y"
        break
    else
        echo -e "${RED}Введите y, n или нажмите Enter${NC}"
    fi
done

if [ "$ENABLE_HTTPS" = "y" ]; then
    read -r -e -p "Доменное имя (для Let's Encrypt) или Enter для самоподписанного: " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | xargs)  # обрезать пробелы

    # Валидация формата домена если введён
    if [ -n "$DOMAIN" ]; then
        if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            echo -e "${RED}⚠ Некорректный формат домена. Будет использован самоподписанный сертификат.${NC}"
            DOMAIN=""
        fi
    fi
fi

echo ""
echo -e "${YELLOW}=== Установка ===${NC}"

# ===== Зависимости =====

echo -e "${CYAN}1. Установка зависимостей...${NC}"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip nginx git curl openssl >/dev/null

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
fi

# ===== Скачивание файлов =====

echo -e "${CYAN}2. Скачивание файлов веб-панели...${NC}"

mkdir -p "$WEB_DIR/static" "$WEB_DIR/templates/partials"

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
if ! git clone --depth 1 -b "$REPO_BRANCH" "$REPO_GIT" repo 2>/dev/null; then
    echo -e "${RED}Не удалось скачать репозиторий ветки $REPO_BRANCH${NC}"
    exit 1
fi

if [ ! -d "repo/web" ]; then
    echo -e "${RED}В ветке $REPO_BRANCH нет папки web/${NC}"
    exit 1
fi

# Копируем файлы веб-панели
cp -r repo/web/* "$WEB_DIR/"

# Копируем cli.sh если он есть в lib/
if [ -f "repo/lib/cli.sh" ]; then
    cp repo/lib/cli.sh "$WARPER_DIR/lib/cli.sh"
fi

# Копируем web-menu.sh в menus/ (для совместимости со старыми установками warper)
if [ -f "repo/menus/web-menu.sh" ] && [ -d "$WARPER_DIR/menus" ]; then
    cp repo/menus/web-menu.sh "$WARPER_DIR/menus/web-menu.sh"
fi

cd /
rm -rf "$TMP_DIR"

# ===== Python venv =====

echo -e "${CYAN}3. Создание venv и установка пакетов...${NC}"
cd "$WEB_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
deactivate

# ===== .env =====

echo -e "${CYAN}4. Создание .env...${NC}"
cat > "$WEB_DIR/.env" <<EOF
PORT=$BACKEND_PORT
DEBUG=false
EOF
chmod 600 "$WEB_DIR/.env"

# Создаём data/ с правильными правами
mkdir -p "$WEB_DIR/data"
chmod 700 "$WEB_DIR/data"

# ===== systemd =====

echo -e "${CYAN}5. Создание systemd сервиса...${NC}"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AZ-WARP Web Panel
After=network.target sing-box.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$WEB_DIR
EnvironmentFile=$WEB_DIR/.env
ExecStart=$WEB_DIR/venv/bin/gunicorn --workers 2 --threads 8 --worker-class gthread --bind 127.0.0.1:$BACKEND_PORT --access-logfile - --error-logfile - --timeout 600 --graceful-timeout 30 --max-requests 1000 --max-requests-jitter 100 app:app
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ===== nginx =====

echo -e "${CYAN}6. Настройка nginx...${NC}"
rm -f "$NGINX_LINK"

# Удаляем default ТОЛЬКО если он является стандартным nginx-заглушкой,
# а не реальным сайтом пользователя.
# Критерии стандартной заглушки:
# - содержит "nginx default" или "Welcome to nginx" или просто listen 80 без реального контента
# - И при этом не содержит никаких proxy_pass или реальных location
_default_link="/etc/nginx/sites-enabled/default"
if [ -L "$_default_link" ] || [ -f "$_default_link" ]; then
    _default_target=$(readlink -f "$_default_link" 2>/dev/null || echo "$_default_link")
    _is_placeholder="n"

    # Признак заглушки: нет proxy_pass и нет реального приложения
    if ! grep -qE 'proxy_pass|fastcgi_pass|uwsgi_pass' "$_default_target" 2>/dev/null; then
        # И размер маленький (стандартная заглушка ~5-15 строк)
        _line_count=$(grep -c '' "$_default_target" 2>/dev/null || echo 0)
        if [ "$_line_count" -lt 30 ]; then
            _is_placeholder="y"
        fi
    fi

    if [ "$_is_placeholder" = "y" ]; then
        rm -f "$_default_link"
        echo -e " - ${CYAN}Удалена стандартная nginx-заглушка (default)${NC}"
    else
        echo -e " - ${YELLOW}⚠ /etc/nginx/sites-enabled/default не удалён — выглядит как реальный сайт${NC}"
        echo -e "   ${YELLOW}Убедитесь что порт ${PORT} не конфликтует с существующими сайтами${NC}"
    fi
fi

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    # ===== HTTPS с доменом (Let's Encrypt) =====
    # Временный конфиг: HTTP на нашем порту + acme-challenge на 80
    mkdir -p /var/www/html

    cat > "$NGINX_AVAIL" <<EOF
# AZ-WARP Web Panel - временно HTTP пока не получен Let's Encrypt сертификат
# Минимальный server-блок на 80 - только для acme-challenge (не мешает другим сайтам)
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Не перехватываем другие запросы на 80
    location / {
        return 404;
    }
}

server {
    listen $PORT default_server;
    server_name _;

    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }
}
EOF

elif [ "$ENABLE_HTTPS" = "y" ]; then
    # ===== HTTPS самоподписанный =====
    SSL_DIR="/etc/nginx/ssl"
    mkdir -p "$SSL_DIR"
    if [ ! -f "$SSL_DIR/warper-web.crt" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$SSL_DIR/warper-web.key" \
            -out "$SSL_DIR/warper-web.crt" \
            -subj "/CN=warper-web" 2>/dev/null
    fi

    cat > "$NGINX_AVAIL" <<EOF
server {
    listen $PORT ssl http2 default_server;
    server_name _;

    ssl_certificate $SSL_DIR/warper-web.crt;
    ssl_certificate_key $SSL_DIR/warper-web.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "same-origin" always;

    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }
}
EOF

else
    # ===== HTTP (без HTTPS) =====
    cat > "$NGINX_AVAIL" <<EOF
server {
    listen $PORT default_server;
    server_name _;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "same-origin" always;

    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }
}
EOF

fi

ln -sf "$NGINX_AVAIL" "$NGINX_LINK"

if ! nginx -t >/dev/null 2>&1; then
    echo -e "${RED}Ошибка в nginx-конфиге!${NC}"
    nginx -t
    exit 1
fi

# ===== Запуск =====

echo -e "${CYAN}7. Запуск сервисов...${NC}"
systemctl daemon-reload
systemctl enable warper-web nginx >/dev/null 2>&1
systemctl restart warper-web nginx
sleep 2

# ===== Получение Let's Encrypt + переписывание конфига на HTTPS =====

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    echo -e "${CYAN}8. Получение Let's Encrypt сертификата для $DOMAIN...${NC}"

    # Все переменные инициализируем заранее чтобы set -u не падал
    CERT_OK="n"
    STOP_OPENVPN_BACKUP="n"
    _backup_choice="1"
    _stopped_services=()
    _port80_pid=""
    _port80_pids=""
    _port80_proc=""
    _az_openvpn_backup=""
    _pid=""
    _name="" 
    _domain_ip=""
    _server_ip=""
    _test_token=""
    _self_test=""
    _port80_after=""
    _port80_after_proc=""

    # Проверяем что у сервера уже есть сертификат
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && \
       [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
        echo -e "${CYAN}Найден существующий сертификат для $DOMAIN — используем его${NC}"
        CERT_OK="y"
    else
        echo -e "${CYAN}Подготовка к получению Let's Encrypt сертификата...${NC}"

        # ===== Диагностика порта 80 =====
        echo -e "${CYAN}Проверка доступности порта 80...${NC}"

        # Собираем ВСЕ pid'ы которые слушают порт 80 (могут быть несколько процессов/воркеров)
        _port80_pids=$(ss -tlnpH "sport = :80" 2>/dev/null | grep -oP 'pid=\K\d+' | sort -u | tr '\n' ' ')

        # Собираем имена процессов в одну строку
        _port80_proc=""
        if [ -n "$_port80_pids" ]; then
            for _pid in $_port80_pids; do
                _name=$(ps -p "$_pid" -o comm= 2>/dev/null | tr -d ' ')
                if [ -n "$_name" ]; then
                    _port80_proc="${_port80_proc} ${_name}"
                fi
            done
            _port80_proc=$(echo "$_port80_proc" | xargs)
        fi

        # Дополнительная проверка: используется ли OpenVPN backup TCP в AntiZapret
        _az_openvpn_backup="n"
        if [ -f "/root/antizapret/setup" ] && \
           grep -qE "^OPENVPN_BACKUP_TCP=y" /root/antizapret/setup 2>/dev/null; then
            _az_openvpn_backup="y"
        fi

        if [ -z "$_port80_pids" ]; then
            echo -e "${YELLOW}⚠ Порт 80 никем не слушается${NC}"
            echo -e "${YELLOW}Возможно nginx не смог занять порт 80. Проверяем дальше...${NC}"
        elif echo "$_port80_proc" | grep -qi "nginx" && [ "$_az_openvpn_backup" != "y" ]; then
            echo -e "${GREEN}✓ Порт 80 слушает nginx — отлично${NC}"
        elif echo "$_port80_proc" | grep -qiE "openvpn" || [ "$_az_openvpn_backup" = "y" ]; then
            echo -e "${YELLOW}⚠ Порт 80 связан с OpenVPN (backup-подключения AntiZapret)${NC}"
            if [ "$_az_openvpn_backup" = "y" ]; then
                echo -e "${YELLOW}  В /root/antizapret/setup: OPENVPN_BACKUP_TCP=y${NC}"
            fi
            if [ -n "$_port80_proc" ]; then
                echo -e "${YELLOW}  Процессы на 80: ${_port80_proc}${NC}"
            fi
            echo -e ""
            echo -e "${YELLOW}OpenVPN использует порт 80 для backup-подключений.${NC}"
            echo -e "${YELLOW}Let's Encrypt может не получить сертификат пока правила iptables${NC}"
            echo -e "${YELLOW}перенаправляют трафик с 80 на OpenVPN.${NC}"
            echo -e ""
            echo -e "${CYAN}Варианты:${NC}"
            echo -e "  ${GREEN}1.${NC} Временно остановить OpenVPN на 80 порту (~1 минута)"
            echo -e "     получить сертификат и запустить OpenVPN обратно"
            echo -e "     ${YELLOW}В это время клиенты не смогут подключаться через backup-порт 80${NC}"
            echo -e "  ${CYAN}2.${NC} Пропустить HTTPS, использовать HTTP"
            echo -e "  ${CYAN}3.${NC} Настроить DNS-01 challenge вручную (для опытных)"
            echo -e ""
            echo -e "${YELLOW}Если у вас уже работает HTTP-сервер на 80 рядом с OpenVPN${NC}"
            echo -e "${YELLOW}(такое бывает) — попробуйте вариант 1: certbot скорее всего получит сертификат${NC}"
            echo -e "${YELLOW}даже без остановки OpenVPN. Можно сразу нажать Enter.${NC}"
            echo -e ""
            read -r -e -p "Выбор [1/2/3, по умолчанию 1]: " _backup_choice
            _backup_choice="${_backup_choice:-1}"

            if [ "$_backup_choice" = "1" ]; then
                STOP_OPENVPN_BACKUP="y"
                echo -e "${CYAN}OpenVPN backup на 80 будет временно остановлен${NC}"
            elif [ "$_backup_choice" = "3" ]; then
                echo -e ""
                echo -e "${CYAN}Инструкция по DNS-01 challenge:${NC}"
                echo -e "1. Установите плагин для вашего DNS-провайдера, например:"
                echo -e "   ${CYAN}apt install -y python3-certbot-dns-cloudflare${NC}"
                echo -e "2. Получите сертификат через DNS:"
                echo -e "   ${CYAN}certbot certonly --dns-cloudflare \\${NC}"
                echo -e "   ${CYAN}  --dns-cloudflare-credentials /root/.cloudflare.ini \\${NC}"
                echo -e "   ${CYAN}  -d $DOMAIN${NC}"
                echo -e "3. Затем переустановите веб-панель — сертификат будет использован"
                echo -e ""
                echo -e "${YELLOW}Сейчас веб-панель будет настроена без HTTPS.${NC}"
            else
                echo -e "${YELLOW}Пропускаем HTTPS, веб-панель будет работать по HTTP${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ Порт 80 слушает: ${_port80_proc:-неизвестно} (PID $_port80_pids)${NC}"
            echo -e "${YELLOW}Это не nginx и не OpenVPN — пробуем всё равно...${NC}"
        fi

        # ===== Если согласились - останавливаем OpenVPN backup =====
        if [ "$STOP_OPENVPN_BACKUP" = "y" ]; then
            echo -e "${CYAN}Останавливаю OpenVPN backup на порту 80...${NC}"

            for _svc in antizapret-tcp vpn-tcp; do
                if systemctl is-active --quiet "openvpn-server@${_svc}" 2>/dev/null; then
                    if grep -q "^port 80$" "/etc/openvpn/server/${_svc}.conf" 2>/dev/null; then
                        echo -e "  Останавливаю openvpn-server@${_svc}..."
                        systemctl stop "openvpn-server@${_svc}" 2>/dev/null
                        _stopped_services+=("openvpn-server@${_svc}")
                    fi
                fi
            done

            sleep 2

            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
            sleep 1

            _port80_pid=$(ss -tlnpH "sport = :80" 2>/dev/null | head -1 | grep -oP 'pid=\K\d+' || echo "")
            if [ -n "$_port80_pid" ]; then
                _port80_proc=$(ps -p "$_port80_pid" -o comm= 2>/dev/null || echo "?")
                if [ "$_port80_proc" = "nginx" ]; then
                    echo -e "${GREEN}✓ Порт 80 теперь у nginx, готов получать сертификат${NC}"
                else
                    echo -e "${YELLOW}⚠ Порт 80 у $_port80_proc, не у nginx${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ Порт 80 свободен, но nginx его не занял${NC}"
            fi
        fi

        # ===== Если пользователь не отказался (выбор 2 или 3) - пробуем получить =====
        if [ "$_backup_choice" != "2" ] && [ "$_backup_choice" != "3" ]; then
            echo -e "${CYAN}Проверка DNS: $DOMAIN...${NC}"
            _domain_ip=$(getent hosts "$DOMAIN" 2>/dev/null | head -1 | awk '{print $1}')
            _server_ip=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "")

            if [ -z "$_domain_ip" ]; then
                echo -e "${RED}⚠ DNS-запись для $DOMAIN не найдена${NC}"
                echo -e "${YELLOW}  Проверьте A-запись на DNS-провайдере${NC}"
            elif [ -n "$_server_ip" ] && [ "$_domain_ip" != "$_server_ip" ]; then
                echo -e "${RED}⚠ DNS-несовпадение!${NC}"
                echo -e "  Домен указывает на: ${RED}$_domain_ip${NC}"
                echo -e "  IP этого сервера:  ${GREEN}$_server_ip${NC}"
            else
                echo -e "${GREEN}✓ DNS корректно указывает на сервер ($_domain_ip)${NC}"
            fi

            # Self-test HTTP с внешнего адреса
            echo -e "${CYAN}Self-test HTTP с внешнего адреса...${NC}"
            mkdir -p /var/www/html/.well-known/acme-challenge
            _test_token="warper-test-$(date +%s)"
            echo "$_test_token" > "/var/www/html/.well-known/acme-challenge/$_test_token"
            chmod 644 "/var/www/html/.well-known/acme-challenge/$_test_token"

            _self_test=$(curl -s --max-time 10 \
                "http://$DOMAIN/.well-known/acme-challenge/$_test_token" 2>/dev/null || echo "")
            rm -f "/var/www/html/.well-known/acme-challenge/$_test_token"

            if [ "$_self_test" = "$_test_token" ]; then
                echo -e "${GREEN}✓ Сервер доступен извне, можно запрашивать сертификат${NC}"
            else
                echo -e "${YELLOW}⚠ Self-test провалился (получено: '${_self_test:-пусто}')${NC}"
                echo -e "${YELLOW}  Возможно firewall блокирует входящий порт 80${NC}"
                echo -e "${YELLOW}  Пробуем certbot всё равно...${NC}"
            fi

            # Запускаем certbot
            echo -e "${CYAN}Запуск certbot...${NC}"
            mkdir -p /var/www/html

            if certbot certonly --webroot --webroot-path /var/www/html \
                -d "$DOMAIN" --non-interactive --agree-tos \
                --register-unsafely-without-email 2>&1 | tail -15; then
                sleep 2
                if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                    CERT_OK="y"
                    echo -e "${GREEN}✓ Сертификат получен!${NC}"
                fi
            fi

            if [ "$CERT_OK" != "y" ]; then
                echo -e "${RED}⚠ Сертификат получить не удалось${NC}"

                # Проверяем характерные ошибки в логе certbot
                _certbot_log="/var/log/letsencrypt/letsencrypt.log"
                if [ -f "$_certbot_log" ]; then
                    if tail -50 "$_certbot_log" | grep -qE "SERVFAIL.*CAA|CAA.*SERVFAIL"; then
                        echo -e ""
                        echo -e "${YELLOW}═══ Похоже на временную проблему DNS-провайдера ═══${NC}"
                        echo -e "${YELLOW}Let's Encrypt не смог проверить CAA-запись для домена.${NC}"
                        echo -e "${YELLOW}Это известная проблема некоторых DNS-провайдеров (DuckDNS, NoIP).${NC}"
                        echo -e ""
                        echo -e "${CYAN}Что делать:${NC}"
                        echo -e "  1. Подождать 15-30 минут и попробовать снова:"
                        echo -e "     ${CYAN}certbot certonly --webroot --webroot-path /var/www/html -d $DOMAIN${NC}"
                        echo -e "  2. Проверить DNS-провайдера:"
                        echo -e "     ${CYAN}dig CAA $(echo $DOMAIN | rev | cut -d. -f1-2 | rev) @1.1.1.1${NC}"
                        echo -e "  3. Если проблема не уходит — рассмотреть смену DNS-провайдера"
                        echo -e ""
                    elif tail -50 "$_certbot_log" | grep -qE "Connection refused|Connection reset"; then
                        echo -e "${YELLOW}Похоже на сетевую проблему — порт 80 может быть заблокирован${NC}"
                    elif tail -50 "$_certbot_log" | grep -qE "rate limit|too many"; then
                        echo -e "${YELLOW}Превышен лимит запросов Let's Encrypt для этого домена${NC}"
                        echo -e "${YELLOW}Попробуйте через час${NC}"
                    fi
                fi
            fi
        fi

        # ===== Возвращаем OpenVPN backup обратно =====
        if [ ${#_stopped_services[@]} -gt 0 ]; then
            echo -e "${CYAN}Запуск OpenVPN backup обратно...${NC}"
            for _svc in "${_stopped_services[@]}"; do
                echo -e "  Запуск $_svc..."
                systemctl start "$_svc" 2>/dev/null
            done
            sleep 2

            _port80_after=$(ss -tlnpH "sport = :80" 2>/dev/null | head -1 | grep -oP 'pid=\K\d+' || echo "")
            if [ -n "$_port80_after" ]; then
                _port80_after_proc=$(ps -p "$_port80_after" -o comm= 2>/dev/null || echo "?")
                echo -e "  Порт 80 теперь у: $_port80_after_proc"
            fi

            echo -e "${GREEN}✓ OpenVPN восстановлен${NC}"
        fi
    fi

    # ===== Создание renewal hooks если нужно =====
    if [ "$CERT_OK" = "y" ] && [ "$STOP_OPENVPN_BACKUP" = "y" ]; then
        echo -e "${CYAN}Создаю hook'и для автопродления сертификата...${NC}"

        mkdir -p /etc/letsencrypt/renewal-hooks/pre
        cat > "/etc/letsencrypt/renewal-hooks/pre/warper-stop-openvpn80.sh" <<'PREHOOK'
#!/bin/bash
# AZ-WARP: останавливаем OpenVPN backup на 80 для продления сертификата
for svc in antizapret-tcp vpn-tcp; do
    if systemctl is-active --quiet "openvpn-server@${svc}" 2>/dev/null; then
        if grep -q "^port 80$" "/etc/openvpn/server/${svc}.conf" 2>/dev/null; then
            systemctl stop "openvpn-server@${svc}" 2>/dev/null
        fi
    fi
done
systemctl reload nginx 2>/dev/null || true
sleep 2
PREHOOK
        chmod +x "/etc/letsencrypt/renewal-hooks/pre/warper-stop-openvpn80.sh"

        mkdir -p /etc/letsencrypt/renewal-hooks/post
        cat > "/etc/letsencrypt/renewal-hooks/post/warper-start-openvpn80.sh" <<'POSTHOOK'
#!/bin/bash
# AZ-WARP: запускаем OpenVPN backup обратно после продления
for svc in antizapret-tcp vpn-tcp; do
    if [ -f "/etc/openvpn/server/${svc}.conf" ]; then
        if grep -q "^port 80$" "/etc/openvpn/server/${svc}.conf" 2>/dev/null; then
            systemctl start "openvpn-server@${svc}" 2>/dev/null
        fi
    fi
done
POSTHOOK
        chmod +x "/etc/letsencrypt/renewal-hooks/post/warper-start-openvpn80.sh"

        echo -e "${GREEN}✓ Hooks созданы — сертификат будет автоматически продлеваться${NC}"
    fi

    # ===== Если сертификат получен - переписываем nginx-конфиг на HTTPS =====
    if [ "$CERT_OK" = "y" ]; then
        CERTBOT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        CERTBOT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

        cat > "$NGINX_AVAIL" <<EOF
# AZ-WARP Web Panel — HTTPS на порту $PORT, домен $DOMAIN
# Минимальный server-блок на 80 для автопродления Let's Encrypt
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 404;
    }
}

server {
    listen $PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERTBOT_CERT;
    ssl_certificate_key $CERTBOT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:WarperSSL:5m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "same-origin" always;

    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
    }
}
EOF
        ln -sf "$NGINX_AVAIL" "$NGINX_LINK"

        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
            echo -e "${GREEN}✓ HTTPS активирован${NC}"
        else
            echo -e "${YELLOW}Предупреждение: ошибка в HTTPS-конфиге nginx${NC}"
            nginx -t
        fi
    else
        echo -e ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠ HTTPS не настроен — веб-панель работает по HTTP${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e ""
        echo -e "${YELLOW}Чтобы исправить:${NC}"
        echo -e ""
        echo -e "${CYAN}1.${NC} Проверьте что DNS-запись A для ${CYAN}$DOMAIN${NC} указывает на IP этого сервера"
        echo -e "${CYAN}2.${NC} Откройте порт 80 в firewall:"
        echo -e "   ${CYAN}iptables -I INPUT -p tcp --dport 80 -j ACCEPT${NC}"
        echo -e "   ${CYAN}ufw allow 80${NC}  (если используете ufw)"
        echo -e "${CYAN}3.${NC} Если хостинг блокирует порт 80 на уровне сети — откройте его в панели хостинга"
        echo -e "${CYAN}4.${NC} Если AntiZapret использует порт 80 для OpenVPN backup — выберите вариант 1 при установке"
        echo -e "${CYAN}5.${NC} После исправления получите сертификат:"
        echo -e "   ${CYAN}certbot certonly --webroot --webroot-path /var/www/html -d $DOMAIN${NC}"
        echo -e "${CYAN}6.${NC} Затем переустановите веб-панель чтобы применить HTTPS:"
        echo -e "   ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/uninstall-web.sh)${NC}"
        echo -e "   ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/install-web.sh)${NC}"
        echo -e ""
        echo -e "${YELLOW}Или используйте самоподписанный сертификат — установите заново без ввода домена.${NC}"
    fi
fi
# ===== Установка пароля =====

echo -e "${CYAN}9. Установка начального пароля...${NC}"

# Ждём пока сервис создаст data/ и инициализируется
sleep 2

# Создаём пользователя НАПРЯМУЮ через Python, не зависим от warper webpass
PASS_OK="n"
NEW_USER="$ADMIN_USER" NEW_PASS="$ADMIN_PASSWORD" "$WEB_DIR/venv/bin/python3" - <<'PYEOF' && PASS_OK="y"
import json
import os
import secrets
import sys
from datetime import datetime
from pathlib import Path

try:
    from flask_bcrypt import Bcrypt
    from flask import Flask
except ImportError as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(2)

username = os.environ.get("NEW_USER", "admin")
password = os.environ.get("NEW_PASS", "")

if not password:
    print("ERROR: empty password", file=sys.stderr)
    sys.exit(1)

app = Flask(__name__)
bcrypt = Bcrypt(app)

data_dir = Path("/root/warper/web/data")
users_file = data_dir / "users.json"
secret_file = data_dir / "secret.key"

data_dir.mkdir(mode=0o700, exist_ok=True)

password_hash = bcrypt.generate_password_hash(password).decode("utf-8")

users = {
    username: {
        "password_hash": password_hash,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "last_login": None,
    }
}

tmp = users_file.with_suffix(".tmp")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(users, f, indent=2, ensure_ascii=False)
os.chmod(tmp, 0o600)
tmp.replace(users_file)
os.chmod(users_file, 0o600)

# Ротируем SECRET_KEY
new_secret = secrets.token_hex(32)
secret_file.write_text(new_secret + "\n", encoding="utf-8")
os.chmod(secret_file, 0o600)

print("OK")
PYEOF

if [ "$PASS_OK" = "y" ]; then
    # Перезапускаем чтобы подхватить новый SECRET_KEY
    systemctl restart warper-web
    sleep 2
    echo -e "${GREEN}✓ Пользователь $ADMIN_USER создан${NC}"
else
    echo -e "${RED}⚠ Не удалось создать пользователя автоматически.${NC}"
    echo -e "${YELLOW}  Используйте после установки: warper webpass${NC}"
    echo -e "${YELLOW}  Будет работать пароль по умолчанию (warper webpass --reset)${NC}"
fi

# ===== Итог =====

EXTERNAL_IP=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "0.0.0.0")

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   ✓ Веб-панель установлена!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        if [ "$PORT" = "443" ]; then
            echo -e "  URL:    ${CYAN}https://$DOMAIN${NC}"
        else
            echo -e "  URL:    ${CYAN}https://$DOMAIN:$PORT${NC}"
        fi
    else
        echo -e "  URL:    ${CYAN}http://$DOMAIN${NC} ${YELLOW}(без SSL)${NC}"
    fi
elif [ "$ENABLE_HTTPS" = "y" ]; then
    echo -e "  URL:    ${CYAN}https://$EXTERNAL_IP:$PORT${NC}  ${YELLOW}(самоподписанный сертификат)${NC}"
else
    echo -e "  URL:    ${CYAN}http://$EXTERNAL_IP:$PORT${NC}"
fi

echo -e "  Логин:  ${CYAN}$ADMIN_USER${NC}"
if [ "$PASSWORD_GENERATED" = "y" ]; then
    echo -e "  Пароль: ${CYAN}$ADMIN_PASSWORD${NC}"
    echo ""
    echo -e "  ${RED}⚠ Пароль показан ТОЛЬКО СЕЙЧАС — сохраните его!${NC}"
else
    echo -e "  Пароль: ${CYAN}[установленный вами]${NC}"
fi
echo ""
echo -e "  ${YELLOW}При утере пароля:${NC}"
echo -e "    ${CYAN}warper webpass --reset${NC}   — сгенерирует новый пароль для admin"
echo -e "    ${CYAN}warper webpass${NC}             — сменить логин/пароль интерактивно"
echo ""
echo -e "  ${YELLOW}Управление:${NC}"
echo -e "    ${CYAN}warper${NC} → пункт ${CYAN}W${NC} — меню веб-панели"
echo -e "    ${CYAN}systemctl status warper-web${NC}"
echo -e "    ${CYAN}journalctl -u warper-web -f${NC}"
echo ""
