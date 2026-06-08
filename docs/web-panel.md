# 🌐 Веб-панель управления WARPER

Подробная документация по веб-панели.

## Содержание

1. [Архитектура](#architecture)
2. [Установка](#install)
3. [Структура файлов](#files)
4. [Авторизация и безопасность](#security)
5. [HTTPS](#https)
6. [Настройки nginx](#nginx)
7. [Обновление](#update)
8. [Удаление](#uninstall)
9. [Управление через CLI](#cli)
10. [Устранение неполадок](#troubleshooting)

---

<a id="architecture"></a>
## 🏗 Архитектура

Веб-панель — это Flask-приложение на Python 3.10+, работающее за nginx reverse-proxy.

**Стек:**

- **Backend**: Flask 3 + Flask-Login + Flask-Bcrypt
- **Frontend**: Jinja2 + HTMX 2 + Tailwind CSS (без сборки, всё офлайн)
- **WSGI**: Gunicorn с gthread workers
- **Reverse proxy**: nginx
- **Real-time updates**: Server-Sent Events (SSE) для логов обновления

**Схема работы:**

```
Браузер
    ↓ HTTPS/HTTP на порту 6060
nginx (proxy_pass)
    ↓ HTTP на 127.0.0.1:16060
Gunicorn (2 workers × 8 threads)
    ↓ subprocess
warper CLI (cli_*функции в lib/cli.sh)
    ↓ чтение/запись
файлы конфигурации WARPER (/root/warper/*.conf, *.txt, *.json)

systemd timer (5 мин)
    ↓ warper traffic snapshot
файл traffic.json (hourly агрегация)
```

Веб-панель **не дублирует логику** WARPER — она вызывает CLI-команды `warper add`, `warper sync`, `warper mode wg`, и т.д.

- **Каталог готовых доменов**: поиск и подключение готовых списков из community-репозитория.
- Поиск идёт по кэшированному списку категорий.
- Предпросмотр показывает итоговые домены после обработки `include:` и оптимизации.
- Добавление выполняется через SSE-прогресс, так как некоторые категории могут включать зависимые списки.

---

<a id="install"></a>
## ⚡ Установка

### Через основной installer

При установке WARPER появится вопрос:

```
Установить веб-панель? (y/N):
```

Ответьте `y` — установка пройдёт автоматически.

### Отдельно

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/install-web.sh)
```

### Через меню warper

```bash
warper
# Затем: W → 1
```

### Параметры установки

| Шаг | Параметр | По умолчанию | Валидация |
|---|---|---|---|
| 1 | Внешний порт | 6060 | 1-65535, проверка занятости |
| 2 | Внутренний порт (Gunicorn) | 16060 | 1-65535, не равен внешнему |
| 3 | Логин | admin | 3-32 символа: `[A-Za-z0-9_-]` |
| 4 | Пароль | автогенерация | Скрытый ввод, мин. 6 символов, подтверждение |
| 5 | HTTPS | нет (n) | y/n |
| 6 | Домен (если HTTPS) | пусто = самоподписанный | Let's Encrypt валидация |

Сгенерированный пароль показывается **один раз** в конце установки. Если ввели свой — он не показывается.

---

<a id="files"></a>
## 📁 Структура файлов

```
/root/warper/web/
├── app.py                    # Flask приложение
├── auth.py                   # авторизация (bcrypt + brute-force)
├── warper_api.py             # обёртки над CLI-командами warper
├── requirements.txt          # Python-зависимости
├── .env                      # PORT, DEBUG (не содержит секретов!)
├── venv/                     # Python venv
├── static/
│   ├── tailwind.js           # Tailwind CSS (офлайн)
│   ├── htmx.min.js           # HTMX 2 (офлайн)
│   └── app.js                # клиентский JS
├── templates/
│   ├── base.html             # макет
│   ├── login.html
│   ├── dashboard.html
│   ├── domains.html
│   ├── ip_ranges.html
│   ├── singbox.html
│   ├── logs.html
│   ├── diagnostics.html
│   ├── settings.html
│   ├── catalog.html
│   ├── traffic.html
│   └── partials/             # HTMX-фрагменты
│       ├── status_summary.html
│       ├── domains_list.html
│       ├── ip_ranges_list.html
│       ├── logs_content.html
│       ├── doctor_results.html
│       ├── singbox_status.html
│       ├── catalog_search_results.html
│       ├── catalog_installed.html
│       └── catalog_preview.html
│       ├── updates_status.html
│       └── update_progress.html
└── data/                     # БД (chmod 700, только root)
    ├── users.json            # bcrypt-хеши пользователей (chmod 600)
    ├── secret.key            # Flask SECRET_KEY (chmod 600)
    ├── blocks.json           # brute-force блокировки (chmod 600)
    └── auth.log              # аудит входов (chmod 600, авторотация)
| `/root/warper/catalog.json` | Метаданные добавленных каталожных списков |
| `/root/warper/catalog-cache.json` | Кэш списка категорий каталога |
```

### Системные файлы

| Путь | Назначение |
|---|---|
| `/etc/systemd/system/warper-web.service` | systemd unit |
| `/etc/nginx/sites-available/warper-web` | nginx конфиг |
| `/etc/nginx/sites-enabled/warper-web` | симлинк на конфиг |
| `/etc/nginx/ssl/warper-web.{crt,key}` | самоподписанный сертификат (если HTTPS) |
| `/etc/letsencrypt/live/DOMAIN/` | Let's Encrypt сертификаты (если домен) |

---

<a id="security"></a>
## 🔒 Авторизация и безопасность

### Хранение паролей

- **bcrypt cost 12** (стандарт безопасности)
- Хеши в `web/data/users.json` (chmod 600, только root)
- При первом запуске создаётся `admin` со случайным паролем (виден в `journalctl -u warper-web | grep -i пароль`)

### SECRET_KEY Flask

- Генерируется автоматически в `web/data/secret.key` (chmod 600)
- **Ротируется при смене пароля** через UI или CLI — все активные сессии становятся невалидными
- File-lock защищает от race condition при параллельном старте Gunicorn-воркеров

### Защита от brute-force

- **10 неудачных попыток за 10 минут** → блокировка IP на 15 минут
- Блокировки **persistent** — хранятся в `web/data/blocks.json`, переживают перезапуск сервиса
- Защита от timing-атак: bcrypt всегда выполняется с одинаковой длительностью

### Валидация

- **Логин**: regex `^[A-Za-z0-9_-]{3,32}$`
- **Пароль**: 6-256 символов
- **IP клиента**: только из заголовка `X-Real-IP` от nginx (невозможно подделать)

### CSRF-защита

Для всех `POST/PUT/DELETE/PATCH` запросов проверяется `Origin` или `Referer`. Запросы с чужого хоста блокируются с `403 CSRF check failed`.

### Cookie

- `HttpOnly` — JavaScript не имеет доступа
- `SameSite=Lax`
- `Secure` — автоматически включается при HTTPS

### Аудит-лог

В `web/data/auth.log` записываются:
- `login_success` — успешный вход
- `login_failed` — неверный пароль
- `blocked_attempt` — попытка от заблокированного IP
- `blocked_now` — IP заблокирован после превышения попыток
- `credentials_changed` — смена логина/пароля

Авторотация: максимум 1MB, хранится 3 файла.

Просмотр через UI: `warper` → `W` → `8`. Или вручную: `tail -f /root/warper/web/data/auth.log`.

---

<a id="https"></a>
## 🔐 HTTPS

### С доменом (Let's Encrypt)

При установке введите доменное имя — установщик автоматически получит сертификат через certbot и настроит nginx.

**Требования:**
- Домен указывает на IP сервера (A-запись)
- Порт 80 открыт и свободен на момент установки
- Сертификат продлевается автоматически через `certbot.timer` (systemd)

### Самоподписанный сертификат

Если оставить домен пустым при HTTPS — будет создан самоподписанный сертификат на 10 лет (`/etc/nginx/ssl/warper-web.crt`).

Браузер покажет предупреждение «небезопасное соединение» — это нормально для self-signed. Соединение всё равно зашифровано.

### Только HTTP (по умолчанию)

Подходит для тестирования или использования внутри частной сети. Не используйте HTTP с публичным IP — пароль будет уходить открытым текстом.

### Смена порта

```bash
warper
# W → 4 (Изменить внешний порт)
```

Новый порт проверяется на занятость. nginx-конфиг автоматически обновится.

---

<a id="nginx"></a>
## 🛠 Настройки nginx

Веб-панель **не перехватывает порт 80** для редиректа — другие сайты на этом порту продолжают работать.

При HTTPS с доменом порт 80 используется только для acme-challenge Let's Encrypt, для всех остальных запросов возвращается 404.

### Security-заголовки

В каждом конфиге nginx прописаны:

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "same-origin" always;
add_header Strict-Transport-Security "max-age=31536000" always;  # только HTTPS
```

### Таймауты

- `proxy_read_timeout 600s` — долгие операции (обновление, смена режима)
- `proxy_buffering off` + `chunked_transfer_encoding on` — для SSE-стрима логов

---

<a id="update"></a>
## 🔄 Обновление

Обновление **общее** — обновляется и WARPER и веб-панель за одну операцию.

### Способы запуска

1. **Из веб-панели**: на Dashboard сверху появляется блок «Доступно обновление» с кнопкой → показывает прогресс в реальном времени через SSE.
2. **Из интерактивного меню**: `warper` → пункт `10`.
3. **Из CLI**: `warper update`.

### Что сохраняется при обновлении

- `web/.env` — конфигурация
- `web/data/` — БД пользователей, SECRET_KEY, блокировки, логи
- `web/venv/` — Python venv

### Что обновляется

- Python-код (`app.py`, `auth.py`, `warper_api.py`)
- Шаблоны (`templates/`)
- Статика (`static/`)
- Python-зависимости (через `pip install -r requirements.txt`)
- `lib/cli.sh`, `menus/web-menu.sh`

### Проверка наличия обновлений

Веб-панель использует **GitHub API** (не raw.githubusercontent.com), что позволяет видеть актуальную версию **мгновенно** после публикации, без CDN-задержки.

Кэш на стороне Flask: 1 минута. Кнопка «Проверить» обходит кэш.

---

<a id="uninstall"></a>
## 🗑 Удаление

### Через меню warper

```bash
warper
# W → 9 (Удалить веб-панель)
```

### Через скрипт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/uninstall-web.sh)
```

### Автоматически при удалении WARPER

```bash
warper
# U → подтвердить
```

При удалении WARPER веб-панель удаляется **автоматически** в начале процесса деинсталляции, чтобы освободить порты и удалить службы.

### Что удаляется

- Сервис `warper-web` (systemd)
- nginx-конфиг
- Самоподписанные SSL-сертификаты (если были)
- Папка `/root/warper/web/` целиком

### Что не удаляется

- WARPER (warper.sh, конфиги в `/root/warper/`)
- sing-box
- Сертификаты Let's Encrypt в `/etc/letsencrypt/`

---

<a id="cli"></a>
## 💻 Управление через CLI

```bash
# Учётные данные
warper webpass                    # сменить логин/пароль (интерактивно)
warper webpass myuser MyPass123   # сменить (неинтерактивно)
warper webpass --reset            # полный сброс: создаст admin со случайным паролем
warper webpass --unblock          # сбросить все блокировки IP

# Обновление
warper webupdate                  # обновить только веб-панель
warper update                     # обновить WARPER + веб-панель

# Управление сервисом
systemctl status warper-web
systemctl restart warper-web
journalctl -u warper-web -f

# Проверка БД
cat /root/warper/web/data/users.json
cat /root/warper/web/data/blocks.json
tail /root/warper/web/data/auth.log
```

---

<a id="troubleshooting"></a>
## 🔧 Устранение неполадок

### Не могу войти, забыл пароль

```bash
warper webpass --reset
# Запишите показанный пароль
```

### IP заблокирован после неудачных попыток

```bash
warper webpass --unblock
```

### Сервис не запускается

```bash
journalctl -u warper-web -n 50 --no-pager
# Покажет точную ошибку
```

Частые причины:
- Порт занят другим процессом
- Ошибка в Python-коде (после ручной правки)
- Сломан `web/data/secret.key`

Сбросить всё:

```bash
rm -rf /root/warper/web/data
systemctl restart warper-web
# Создастся новый admin со случайным паролем (см. journalctl)
```

### 502 Bad Gateway

Сервис warper-web не запущен или упал.

```bash
systemctl status warper-web
systemctl restart warper-web
```

### Веб-панель медленная

Проверьте загрузку сервера:

```bash
top
journalctl -u warper-web -n 100 | grep -i timeout
```

Возможно, идёт долгая операция (обновление, смена подсети). Подождите 1-3 минуты.

### Кнопка "Обновить" не показывает новую версию

GitHub Raw CDN кэширует файлы до 5 минут. Веб-панель использует GitHub API для обхода кэша. Если всё равно не показывает:

```bash
# Проверка вручную
curl -s "https://api.github.com/repos/Liafanx/AZ-WARP/contents/version?ref=main" \
    | python3 -c "import json,sys,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode())"

# Сравните с локальной
cat /root/warper/version
```

Если версии разные, а UI не обновляется — нажмите `Ctrl+F5` в браузере (обход кэша).

### SSE-стрим обновления не работает

Возможно nginx буферизует SSE. Проверьте конфиг:

```bash
grep -A 1 "proxy_buffering" /etc/nginx/sites-available/warper-web
```

Должно быть `proxy_buffering off;` и `chunked_transfer_encoding on;`.

Если нет — добавьте и перезагрузите:

```bash
sed -i '/proxy_buffering off;/a\        chunked_transfer_encoding on;' /etc/nginx/sites-available/warper-web
nginx -t && systemctl reload nginx
```
