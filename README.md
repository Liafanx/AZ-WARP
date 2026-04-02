# 🚀 Как точечно пустить сервисы (Gemini, ChatGPT и др.) через Cloudflare WARP на сервере с AntiZapret

Сам проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

## 📋 Оглавление
1. [О проекте](#-о-проекте)
2. [Установка в 1 команду (Рекомендуется)](#-установка-в-1-команду-рекомендуется)
3. [Удаление утилиты](#-удаление-утилиты)
4. [Частые вопросы (FAQ)](#-частые-вопросы-faq)
5. [Поддержать проект](#-поддержать-проект)
6. [Ручная Установка (Для продвинутых пользователей)](#-ручная-установка-для-продвинутых-пользователей)

---

## ℹ️ О проекте
**Проблема:** У вас установлен свой сервер с AntiZapret. Всё работает отлично, заблокированные сайты открываются. Но при попытке зайти на Gemini или ChatGPT вы получаете ошибку (сервис недоступен в вашей стране, или что ваш IP заблокирован). Это происходит потому, что IP-адрес вашего VPS заблокирован самими нейросетями, либо по GEO определяется в недоступной стране.

**Решение:** Мы установим легковесное ядро `sing-box`, подключим его к Cloudflare WARP и создадим удобную интерактивную утилиту `warper`. Она позволит в пару кликов направлять любые нужные вам домены в туннель WARP, оставляя весь остальной трафик работать как обычно. Утилита полностью защищена от сброса настроек при обновлениях AntiZapret, потребуется только сделать восстановление одной кнопкой.

⚠️ **Внимание:** По умолчанию для маршрутизации (fake-ip) используется подсеть `198.18.0.0/24` во избежание конфликтов с внутренними сетями. В процессе автоматической установки, а также позже в настройках утилиты, вы сможете задать свою собственную подсеть, если стандартная у вас уже чем-то занята.

---

*Проверено и работает на Ubuntu 24.04.*

---

## ⚡ Установка в 1 команду (Рекомендуется)
Подключитесь к вашему серверу по SSH от имени `root` и выполните команду:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```
*Во время установки скрипт задаст несколько вопросов (добавление популярных нейросетей в списки и выбор фейковой подсети).*

*После завершения установки просто введите в консоли команду `warper`.*

*Примечание: Для применения изменений на клиенте (вашем ПК или телефоне) в некоторых случаях нужно переподключиться к VPN.*

---

## 🗑 Удаление утилиты
Если вы хотите полностью удалить интеграцию с WARP и вернуть сервер AntiZapret в исходное состояние, вы можете сделать это двумя способами:

**Способ 1:** Откройте меню утилиты командой `warper` и выберите пункт `U`.
**Способ 2:** Выполните команду удаления в консоли:
```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstaller.sh | bash
```
*При удалении скрипт заботливо уточнит, хотите ли вы сохранить ваш список доменов и сетевые настройки для будущих установок.*

---

## ❓ Частые вопросы (FAQ)

<details>
<summary><b>Что именно делает утилита WARPER? (Развернуть)</b></summary>
<br>
Утилита <code>warper</code> — это менеджер маршрутизации. Когда вы добавляете домен (например, <code>openai.com</code>), утилита прописывает его в локальный DNS-сервер (kresd).<br><br> 
При попытке открыть этот сайт, DNS выдает вашему устройству фейковый IP-адрес из настроенного диапазона (по умолчанию <code>198.18.0.x</code>). Весь трафик к этому фейковому адресу перехватывается службой <code>sing-box</code>, которая незаметно перенаправляет его в защищенный туннель Cloudflare WARP. Таким образом, сайты видят чистый IP-адрес Cloudflare, а не адрес вашего сервера.
</details>

<details>
<summary><b>Почему скрипт добавляет правила в kresd.conf в двух местах?</b></summary>
<br>
Архитектура локального DNS-сервера в AntiZapret разделена на два логических блока: один обрабатывает домены из реестра заблокированных (пускает через VPN), а другой — все остальные домены (пускает напрямую).<br><br>
Внедряя код <code>warper</code> в оба блока, мы получаем возможность пускать через WARP <b>абсолютно любые сайты</b>. Вы можете добавить туда как заблокированный ресурс, так и совершенно легальный сайт, от которого вы просто хотите скрыть свой реальный IP-адрес.
</details>

<details>
<summary><b>Нужно ли писать точку на конце домена?</b></summary>
<br>
Нет, вводите домены как обычно (например, <code>chatgpt.com</code>). Утилита сама подставит необходимые для DNS точки при компиляции конфигурации.
</details>

---

## ⭐️ Поддержать проект

Если этот скрипт сэкономил вам время и нервы, помог обойти блокировки нейросетей и сделал ваш VPN лучше — **пожалуйста, поставьте ⭐️ (звездочку) этому репозиторию в правом верхнем углу!** 

---

## 🛠 Ручная Установка (Для продвинутых пользователей)

<details>
<summary>Нажмите, чтобы развернуть пошаговую инструкцию по ручной настройке</summary>

### Шаг 1. Установка sing-box
Выполняем команду для установки актуальной версии `sing-box` (проверено на 1.13.5):

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

### Шаг 2. Получение ключей Cloudflare WARP
Чтобы `sing-box` мог подключиться к WARP, нам нужно сгенерировать личный профиль через утилиту `wgcf`. Выполняем команды по очереди:

```bash
# Создаем рабочую папку
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

# Скачиваем утилиту и даем права на запуск
wget -O /usr/local/bin/wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
chmod +x /usr/local/bin/wgcf

# Регистрируем аккаунт и генерируем конфиг
/usr/local/bin/wgcf register --accept-tos
/usr/local/bin/wgcf generate
```

Открываем созданный файл:
```bash
cat wgcf-profile.conf
```
Скопируйте из вывода два значения (сохраните их в блокнот):
* `PrivateKey` (строка вида `uBW0nm7U...=`)
* `Address` (ваш IPv4, обычно это `172.16.0.2/32`)

*Примечание: Если файл не создался (ошибка 429), значит Cloudflare заблокировал регистрацию с вашего сервера. Сгенерируйте файл `wgcf-profile.conf` на домашнем ПК и загрузите его в папку `/root/warper/wgcf/` на сервере.*

### Шаг 3. Настройка конфига sing-box
Создаем конфигурационный файл:
```bash
nano /etc/sing-box/config.json
```
Вставляем этот код. **Обязательно замените значения `Address` и `PrivateKey` на свои из Шага 2!** *(В этом конфиге по умолчанию прописана подсеть `198.18.0.0/24`, при необходимости вы можете изменить её на свою)*.

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
        "server": "1.1.1.1",
        "detour": "warp"
      },
      {
        "tag": "fakeip-dns",
        "type": "fakeip",
        "inet4_range": "198.18.0.0/24",
        "inet6_range": "fc00::/18"
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
        "198.18.0.1/24"
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
Чтобы `sing-box` запускался автоматически от имени `root` и создавал интерфейс `tun`, создадим службу:

```bash
nano /usr/lib/systemd/system/sing-box.service
```
Вставляем следующий текст:

```ini
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
# Ждем 2 секунды, пока интерфейс resolved появится
ExecStartPost=/bin/sleep 2
# Стираем локальные DNS
ExecStartPost=-/usr/bin/resolvectl dns singbox-tun ""
ExecStartPost=-/usr/bin/resolvectl domain singbox-tun ""
# Разрешаем маршрутизацию FORWARD (Фикс для Docker)
ExecStartPost=-/usr/sbin/iptables -I FORWARD -o singbox-tun -j ACCEPT
ExecStartPost=-/usr/sbin/iptables -I FORWARD -i singbox-tun -j ACCEPT
# Убираем правила при остановке службы
ExecStopPost=-/usr/sbin/iptables -D FORWARD -o singbox-tun -j ACCEPT
ExecStopPost=-/usr/sbin/iptables -D FORWARD -i singbox-tun -j ACCEPT

Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
```
*Сохраняем: `Ctrl+O`, `Enter`, `Ctrl+X`.*

Перезагружаем демоны, добавляем в автозагрузку и запускаем:
```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

### Шаг 5. Интеграция с маршрутами AntiZapret
Устройства должны знать, что трафик к виртуальным IP-адресам `sing-box` нужно отправлять в VPN.
Добавляем фейковую подсеть в конфиг маршрутов и применяем *(если вы меняли её в Шаге 3, укажите свою)*:
```bash
echo "198.18.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

### Шаг 6. Создание умной утилиты WARPER
Мы создадим мощный инструмент, который защитит ваши настройки от перезаписи при обновлениях AntiZapret и позволит легко управлять туннелем прямо из консоли.

**1. Создаем папку и файл настроек для утилиты:**
```bash
mkdir -p /root/warper
echo 'SUBNET="198.18.0.0/24"' > /root/warper/warper.conf
echo 'TUN_IP="198.18.0.1/24"' >> /root/warper/warper.conf
```
*(Мастер-файл со списком доменов `domains.txt` утилита создаст сама при первом запуске).*

**2. Создаем скрипт-утилиту:**
```bash
nano /root/warper/warper.sh
```
Вставляем код утилиты:
*(Код утилиты смотрите в файле `warper.sh` в этом репозитории)*

**3. Создаем службу автопатча для сохранения настроек при перезагрузках:**
```bash
nano /usr/lib/systemd/system/warper-autopatch.service
```
Вставляем следующий текст:
```ini
[Unit]
Description=WARPER Auto-Patch Kresd on Boot
After=network-online.target kresd@1.service kresd@2.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warper patch
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

**4. Выдаем права, создаем ярлык и включаем службу:**
```bash
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper
systemctl daemon-reload
systemctl enable warper-autopatch
```

### Шаг 7. Активация и Финал
Теперь просто введите в консоли сервера команду:
```bash
warper
```
Перед вами появится главное меню утилиты:
1. Рекомендуется нажать **10** (Проверить и обновить списки доменов), чтобы утилита скачала готовые списки (Gemini, ChatGPT) с GitHub.
2. Перейдите в раздел **9 (Настройки)**. Там вы можете в один клик включить интеграцию скачанных списков или **изменить фейковую подсеть (пункт 4)**.
3. Вы также можете добавлять любые свои домены вручную через пункт **1** главного меню.
4. Нажмите **5**, чтобы утилита внедрила правила в конфигурацию DNS.
5. Проверьте статусы в шапке (все должно светиться зеленым).
6. Нажмите **0** для выхода.

**Готово! 🎉**
У вас настроен идеальный гибридный VPN. AntiZapret обрабатывает стандартные блокировки, а `sing-box` (через WARP) берет на себя недоступные по какой-либо причине ресурсы или нужные вам для скрытия IP адреса. Если сервис перестал работать — просто введите `warper`, добавьте его домен в список, нажмите `Enter` (для авто-перезагрузки DNS) и пользуйтесь!

</details>
