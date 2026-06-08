# 🏗 Архитектура WARPER

## Общая схема для доменов

```
AntiZapret-клиенты → kresd@1 → WARPER-домены → sing-box → WARP / Slave / WG
                             → остальное → обычная маршрутизация

FullVPN-клиенты → kresd@2 → всё → встроенный WARP автора (при VPN_WARP=y)
```

## Компоненты

| Компонент | Расположение | Назначение |
|---|---|---|
| warper.sh | /root/warper/ | Основной скрипт управления |
| sing-box | /usr/bin/sing-box | Прокси-ядро (tun + DNS + WireGuard/SS) |
| kresd | /etc/knot-resolver/ | DNS-резолвер AntiZapret |
| config.json | /etc/sing-box/ | Конфиг sing-box |
| warper-domains.txt | /etc/knot-resolver/ | Активный список доменов |
| domains.txt | /root/warper/ | Мастер-файл доменов |
| warper.conf | /root/warper/ | Настройки (подсеть, TUN IP) |
| slave_mode.conf | /root/warper/ | Настройки режима (WARP/Slave/WG) |
| wg_mode.conf | /root/warper/ | Параметры WG-соединения |
| ip-ranges.txt | /root/warper/ | Желаемые CIDR (редактируется пользователем) |
| ip-ranges.applied | /root/warper/ |Последнее применённое состояние |
| warper-include-ips.txt | /root/antizapret/config/ | Экспорт в AntiZapret |
| catalog.json | /root/warper/ | Метаданные установленных каталогов |
| catalog-cache.json | /root/warper/ | Кэш списка категорий (TTL 24ч) |
| py/warper_api/ | /root/warper/py/ | Python API пакет |

## Модульная структура (WARPER ≥1.3.1)

Проект разделён на библиотеки и меню для лучшей поддерживаемости:

- `lib/utils.sh` – общие функции (валидация, цвета, загрузка файлов)
- `lib/config.sh` – работа с конфигурационными файлами
- `lib/domains.sh` – логика доменов
- `lib/singbox.sh` – управление sing-box
- `lib/kresd.sh` – патчинг kresd
- `lib/warp-keys.sh` – работа с WARP-ключами
- `lib/wg.sh` – WireGuard
- `lib/ip-routes.sh` – маршрутизация IP-подсетей (CIDR)
- `lib/diagnostics.sh` – проверки, `doctor`, `status`
- `lib/update.sh` – безопасное обновление
- `lib/traffic.sh` – статистика трафика (счётчики, агрегация, хранение)
- `lib/catalog.sh` – каталог готовых доменных списков, поиск, импорт, обновление
- `menus/main.sh` – главное меню
- `menus/settings.sh` – меню настроек
- `menus/singbox-menu.sh` – меню управления sing-box
- `menus/ip-menu.sh` – меню управления IP-подсетями

## Маршрутизация по IP-подсетям

| Режим | Механизм |
|---|---|
| `antizapret` | `ip rule from AZ_NET lookup 100` + маршруты в `table 100` |
| `all_vpn` | `ip rule from ALL_NET lookup 100` + маршруты в `table 100` |
| `all` | маршруты в `main table` + `table 13335` (если есть) |

### Синхронизация

```
ip-ranges.txt → extract_ip_ranges()
                    ↓
              desired state
                    ↓
         comm -23 desired vs kernel → add_tmp (что добавить)
         comm -23 applied vs desired → del_tmp (что удалить)
                    ↓
         ip route replace/del → kernel routes
         ipset add/del → antizapret-forward
         save → ip-ranges.applied
                    ↓
         sync_ip_ranges_to_antizapret() → warper-include-ips.txt → doall.sh ip
```

## Режим WARP

```
kresd@1/ip route → fake-ip (198.20.0.0/24) → singbox-tun → WireGuard endpoint → Cloudflare WARP
```

## Режим Slave

```
kresd@1/ip route → fake-ip → singbox-tun → Shadowsocks outbound → slave-сервер:8444
```

## Режим WG

```
kresd@1/ip route → fake-ip → singbox-tun → WireGuard endpoint → WG-сервер
```

### Интеграция с AntiZapret

```
При `IP_EXPORT_TO_ANTIZAPRET=y`:
1. WARPER записывает CIDR в `/root/antizapret/config/warper-include-ips.txt`
2. `parse.sh` читает `config/*include-ips.txt` — файл подхватывается автоматически
3. CIDR попадают в `result/route-ips.txt` → клиенты получают маршруты
4. CIDR попадают в `result/forward-ips.txt` → ipset `antizapret-forward` обновляется штатно
```

## WARPERSLAVE

| Компонент | Расположение |
|---|---|
| warperslave.sh | /root/warperslave/ |
| slave.conf | /root/warperslave/ |
| config.json | /etc/sing-box-slave/ |
| sing-box-slave.service | /etc/systemd/system/ |

## Шаблоны конфигураций

| Шаблон | Назначение |
|---|---|
| templates/config.json.template | WARPER в режиме WARP |
| templates/config-slave-master.json.template | WARPER в режиме Slave |
| templates/config-wg.json.template | WARPER в режиме WG |
| templates/config-slave-direct.json.template | WARPERSLAVE в режиме Direct |
| templates/config-slave-warp.json.template | WARPERSLAVE в режиме WARP |

## Управление WARP-ключами

Источники ключей проверяются в порядке приоритета:
1. `/etc/wireguard/warp.conf` — системный файл AntiZapret (только с ключом Cloudflare)
2. `/root/warper/wgcf/wgcf-profile.conf` — локальный профиль WARPER
3. `/root/wgcf-profile.conf` — профиль в корне

Файлы WireGuard-соединений (не от Cloudflare) автоматически исключаются из поиска WARP-ключей.

## Статистика трафика

| Компонент | Расположение | Назначение |
|---|---|---|
| traffic.json | /root/warper/ | История трафика (hourly + сессии) |
| warper-traffic-snapshot.timer | /etc/systemd/system/ | Таймер snapshot'ов (каждые 5 мин) |
| warper-traffic-snapshot.service | /etc/systemd/system/ | Oneshot-сервис для snapshot |

### Источник данных

```
/sys/class/net/singbox-tun/statistics/rx_bytes  ← входящий трафик
/sys/class/net/singbox-tun/statistics/tx_bytes  ← исходящий трафик
```

Счётчики ядра Linux. Сбрасываются при пересоздании интерфейса (рестарт sing-box).

### Хранение

```
traffic.json
├── sessions[]      — завершённые сессии (макс. 100)
│   └── {started, stopped, rx, tx}
├── hourly{}        — почасовая агрегация (макс. 744 = 31 день)
│   └── "2025-06-04T10": {rx, tx}
└── last_snapshot   — последний снимок счётчиков
    └── {rx, tx, ts}
```

### Жизненный цикл данных

```
Загрузка системы → warper-autopatch → первый snapshot → hourly[текущий_час] += delta
Каждые 5 минут  → warper-traffic-snapshot.timer → snapshot → hourly += delta
Остановка sing-box → traffic_finalize_session → sessions[] += текущая
Ребут/shutdown → ExecStop warper-autopatch → trafficfinalize → sessions[] += текущая
Crash sing-box → теряется <= 5 минут (между snapshot'ами)
```

### Автосинхронизация WARP-ключей

```
Загрузка системы → warper-autopatch → warpkeysync
  ├── /etc/wireguard/warp.conf существует?
  │   ├── Да → ключи отличаются от config.json?
  │   │   ├── Да → пересборка config.json + restart sing-box
  │   │   └── Нет → ничего
  │   └── Нет → ничего (пользователь не использует VPN_WARP)
  └── Режим != warp → пропуск
```

## Каталог готовых доменных списков

WARPER умеет использовать внешний community-каталог доменов на основе репозитория `v2fly/domain-list-community`.

### Как это работает

1. WARPER получает список доступных категорий через GitHub API
2. Список категорий кэшируется в `catalog-cache.json`
3. При добавлении категории WARPER скачивает соответствующий файл из `data/`
4. Директивы `include:` обрабатываются рекурсивно
5. Из правил берутся только совместимые записи:
   - `domain:`
   - `full:`
6. Правила `keyword:` и `regexp:` игнорируются
7. Домены оптимизируются:
   - удаляются дубликаты
   - лишние поддомены убираются если уже есть родительский домен
8. Итоговые домены добавляются в `domains.txt`

### Хранение состояния

Файл `catalog.json` хранит:
- какие категории были добавлены
- когда они были добавлены / обновлены
- сколько доменов было импортировано
- список доменов для корректного удаления и обновления

Это позволяет:
- удалять каталог целиком
- обновлять ранее добавленные каталоги
- не плодить дубликаты в `domains.txt`

## Патчинг kresd.conf

WARPER вставляет блок `[WARP-MOD-START]...[WARP-MOD-END]` только в секцию `kresd@1`. Блок читает `/etc/knot-resolver/warper-domains.txt` и направляет DNS-запросы для этих доменов на `127.0.0.1:40000` (sing-box DNS-in).

Начиная с версии 1.3.1 добавлена опциональная возможность патчить также kresd@2 для FullVPN-клиентов (см. FullVPN WARP-резолвинг).
