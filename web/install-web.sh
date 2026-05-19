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

# Валидация логина
while ! [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_-]{3,32}$ ]]; do
    echo -e "${RED}Логин: 3-32 символа, латиница/цифры/_-${NC}"
    read -r -p "Логин администратора [admin]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-admin}"
done

# Генерация безопасного пароля по умолчанию
DEFAULT_PASSWORD=$(openssl rand -base64 16 2>/dev/null | tr -d '=+/' | cut -c1-12)
if [ -z "$DEFAULT_PASSWORD" ] || [ ${#DEFAULT_PASSWORD} -lt 10 ]; then
    DEFAULT_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-12)
fi

echo ""
read -r -p "Пароль (Enter = сгенерировать автоматически, мин. 6 симв.): " ADMIN_PASSWORD
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$DEFAULT_PASSWORD}"

# Валидация пароля
while [ ${#ADMIN_PASSWORD} -lt 6 ]; do
    echo -e "${RED}Пароль слишком короткий (минимум 6 символов).${NC}"
    read -r -p "Пароль [Enter = сгенерировать]: " ADMIN_PASSWORD
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$DEFAULT_PASSWORD}"
done

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
ExecStart=$WEB_DIR/venv/bin/gunicorn --workers 2 --threads 8 --worker-class gthread --bind 127.0.0.1:$BACKEND_PORT --access-logfile - --error-logfile - --timeout 600 --graceful-timeout 30 app:app
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
    # ===== HTTPS с доменом (Let's Encrypt) =====
    # Шаг 1: временный HTTP-конфиг для получения сертификата
    mkdir -p /var/www/html

    cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
    listen [::]:$PORT ssl http2 default_server;
    server_name _;

    ssl_certificate $SSL_DIR/warper-web.crt;
    ssl_certificate_key $SSL_DIR/warper-web.key;
    ssl_protocols TLSv1.2 TLSv1.3;

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
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }
}
EOF

else
    # ===== HTTP (без HTTPS) =====
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
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
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

# ===== Получение Let's Encrypt + переписывание конфига на HTTPS =====

if [ "$ENABLE_HTTPS" = "y" ] && [ -n "$DOMAIN" ]; then
    echo -e "${CYAN}8. Получение Let's Encrypt сертификата для $DOMAIN...${NC}"

    CERT_OK="n"
    if certbot certonly --webroot --webroot-path /var/www/html \
        -d "$DOMAIN" --non-interactive --agree-tos \
        --register-unsafely-without-email 2>&1 | tail -10; then
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            CERT_OK="y"
            echo -e "${GREEN}✓ Сертификат получен${NC}"
        fi
    fi

    if [ "$CERT_OK" = "y" ]; then
        # Переписываем конфиг на HTTPS
        CERTBOT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        CERTBOT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

        cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host:$PORT\$request_uri;
    }
}

server {
    listen $PORT ssl http2;
    listen [::]:$PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERTBOT_CERT;
    ssl_certificate_key $CERTBOT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

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
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
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
        echo -e "${YELLOW}⚠ Сертификат не получен — продолжаем с HTTP${NC}"
        echo -e "${YELLOW}Возможные причины:${NC}"
        echo -e "  - Домен $DOMAIN не указывает на этот сервер"
        echo -e "  - Порт 80 заблокирован (firewall/провайдер)"
        echo -e "  - Лимит Let's Encrypt"
        echo -e "${CYAN}Веб-панель работает по HTTP. Попробовать получить сертификат позже:${NC}"
        echo -e "  ${CYAN}certbot --nginx -d $DOMAIN${NC}"
    fi
fi

# ===== Установка пароля =====

echo -e "${CYAN}9. Установка начального пароля...${NC}"
sleep 3

if ! warper webpass "$ADMIN_USER" "$ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Не удалось установить пароль автоматически.${NC}"
    echo -e "${YELLOW}  Используйте: warper webpass${NC}"
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
echo -e "  Пароль: ${CYAN}$ADMIN_PASSWORD${NC}"
echo ""
echo -e "  ${RED}⚠ Пароль показан ТОЛЬКО СЕЙЧАС — сохраните его!${NC}"
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
