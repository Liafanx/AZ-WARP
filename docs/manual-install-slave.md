# 🛠 Ручная установка WARPERSLAVE

## Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables openssl
```

## Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash -s -- --version 1.14.1
```

## Шаг 3. Утилита warperslave

```bash
mkdir -p /root/warperslave /etc/sing-box-slave
cd /root/warperslave
REPO=https://raw.githubusercontent.com/Liafanx/AZ-WARP/main
curl -fsSLO $REPO/warperslave.sh
curl -fsSLO $REPO/uninstall-slave.sh
curl -fsSLO $REPO/versionslave
chmod +x warperslave.sh uninstall-slave.sh
ln -sf /root/warperslave/warperslave.sh /usr/local/bin/warperslave
```

## Шаг 4. Настройки и конфиг sing-box

```bash
cat > /root/warperslave/slave.conf << 'EOF'
SLAVE_MODE=direct
SLAVE_PROTO=vless
SLAVE_PORT=8444
SLAVE_SNI=www.microsoft.com
EOF
chmod 600 /root/warperslave/slave.conf

warperslave rebuild
```

- `SLAVE_PROTO` — протокол подключения master: `ss` (Shadowsocks 2022),
  `vless` (VLESS+Reality) или `hy2` (Hysteria2).
- `SLAVE_MODE` — выход: `direct` (IP донора) или `warp` (через Cloudflare WARP).
  Для `warp` положите `wgcf-profile.conf` в `/root/warperslave/wgcf/`.
- `SLAVE_SNI` — сайт для маскировки Reality, должен отвечать по TLS 1.3:
  `openssl s_client -connect www.microsoft.com:443 -tls1_3 </dev/null`.

`warperslave rebuild` генерирует недостающие ключи (UUID и ключи Reality,
пароли Hysteria2 и сертификат, ключ Shadowsocks), записывает их в
`slave.conf`, собирает `/etc/sing-box-slave/config.json` и проверяет его
`sing-box check`.

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
LimitNOFILE=infinity

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
ss -tulnp | grep 8444
warperslave doctor
```

## Шаг 8. Подключение master

```bash
warperslave link
```

Выполните напечатанную команду `warper mode … '…'` на основном сервере.
