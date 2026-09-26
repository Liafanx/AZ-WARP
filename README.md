# 🚀 WARPER для AntiZapret VPN

Точечная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и других доменов и IPv4-подсетей (CIDR) через **Cloudflare WARP**, **внешний донор-сервер**, **собственное WireGuard-соединение** или сторонний сервер **VLESS+Reality / Hysteria2 / OpenVPN** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#about)
2. [Как это работает](#how-it-works)
3. [Режимы работы](#modes)
4. [Системные требования](#requirements)
5. [Установка WARPER](#install-warper)
6. [Веб-панель управления](#web-panel)
7. [Установка WARPERSLAVE](#install-warperslave)
8. [Быстрая проверка](#quick-check)
9. [Команды управления](#commands)
10. [Удаление](#uninstall)
11. [FAQ](#faq)
12. [Известные ограничения](#limitations)
13. [Документация](#docs)
14. [Python API](#python-api)
15. [Поддержать проект](#support)

---

<a id="about"></a>
## ℹ️ О проекте

### Проблема

У вас настроен сервер с **AntiZapret**. Заблокированные сайты открываются. Но при попытке зайти на **Gemini**, **ChatGPT** или другие сервисы — ошибка:

- сервис недоступен в вашей стране
- IP вашего VPS заблокирован
- сервис режет доступ по GEO

### Решение

WARPER позволяет **точечно направлять только нужные домены + IPv4-подсети (CIDR)** через Cloudflare WARP, внешний донор-сервер или своё WireGuard-соединение, не меняя остальной сценарий работы AntiZapret.

Гибридная схема:

- обычные блокировки → **AntiZapret**
- "проблемные" домены/подсети → **WARP**, **донор-сервер** или **WG-туннель**

---

<a id="how-it-works"></a>
## ⚙️ Как это работает

### Когда вы добавляете домен в WARPER:

1. Домен попадает в список маршрутизации
2. `kresd` (только для AntiZapret-клиентов) отдаёт для него **fake-ip** из подсети `10.224.0.0/16 (по умолчанию)`
3. Трафик к fake-ip перехватывает `sing-box`
4. `sing-box` отправляет его в **WARP-туннель**, на **донор-сервер**, через **WG-соединение** или на сторонний сервер (**VLESS / Hysteria2 / OpenVPN**)
5. Сайт видит IP Cloudflare/донора/WG-сервера, а не IP вашего VPS

### Маршрутизация по IP-подсетям

Помимо доменной маршрутизации, WARPER поддерживает прямую маршрутизацию по IPv4-подсетям (CIDR):

1. Вы добавляете подсеть (например `91.108.4.0/22`) в файл `ip-ranges.txt`
2. WARPER создаёт маршрут в ядре Linux: трафик к этой подсети → `singbox-tun`
3. `sing-box` отправляет его в **WARP**, на **донор-сервер** или через **WG-соединение**
4. При включённом экспорте в AntiZapret — подсеть автоматически попадает в маршруты AntiZapret-клиентов

Это полезно для сервисов, которые невозможно поймать только по доменам (Telegram, игровые серверы и т.д.).
Примечание: после обновления маршрутов клиентам OPENVPN потребуется переподключение, а клиентам AWG/WG, пересборка конфига с учетом новых IPv4-подсетей (CIDR). В роутеры новые маршруты тоже нужно будет добавлять, если это требуется.

---

<a id="modes"></a>
## 🔀 Режимы работы

### Режим WARP (локальный)

```
Клиент → AntiZapret → kresd/ip route → fake-ip → sing-box → Cloudflare WARP → Интернет
```

Трафик идёт через Cloudflare WARP напрямую с вашего сервера.

### Режим Slave (донор-сервер)

```
Сервер 1 (WARPER)                    Сервер 2 (WARPERSLAVE)
Клиент → AntiZapret → kresd/ip route →        → sing-box (вход) →
  fake-ip → sing-box ───────────────→   direct / WARP → Интернет
          SS 2022 / VLESS+Reality / Hysteria2
```

Трафик идёт через второй сервер (донор). Канал master → донор — Shadowsocks 2022,
VLESS+Reality (рекомендуется: выглядит как обычный TLS к выбранному сайту) или
Hysteria2 (QUIC). На доноре трафик может выходить напрямую (Direct) или через WARP.

Донор выдаёт готовую команду для master: `warperslave link`. Для VLESS и
Hysteria2 master переключается в режим `vless` / `hy2` — так же, как на
сторонний сервер.

**Когда нужен Slave:**
- IP основного сервера заблокирован сервисом
- Нужен выход через конкретную страну/IP
- WARP на основном сервере не работает

### Режим WG (WireGuard)

```
Клиент → AntiZapret → kresd/ip route → fake-ip → sing-box → WireGuard-туннель → Интернет
```

Трафик идёт через ваш собственный WireGuard-сервер. Используйте любой `.conf` файл от WG-сервера.

**Когда нужен WG:**
- Есть свой WireGuard VPN-сервер
- Нужен выход через конкретный IP без Cloudflare
- WARP не подходит, донор-сервер не нужен

### Режимы VLESS, Hysteria2, OpenVPN

```
Клиент → AntiZapret → kresd/ip route → fake-ip → sing-box → VLESS / Hysteria2 / OpenVPN → Интернет
```

Выход через любой сторонний сервер или свой донор:
- **VLESS** (в том числе Reality, транспорты ws/grpc/httpupgrade/http) — по
  ссылке `vless://…`;
- **Hysteria2** — по ссылке `hy2://…` или `hysteria2://…` (obfs salamander,
  диапазоны портов, пиннинг сертификата `pinSHA256`);
- **OpenVPN** — по файлу `.ovpn` (`dev tun`, инлайн-сертификаты, `tls-auth`,
  `tls-crypt`, логин/пароль для `auth-user-pass`). Логин и пароль
  запоминаются для каждого файла — между профилями (например, серверами
  ProtonVPN) можно переключаться без повторного ввода.

VLESS Encryption из Xray (`encryption=mlkem768x25519plus…`) sing-box не
поддерживает — нужна ссылка с `encryption=none`.

Ссылка или файл проверяются до применения: при ошибке режим и конфиг остаются
прежними.

### Совместимость со встроенным WARP AntiZapret

Актуальный AntiZapret хранит в `ANTIZAPRET_WARP` и `VPN_WARP` **число**, а не
`y`/`n`:

| Значение | Что делает AntiZapret |
|---|---|
| `0`, `1` | встроенный WARP выключен |
| `2` | весь трафик подсети идёт через `warp-antizapret` / `warp-vpn` |
| `3`, `4` | выборочно, по `fwmark 0x2` |

WARPER совместим со **всеми** режимами. В режиме `2` AntiZapret добавляет
`ip rule ... lookup 13335` (или `13336`) без fwmark, который перехватывал бы и
трафик на fake-подсеть — поэтому WARPER прописывает fake-подсеть и свои CIDR
прямо в эти таблицы. Наличие маршрута проверяет `warper doctor`.

### FullVPN WARP-резолвинг доменов

WARPER умеет применять патч для `kresd@2` (FullVPN-клиенты), чтобы заданные домены также маршрутизировались через WARP/Slave/WG, как и для AntiZapret.

- По умолчанию **выключен**.
- Совместим с любым значением `VPN_WARP` (см. таблицу выше).
- Управляется в меню: `Настройки → FullVPN WARP-резолвинг` или
  `warper fullvpn on|off`.
- Статус отображается в главном меню, `warper status` и `warper doctor`.

### Совместимость IPv4-подсетей (CIDR) со встроенным WARP AntiZapret

Маршрутизация подсетей работает при любых значениях `ANTIZAPRET_WARP` и `VPN_WARP`.

---

<a id="requirements"></a>
## 📦 Системные требования

### WARPER (основной сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 22.04/24.04, Debian 12/13 |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Установлен **AntiZapret VPN** |

### WARPERSLAVE (донор-сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 20.04+, Debian 10+ |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Открытый порт (по умолчанию 8444): TCP для SS и VLESS, UDP для Hysteria2 |

---

<a id="install-warper"></a>
## ⚡ Установка WARPER

На сервере с AntiZapret от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```

Во время установки выбираете режим маршрутизации (режим можно менять после установки):

- **WARP** — локальный Cloudflare WARP (warper найдёт действующие ключи или предложит создать новые)
- **Slave** — свой донор-сервер: вставьте ссылку из `warperslave link` (ss://, vless:// или hy2://, можно всю строку `warper mode …`); для старого донора — IP, порт и ключ
- **WG** — WireGuard-соединение (потребуется `.conf` файл)
- **VLESS / Hysteria2** — сторонний сервер по ссылке
- **OpenVPN** — файл `.ovpn` (предлагается список найденных в `/root` и `/root/warper`)

После установки:

```bash
warper
```

> После установки клиентам нужно переподключиться по OpenVPN. Если вы используете AWG/WG — обновите конфиг с учётом новой fake-подсети. Аналогично для роутеров, где маршруты прописываются вручную.

---

Во время установки появится опциональный вопрос «Установить веб-панель?» — это удобный браузерный интерфейс управления (см. ниже).
Так же, веб управление warper втроенно в панеле для Antizapret https://github.com/Kirito0098/AdminPanelAZ

---

<a id="web-panel"></a>
## 🌐 Веб-панель управления

WARPER включает опциональную **веб-панель** — браузерный интерфейс для управления всеми функциями. Идеально подходит для тех, кто не хочет работать в терминале.

### Возможности

- Управление доменами и IP-подсетями (с поддержкой комментариев)
- Включение/отключение WARPER, sing-box
- Переключение режимов WARP / Slave / WG / VLESS / Hysteria2 / OpenVPN прямо из браузера
- Загрузка WG- и OpenVPN-конфигов через drag & drop, вставка ссылок vless:// hy2:// ss://
- Управление WARP-ключами (выбор источника, генерация)
- Все настройки: log level, MTU, fake-подсеть, FullVPN-резолвинг, режим IP-маршрутов
- Просмотр логов sing-box в реальном времени с фильтром
- Запуск `warper doctor` (диагностика) одной кнопкой
- Проверка обновлений и установка одной кнопкой (с прогрессом в реальном времени)
- Статистика трафика через WARPER (текущая сессия, сегодня, неделя, месяц)
- Управление HTTPS (самоподписанный / Let's Encrypt / HTTP) прямо из браузера
- Тёмно-зелёный дизайн, адаптивный (мобильный и десктоп)
- Каталог готовых списков доменов из community-репозитория с поиском, предпросмотром и добавлением одной кнопкой
- Обновление ранее добавленных каталожных списков прямо из веб-панели

### Установка веб-панели

Если вы выбрали установку при основной установке WARPER — ничего больше делать не нужно. Иначе:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/install-web.sh)
```

Или через интерактивное меню warper:

```bash
warper
# Затем: W → 1
```

### Параметры установки

Установщик спросит:

| Параметр | По умолчанию | Описание |
|---|---|---|
| **Внешний порт** | 6060 | Порт, на котором будет доступна панель (проверяется занятость) |
| **Внутренний порт** | 16060 | Порт для Gunicorn (обычно не меняется) |
| **Логин администратора** | admin | 3-32 символа, латиница/цифры/`_`/`-` |
| **Пароль** | автогенерация | Скрытый ввод, минимум 6 символов |
| **HTTPS** | нет | Let's Encrypt с доменом или самоподписанный сертификат |

После установки веб-панель доступна по адресу `http://SERVER_IP:6060` (или вашему).

### Управление веб-панелью

Через интерактивное меню:

```bash
warper
# Затем: W
```

Возможности меню:
- Смена логина/пароля
- Сброс пароля (создаёт `admin` со случайным паролем)
- Сброс блокировок IP
- Изменение внешнего порта
- Запуск/остановка/перезапуск сервиса
- Просмотр логов
- Удаление веб-панели

### CLI-команды управления

```bash
warper webpass                    # сменить логин/пароль (интерактивно)
warper webpass myuser MyPass123   # сменить (неинтерактивно)
warper webpass --reset            # полный сброс, создаст admin со случайным паролем
warper webpass --unblock          # сбросить блокировки IP (если попали под brute-force)
warper webhttps status            # текущий режим HTTPS
warper webhttps enable-selfsigned # включить самоподписанный HTTPS
warper webhttps enable-letsencrypt DOMAIN  # Let's Encrypt
warper webhttps disable           # переключить на HTTP
warper webhttps renew             # обновить сертификат

warper web status                 # установлена, активна, режим, внешний порт
warper web start|stop|restart     # управление службой
warper web enable|disable         # автозагрузка
warper web port                   # показать внешний порт
warper web port 8443              # изменить внешний порт
warper web logs 100               # логи службы
warper web authlog 50             # журнал авторизаций
warper web install|uninstall      # установка и удаление
warper webupdate                  # обновить файлы панели
```

Полный список — `warper help`.

### Безопасность

- Пароли в виде **bcrypt-хеша** в `/root/warper/web/data/users.json` (chmod 600)
- `SECRET_KEY` Flask в `/root/warper/web/data/secret.key`, ротируется при смене пароля
- Защита от brute-force: **10 попыток / 10 минут → блокировка IP на 15 минут**
- CSRF-защита. `X-Real-IP` принимается только когда панель стоит за nginx;
  в режиме без nginx `ProxyFix` отключается, иначе заголовок можно подделать
  и обойти блокировку по IP
- Аудит-лог в `/root/warper/web/data/auth.log`
- Cookie: HttpOnly, SameSite=Lax, Secure при HTTPS
- Настраиваемые параметры brute-force (попытки, окно, длительность блокировки)
- Настраиваемая длительность сессий (cookie lifetime)
- Healthcheck: проверка nginx → gunicorn → веб-панели одной кнопкой
- Управление HTTPS из браузера (самоподписанный / Let's Encrypt / HTTP)

Подробнее: [docs/web-panel.md](docs/web-panel.md)

### Удаление веб-панели

```bash
warper web uninstall
```

Или через меню: `warper` → `W` → `10`, или напрямую:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/web/uninstall-web.sh)
```

> При полном удалении WARPER (`warper uninstall --yes`) веб-панель
> удаляется автоматически.

---

<a id="install-warperslave"></a>
## 🔧 Установка WARPERSLAVE

На **втором сервере** (донор) от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install-slave.sh | bash
```

Установщик спросит:
- **Режим**: Direct (трафик через IP донора) или WARP (через Cloudflare)
- **Протокол**: Shadowsocks 2022, VLESS+Reality (рекомендуется) или Hysteria2
- **SNI** для Reality: сайт с TLS 1.3, под который маскируется канал (по умолчанию `www.microsoft.com`)
- **Порт**: по умолчанию 8444
- **Ключ Shadowsocks** (только для SS): сгенерировать новый или ввести существующий

Ключи VLESS/Reality и Hysteria2 генерируются автоматически. В конце установщик
печатает команду для основного сервера.

### Подключение WARPER к донору

На доноре:

```bash
warperslave link
```

Выполните напечатанную команду на основном сервере, например:

```bash
warper mode vless 'vless://…@203.0.113.10:8444?security=reality&…#warperslave'
```

То же можно сделать в меню `warper` → `Настройки (9)` → `Режим маршрутизации (7)`
или в веб-панели — вставив ссылку, а при установке WARPER — в пункте Slave.
Для Shadowsocks по-прежнему можно ввести IP, порт и ключ вручную.

### Управление донором

```bash
warperslave          # интерактивное меню
warperslave status   # статус
warperslave switch   # переключить Direct ↔ WARP
warperslave proto vless  # сменить протокол: ss | vless | hy2
warperslave link     # ссылка и команда для master
warperslave doctor   # диагностика
warperslave update   # обновление
```

---

<a id="quick-check"></a>
## ✅ Быстрая проверка

### WARPER

```bash
warper doctor    # полная диагностика
warper status    # краткий статус
```

### WARPERSLAVE

```bash
warperslave doctor
warperslave status
```

---

<a id="commands"></a>
## 🧰 Команды управления

Полный список: `warper help`. Неизвестная команда возвращает код 1,
а не открывает меню.

### Домены

```bash
warper                          # главное меню
warper add openai.com           # добавить домен
warper remove openai.com        # удалить домен
warper domains list             # пользовательский блок как текст
warper domains save < file.txt  # заменить блок текстом из stdin
warper domains edit             # открыть domains.txt в редакторе
warper domainslist              # машинный вид: домен|источник|включён
warper enable gemini            # включить встроенный список
warper disable gemini           # выключить встроенный список
warper listupdate               # обновить встроенные списки из репозитория
warper sync                     # применить список к DNS
warper sync --force             # то же, с обязательным перезапуском kresd
warper patch                    # переприменить патч kresd
```

### Состояние и обслуживание

```bash
warper status                   # краткий статус
warper status json              # то же в JSON (для скриптов и API)
warper doctor                   # диагностика
warper toggle                   # включить или выключить WARPER
warper resync                   # восстановить правила, ipset, маршруты, патч DNS
warper resync -v                # то же с отчётом, что было починено
warper subnets                  # подсети VPN-клиентов и режим маршрутизации
warper traffic                  # трафик за сегодня
warper traffic week|month|all   # за период
warper traffic all json         # в JSON
warper update                   # обновить WARPER
warper uninstall --yes          # полное удаление
```

`warper resync` вызывается автоматически: таймером `warper-resync.timer`
раз в 10 минут и из `/root/antizapret/custom-doall.sh` сразу после ночной
пересборки правил AntiZapret. Вручную нужен редко.

### Настройки

```bash
warper config get SUBNET        # прочитать параметр
warper config set MTU 1380      # изменить параметр
warper subnet 10.224.0.0/16     # сменить fake-подсеть
warper loglevel debug           # уровень логов sing-box
warper mtu 1420                 # MTU
warper autopatch on|off         # автопатч DNS при загрузке
warper fullvpn on|off           # WARP-резолвинг для FullVPN-клиентов
warper iproutemode antizapret   # antizapret | all_vpn | all
warper ipexport on|off          # экспорт CIDR в AntiZapret
```

Записываемые через `config set` ключи: `SUBNET`, `IP_ROUTE_MODE`,
`IP_EXPORT_TO_ANTIZAPRET`, `FULLVPN_WARP_RESOLVE`, `LOG_LEVEL`, `MTU`,
`WARP_KEY_SOURCE`. Остальные доступны только на чтение.

### Режим работы и ключи

```bash
warper mode warp                # WARP с текущими ключами
warper mode warp system         # взять ключи AntiZapret
warper mode warp generate       # зарегистрировать новый WARP-ключ
warper mode slave СЕРВЕР ПОРТ ПАРОЛЬ
warper mode slave 'ss://…'      # Shadowsocks-ссылка донора
warper mode wg /root/proton.conf
warper mode vless 'vless://…'
warper mode hy2 'hy2://…'
warper mode openvpn /root/server.ovpn [ЛОГИН ПАРОЛЬ]
warper outbound                 # текущий режим и сервер без секретов
warper ovpnconfig list          # найденные .ovpn
warper ovpnconfig forget ФАЙЛ   # забыть сохранённые логин и пароль
warper warpkey list             # доступные источники ключей
warper warpkey generate         # сгенерировать новый ключ
warper wgconfig list            # найденные WG-конфиги
```

`WARP_KEY_SOURCE=system` означает, что WARPER следует за ключами
AntiZapret и пересобирает конфиг, когда `up.sh` их перегенерирует.
При `local` (по умолчанию) ключи не трогаются.

### Служба sing-box

```bash
warper singbox status           # состояние, версия, log level, MTU
warper singbox start|stop|restart
warper singbox enable|disable   # автозагрузка
warper singbox version          # установленная версия
warper singbox upgrade          # обновить до версии из установщика
warper singbox upgrade 1.14.1   # до конкретной версии
warper logs                     # последние 100 строк лога
warper logs 500                 # последние 500
```

Бинарь sing-box общий со службой `sing-box-slave`, поэтому `upgrade`
перезапускает обе. Конфиг проверяется до рестарта: при ошибке службы
не трогаются.

### Веб-панель

```bash
warper web status               # установлена, активна, порт, режим
warper web install              # установить
warper web uninstall            # удалить
warper web start|stop|restart   # управление службой
warper web enable|disable       # автозагрузка
warper web port                 # показать внешний порт
warper web port 8443            # изменить внешний порт
warper web logs 100             # логи службы
warper web authlog 50           # журнал авторизаций
warper webpass                  # сменить логин/пароль интерактивно
warper webpass admin ПАРОЛЬ     # задать пароль напрямую
warper webpass --reset          # сгенерировать новый пароль
warper webpass --unblock        # снять блокировки по IP
warper webhttps status          # состояние HTTPS
warper webupdate                # обновить файлы панели
```

В режиме без nginx порт задаётся при установке, и `web port ПОРТ`
возвращает ошибку — менять его нужно переустановкой панели.

### Авто-резолв доменов в IP-маршруты

Резолвит домены из `domains.txt` и складывает адреса в блок `RESOLVED`
внутри `ip-ranges.txt`. По умолчанию **выключен**. В меню: `warper` →
`Настройки (9)` → `A`; в веб-панели — «Настройки» → «Дополнительные опции».

```bash
warper resolve on                  # включить (раз в час)
warper resolve off                 # выключить
warper resolve status              # состояние
warper resolvesync                 # резолвить сейчас
warper resolvesync --force         # даже если список не изменился
warper resolveclean                # очистить блок целиком
warper resolveclean gemini.google  # убрать записи одного домена
```

Список **накопительный**: CDN отдаёт разные адреса в разные моменты, и
удаление прошлого адреса рвало бы уже установленные соединения. Каждая
строка аннотирована источником, чтобы было видно, откуда адрес:

```
142.251.13.100/32 #ai.google.dev,aistudio.google.com
```

Аннотации видны только в файле — в маршруты и в экспорт AntiZapret уходят
чистые CIDR.

### IP-подсети

```bash
warper ipadd 91.108.4.0/22     # добавить подсеть
warper ipremove 91.108.4.0/22  # удалить подсеть
warper ipsync                  # синхронизировать маршруты
warper iplist                  # показать подсети из файла
warper ipranges list           # файл ip-ranges.txt как текст
warper ipranges save < f.txt   # заменить файл текстом из stdin
warper iproutes                # показать применённые маршруты
warper iproutes clear          # удалить применённые маршруты (файл не трогает)
warper iproutemode all_vpn     # antizapret | all_vpn | all
warper ipexport on|off         # экспорт CIDR в AntiZapret
```
Или в главном меню: I → Управление IP-подсетями.

### Каталог доменов (пример tiktok)
```bash
warper catalog search tiktok   # поиск готовых списков доменов
warper catalog show tiktok     # показать домены из каталога
warper catalog add tiktok      # добавить готовый список в WARPER
warper catalog remove tiktok   # удалить ранее добавленный список
warper catalog update          # обновить все добавленные каталоги
warper catalog update tiktok   # обновить конкретный каталог
warper catalog list            # показать установленные каталоги
warper catalog refresh         # обновить локальный кэш каталога
```
Или в главном меню: C → Каталог доменов.

### WARPERSLAVE

```bash
warperslave                    # главное меню
warperslave status             # статус
warperslave switch             # переключить режим Direct ↔ WARP
warperslave proto ss|vless|hy2 [SNI]  # протокол подключения master
warperslave link               # ссылка и команда для master
warperslave link --command     # только команда для master
warperslave host example.com   # адрес донора в ссылке (auto — IP)
warperslave rebuild            # пересобрать конфиг из slave.conf
warperslave port [ПОРТ]        # изменить порт
warperslave key                # перевыпустить ключи текущего протокола
warperslave showkey            # показать полный SS-ключ
warperslave restart            # перезапустить службу
warperslave logs 100           # логи службы
warperslave loglevel           # показать log level
warperslave loglevel debug     # изменить log level
warperslave mtu                # показать MTU
warperslave mtu 1380           # изменить MTU (только режим WARP)
warperslave singbox version    # версия sing-box
warperslave singbox upgrade    # обновить sing-box
warperslave doctor             # диагностика
warperslave update             # обновление
warperslave uninstall          # удаление
warperslave help               # справка
```

---

<a id="uninstall"></a>
## 🗑 Удаление

### WARPER

```bash
warper uninstall --yes
```

Или через меню (`warper` → `U`), или напрямую:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstaller.sh | bash
```

### WARPERSLAVE

```bash
warperslave
# Затем: U
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstall-slave.sh | bash
```

---

<a id="faq"></a>
## ❓ FAQ

<details>
<summary><b>Что делает WARPER?</b></summary>

WARPER — менеджер доменной маршрутизации. Когда вы добавляете домен, система возвращает для него fake-ip, перенаправляет трафик в sing-box и отправляет его в WARP, на донор-сервер или через WG-туннель. Остальной трафик работает через AntiZapret как обычно.

Для FullVPN-клиентов доменная маршрутизация тоже доступна — включается
отдельно: `warper fullvpn on` (патч для `kresd@2`).
</details>

<details>
<summary><b>Можно ли использовать WARPER вместе со встроенным WARP AntiZapret (VPN_WARP)?</b></summary>

Да, с любым значением `VPN_WARP`. По умолчанию WARPER патчит только
`kresd@1` (AntiZapret-клиенты), а FullVPN-клиенты идут через встроенный WARP.
Если нужна доменная маршрутизация и для них — `warper fullvpn on`.
</details>

<details>
<summary><b>Зачем нужен WARPERSLAVE?</b></summary>

Если IP основного сервера заблокирован, или WARP не работает, или нужен выход через конкретную страну — трафик можно направить через второй сервер (донор). На доноре трафик может выходить напрямую или через WARP.
</details>

<details>
<summary><b>Что такое режим WG?</b></summary>

Режим WG позволяет направлять трафик через ваш собственный WireGuard-сервер. Вам нужен `.conf` файл от WG-соединения — установщик и меню warper найдут его автоматически в `/root/` и `/root/warper/`, или вы можете ввести данные вручную.

Важно: файлы Cloudflare WARP (wgcf-profile.conf и warp.conf) автоматически исключаются из списка — они предназначены для режима WARP, а не WG.
</details>

<details>
<summary><b>Можно ли WARPER и WARPERSLAVE на одном сервере?</b></summary>

Да. Они используют разные экземпляры sing-box с разными конфигами и портами, не конфликтуют.
</details>

<details>
<summary><b>Что значит конфликт fake-подсети?</b></summary>

Если fake-подсеть уже используется на локальных интерфейсах (кроме singbox-tun), в маршрутах или Docker-сетях — это может ломать маршрутизацию. WARPER умеет это выявлять и предупреждать.
</details>

<details>
<summary><b>Как переключаться между режимами WARP / Slave / WG?</b></summary>

`warper` → `Настройки (9)` → `Режим маршрутизации (7)`. При переключении обратно на ранее использованный режим предлагается использовать сохранённое подключение или выбрать новое.
</details>

<details>
<summary><b>Как управлять WARP-ключами?</b></summary>

`warper` → `Настройки (9)` → `Управление WARP-ключами (8)` — доступно только в режиме WARP. Можно выбрать источник ключей (системный warp.conf, локальный профиль) или сгенерировать новые.
</details>

<details>
<summary><b>Как изменить MTU / log level?</b></summary>

`warper` → `Настройки (9)` → `Изменить MTU (6)` или `Изменить log level (5)`.
</details>

<details>
<summary><b>Что такое маршрутизация по IP-подсетям?</b></summary>

Помимо доменов, WARPER может направлять трафик к конкретным IPv4-подсетям через sing-box. Вы добавляете подсеть в формате CIDR (например `91.108.4.0/22`), и весь трафик к этим адресам пойдёт через WARP/Slave/WG.

Для AntiZapret-клиентов необходимо, чтобы подсеть также присутствовала в маршрутах AntiZapret. Включите опцию "Экспорт в AntiZapret" (включена по умолчанию) — WARPER автоматически создаст файл `warper-include-ips.txt` и обновит маршруты через `doall.sh`.
</details>

<details>
<summary><b>Какие режимы применения IP-подсетей существуют?</b></summary>

- **Только AntiZapret** (по умолчанию) — маршруты действуют только для AntiZapret-клиентов через policy routing (`ip rule` + отдельная таблица маршрутизации).
- **AntiZapret + FullVPN** — маршруты действуют для обоих типов VPN-клиентов.
- **Весь трафик сервера (Beta)** — маршруты в основной таблице, затрагивают весь трафик.

Переключение: `warper` → `I` → `8`.
</details>

<details>
<summary><b>Почему IP-подсеть не работает для AntiZapret-клиентов?</b></summary>

AntiZapret — это split-tunnel VPN. Клиент отправляет на сервер только те сети, которые входят в маршруты AntiZapret (`result/route-ips.txt`). Если вашей подсети там нет, клиент просто не пошлёт этот трафик на сервер.

Решение: включите "Экспорт в AntiZapret" (`warper` → `I` → `9`). WARPER запишет ваши подсети в `/root/antizapret/config/warper-include-ips.txt`, и после `doall.sh ip` клиенты начнут маршрутизировать эти сети через Antizapret VPN.

Примечание: после обновления маршрутов клиентам OPENVPN потребуется переподключение, а клиентам AWG/WG, пересборка конфига с учетом новых IPv4-подсетей (CIDR). В роутеры новые маршруты тоже нужно будет добавлять, если это требуется.
</details>

<details>
<summary><b>Как включить маршрутизацию доменов для FullVPN?</b></summary>

В меню `warper` выберите `Настройки → FullVPN WARP-резолвинг` или выполните `warper fullvpn on`. WARPER пропатчит `kresd@2` аналогично `kresd@1`, и домены из списка пойдут через выбранный режим (WARP, Slave, WG, VLESS, Hysteria2, OpenVPN). Работает при любом значении `VPN_WARP`.
</details>

<details>
<summary><b>Где посмотреть статистику трафика?</b></summary>

В терминале: `warper traffic` (по умолчанию за сегодня), `warper traffic week`, `warper traffic month`, `warper traffic all`.

В веб-панели: страница «Трафик» — показывает текущую сессию и агрегированные данные за периоды. Данные обновляются автоматически каждые 30 секунд.

Трафик считается по интерфейсу `singbox-tun` (счётчики ядра Linux). Snapshot снимается каждые 5 минут через systemd-таймер. При перезагрузке сервера или остановке sing-box данные сессии автоматически сохраняются.

История хранится в `/root/warper/traffic.json` (максимум 31 день почасовой агрегации, ~50-80 KB).
</details>

<details>
<summary><b>Можно ли добавлять готовые списки доменов, не вписывая всё вручную?</b></summary>

Да. Начиная с версии 1.3.8 WARPER умеет подключать готовые каталоги доменов из community-репозитория.

Примеры:
```bash
warper catalog search tiktok
warper catalog show tiktok
warper catalog add tiktok
```
В веб-панели для этого есть отдельная страница «Каталог»:

поиск по имени категории
предпросмотр доменов
добавление одной кнопкой
удаление и обновление добавленных каталогов
WARPER рекурсивно обрабатывает include: зависимости, оставляет только совместимые с DNS-маршрутизацией правила (domain и full), убирает дубликаты и не плодит одинаковые домены в domains.txt.

</details>

<details>
<summary><b>Есть ли Python API для интеграции?</b></summary>

Да. Пакет `warper_api` устанавливается автоматически с WARPER. Для сторонних проектов:

```bash
pip install git+https://github.com/Liafanx/AZ-WARP.git#subdirectory=py
```

```python
from warper_api import WarperAPI
w = WarperAPI()
w.add_domain("example.com")
```

Подробности: [docs/python-api.md](docs/python-api.md)
</details>

---

<a id="limitations"></a>
## ⚠️ Известные ограничения

- Работает только с **IPv4**
- Ожидается стандартная структура AntiZapret в `/root/antizapret`
- Совместим со всеми значениями `ANTIZAPRET_WARP` и `VPN_WARP` (см. [совместимость](#modes))
- При переключении `VPN_WARP` нужен перезапуск: `down.sh && up.sh` (или reboot сервера)
- Используются `iptables`; nft-only конфигурации могут требовать адаптации
- `sing-box` работает в userspace — при высокой нагрузке CPU может быть заметным
- Для режима WG: PresharedKey обязателен — конфиги без него не принимаются
- OpenVPN: поддерживаются только `dev tun` и TLS-режим; `dev tap`, статический ключ (`secret`), `pkcs12` и прокси в `.ovpn` не поддерживаются sing-box
- IP-маршруты не переживают перезагрузку `sing-box` автоматически — WARPER пересинхронизирует их при каждом restart через `resync_ip_routes_if_needed`
- При `RESTRICT_FORWARD=y` WARPER автоматически добавляет CIDR в ipset `antizapret-forward`, но эти записи будут перезаписаны при следующем `doall.sh` — используйте экспорт в AntiZapret для постоянного эффекта
- Режим "Весь трафик сервера" помечен как Beta — поведение зависит от конфигурации `VPN_WARP` и наличия table 13335, в теории туда могут упасть также запросы от других сервисов на сервере. (Например telemt при добавлении CIDR Telegram в warper)
- Счётчики трафика текущей сессии сбрасываются при перезапуске sing-box (интерфейс пересоздаётся). Накопленная история сохраняется в `traffic.json`
- При crash/kill sing-box без graceful shutdown может потеряться до 5 минут данных трафика (между snapshot'ами таймера)
- Каталожные списки доменов используют внешний community-репозиторий; для поиска и обновления требуется доступ к GitHub
- Правила типов `keyword:` и `regexp:` из внешнего каталога не импортируются, так как WARPER работает через доменную DNS-маршрутизацию и использует только совместимые `domain:` / `full:` записи
- Python API работает через CLI `warper` (subprocess) — требует root и установленный WARPER

---

<a id="docs"></a>
## 📚 Документация

Расширенная документация доступна в директории [`docs/`](docs/):

- [Ручная установка WARPER](docs/manual-install.md)
- [Ручная установка WARPERSLAVE](docs/manual-install-slave.md)
- [Архитектура и совместимость с VPN_WARP](docs/architecture.md)
- [Устранение неполадок](docs/troubleshooting.md)
- [WEB панель](docs/web-panel.md)
- [Python API](docs/python-api.md)

---

<a id="python-api"></a>
## 🐍 Python API

WARPER предоставляет Python-пакет для интеграции в сторонние проекты.

### Установка

```bash
pip install git+https://github.com/Liafanx/AZ-WARP.git#subdirectory=py
```

### Использование

```python
from warper_api import WarperAPI

w = WarperAPI()
print(w.version)           # "1.5.0"
print(w.is_active())       # True

w.add_domain("example.com")
w.catalog_add("tiktok")
w.set_mtu(1400)

t = w.get_traffic("today")
print(t.data["period_rx"]) # байты
```

### Требования

- WARPER установлен на сервере
- Python 3.9+
- Запуск от root
- Не требует web-панели

Подробная документация: [docs/python-api.md](docs/python-api.md)

---

<a id="support"></a>
## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию
- расскажите другим пользователям AntiZapret
- создавайте issue и pull request'ы
- поддержать автора: [cloudtips.ru](https://pay.cloudtips.ru/p/b7e90365)
