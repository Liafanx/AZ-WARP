# 🚀 Как точечно пустить сервисы (Gemini и не только) через Cloudflare WARP на сервере с AntiZapret

**Проблема:** У вас установлен свой сервер с AntiZapret. Всё работает отлично, заблокированные сайты открываются. Но при попытке зайти на Gemini или ChatGPT вы получаете ошибку (сервис недоступен или пишет, что ваш IP заблокирован). Это происходит потому, что нейросети часто блокируют IP-адреса дата-центров (хостингов).

**Решение:** Мы установим легковесное ядро `sing-box`, подключим его к Cloudflare WARP (у которого "чистые" IP-адреса) и настроим роутер AntiZapret так, чтобы **только** заблокированные домены (например, `gemini.google.com`) улетали в туннель WARP, а весь остальной трафик работал как обычно.

---

### Шаг 1. Установка sing-box
Подключаемся к вашему серверу по SSH и выполняем команду для установки актуальной версии `sing-box`:

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

### Шаг 2. Получение ключей Cloudflare WARP
Чтобы `sing-box` мог подключиться к WARP, нам нужно сгенерировать личный профиль. Сделаем это через утилиту `wgcf`. Выполняем команды по очереди:

```bash
# Скачиваем утилиту и даем права на запуск
wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
chmod +x wgcf

# Регистрируем аккаунт и генерируем конфиг
./wgcf register --accept-tos
./wgcf generate
```

Открываем созданный файл:
```bash
cat wgcf-profile.conf
```
Вам нужно скопировать из вывода два значения:
* `PrivateKey` (строка вида `uBW0nm7U...=`)
* `Address` (ваш IPv4, обычно это `172.16.0.2/32`)

### Шаг 3. Настройка конфига sing-box
Создаем/открываем конфигурационный файл:
```bash
nano /etc/sing-box/config.json
```
Вставляем этот код. **Обязательно замените значения `Address` и `PrivateKey` на свои из Шага 2!**

```json
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "tag": "real-dns",
        "type": "udp",
        "server": "8.8.8.8",
        "detour": "warp"
      },
      {
        "tag": "fakeip-dns",
        "type": "fakeip",
        "inet4_range": "10.255.0.0/16"
      }
    ],
    "rules": [
      {
        "query_type": ["A", "AAAA"],
        "server": "fakeip-dns"
      }
    ],
    "independent_cache": true
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "name": "warp-tun",
      "system": false,
      "mtu": 1280,
      "address": [
        "ВАШ_ADDRESS_ИЗ_WGCF" 
      ],
      "private_key": "ВАШ_PRIVATE_KEY_ИЗ_WGCF",
      "peers": [
        {
          "address": "162.159.192.1",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "inbounds": [
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "listen_port": 40000,
      "network": "udp"
    },
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox-tun",
      "address": [
        "10.255.0.1/16"
      ],
      "auto_route": false,
      "strict_route": false,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "dns-in",
        "action": "hijack-dns"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": "tun-in",
        "outbound": "warp"
      }
    ],
    "default_domain_resolver": "real-dns",
    "auto_detect_interface": true,
    "final": "direct"
  }
}
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

### Шаг 4. Настройка службы systemd
Чтобы сервис `sing-box` запускался автоматически и имел права на создание виртуального сетевого интерфейса (tun), создадим/отредактируем службу:

```bash
nano /usr/lib/systemd/system/sing-box.service
```
Вставляем следующий текст (обратите внимание, мы запускаем сервис от `root`, чтобы не было ошибок прав доступа):

```ini
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

Перезагружаем демоны и запускаем службу:
```bash
systemctl daemon-reload
systemctl start sing-box
systemctl status sing-box
```
*(Статус должен гореть зеленым `active (running)`).*

### Шаг 5. Интеграция с AntiZapret (kresd и маршруты)

**1. Добавляем фейковую подсеть в маршруты VPN**
Ваши устройства должны знать, что трафик к виртуальным IP-адресам нужно отправлять в VPN.
```bash
echo "10.255.0.0/16" >> /root/antizapret/config/include-ips.txt
```
делаем doall
```bash
/root/antizapret/doall.sh
```

**2. Направляем домены в WARP**
Открываем конфиг локального DNS-резолвера:
```bash
nano /etc/knot-resolver/kresd.conf
```
Находим блок `if string.match(systemd_instance, '^1') then` и листаем чуть ниже. Перед блоком `-- Resolve non-blocked domains` вставляем это правило:

```lua
	-- Unlock Gemini
	policy.add(
   		 policy.suffix(
        		policy.STUB('127.0.0.1@40000'), 
       			policy.todnames({'gemini.google.com.', 'proactivebackend-pa.googleapis.com.', 'assistant-s3-pa.googleapis.com.', 'gemini.google.',
    			'alkaliminer-pa.googleapis.com.', 'robinfrontend-pa.googleapis.com.'})
    		)
	)
```
⚠️ **Внимание:** Файл разделен на две части (для инстанса `kresd@1` и `kresd@2`). Пролистайте файл ниже до `elseif string.match(systemd_instance, '^2') then` и вставьте **этот же блок** туда тоже перед блоком `-- Resolve blocked domains`!
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

В теории если сюда воткнуть любые домены то они потом пойдут через варп.

### Шаг 6. Финал
Перезапускаем DNS-резолвер для применения правил:
```bash
systemctl restart kresd@1 kresd@2
```
Пробуем, и если все хорошо, gemini поднялся то можно включить sing box в автозагрузку

```bash
systemctl enable sing-box
```

**Готово! 🎉**
Теперь при попытке зайти на Gemini или ChatGPT, роутер спросит IP-адрес у `sing-box`. `sing-box` выдаст фейковый IP `10.255.x.x`. Трафик полетит в виртуальный туннель и завернется в Cloudflare WARP. 

**Как убедиться, что всё работает?**
Введите на сервере команду:
```bash
journalctl -u sing-box -f
```
Попробуйте зайти на YouTube — в консоли будет пусто (трафик идет штатно через AntiZapret).
Попробуйте открыть Gemini — в консоли сразу побегут логи перехвата DNS и отправки пакетов в `[warp]`. 

*(Чтобы добавить новые сайты, просто дописывайте их домены в `kresd.conf` в блок `policy.todnames` и перезапускайте `kresd`)*.
