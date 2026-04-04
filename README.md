# 🚀 WARPER для AntiZapret VPN

Точечная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и других доменов через **Cloudflare WARP** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#-о-проекте)
2. [Как это работает](#-как-это-работает)
3. [Системные требования](#-системные-требования)
4. [Установка в 1 команду](#-установка-в-1-команду)
5. [Быстрая проверка после установки](#-быстрая-проверка-после-установки)
6. [Команды управления](#-команды-управления)
7. [Удаление](#-удаление)
8. [FAQ](#-faq)
9. [Известные ограничения](#-известные-ограничения)
10. [Ручная установка](#-ручная-установка)
11. [Поддержать проект](#-поддержать-проект)

---

## ℹ️ О проекте

### Проблема
У вас уже настроен сервер с **AntiZapret**. Заблокированные сайты открываются, всё работает. Но при попытке зайти на **Gemini**, **ChatGPT** или другие AI-сервисы вы получаете ошибку:

- сервис недоступен в вашей стране;
- доступ запрещён по IP;
- IP вашего VPS попал в deny/block list;
- сервис режет доступ по GEO.

### Решение
WARPER устанавливает:

- `sing-box`
- профиль **Cloudflare WARP**
- интерактивную утилиту `warper`

После этого вы можете **точечно направлять только нужные домены через WARP**, не меняя остальной сценарий работы AntiZapret.

То есть получается гибридная схема:

- обычные блокировки обслуживает **AntiZapret**
- “проблемные” домены вроде нейросетей идут через **WARP**

---

## ⚙️ Как это работает

Когда вы добавляете домен в WARPER:

1. домен попадает в список маршрутизации;
2. `kresd` отдаёт для него **fake-ip** из выбранной подсети;
3. трафик к этому fake-ip перехватывает `sing-box`;
4. `sing-box` отправляет его в туннель **Cloudflare WARP**;
5. сайт видит IP Cloudflare WARP, а не IP вашего VPS.

По умолчанию используется fake-подсеть:

```txt
198.18.0.0/24
```

При установке или позже в настройках можно выбрать свою.

---

## 📦 Системные требования

| Параметр | Поддерживаемые значения |
|---|---|
| **ОС** | Ubuntu 22.04, Ubuntu 24.04, Debian 11, Debian 12 |
| **Архитектура** | x86_64 (amd64), aarch64 (arm64), armv7l |
| **Права** | root |
| **Обязательное условие** | Уже установлен **AntiZapret VPN** |

Скрипт автоматически:

- проверяет ОС,
- определяет архитектуру,
- проверяет наличие AntiZapret.

---

## ⚡ Установка в 1 команду

Подключитесь к серверу по SSH от имени `root` и выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```

Во время установки скрипт:

- проверит совместимость системы;
- убедится, что AntiZapret установлен;
- установит `sing-box`;
- получит или использует существующие ключи WARP;
- создаст конфигурацию;
- пропатчит DNS;
- предложит добавить готовые списки доменов Gemini и ChatGPT.

После завершения установки просто выполните:

```bash
warper
```

> В некоторых случаях после применения изменений клиенту нужно переподключиться к VPN.

---

## ✅ Быстрая проверка после установки

Проверьте статус `sing-box`:

```bash
systemctl status sing-box --no-pager
```

Посмотрите последние логи:

```bash
journalctl -u sing-box -n 30 --no-pager
```

Запустите диагностику:

```bash
warper doctor
```

Если всё хорошо, вы увидите, что:

- `sing-box` активен;
- `config.json` валиден;
- `kresd.conf` пропатчен;
- fake-подсеть добавлена в `include-ips.txt`;
- активный список доменов синхронизирован.

---

## 🧰 Команды управления

### Главное меню
```bash
warper
```

### Диагностика
```bash
warper doctor
```

### Принудительно переприменить патч DNS
```bash
warper patch
```

### Открыть логи
Через меню:
- `6` → управление `sing-box`
- `7` → логи

Или напрямую:
```bash
journalctl -u sing-box -f
```

---

## 🗑 Удаление

### Способ 1
Через меню:

```bash
warper
```

Затем выберите:

```txt
U
```

### Способ 2
Через отдельный скрипт:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstaller.sh | bash
```

Скрипт удалит:

- `sing-box`
- патч DNS
- маршруты fake-подсети
- systemd-службы
- правила firewall

При этом он спросит, нужно ли сохранить:

- список доменов,
- настройки,
- ключи WARP.

---

## ❓ FAQ

<details>
<summary><b>Что делает WARPER?</b></summary>

WARPER — это менеджер доменной маршрутизации через Cloudflare WARP.

Когда вы добавляете, например, `openai.com`, система начинает:

- возвращать fake-ip для этого домена;
- перенаправлять соответствующий трафик в `sing-box`;
- отправлять его в WARP.

Остальной трафик продолжает работать как обычно через схему AntiZapret.
</details>

<details>
<summary><b>Нужно ли писать точку на конце домена?</b></summary>

Нет. Пишите как обычно:

```txt
chatgpt.com
```

WARPER сам корректно подготовит запись для DNS.
</details>

<details>
<summary><b>Почему правила добавляются в kresd.conf в двух местах?</b></summary>

Потому что AntiZapret логически разделяет обработку:

- заблокированных доменов;
- незаблокированных доменов.

Вставка в оба блока позволяет направлять через WARP **любой домен**, а не только домены из одного сценария.
</details>

<details>
<summary><b>Что делать, если Cloudflare не даёт зарегистрировать WARP?</b></summary>

Если `wgcf-profile.conf` не создаётся, скорее всего Cloudflare ограничил регистрацию с IP вашего сервера.

Решение:

1. сгенерировать `wgcf-profile.conf` на домашнем ПК;
2. загрузить его в:
   ```bash
   /root/warper/wgcf/
   ```
3. повторно запустить установку.
</details>

<details>
<summary><b>Как проверить, что fake-подсеть реально сменилась?</b></summary>

После изменения подсети выполните:

```bash
cat /root/antizapret/config/include-ips.txt
```

Там должна быть только актуальная fake-подсеть, без старой.
</details>

<details>
<summary><b>Что проверяет warper doctor?</b></summary>

Команда `warper doctor` проверяет:

- наличие AntiZapret;
- наличие и валидность конфигов;
- активность `sing-box`;
- включена ли автозагрузка;
- пропатчен ли `kresd.conf`;
- существует ли backup `kresd.conf`;
- синхронизированы ли домены;
- присутствует ли fake-подсеть в `include-ips.txt`;
- существует ли интерфейс `singbox-tun`;
- есть ли нужные правила `iptables`.
</details>

---

## ⚠️ Известные ограничения

- Проект работает только с **IPv4**-сценарием.
- Ожидается стандартная структура AntiZapret в `/root/antizapret`.
- Если upstream AntiZapret сильно изменит структуру `kresd.conf`, патч может потребовать адаптации.
- На некоторых серверах Cloudflare может блокировать регистрацию WARP.
- Некоторые сервисы используют дополнительные CDN/endpoint-домены, которые может потребоваться вручную добавить в список.
- Используются `iptables`; в экзотических nft-only конфигурациях может потребоваться ручная адаптация.

---

## 🛠 Ручная установка

<details>
<summary>Нажмите, чтобы развернуть пошаговую ручную инструкцию</summary>

### Шаг 1. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

### Шаг 2. Получение ключей WARP

```bash
mkdir -p /root/warper/wgcf
cd /root/warper/wgcf

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  WGCF_ARCH="amd64" ;;
    aarch64) WGCF_ARCH="arm64" ;;
    armv7l)  WGCF_ARCH="armv7" ;;
    *)       echo "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

wget -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${WGCF_ARCH}"
chmod +x /usr/local/bin/wgcf

/usr/local/bin/wgcf register --accept-tos
/usr/local/bin/wgcf generate
chmod 600 wgcf-profile.conf wgcf-account.toml 2>/dev/null || true
```

Посмотреть профиль:

```bash
cat wgcf-profile.conf
```

Нужны значения:

- `PrivateKey`
- `Address`

---

### Шаг 3. Настройка `sing-box`

Создайте конфиг:

```bash
mkdir -p /etc/sing-box
nano /etc/sing-box/config.json
```

Вставьте конфиг из файла `config.json.template` этого репозитория, подставив:

- `Address`
- `PrivateKey`
- fake-подсеть
- TUN IP

После сохранения проверьте:

```bash
sing-box check -c /etc/sing-box/config.json
```

---

### Шаг 4. Systemd-служба

Создайте:

```bash
nano /etc/systemd/system/sing-box.service
```

Вставьте содержимое `sing-box.service` из этого репозитория.

Затем:

```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
systemctl status sing-box --no-pager
```

---

### Шаг 5. Добавление fake-подсети в AntiZapret

```bash
echo "198.18.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

---

### Шаг 6. Установка WARPER

Создайте папку:

```bash
mkdir -p /root/warper
```

Создайте конфиг:

```bash
cat > /root/warper/warper.conf <<EOF
SUBNET=198.18.0.0/24
TUN_IP=198.18.0.1/24
EOF
chmod 600 /root/warper/warper.conf
```

Скачайте файлы проекта из репозитория:

- `warper.sh`
- `uninstaller.sh`
- `config.json.template`
- `version`

Создайте симлинк:

```bash
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

Создайте автопатч:

```bash
nano /etc/systemd/system/warper-autopatch.service
```

Вставьте содержимое `warper-autopatch.service` из репозитория.

Затем:

```bash
systemctl daemon-reload
systemctl enable warper-autopatch
```

---

### Шаг 7. Финал

Запустите:

```bash
warper
```

Рекомендуется:

1. обновить списки доменов;
2. включить нужные наборы;
3. выполнить патч DNS;
4. проверить:
   ```bash
   warper doctor
   ```

</details>

---

## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию;
- расскажите другим пользователям AntiZapret;
- создавайте issue и pull request'ы, если нашли проблемы или хотите улучшить проект.
```

---
