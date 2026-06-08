# 🔧 Устранение неполадок

## Диагностика

```bash
warper doctor          # WARPER
warperslave doctor     # WARPERSLAVE
```

## Типичные проблемы

### ANTIZAPRET_WARP=y — конфликт

**Симптом:** WARPER не работает, в меню предупреждение.

**Решение:**
```bash
# В /root/antizapret/setup:
ANTIZAPRET_WARP=n

/root/antizapret/down.sh
/root/antizapret/up.sh
```

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
ss -tlnp | grep 8444
iptables -L INPUT -n | grep 8444
warperslave doctor
```

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

**Решение:** Перезагрузите сервер или выполните:
```bash
warper warpkeysync
```

Команда автоматически проверит `/etc/wireguard/warp.conf` и если ключи изменились — пересоберёт конфиг и перезапустит sing-box.

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
