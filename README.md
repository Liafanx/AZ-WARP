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
7. [CLI-команды без меню](#-cli-команды-без-меню)
8. [Удаление](#-удаление)
9. [FAQ](#-faq)
10. [Известные ограничения](#-известные-ограничения)
11. [Ручная установка](#-ручная-установка)
12. [Поддержать проект](#-поддержать-проект)

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
- проверяет наличие AntiZapret,
- устанавливает `jq` для безопасной работы с JSON.

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
- проверит конфиг через `sing-box check`;
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

И краткий статус:

```bash
warper status
```

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

### Краткий статус
```bash
warper status
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

## ⚡ CLI-команды без меню

Теперь можно работать без интерактивного меню:

### Добавить домен
```bash
warper add openai.com
```

### Удалить домен
```bash
warper remove openai.com
```

### Включить встроенный список
```bash
warper enable gemini
warper enable chatgpt
```

### Выключить встроенный список
```bash
warper disable gemini
warper disable chatgpt
```

### Синхронизировать и применить
```bash
warper sync
```

### Проверка состояния
```bash
warper status
warper doctor
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
<summary><b>Что добавилось в 1.0.24.1?</b></summary>

В версии 1.0.24.1 есть:

- `warper status`
- CLI-команды без меню
- безопасное чтение `config.json` через `jq`
- проверка конфликта fake-подсети
- расширенный `doctor`
- доработки стабильности и совместимости
</details>

<details>
<summary><b>Зачем нужен jq?</b></summary>

`jq` используется для безопасного чтения JSON-конфигурации `sing-box`.  
Это надёжнее, чем парсить JSON через `grep/sed`, особенно если форматирование файла изменится.
</details>

<details>
<summary><b>Что значит конфликт fake-подсети?</b></summary>

Если fake-подсеть уже используется:

- на локальных интерфейсах,
- в маршрутах,
- в Docker-сетях,

то это может ломать маршрутизацию.  
WARPER умеет это выявлять и предупреждать.
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

### Шаг 1. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables nano
```

### Шаг 2. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

### Шаг 3. Получение ключей WARP

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

### Шаг 4. Настройка `sing-box`

Создайте конфиг:

```bash
mkdir -p /etc/sing-box
nano /etc/sing-box/config.json
```

Вставьте конфиг из `config.json.template`, подставив свои значения.

Проверьте:

```bash
sing-box check -c /etc/sing-box/config.json
```

### Шаг 5. Systemd-служба

```bash
nano /etc/systemd/system/sing-box.service
```

Вставьте содержимое `sing-box.service`.

Затем:

```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

### Шаг 6. Добавление fake-подсети в AntiZapret

```bash
echo "198.18.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

### Шаг 7. Установка WARPER

```bash
mkdir -p /root/warper
cat > /root/warper/warper.conf <<EOF
SUBNET=198.18.0.0/24
TUN_IP=198.18.0.1/24
EOF
chmod 600 /root/warper/warper.conf
```

Загрузите из репозитория:

- `warper.sh`
- `uninstaller.sh`
- `config.json.template`
- `version`

И создайте симлинк:

```bash
chmod +x /root/warper/warper.sh
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

Создайте `warper-autopatch.service`, затем:

```bash
systemctl daemon-reload
systemctl enable warper-autopatch
```

### Шаг 8. Финал

```bash
warper doctor
warper status
```

</details>

---

## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию;
- расскажите другим пользователям AntiZapret;
- создавайте issue и pull request'ы, если нашли проблемы или хотите улучшить проект.

