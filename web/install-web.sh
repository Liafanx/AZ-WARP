#!/bin/bash

set -uo pipefail

# Если запущено через "curl ... | bash" — переключаем stdin на терминал
# чтобы read работал. Делаем это БЕЗОПАСНО.
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

REPO_BRANCH="${WARPER_WEB_BRANCH:-1.3.2}"
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

read -r -p "Внешний порт веб-панели [$DEFAULT_PORT]: " PORT
PORT="${PORT:-$DEFAULT_PORT}"

read -r -p "Внутренний порт (gunicorn) [$DEFAULT_BACKEND_PORT]: " BACKEND_PORT
BACKEND_PORT="${BACKEND_PORT:-$DEFAULT_BACKEND_PORT}"

read -r -p "Логин администратора [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

DEFAULT_PASSWORD=$(openssl rand -base64 12 2>/dev/null | tr -d '=+/' | cut -c1-12)
read -r -p "Пароль [сгенерировать автоматически]: " ADMIN_PASSWORD
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$DEFAULT_PASSWORD}"

# ===== HTTPS =====

ENABLE_HTTPS="n"
DOMAIN=""
read -r -p "Включить HTTPS? (y/N): " enable_https_input
if [[ "$enable_https_input" =~ ^[Yy]$ ]]; then
    ENABLE_HTTPS="y"
    read -r -p "Доменное имя (для Let's Encrypt) или Enter для самоподписанного: " DOMAIN
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
# В .env храним только не-секретные параметры.
# SECRET_KEY создаётся автоматически в web/data/secret.key (chmod 600).
# Учётные данные хранятся в web/data/users.json (chmod 600).
cat > "$WEB_DIR/.env" <<EOF
PORT=$BACKEND_PORT
DEBUG=false
EOF
chmod 600 "$WEB_DIR/.env"

# Создаём data/ заранее с правильными правами
mkdir -p "$WEB_DIR/data"
chmod 700 "$WEB_DIR/data"

# Создаём data/ заранее с правильными правами
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
ExecStart=$WEB_DIR/venv/bin/gunicorn \\
    --workers 2 \\
    --threads 8 \\
    --worker-class gthread \\
    --bind 127.0.0.1:$BACKEND_PORT \\
    --access-logfile - \\
    --error-logfile - \\
    --timeout 600 \\
    --graceful-timeout 30 \\
    app:app
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
# ===== nginx =====

echo -e "${CYAN}6. Настройка nginx...${NC}"
rm -f "$NGINX_LINK" /etc/nginx/sites-enabled/default

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    # Let's Encrypt
    cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen $PORT ssl http2;
    server_name $DOMAIN;
    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;
    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
}
EOF
elif [ "$ENABLE_HTTPS" = "y" ]; then
    # Самоподписанный
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
    listen [::]:$PORT ssl http2 default_server;
    server_name _;
    ssl_certificate $SSL_DIR/warper-web.crt;
    ssl_certificate_key $SSL_DIR/warper-web.key;
    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;
    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
}
EOF
else
    # HTTP
    cat > "$NGINX_AVAIL" <<EOF
server {
    listen $PORT default_server;
    listen [::]:$PORT default_server;
    server_name _;
    client_max_body_size 2M;
    access_log /var/log/nginx/warper-web.access.log;
    error_log /var/log/nginx/warper-web.error.log;
    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
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

# Получение Let's Encrypt
if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    echo -e "${CYAN}8. Получение Let's Encrypt сертификата...${NC}"
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
        --register-unsafely-without-email --redirect 2>&1 | tail -5 || \
        echo -e "${YELLOW}Сертификат не получен — проверьте настройки DNS${NC}"
fi

# Сохранение пароля
echo "$ADMIN_PASSWORD" > "$WARPER_DIR/web_admin_pass.txt"
chmod 600 "$WARPER_DIR/web_admin_pass.txt"


echo -e "${CYAN}9. Установка начального пароля...${NC}"
# Дожидаемся пока сервис стартанёт (создастся data/users.json с admin/admin)
sleep 3

# Устанавливаем пользовательский логин/пароль через CLI
warper webpass "$ADMIN_USER" "$ADMIN_PASSWORD" >/dev/null 2>&1 || {
    echo -e "${YELLOW}Не удалось установить начальный пароль. Используйте 'warper webpass' вручную.${NC}"
}


# ===== Итог =====

EXTERNAL_IP=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   ✓ Веб-панель установлена!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    echo -e "  URL:    ${CYAN}https://$DOMAIN${NC}"
    [ "$PORT" != "443" ] && echo -e "          (порт $PORT)"
elif [ "$ENABLE_HTTPS" = "y" ]; then
    echo -e "  URL:    ${CYAN}https://$EXTERNAL_IP:$PORT${NC}  ${YELLOW}(самоподписанный)${NC}"
else
    echo -e "  URL:    ${CYAN}http://$EXTERNAL_IP:$PORT${NC}"
fi

echo -e "  Логин:  ${CYAN}$ADMIN_USER${NC}"
echo -e "  Пароль: ${CYAN}$ADMIN_PASSWORD${NC}"
echo ""
echo -e "  Пароль сохранён в: ${YELLOW}$WARPER_DIR/web_admin_pass.txt${NC}"
echo ""
echo -e "  Управление: systemctl status warper-web"
echo -e "  Логи:       journalctl -u warper-web -f"
echo ""
