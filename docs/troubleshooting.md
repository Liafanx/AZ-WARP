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
А лучше перезагрузить сервер.

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

**Симптом:** `wgcf-profile.conf` не создан.

**Решение:** Сгенерируйте файл на домашнем ПК и загрузите на сервер:
- WARPER: `/root/warper/wgcf/wgcf-profile.conf`
- WARPERSLAVE: `/root/warperslave/wgcf/wgcf-profile.conf`

### IPv6 в логах sing-box (WARPERSLAVE)

**Симптом:** DNS-ответы содержат AAAA-записи.

**Решение:** Обновите WARPERSLAVE — в новых конфигах добавлено `"strategy": "ipv4_only"`. Или переключите режим: `warperslave` → 1 (switch).

## Логи

```bash
# WARPER
journalctl -u sing-box -f

# WARPERSLAVE
journalctl -u sing-box-slave -f
```

## Полный сброс

```bash
# WARPER — удаление и переустановка
warper   # → U
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash

# WARPERSLAVE
warperslave   # → U
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install-slave.sh | bash
```
