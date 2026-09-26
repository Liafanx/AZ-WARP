# 🛠 Ручная установка WARPER

## Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables nano
```

## Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash -s -- --version 1.14.1
```

## Шаг 3. Получение ключей WARP

Если включён встроенный WARP AntiZapret, ключи лежат в
`/etc/wireguard/warp-vpn.conf` или `warp-antizapret.conf` (в старых версиях — `warp.conf`):

```bash
WARP_CONF=$(ls /etc/wireguard/warp-vpn.conf /etc/wireguard/warp-antizapret.conf /etc/wireguard/warp.conf 2>/dev/null | head -1)
WARP_PRIVATE_KEY=$(grep '^PrivateKey' "$WARP_CONF" | awk -F'= ' '{print $2}')
WARP_ADDRESS=$(grep '^Address' "$WARP_CONF" | awk -F'= ' '{print $2}')
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

/usr/local/bin/wgcf register --accept-tos || true
/usr/local/bin/wgcf generate || true
```

## Шаг 4. Настройка sing-box

```bash
mkdir -p /etc/sing-box
nano /etc/sing-box/config.json
```

Используйте `templates/config.json.template` из репозитория, подставив свои значения.

Проверка:

```bash
sing-box check -c /etc/sing-box/config.json
```

## Шаг 5. Systemd-служба

```bash
cp templates/sing-box.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

## Шаг 6. Добавление fake-подсети в AntiZapret

```bash
echo "10.224.0.0/16" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

## Шаг 7. Установка WARPER

```bash
mkdir -p /root/warper
cat > /root/warper/warper.conf <<EOF
SUBNET=10.224.0.0/16
TUN_IP=10.224.0.1/16
EOF
chmod 600 /root/warper/warper.conf

# Создать slave_mode.conf для WARP-режима
cat > /root/warper/slave_mode.conf <<EOF
OUTBOUND_MODE=warp
SLAVE_SERVER=
SLAVE_PORT=8444
SLAVE_PASSWORD=
EOF
chmod 600 /root/warper/slave_mode.conf
```

Загрузите из репозитория: `warper.sh`, `uninstaller.sh`, `version`, шаблоны из `templates/`.
Проект состоит из главного скрипта `warper.sh` и набора модулей в папках `lib/` и `menus/`.  
Скопируйте их в соответствующие директории, либо используйте автоматический установщик.

```bash
chmod +x /root/warper/warper.sh /root/warper/lib/outbound-parse.py
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

Модуль `lib/outbound-parse.py` нужен режимам VLESS, Hysteria2 и OpenVPN и
требует `python3`. Переключиться на них можно после установки:
`warper mode vless|hy2 'ссылка'` или `warper mode openvpn файл.ovpn`.

Создайте warper-autopatch.service:

```bash
cp templates/warper-autopatch.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable warper-autopatch
```

## Шаг 8. Проверка

```bash
warper doctor
warper status
```
