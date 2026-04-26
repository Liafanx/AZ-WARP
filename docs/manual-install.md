# 🛠 Ручная установка WARPER

Если автоматический установщик не подходит, можно установить WARPER вручную.

## Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables nano
```

## Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

## Шаг 3. Получение ключей WARP

Если есть `/etc/wireguard/warp.conf` (от VPN_WARP=y):

```bash
WARP_PRIVATE_KEY=$(grep '^PrivateKey' /etc/wireguard/warp.conf | awk -F'= ' '{print $2}')
WARP_ADDRESS=$(grep '^Address' /etc/wireguard/warp.conf | awk -F'= ' '{print $2}')
```

Или сгенерировать новые:

```bash
mkdir -p /root/warper/wgcf && cd /root/warper/wgcf

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  WGCF_ARCH="amd64" ;;
    aarch64) WGCF_ARCH="arm64" ;;
    armv7l)  WGCF_ARCH="armv7" ;;
esac

wget -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${WGCF_ARCH}"
chmod +x /usr/local/bin/wgcf

/usr/local/bin/wgcf register --accept-tos
/usr/local/bin/wgcf generate
```

## Шаг 4. Настройка sing-box

```bash
mkdir -p /etc/sing-box
nano /etc/sing-box/config.json
```

Используйте `config.json.template` из репозитория, подставив свои значения.

Проверка:

```bash
sing-box check -c /etc/sing-box/config.json
```

## Шаг 5. Systemd-служба

```bash
cp sing-box.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

## Шаг 6. Добавление fake-подсети в AntiZapret

```bash
echo "198.20.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

## Шаг 7. Установка WARPER

```bash
mkdir -p /root/warper
cat > /root/warper/warper.conf <<EOF
SUBNET=198.20.0.0/24
TUN_IP=198.20.0.1/24
EOF
chmod 600 /root/warper/warper.conf
```

Загрузите `warper.sh`, `uninstaller.sh`, `config.json.template`, `version` из репозитория.

```bash
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

Создайте `warper-autopatch.service`:

```bash
cp warper-autopatch.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable warper-autopatch
```

## Шаг 8. Проверка

```bash
warper doctor
warper status
```
```

---

### `docs/manual-install-slave.md`

```markdown
# 🛠 Ручная установка WARPERSLAVE

## Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables openssl
```

## Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

## Шаг 3. Генерация ключа Shadowsocks

```bash
openssl rand -base64 16
```

Сохраните ключ — он понадобится на обоих серверах.

## Шаг 4. Конфигурация sing-box

### Режим Direct

```bash
mkdir -p /etc/sing-box-slave
cat > /etc/sing-box-slave/config.json << 'EOF'
{
  "log": { "level": "info" },
  "dns": {
    "servers": [{ "tag": "direct-dns", "type": "udp", "server": "1.1.1.1" }],
    "strategy": "ipv4_only",
    "independent_cache": true
  },
  "inbounds": [{
    "type": "shadowsocks", "tag": "ss-in",
    "listen": "0.0.0.0", "listen_port": 8444,
    "method": "2022-blake3-aes-128-gcm",
    "password": "ВАШ_КЛЮЧ"
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rules": [{ "inbound": "ss-in", "outbound": "direct" }],
    "default_domain_resolver": "direct-dns",
    "final": "direct"
  }
}
EOF
chmod 600 /etc/sing-box-slave/config.json
```

### Режим WARP

Используйте шаблон `config-slave-warp.json.template`, подставив WARP-ключи и пароль Shadowsocks.

## Шаг 5. Systemd-служба

```bash
cat > /etc/systemd/system/sing-box-slave.service << 'EOF'
[Unit]
Description=sing-box slave service (warperslave)
After=network.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box-slave/config.json
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box-slave
systemctl start sing-box-slave
```

## Шаг 6. Открытие порта

```bash
iptables -I INPUT -p tcp --dport 8444 -j ACCEPT
iptables -I INPUT -p udp --dport 8444 -j ACCEPT
```

## Шаг 7. Проверка

```bash
systemctl status sing-box-slave
ss -tlnp | grep 8444
```
```

---

### `docs/architecture.md`

```markdown
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
```

---

### `docs/troubleshooting.md`

```markdown
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
```
