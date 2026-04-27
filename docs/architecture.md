# 🏗 Архитектура WARPER

## Общая схема

```
AntiZapret-клиенты → kresd@1 → WARPER-домены → sing-box → WARP / Slave
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
| slave_mode.conf | /root/warper/ | Настройки slave-режима |

## Режим WARP

```
kresd@1 → fake-ip (198.20.0.0/24) → singbox-tun → WireGuard endpoint → WARP
```

## Режим Slave

```
kresd@1 → fake-ip → singbox-tun → Shadowsocks outbound → slave-сервер:8444
```

## WARPERSLAVE

| Компонент | Расположение |
|---|---|
| warperslave.sh | /root/warperslave/ |
| slave.conf | /root/warperslave/ |
| config.json | /etc/sing-box-slave/ |
| sing-box-slave.service | /etc/systemd/system/ |

## Синхронизация WARP-ключей

При каждом запуске WARPER проверяет `/etc/wireguard/warp.conf`. Если ключи изменились — обновляет конфиг sing-box и перезапускает kresd@1.

## Патчинг kresd.conf

WARPER вставляет блок `[WARP-MOD-START]...[WARP-MOD-END]` только в секцию `kresd@1`. Блок читает `/etc/knot-resolver/warper-domains.txt` и направляет DNS-запросы для этих доменов на `127.0.0.1:40000` (sing-box DNS-in).


## Архитектура
AZ-WARP/
├── install.sh

├── install-slave.sh

├── warper.sh

├── warperslave.sh

├── uninstaller.sh

├── uninstall-slave.sh

├── version

├── versionslave

├── CHANGELOG.md

├── README.md

├── templates/

   ├── config.json.template

   ├── config-slave-master.json.template

   ├── config-slave-direct.json.template

   ├── config-slave-warp.json.template

   ├── sing-box.service

   ├── sing-box-slave.service

   └── warper-autopatch.service

├── download/

   ├── gemini.txt

   └── chatgpt.txt

├── docs/

    ├── architecture.md
    
    ├── manual-install.md
    
    ├── manual-install-slave.md
    
    └── troubleshooting.md
    
