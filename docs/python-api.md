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

```bash
pip install git+https://github.com/Liafanx/AZ-WARP.git#subdirectory=py
```

После этого:

```python
from warper_api import WarperAPI
```

## Быстрый старт

```python
from warper_api import WarperAPI

w = WarperAPI()

# Версия и статус
print(w.version)          # "1.3.8"
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

`WarperResult` поддерживает `bool`:

```python
result = w.add_domain("example.com")
if result:          # эквивалентно if result.ok:
    print("OK!")
```

## Полный список методов

### Статус и управление

| Метод | Описание |
|---|---|
| `get_status()` | Полный статус WARPER (JSON) |
| `is_active()` | Проверка: WARPER активен (sing-box + kresd) |
| `get_version()` | Версия WARPER |
| `doctor()` | Полная диагностика |
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
| `get_logs(lines)` | Получить логи (1-2000 строк) |

### Настройки

| Метод | Описание |
|---|---|
| `set_mode_warp(key_source)` | Режим WARP (`system` / `wgcf` / `root` / `generate`) |
| `set_mode_slave(server, port, password)` | Режим Slave |
| `set_mode_wg(conf_path)` | Режим WireGuard |
| `get_mode()` | Текущий режим |
| `set_subnet(subnet)` | Изменить fake-подсеть |
| `set_mtu(mtu)` | MTU (1280-1500) |
| `get_mtu()` | Текущий MTU |
| `set_log_level(level)` | Log level (`debug` / `info` / `warn` / `error`) |
| `get_log_level()` | Текущий log level |
| `set_autopatch(enable)` | Автопатч DNS при загрузке |
| `set_fullvpn(enable)` | FullVPN WARP-резолвинг |
| `list_warp_keys()` | Доступные WARP-ключи |
| `list_wg_configs()` | Доступные WG-конфиги |

### Трафик

| Метод | Описание |
|---|---|
| `get_traffic(period)` | Трафик за период (`today` / `week` / `month` / `all`) |
| `get_traffic_today()` | Краткая строка: `↑ X ↓ Y` |

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
    ├── _runner.py       # subprocess-обёртка
    ├── catalog.py       # каталог доменов
    ├── domains.py       # домены
    ├── ip_ranges.py     # IP-подсети
    ├── settings.py      # настройки
    ├── singbox.py       # sing-box
    ├── status.py        # статус и диагностика
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
print(warper_api.__version__)  # "1.4.0"
```






