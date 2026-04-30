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

## Патчинг kresd.conf

WARPER вставляет блок `[WARP-MOD-START]...[WARP-MOD-END]` только в секцию `kresd@1`. Блок читает `/etc/knot-resolver/warper-domains.txt` и направляет DNS-запросы для этих доменов на `127.0.0.1:40000` (sing-box DNS-in).
