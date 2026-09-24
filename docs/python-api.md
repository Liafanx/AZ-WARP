# 🐍 Python API для WARPER

## Обзор

WARPER предоставляет Python-пакет `warper_api` для интеграции в сторонние проекты.

**Требования:**
- WARPER установлен на сервере (`/usr/local/bin/warper`)
- Python 3.9+
- Запуск от root
- Не требует web-панели, Flask или других зависимостей

## Установка

### На сервере с WARPER (уже установлено автоматически)

Файлы лежат в `/root/warper/py/warper_api/`. Для использования:

```python
import sys
sys.path.insert(0, "/root/warper/py")

from warper_api import WarperAPI
```

### Через pip (для внешних проектов)

В виртуальное окружение проекта — из установленного WARPER (версия пакета
совпадёт с версией на сервере):

```bash
/path/to/project/venv/bin/pip install /root/warper/py
```

или из GitHub:

```bash
pip install git+https://github.com/Liafanx/AZ-WARP.git#subdirectory=py
```

Путь `/root/warper/py` через `sys.path` подходит только процессам от root —
остальным каталог `/root` недоступен. Зависимостей у пакета нет. После
обновления WARPER переустановите пакет, чтобы получить новые методы.

После этого:

```python
from warper_api import WarperAPI
```

## Интеграция в другой проект

API — тонкая обёртка над CLI `warper`: каждый вызов запускает
`/usr/local/bin/warper` через `subprocess`. Отсюда правила:

- **Тот же сервер.** Проект должен работать на сервере, где установлен
  WARPER. Удалённого доступа у API нет — для управления с другой машины
  нужен свой HTTP-слой поверх `WarperAPI` (или веб-панель).
- **Права root.** WARPER меняет маршруты, kresd и службы. Если проект
  работает не от root (бот, веб-приложение), разрешите ему только `warper`
  через sudo и включите `WARPER_SUDO`:

  ```bash
  echo 'mybot ALL=(root) NOPASSWD: /usr/local/bin/warper' > /etc/sudoers.d/warper-mybot
  chmod 440 /etc/sudoers.d/warper-mybot
  visudo -cf /etc/sudoers.d/warper-mybot
  ```

  ```bash
  WARPER_SUDO=1 python3 bot.py
  ```

  Без прав методы возвращают `ok=False` с сообщением «Нет прав на запуск
  warper», исключений не бросают.
- **Переменные окружения** (читаются при импорте):

  | Переменная | По умолчанию | Назначение |
  |---|---|---|
  | `WARPER_BIN` | `/usr/local/bin/warper` | Путь к CLI |
  | `WARPER_SUDO` | выкл | `1` — вызывать через `sudo -n`, если процесс не от root |

- **Параллельные вызовы безопасны.** Команды, меняющие состояние (режим,
  домены, подсети, синхронизация, обновление), выполняются под общей
  блокировкой с веб-панелью, таймерами и терминалом и ждут друг друга до
  30 секунд — затем `ok=False` с текстом «Не удалось получить блокировку».
  Чтение (`get_status`, `list_*`, `get_*`) идёт без блокировки.
- **Вызовы синхронные** и могут длиться секунды (смена режима, `sync`
  с перезапуском kresd). В asyncio-приложениях оборачивайте их:

  ```python
  result = await asyncio.to_thread(w.set_mode_vless, link)
  ```

- **Исключения не бросаются.** Ошибки CLI, таймауты и отсутствие `warper`
  приходят как `WarperResult(ok=False, message=...)`; `return_code` 124 —
  таймаут, 126 — нет прав, 127 — `warper` не найден.
- **Секреты.** `get_status().data["slave"]["password"]` содержит ключ
  Shadowsocks — не логируйте статус целиком. `get_outbound()` секретов
  не содержит.

## Быстрый старт

```python
from warper_api import WarperAPI

w = WarperAPI()

# Версия и статус
print(w.version)          # "1.5.0"
print(w.is_active())      # True

# Полный статус (JSON)
status = w.get_status()
print(status.data["outbound_mode"])   # "warp"
print(status.data["singbox"]["mtu"])  # 1420

# Домены
result = w.add_domain("example.com")
if result:
    print(result.message)  # "Домен добавлен: example.com"

w.sync_domains()

# IP-подсети
w.add_ip_range("91.108.4.0/22")
w.sync_ip_ranges()

# Каталог
results = w.catalog_search("tiktok")
for cat in results.data:
    print(cat["name"], cat["installed"])

w.catalog_add("tiktok")

# Трафик
t = w.get_traffic("today")
print(t.data["period_rx"])        # байты
print(w.get_traffic_today())      # "↑ 500 MB ↓ 1.2 GB"

# Настройки
w.set_mtu(1400)
w.set_log_level("debug")
w.set_mode_warp("system")
w.set_mode_vless("vless://…")   # ссылка от `warperslave link` или стороннего сервера
print(w.get_outbound().data)    # {'mode': 'vless', 'server': '…', 'port': '…', …}

# Sing-box
w.singbox_restart()
logs = w.get_logs(50)
for line in logs.data:
    print(line)
```

## WarperResult

Все методы возвращают объект `WarperResult`:

```python
@dataclass
class WarperResult:
    ok: bool          # True если команда выполнена успешно
    message: str      # Человекочитаемое сообщение
    data: Any         # Структурированные данные (dict, list, ...)
    raw_stdout: str   # Сырой stdout процесса
    raw_stderr: str   # Сырой stderr процесса
    return_code: int  # Код возврата процесса
```

Исключения — несколько методов, которые сразу возвращают значение:

| Метод | Тип |
|---|---|
| `version` (свойство), `get_version()` | `str` |
| `is_active()` | `bool` |
| `get_mode()`, `get_log_level()`, `get_traffic_today()` | `str` |
| `get_mtu()` | `int` |

### Поля `get_status().data`

| Ключ | Тип | Описание |
|---|---|---|
| `version`, `remote_version` | str | Установленная и последняя версии |
| `update_available` | bool | Есть обновление |
| `outbound_mode` | str | `warp` / `slave` / `wg` / `vless` / `hy2` / `openvpn` |
| `outbound_label` | str | Режим человекочитаемо, например `Hysteria2 (…:443)` |
| `outbound` | dict | `protocol`, `server`, `port`, `ports`, `name`, `transport` (для vless/hy2/openvpn) |
| `slave` | dict | `server`, `port`, `password` |
| `wg` | dict | `endpoint_host`, `endpoint_port`, `address`, `conf_file` |
| `singbox` | dict | `running`, `enabled`, `log_level`, `mtu` |
| `kresd` | dict | `patched`, `fullvpn_patched` |
| `domains` | dict | `synced` |
| `subnet` | dict | `fake`, `in_antizapret`, `conflict` |
| `ip_ranges` | dict | `count`, `routes_count`, `synced`, `mode`, `export_to_antizapret` |
| `antizapret_warp`, `vpn_warp` | bool | Встроенный WARP AntiZapret включён |
| `antizapret_warp_mode`, `vpn_warp_mode` | str | `off` / `all` / `selective` |
| `warp_rules_active` | bool | Нужен `down.sh && up.sh` |
| `fullvpn_warp_resolve` | str | `y` / `n` |
| `autopatch_enabled` | bool | Автопатч DNS при загрузке |
| `warp_keys_source` | str | Источник WARP-ключей |
| `traffic_today` | str | `↑ X ↓ Y` |

`WarperResult` поддерживает `bool`:

```python
result = w.add_domain("example.com")
if result:          # эквивалентно if result.ok:
    print("OK!")
```

**`message` обрезается до 3 строк.** Для многострочного вывода
(`doctor`, `list_ip_ranges`, `get_logs`) читайте `raw_stdout`:

```python
print(w.doctor().raw_stdout)   # весь вывод
print(w.doctor().message)      # первые 3 строки + "... (N строк всего)"
```

Таймауты по умолчанию — 60 секунд, но у долгих операций больше:
`toggle()` 180, `set_subnet()` / `catalog_update()` / `resync()` /
`resolve_sync()` / `singbox_upgrade()` — 300, `update()` — 600.

## Полный список методов

### Статус и управление

| Метод | Описание |
|---|---|
| `get_status()` | Полный статус WARPER (JSON) |
| `is_active()` | Проверка: WARPER активен (sing-box + kresd) |
| `get_version()` | Версия WARPER |
| `doctor()` | Полная диагностика |
| `resync()` | Восстановить правила FORWARD, ipset, маршруты и патч kresd |
| `get_subnets()` | Подсети VPN-клиентов и режим маршрутизации (`data=dict`) |
| `config_get(key)` | Прочитать параметр конфигурации |
| `config_set(key, value)` | Изменить параметр (см. список ключей ниже) |

Записываемые через `config_set` ключи: `SUBNET`, `IP_ROUTE_MODE`,
`IP_EXPORT_TO_ANTIZAPRET`, `FULLVPN_WARP_RESOLVE`, `LOG_LEVEL`, `MTU`,
`WARP_KEY_SOURCE`. Остальные доступны только на чтение.
| `toggle()` | Включить/выключить WARPER |
| `enable()` | Включить WARPER (если выключен) |
| `disable()` | Выключить WARPER (если включён) |

### Домены

| Метод | Описание |
|---|---|
| `add_domain(domain)` | Добавить домен |
| `remove_domain(domain)` | Удалить домен |
| `list_domains()` | Список доменов с типами и статусами |
| `sync_domains()` | Синхронизировать и применить патч DNS |
| `enable_list(name)` | Включить встроенный список (`gemini` / `chatgpt`) |
| `disable_list(name)` | Выключить встроенный список |
| `patch_kresd()` | Переприменить патч DNS |
| `get_user_domains_text()` | Получить пользовательский блок domains.txt как текст для редактирования |
| `save_user_domains_text(text)` | Сохранить текст и запустить синхронизацию (сохраняет комментарии и пустые строки) |
| `update_lists()` | Обновить встроенные списки (gemini/chatgpt) из репозитория |

### IP-подсети

| Метод | Описание |
|---|---|
| `add_ip_range(cidr)` | Добавить CIDR |
| `remove_ip_range(cidr)` | Удалить CIDR |
| `sync_ip_ranges()` | Синхронизировать маршруты |
| `list_ip_ranges()` | Список подсетей из файла |
| `list_ip_routes()` | Список применённых маршрутов в ядре |
| `set_ip_route_mode(mode)` | Режим: `antizapret` / `all_vpn` / `all` |
| `set_ip_export(enable)` | Экспорт CIDR в AntiZapret |
| `get_ip_ranges_text()` | Получить содержимое ip-ranges.txt как текст для редактирования |
| `save_ip_ranges_text(text)` | Сохранить текст и запустить синхронизацию (сохраняет комментарии и пустые строки) |
| `clear_ip_routes()` | Удалить применённые маршруты из ядра (файл не трогается) |
| `resolve_sync(force=False)` | Резолвить домены в IP, обновить накопительный блок `RESOLVED` |
| `resolve_clean(domain=None)` | Очистить блок `RESOLVED` целиком или записи одного домена |
| `set_auto_resolve(enabled)` | Включить/выключить почасовой авто-резолв |
| `get_auto_resolve()` | Состояние авто-резолва: `message` — `enabled` / `disabled`, `data` — `bool` |

Блок `RESOLVED` накопительный: адреса из прошлых прогонов не удаляются, так
как CDN отдаёт разные IP в разные моменты. Строки аннотированы источником
(`1.2.3.4/32 #gemini.google.com`), но `list_ip_ranges()` и экспорт в
AntiZapret отдают чистые CIDR.

### Каталог

| Метод | Описание |
|---|---|
| `catalog_search(query)` | Поиск категорий (пусто = популярные) |
| `catalog_show(name)` | Предпросмотр доменов категории |
| `catalog_add(name)` | Добавить каталог в WARPER |
| `catalog_remove(name)` | Удалить каталог |
| `catalog_update(name)` | Обновить каталог (пусто = все) |
| `catalog_list_installed()` | Список установленных каталогов |
| `catalog_refresh_cache()` | Обновить кэш категорий |

### Sing-box

| Метод | Описание |
|---|---|
| `singbox_start()` | Запустить |
| `singbox_stop()` | Остановить |
| `singbox_restart()` | Перезапустить |
| `singbox_enable()` | Включить автозагрузку |
| `singbox_disable()` | Выключить автозагрузку |
| `singbox_status()` | Состояние службы: active, enabled, version, log_level, mtu (`data=dict`) |
| `singbox_version()` | Установленная версия sing-box (`message` и `data` — строка) |
| `singbox_upgrade(target=None)` | Обновить бинарь (общий с `sing-box-slave` — перезапускаются обе службы) |
| `get_logs(lines)` | Получить логи (1-2000 строк) |

### Настройки

| Метод | Описание |
|---|---|
| `set_mode_warp(key_source)` | Режим WARP (`system` / `wgcf` / `root` / `generate`) |
| `set_mode_slave(server, port, password)` | Режим Slave; вместо `server` можно передать ссылку `ss://…` без порта и пароля |
| `set_mode_wg(conf_path)` | Режим WireGuard |
| `set_mode_vless(link)` | Режим VLESS / VLESS+Reality по ссылке `vless://…` |
| `set_mode_hy2(link)` | Режим Hysteria2 по ссылке `hy2://…` или `hysteria2://…` |
| `set_mode_openvpn(conf_path, username=None, password=None)` | Режим OpenVPN по файлу `.ovpn` на сервере; логин и пароль — для `auth-user-pass`. Переданные сохраняются для этого файла, без них берутся сохранённые |
| `get_mode()` | Текущий режим: `warp` / `slave` / `wg` / `vless` / `hy2` / `openvpn` |
| `get_outbound()` | Текущий режим и сервер без секретов (`data=dict`: mode, label, protocol, server, port, ports, name, transport) |
| `set_subnet(subnet)` | Изменить fake-подсеть |
| `set_mtu(mtu)` | MTU (1280-1500) |
| `get_mtu()` | Текущий MTU |
| `set_log_level(level)` | Log level (`debug` / `info` / `warn` / `error`) |
| `get_log_level()` | Текущий log level |
| `set_autopatch(enable)` | Автопатч DNS при загрузке |
| `set_fullvpn(enable)` | FullVPN WARP-резолвинг |
| `list_warp_keys()` | Доступные WARP-ключи |
| `list_wg_configs()` | Доступные WG-конфиги |
| `list_ovpn_configs()` | Файлы `.ovpn` в `/root/` и `/root/warper/` (`data=list[dict]`: path, server, needs_auth, saved_user) |
| `forget_ovpn_credentials(conf_path)` | Удалить сохранённые логин и пароль для `.ovpn` |

### Веб-панель

| Метод | Описание |
|---|---|
| `web_status()` | installed, active, enabled, mode, external_port (`data=dict`) |
| `web_install()` | Установить панель (установщик интерактивный) |
| `web_uninstall()` | Удалить панель |
| `web_start()` / `web_stop()` / `web_restart()` | Управление службой |
| `web_set_autostart(enabled)` | Автозагрузка панели |
| `web_get_port()` | Внешний порт (`data=int`) |
| `web_set_port(port)` | Сменить внешний порт (недоступно в режиме без nginx) |
| `web_get_logs(lines=50)` | Логи службы (`data=list[str]`) |
| `web_get_auth_log(lines=30)` | Журнал авторизаций (`data=list[str]`) |
| `web_update()` | Обновить файлы панели |

### Трафик

| Метод | Описание |
|---|---|
| `get_traffic(period)` | Трафик за период (`today` / `week` / `month` / `all`) |
| `get_traffic_today()` | Краткая строка: `↑ X ↓ Y` |

## Обновления WARPER

### Методы

| Метод | Описание |
|---|---|
| `check_for_updates(force=False)` | Проверить наличие новой версии (кэш 60 сек) |
| `update(timeout=600)` | Запустить обновление синхронно |
| `update_async()` | Запустить обновление в фоне. Возвращает `subprocess.Popen` |
| `update_stream()` | Запустить со стримингом логов. Возвращает `tuple[Popen \| None, str \| None]` |
| `invalidate_version_cache()` | Сбросить кэш версии |


## Модульный импорт

Помимо фасада `WarperAPI`, можно импортировать модули напрямую:

```python
from warper_api.domains import add_domain, list_domains
from warper_api.catalog import search, add
from warper_api.traffic import get_traffic
from warper_api.settings import set_mtu, get_mtu
from warper_api.status import is_active, doctor
```

## Структура пакета

```
/root/warper/py/
├── setup.py
└── warper_api/
    ├── __init__.py      # WarperAPI (фасад)
    ├── _result.py       # WarperResult
    ├── _runner.py       # subprocess-обёртка, WARPER_BIN / WARPER_SUDO
    ├── catalog.py       # каталог доменов
    ├── domains.py       # домены
    ├── ip_ranges.py     # IP-подсети
    ├── settings.py      # настройки
    ├── singbox.py       # sing-box
    ├── status.py        # статус и диагностика
    ├── updates.py       # обновление warper
    ├── web.py           # веб-панель
    └── traffic.py       # трафик
```

## Обратная совместимость

Python API использует CLI `warper` как backend. Это означает:
- API всегда совместим с текущей версией WARPER
- новые CLI-команды автоматически становятся доступны через API
- не зависит от внутренней структуры bash-скриптов

Версия пакета совпадает с версией WARPER:

```python
import warper_api
print(warper_api.__version__)  # "1.5.0"
```






