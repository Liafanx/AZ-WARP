# 🔧 Устранение неполадок

## Диагностика

```bash
warper doctor          # WARPER
warperslave doctor     # WARPERSLAVE
```

## Типичные проблемы

### Домены перестают открываться через сутки-двое

**Симптом:** всё работает, потом конкретные сайты перестают открываться,
а панель показывает, что всё активно. Помогает выключить и включить WARPER
или перезагрузить сервер.

**Причины и что проверить:**

```bash
warper doctor        # ёмкость пула fake-IP, маршруты, правила
warper resync -v     # восстановить состояние вручную
```

1. **Мал пул fake-IP.** kresd выдаёт fake-IP каждому ПОДдомену, поэтому `/24`
   (254 адреса) исчерпывается за сутки-двое: sing-box переиспользует адрес и
   стирает старый маппинг, а kresd продолжает отдавать клиентам старый.
   `warper doctor` покажет ёмкость. Лечится сменой подсети:
   ```bash
   warper subnet 10.224.0.0/16
   ```
   После смены клиентам нужно переподключиться — им пушится маршрут
   фейковой подсети.

2. **Ночная пересборка правил AntiZapret.** `antizapret-update.timer`
   пересобирает ipset `antizapret-forward` и правила `FORWARD`. Начиная с
   1.5.0 состояние восстанавливает `warper resync`: таймер раз в 10 минут
   плюс хук в `/root/antizapret/custom-doall.sh`. Проверить:
   ```bash
   systemctl status warper-resync.timer
   grep WARPER /root/antizapret/custom-doall.sh
   ```

### Домены не работают после обновления sing-box до 1.14

**Симптом:** соединения обрываются сразу, в логе:
`a resolve action is required before routing to outbound/wireguard`.

**Причина:** 1.14 требует явного `action: resolve` перед маршрутизацией
fake-адреса в wireguard-endpoint.

**Решение:** обновить WARPER до 1.5.0+ и пересобрать конфиг
(`warper toggle` дважды либо `warper mode warp`). В `route.rules` должно
появиться правило `{ "inbound": "tun-in", "action": "resolve", "server": "real-dns" }`.

### WARN "listen egress member on docker0 ... address already in use"

**Симптом:** в логе sing-box после старта 2-3 раза подряд:

```
WARN endpoint/wireguard[warp]: listen egress member on docker0 (172.17.0.1):
listen udp4 172.17.0.1:43480: bind: address already in use
```

**Это безвредно.** Начиная с 1.14 sing-box поднимает UDP-сокет на каждом
интерфейсе, который UP и не point-to-point, — включая `docker0`. Для
wireguard-endpoint исключается только его собственный интерфейс, отдельной
настройки для остальных нет. Неудавшийся сокет просто не создаётся, а
трафик идёт через основной интерфейс.

Предупреждение появляется несколько раз при старте и затихает. Проверить,
что WARP действительно работает:

```bash
warper doctor
curl --interface singbox-tun https://www.cloudflare.com/cdn-cgi/trace | grep warp=
```

Если `docker0` на сервере не нужен — сообщение исчезнет вместе с ним.

### Системный DNS уходит в туннель, ничего не качается

**Симптом:** после запуска WARPER на самом сервере перестают работать `apt`,
`curl`, `git`.

**Причина:** sing-box прописал свой DNS на интерфейс `singbox-tun`.

**Решение:** в конфиге у tun-inbound должно стоять `"dns_mode": "disabled"`
(в 1.14 значение по умолчанию — `hijack`, оно трогает systemd-resolved).
Проверяется автоматически:

```bash
warper doctor                      # строка "Системный DNS не перехвачен"
resolvectl status singbox-tun      # DNS Servers быть не должно
```

### Встроенный WARP AntiZapret (ANTIZAPRET_WARP / VPN_WARP)

Начиная с 1.5.0 WARPER совместим со всеми режимами (`0`-`4`). В режиме `2`
AntiZapret добавляет `ip rule` без fwmark, который перехватывает и трафик на
fake-подсеть, поэтому WARPER прописывает её в таблицы 13335/13336:

```bash
ip route show table 13335 | grep 10.224
ip route show table 13336 | grep 10.224
warper resync        # если маршрута нет
```

### Веб-панель недоступна, nginx не стартует

**Симптом:** `Job for nginx.service failed`, при этом `nginx -t` проходит.

**Причина:** `nginx -t` проверяет только синтаксис. Порт из `listen`
какого-то vhost занят другим процессом.

```bash
systemctl status nginx --no-pager -l     # покажет bind() ... Address already in use
ss -ltnp | grep ':80 '                   # кто держит порт
```

Чаще всего виноват оставшийся `/etc/nginx/sites-enabled/default` с
`listen 80`, когда 80-й занят сторонним сервисом:

```bash
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl start nginx
```

Если освободить порт нельзя, панель можно поставить **без nginx** — gunicorn
будет слушать внешний порт сам (вопрос задаётся при установке).

### ProtonVPN и другие WG-конфиги не импортируются

**Симптом:** `В файле отсутствуют обязательные параметры: PresharedKey`.

**Решение:** обновить WARPER до 1.5.0+ — `PresharedKey` стал опциональным,
как и должно быть по спецификации WireGuard. Заодно `MTU` и `DNS` теперь
берутся из импортируемого файла.

### Предупреждение "Требуется перезапуск правил AntiZapret"

**Симптом:** Активны правила от предыдущего `up.sh`.

**Решение:**
```bash
/root/antizapret/down.sh
/root/antizapret/up.sh
```

Если не помогло — перезагрузите сервер.

### sing-box не запускается

```bash
systemctl status sing-box --no-pager
journalctl -u sing-box -n 30 --no-pager
sing-box check -c /etc/sing-box/config.json
```

### Домены не работают после добавления

1. Проверьте синхронизацию: `warper sync`
2. Переподключите VPN-клиент
3. Проверьте DNS: `dig @127.0.0.1 -p 40000 домен.com`

### WARPERSLAVE не принимает подключения

```bash
# На донор-сервере:
ss -tulnp | grep 8444
iptables -L INPUT -n | grep 8444
warperslave doctor
```

- Hysteria2 работает по **UDP** — порт должен быть открыт для UDP и у
  хостера (облачный firewall).
- После `warperslave key`, `port`, `proto` или `host` ссылка меняется —
  выполните на master новую команду из `warperslave link`.
- VLESS+Reality: сайт из SNI должен отвечать по TLS 1.3 с донора
  (`warperslave doctor` это проверяет). Если нет — `warperslave proto vless другой.сайт`.

### VLESS / Hysteria2: режим не включается

Ссылка проверяется до применения, текст ошибки указывает на поле. Частые причины:
- неполная ссылка при копировании (обрезан `pbk=` или `sid=`); ссылку берите
  в одинарные кавычки: `warper mode vless '…'`;
- `sid` длиннее 16 hex-символов или нечётной длины;
- `flow=xtls-rprx-vision` вместе с транспортом, отличным от tcp.

Предупреждение `insecure=1 без пиннинга` означает, что сертификат Hysteria2 не
проверяется. Для своего донора пиннинг добавляется автоматически.

### OpenVPN: конфиг не принимается

sing-box реализует OpenVPN сам, поэтому поддерживается не всё:
- только `dev tun` — `dev tap` не поддерживается;
- только TLS-режим — `secret` (статический ключ), `pkcs12`, `http-proxy`,
  `socks-proxy` и `static-challenge` не поддерживаются;
- `auth-user-pass` — логин и пароль передаются отдельно:
  `warper mode openvpn /root/server.ovpn ЛОГИН ПАРОЛЬ`;
- имена шифров и `tls-auth`/`tls-crypt`/`tls-crypt-v2`, сертификаты в
  `<ca>…</ca>` или файлами рядом — разбираются автоматически.

Если соединение не поднимается: `journalctl -u sing-box -n 50`.

### Cloudflare заблокировал регистрацию WARP

**Симптом:** `wgcf-profile.conf` не создан при установке.

**Решение:** Сгенерируйте файл на домашнем ПК и загрузите на сервер:
- WARPER: `/root/warper/wgcf/wgcf-profile.conf`
- WARPERSLAVE: `/root/warperslave/wgcf/wgcf-profile.conf`

Или используйте режим WG / Slave вместо WARP.

### WG-конфиг не появляется в списке

**Причина:** Файл не проходит валидацию — отсутствует `[Peer]`, `Endpoint`, `PublicKey` или `PresharedKey`.

**Также:** файлы Cloudflare WARP (wgcf-profile.conf, warp.conf) намеренно исключаются из списка WG-конфигов.

**Решение:** Убедитесь что файл содержит все обязательные параметры:
```ini
[Interface]
PrivateKey = ...
Address = ...

[Peer]
PublicKey = ...
PresharedKey = ...
Endpoint = host:port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
```

### IPv6 в логах sing-box (WARPERSLAVE)

**Симптом:** DNS-ответы содержат AAAA-записи.

**Решение:** Обновите WARPERSLAVE или переключите режим: `warperslave` → 1 (switch) — конфиг пересоберётся с `"strategy": "ipv4_only"`.

### Ошибка «Отсутствует модуль ...» при запуске WARPER

**Симптом:** после обновления появляется сообщение `Отсутствует модуль: /root/warper/lib/utils.sh`.

**Решение:**  
Запустите WARPER ещё раз — он автоматически скачает недостающие модули.  
Если ошибка повторяется, выполните вручную:
```bash
mkdir -p /root/warper/lib /root/warper/menus
cd /root/warper
for lib in utils config domains singbox kresd warp-keys wg ip-routes diagnostics update; do
    curl -fsSL "https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/lib/${lib}.sh" -o "lib/${lib}.sh"
done
for menu in main settings singbox-menu ip-menu; do
    curl -fsSL "https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/menus/${menu}.sh" -o "menus/${menu}.sh"
done
```

## Логи

```bash
# WARPER
journalctl -u sing-box -f

# WARPERSLAVE
journalctl -u sing-box-slave -f
```

## Полный сброс

```bash
# WARPER
warper   # → U
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash

# WARPERSLAVE
warperslave   # → U
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install-slave.sh | bash
```

### Трафик показывает 0 или одинаковые данные за все периоды

**Симптом:** Все периоды (сегодня/неделя/месяц) показывают одинаковые значения.

**Причина:** При первом запуске модуля трафика все данные попадают в один час. Через сутки данные разойдутся по периодам.

**Также проверьте:**
```bash
# Интерфейс существует?
ip link show singbox-tun

# Счётчики доступны?
cat /sys/class/net/singbox-tun/statistics/rx_bytes

# Таймер запущен?
systemctl status warper-traffic-snapshot.timer

# Файл данных существует?
cat /root/warper/traffic.json | jq .
```

**Сброс данных:**
```bash
rm -f /root/warper/traffic.json
# Файл пересоздастся автоматически
```

### После переустановки AntiZapret WARP-ключи не обновились

**Симптом:** sing-box использует старые ключи, сервисы не работают.

**Решение:** если WARPER использует ключи AntiZapret (`WARP_KEY_SOURCE=system`),
перезагрузите сервер или выполните:
```bash
warper warpkeysync
```

Команда сверит ключи с системным конфигом AntiZapret (`/etc/wireguard/warp-vpn.conf`,
`warp-antizapret.conf` или `warp.conf`) и при расхождении пересоберёт конфиг и
перезапустит sing-box. При собственных ключах (`local`) синхронизация не нужна;
выбрать ключи AntiZapret: `warper mode warp system`.

---

### Каталог доменов не ищет категории / ничего не находится

**Симптом:** `warper catalog search telegram` ничего не показывает, либо веб-панель пишет что ничего не найдено.

**Проверьте:**
```bash
warper catalog refresh
warper catalog search telegram
```

Если `refresh` завершается ошибкой:
- проверьте доступ к `api.github.com`
- убедитесь что на сервере нет ограничений сети / DNS
- повторите позже, если GitHub API временно недоступен

### Каталог добавился, но доменов меньше чем ожидалось

WARPER импортирует только совместимые правила:
- `domain:`
- `full:`

Правила:
- `keyword:`
- `regexp:`

специально игнорируются, так как WARPER работает через доменную DNS-маршрутизацию и fake-ip.

### Как сбросить кэш каталога

```bash
rm -f /root/warper/catalog-cache.json
warper catalog refresh
```

### Как удалить все метаданные каталога

```bash
rm -f /root/warper/catalog.json /root/warper/catalog-cache.json
```

> Делайте это только если понимаете последствия: после этого WARPER перестанет знать какие каталоги были добавлены ранее.

---
