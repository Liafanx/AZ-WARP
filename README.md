# 🚀 WARPER для AntiZapret VPN

Точечная и глобальная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и любых других доменов через **Cloudflare WARP** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#-о-проекте)
2. [Режимы работы](#-режимы-работы)
3. [Как это работает](#-как-это-работает)
4. [Системные требования](#-системные-требования)
5. [Установка в 1 команду](#-установка-в-1-команду)
6. [Быстрая проверка после установки](#-быстрая-проверка-после-установки)
7. [Команды управления](#-команды-управления)
8. [CLI-команды без меню](#-cli-команды-без-меню)
9. [Удаление](#-удаление)
10. [FAQ](#-faq)
11. [Известные ограничения](#-известные-ограничения)
12. [Ручная установка](#-ручная-установка)
13. [Поддержать проект](#-поддержать-проект)

---

## ℹ️ О проекте

### Проблема
У вас уже настроен сервер с **AntiZapret**. Заблокированные сайты открываются, всё работает. Но при попытке зайти на **Gemini**, **ChatGPT** или другие AI-сервисы вы получаете ошибку:

- сервис недоступен в вашей стране;
- доступ запрещён по IP;
- IP вашего VPS попал в deny/block list;
- сервис режет доступ по GEO.

Также бывает и обратная задача: вы хотите пускать через WARP не отдельные домены, а почти всё, оставляя обычным маршрутом только конкретные исключения.

### Решение
WARPER устанавливает:

- `sing-box`
- профиль **Cloudflare WARP**
- интерактивную утилиту `warper`

После этого вы можете выбрать один из двух сценариев:

- **Selective** — только отдельные домены идут через WARP
- **Global-Except** — всё идёт через WARP, кроме доменов-исключений

---

## 🔀 Режимы работы

### 1. Selective
Через WARP направляются **только выбранные домены**.

Используется файл:
```txt
/root/warper/domains.txt
```

Примеры:
- `openai.com`
- `chatgpt.com`
- `gemini.google.com`

В этом режиме можно использовать встроенные списки:
- Gemini
- ChatGPT

---

### 2. Global-Except
Через WARP идёт **всё, кроме доменов из списка исключений**.

Используется файл:
```txt
/root/warper/exclude_domains.txt
```

Примеры исключений:
- `ya.ru`
- `mail.ru`
- `my.local.domain`

В этом режиме встроенные списки Gemini и ChatGPT **не используются**, потому что логика обратная.

---

## ⚙️ Как это работает

### Режим Selective
Когда вы добавляете домен в WARPER:

1. домен попадает в список маршрутизации;
2. `kresd` отдаёт для него **fake-ip** из выбранной подсети;
3. трафик к этому fake-ip перехватывает `sing-box`;
4. `sing-box` отправляет его в туннель **Cloudflare WARP**;
5. сайт видит IP Cloudflare WARP, а не IP вашего VPS.

### Режим Global-Except
В этом режиме логика обратная:

1. запросы по умолчанию направляются в локальный DNS `sing-box`;
2. далее трафик уходит в WARP;
3. домены из `exclude_domains.txt` исключаются и идут обычным маршрутом.

---

## 📦 Системные требования

| Параметр | Поддерживаемые значения |
|---|---|
| **ОС** | Ubuntu 22.04, Ubuntu 24.04, Debian 11, Debian 12 |
| **Архитектура** | x86_64 (amd64), aarch64 (arm64), armv7l |
| **Права** | root |
| **Обязательное условие** | Уже установлен **AntiZapret VPN** |

Скрипт автоматически:

- проверяет ОС;
- определяет архитектуру;
- проверяет наличие AntiZapret;
- проверяет, не включён ли несовместимый режим `WARP_OUTBOUND=y`;
- ищет существующие ключи WARP;
- устанавливает `jq` для безопасной работы с JSON.

---

## ⚠️ Важная проверка совместимости с AntiZapret

Если в AntiZapret включён режим:

```txt
WARP_OUTBOUND=y
```

то WARPER **не будет работать вместе с ним**.

Скрипт установки проверяет файл:

```txt
/root/antizapret/setup
```

и если обнаруживает:

```txt
WARP_OUTBOUND=y
```

то установка прерывается с пояснением.

---

## 🔑 Поиск существующих ключей WARP

WARPER при установке пытается найти уже существующий профиль WARP в следующих местах:

1. `/root/warper/wgcf/wgcf-profile.conf`
2. `/root/wgcf-profile.conf`
3. `/etc/wireguard/warp.conf`

Если ключи найдены — они будут использованы повторно.  
Если нет — WARPER попробует зарегистрировать новый профиль через `wgcf`.

---

## ⚡ Установка в 1 команду

Подключитесь к серверу по SSH от имени `root` и выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```

Во время установки скрипт:

- проверит совместимость системы;
- убедится, что AntiZapret установлен;
- проверит, что в AntiZapret выключен `WARP_OUTBOUND`;
- установит `sing-box`;
- попытается найти существующие ключи WARP;
- при необходимости получит новые ключи WARP;
- предложит выбрать режим:
  - `selective`
  - `global-except`
- создаст конфигурацию;
- проверит конфиг через `sing-box check`;
- пропатчит DNS;
- в режиме `selective` предложит добавить готовые списки Gemini и ChatGPT.

После завершения установки просто выполните:

```bash
warper
```

> В некоторых случаях после применения изменений клиенту н��жно переподключиться к VPN.

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

### Синхронизация списков и переприменение патча
```bash
warper sync
```

### Открыть логи `sing-box`
```bash
journalctl -u sing-box -f
```

---

## ⚡ CLI-команды без меню

Теперь можно работать без интерактивного меню.

### Общие команды

#### Краткий статус
```bash
warper status
```

#### Диагностика
```bash
warper doctor
```

#### Переприменить патч
```bash
warper patch
```

#### Синхронизировать и применить
```bash
warper sync
```

---

### Команды для режима Selective

#### Добавить домен
```bash
warper add openai.com
```

#### Удалить домен
```bash
warper remove openai.com
```

#### Включить встроенный список Gemini
```bash
warper enable gemini
```

#### Выключить встроенный список Gemini
```bash
warper disable gemini
```

#### Включить встроенный список ChatGPT
```bash
warper enable chatgpt
```

#### Выключить встроенный список ChatGPT
```bash
warper disable chatgpt
```

---

### Команды для режима Global-Except

#### Добавить домен в исключения
```bash
warper exclude-add ya.ru
```

#### Удалить домен из исключений
```bash
warper exclude-remove ya.ru
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
- список исключений,
- настройки,
- ключи WARP.

---

## ❓ FAQ

<details>
<summary><b>Что делает WARPER?</b></summary>

WARPER — это менеджер доменной маршрутизации через Cloudflare WARP для сервера с AntiZapret.
</details>

<details>
<summary><b>Какие режимы есть?</b></summary>

Два режима:

- `selective` — через WARP идут только домены из `domains.txt`
- `global-except` — через WARP идёт всё, кроме доменов из `exclude_domains.txt`
</details>

<details>
<summary><b>Почему WARPER не ставится, если в AntiZapret включён WARP_OUTBOUND=y?</b></summary>

Потому что в этом случае сам AntiZapret уже использует Cloudflare WARP для outbound-трафика, и WARPER не сможет корректно работать вместе с этой схемой.
</details>

<details>
<summary><b>Откуда WARPER берёт существующие ключи WARP?</b></summary>

Проверяются:

1. `/root/warper/wgcf/wgcf-profile.conf`
2. `/root/wgcf-profile.conf`
3. `/etc/wireguard/warp.conf`
</details>

<details>
<summary><b>Нужно ли писать точку на конце домена?</b></summary>

Нет. Пишите как обычно:

```txt
chatgpt.com
```

WARPER сам корректно подготовит записи для DNS.
</details>

<details>
<summary><b>Что такое global-except?</b></summary>

Это режим, где через WARP идёт всё, кроме доменов из файла:

```txt
/root/warper/exclude_domains.txt
```
</details>

<details>
<summary><b>Нужны ли Gemini и ChatGPT списки в global-except?</b></summary>

Нет. В этом режиме они не используются.
</details>

<details>
<summary><b>Что делает warper doctor?</b></summary>

Проверяет:

- наличие AntiZapret;
- конфиги WARPER и sing-box;
- валидность `config.json`;
- активность `sing-box`, `kresd@1`, `kresd@2`;
- наличие патча в `kresd.conf`;
- синхронизацию доменных списков;
- наличие fake-подсети в маршрутах AntiZapret;
- интерфейс `singbox-tun`;
- iptables-правила;
- права доступа на чувствительные файлы;
- возможный конфликт fake-подсети.
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
   или использовать уже существующий:
   ```bash
   /etc/wireguard/warp.conf
   ```
3. повторно запустить установку.
</details>

---

## ⚠️ Известные ограничения

- Проект работает только с **IPv4**.
- Требуется стандартная структура AntiZapret в `/root/antizapret`.
- Если upstream AntiZapret изменит структуру `kresd.conf`, патч может потребовать адаптации.
- В режиме `global-except` логика патча `kresd.conf` отличается от `selective`.
- Если в AntiZapret включён `WARP_OUTBOUND=y`, WARPER не устанавливается.
- На некоторых серверах Cloudflare может ограничивать регистрацию WARP.
- Некоторые сервисы используют дополнительные CDN/endpoint-домены, которые может потребоваться добавить вручную.

---

## 🛠 Ручная установка

<details>
<summary>Нажмите, чтобы развернуть пошаговую ручную инструкцию</summary>

### Шаг 1. Проверка AntiZapret и несовместимого WARP_OUTBOUND

Проверьте, что AntiZapret уже установлен:

```bash
ls -l /root/antizapret/doall.sh
ls -l /root/antizapret/config/include-ips.txt
ls -l /root/antizapret/setup
```

Проверьте, что в файле `/root/antizapret/setup` выключен режим:

```bash
grep '^WARP_OUTBOUND=' /root/antizapret/setup
```

Ожидается:

```txt
WARP_OUTBOUND=n
```

Если там:

```txt
WARP_OUTBOUND=y
```

то WARPER ставить нельзя, пока этот режим не будет выключен.

---

### Шаг 2. Установка зависимостей

```bash
apt-get update
apt-get install -y curl wget jq iptables nano
```

---

### Шаг 3. Установка sing-box

```bash
curl -fsSL https://sing-box.app/install.sh | bash
```

---

### Шаг 4. Подготовка WARP-ключей

WARPER может использовать уже существующий профиль из:

- `/root/warper/wgcf/wgcf-profile.conf`
- `/root/wgcf-profile.conf`
- `/etc/wireguard/warp.conf`

Если у вас уже есть файл:

```bash
/etc/wireguard/warp.conf
```

проверьте в нём наличие:

- `PrivateKey`
- `Address`

Если готового профиля нет, можно сгенерировать новый через `wgcf`.

---

### Шаг 5. Генерация профиля через wgcf

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

### Шаг 6. Выбор режима работы

Создайте папку WARPER:

```bash
mkdir -p /root/warper/download
```

Выберите один из двух режимов:

#### Вариант A. Selective
```bash
MODE=selective
```

#### Вариант B. Global-Except
```bash
MODE=global-except
```

---

### Шаг 7. Создание конфигурации WARPER

Создайте файл:

```bash
cat > /root/warper/warper.conf <<EOF
SUBNET=198.18.0.0/24
TUN_IP=198.18.0.1/24
MODE=selective
EOF
chmod 600 /root/warper/warper.conf
```

Если хотите режим `global-except`, замените:

```txt
MODE=selective
```

на:

```txt
MODE=global-except
```

---

### Шаг 8. Создание файлов списков

#### Для режима Selective
```bash
cat > /root/warper/domains.txt <<EOF
# ==========================================
# СПИСОК ДОМЕНОВ ДЛЯ РЕЖИМА SELECTIVE
# ==========================================

# Пользовательские домены:
EOF
```

#### Для режима Global-Except
```bash
cat > /root/warper/exclude_domains.txt <<EOF
# ==========================================
# СПИСОК ИСКЛЮЧЕНИЙ ДЛЯ РЕЖИМА GLOBAL-EXCEPT
# Всё идёт через WARP, кроме доменов отсюда
# ==========================================

# Пользовательские исключения:
EOF
```

---

### Шаг 9. Подготовка конфигурации sing-box

Создайте папку:

```bash
mkdir -p /etc/sing-box
```

Откройте конфиг:

```bash
nano /etc/sing-box/config.json
```

Вставьте конфиг из файла `config.json.template` этого репозитория и подставьте:

- `Address`
- `PrivateKey`
- fake-подсеть
- TUN IP

После сохранения проверьте:

```bash
sing-box check -c /etc/sing-box/config.json
```

---

### Шаг 10. Создание systemd-службы sing-box

Создайте файл:

```bash
nano /etc/systemd/system/sing-box.service
```

Вставьте содержимое `sing-box.service` из репозитория.

Затем выполните:

```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
systemctl status sing-box --no-pager
```

---

### Шаг 11. Добавление fake-подсети в AntiZapret

```bash
echo "198.18.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

Если вы используете другую fake-подсеть, подставьте её.

---

### Шаг 12. Установка файлов WARPER

Скачайте или перенесите из репозитория файлы:

- `warper.sh`
- `uninstaller.sh`
- `config.json.template`
- `version`
- `sing-box.service`
- `warper-autopatch.service`

Выдайте права:

```bash
chmod +x /root/warper/warper.sh
chmod +x /root/warper/uninstaller.sh
```

Создайте симлинк:

```bash
ln -sf /root/warper/warper.sh /usr/local/bin/warper
```

---

### Шаг 13. Создание автопатча

Создайте файл:

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

### Шаг 14. Применение патча DNS

Запустите:

```bash
warper patch
```

---

### Шаг 15. Применение firewall-правил

```bash
iptables -C FORWARD -o singbox-tun -j ACCEPT 2>/dev/null || iptables -I FORWARD -o singbox-tun -j ACCEPT
iptables -C FORWARD -i singbox-tun -j ACCEPT 2>/dev/null || iptables -I FORWARD -i singbox-tun -j ACCEPT
```

---

### Шаг 16. Проверка

Проверьте:

```bash
warper status
warper doctor
systemctl status sing-box --no-pager
journalctl -u sing-box -n 30 --no-pager
```

---

### Шаг 17. Наполнение доменов

#### Если режим Selective
Добавьте домены вручную:

```bash
warper add openai.com
warper add chatgpt.com
```

Или включите встроенные списки:

```bash
warper enable gemini
warper enable chatgpt
```

#### Если режим Global-Except
Добавьте исключения:

```bash
warper exclude-add ya.ru
warper exclude-add mail.ru
```

</details>

---

## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию;
- расскажите другим пользователям AntiZapret;
- создавайте issue и pull request'ы, если нашли проблемы или хотите улучшить проект.
