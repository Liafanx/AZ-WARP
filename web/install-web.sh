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
    # Шаг 1: временный HTTP-конфиг на нашем порту до получения сертификата
    mkdir -p /var/www/html

    cat > "$NGINX_AVAIL" <<EOF
# AZ-WARP Web Panel — временно HTTP до получения сертификата
# (порт 80 НЕ трогаем чтобы не конфликтовать с другими сайтами)
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

    CERT_OK="n"

    # Проверяем что у сервера уже есть сертификат
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo -e "${CYAN}Найден существующий сертификат для $DOMAIN — используем его${NC}"
        CERT_OK="y"
    else
        # Получаем сертификат через --webroot (не модифицирует nginx-конфиги)
        # Это безопасно для серверов где уже есть другие nginx-сайты
        mkdir -p /var/www/html
        if certbot certonly --webroot --webroot-path /var/www/html \
            -d "$DOMAIN" --non-interactive --agree-tos \
            --register-unsafely-without-email 2>&1 | tail -10; then
            sleep 2
            if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                CERT_OK="y"
                echo -e "${GREEN}✓ Сертификат получен${NC}"
            fi
        fi
    fi

    # Проверяем что сертификат реально создался (может уже был от прошлой установки)
    sleep 2
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && \
       [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
        CERT_OK="y"
        echo -e "${GREEN}✓ Сертификат готов (получен или уже существовал)${NC}"
    else
        echo -e "${YELLOW}⚠ Сертификат не найден${NC}"
    fi

if [ "$CERT_OK" = "y" ]; then
    # Переписываем конфиг — ТОЛЬКО на нашем порту, БЕЗ блока на порту 80
    # (acme-challenge для продления сертификата работает через другие конфиги
    # продление будет работать через --webroot certbot)
    CERTBOT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    CERTBOT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    cat > "$NGINX_AVAIL" <<EOF
# AZ-WARP Web Panel — HTTPS на порту $PORT, домен $DOMAIN
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
