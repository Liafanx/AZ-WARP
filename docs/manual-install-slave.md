# 🛠 Ручная установка WARPERSLAVE

## Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables openssl
```

## Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash -s -- --version 1.13.5
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
