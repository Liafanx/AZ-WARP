# 🚀 WARPER для AntiZapret VPN

Точечная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и других доменов через **Cloudflare WARP** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#-о-проекте)
2. [Как это работает](#-как-это-работает)
3. [Совместимость с VPN_WARP](#-совместимость-с-vpn_warp)
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

### Решение
WARPER устанавливает:

- `sing-box`
- профиль **Cloudflare WARP**
- интерактивную утилиту `warper`

После этого вы можете **точечно направлять только нужные домены через WARP**, не меняя остальной сценарий работы AntiZapret.

То есть получается гибридная схема:

- обычные блокировки обслуживает **AntiZapret**
- "проблемные" домены вроде нейросетей идут через **WARP**

---

## ⚙️ Как это работает

Когда вы добавляете домен в WARPER:

1. домен попадает в список маршрутизации;
2. `kresd` (только для клиентов AntiZapret) отдаёт для него **fake-ip** из выбранной подсети;
3. трафик к этому fake-ip перехватывает `sing-box`;
4. `sing-box` отправляет его в туннель **Cloudflare WARP**;
5. сайт видит IP Cloudflare WARP, а не IP вашего VPS.

По умолчанию используется fake-подсеть:

```txt
198.20.0.0/24
```

При установке или позже в настройках можно выбрать свою.

### Синхронизация WARP-ключей

WARPER автоматически синхронизируется с системным файлом `/etc/wireguard/warp.conf`:

- При каждом запуске проверяется наличие этого файла
- Если файл существует и содержит валидные ключи — они используются
- Это обеспечивает совместимость с `VPN_WARP=y` от AntiZapret
- Если системный файл появился после установки WARPER — ключи автоматически обновятся
- При изменении ключей автоматически перезапускается `kresd@1`

---

## 🔄 Совместимость с VPN_WARP

Начиная с версии 1.1.0, WARPER **полностью совместим** с настройкой `VPN_WARP=y` в AntiZapret.

### Как это работает

| Параметр в `/root/antizapret/setup` | Поведение |
|---|---|
| `ANTIZAPRET_WARP=n` + `VPN_WARP=n` | WARPER работает для клиентов AntiZapret |
| `ANTIZAPRET_WARP=n` + `VPN_WARP=y` | ✅ **WARPER работает только для AntiZapret-клиентов**, FullVPN-клиенты идут через встроенный WARP автора |
| `ANTIZAPRET_WARP=y` | ❌ **WARPER не может работать** — конфликт с встроенным WARP |

### Архитектура при VPN_WARP=y

```
AntiZapret-клиенты → kresd@1 → WARPER-домены → sing-box → WARP
                             → остальное → обычная маршрутизация

FullVPN-клиенты → всё → встроенный WARP автора
```

**Ключевой момент:** WARPER патчит только `kresd@1` (который обслуживает AntiZapret-клиентов), не затрагивая `kresd@2`. Это позволяет двум системам WARP работать параллельно без конфликтов.

### Автоматическое использование существующих ключей

При установке и во время работы WARPER автоматически ищет WARP-ключи в следующем порядке:

1. `/etc/wireguard/warp.conf` — ключи от встроенного WARP AntiZapret (приоритет)
2. `/root/warper/wgcf/wgcf-profile.conf` — существующий профиль WARPER
3. `/root/wgcf-profile.conf` — профиль в корневой директории

Если ключи найдены — они используются повторно. Если нет — генерируются новые.

### Переключение между режимами

При отключении `VPN_WARP` (изменении на `VPN_WARP=n`) необходимо перезапустить правила AntiZapret:

```bash
/root/antizapret/down.sh
/root/antizapret/up.sh
```

WARPER автоматически обнаружит эту ситуацию и покажет предупреждение в меню.

---

## 📦 Системные требования

| Параметр | Поддерживаемые значения |
|---|---|
| **ОС** | Ubuntu 22.04, Ubuntu 24.04, Debian 12, Debian 13 |
| **Архитектура** | x86_64 (amd64), aarch64 (arm64), armv7l |
| **Права** | root |
| **Обязательное условие** | Уже установлен **AntiZapret VPN** |

Скрипт автоматически:

- проверяет ОС,
- определяет архитектуру,
- проверяет наличие AntiZapret,
- проверяет настройку `ANTIZAPRET_WARP` и предупреждает о конфликтах,
- проверяет активные правила от `up.sh` и предупреждает о необходимости их перезапуска,
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
- проверит `ANTIZAPRET_WARP` — если включён, предупредит и предложит продолжить без активации;
- установит `sing-box`;
- найдёт существующие ключи WARP или сгенерирует новые;
- создаст конфигурацию;
- проверит конфиг через `sing-box check`;
- пропатчит DNS (только `kresd@1` для AntiZapret-клиентов);
- предложит добавить готовые списки доменов Gemini и ChatGPT.

После завершения установки просто выполните:

```bash
warper
```

> В некоторых случаях после применения изменений клиенту нужно переподключиться к VPN.

домены от сервисов Google https://github.com/v2fly/domain-list-community/blob/master/data%2Fgoogle-deepmind

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

- возвращать fake-ip для этого домена (только для AntiZapret-клиентов);
- перенаправлять соответствующий трафик в `sing-box`;
- отправлять его в WARP.

Остальной трафик продолжает работать как обычно через схему AntiZapret.
</details>

<details>
<summary><b>Можно ли использовать WARPER вместе с VPN_WARP=y?</b></summary>

**Да!** Начиная с версии 1.1.0, WARPER полностью совместим с `VPN_WARP=y`.

- AntiZapret-клиенты будут использовать WARPER для указанных доменов
- FullVPN-клиенты будут использовать встроенный WARP автора для всего трафика

Это достигается за счёт того, что WARPER патчит только `kresd@1`, не затрагивая `kresd@2`.
</details>

<details>
<summary><b>Почему при ANTIZAPRET_WARP=y WARPER не работает?</b></summary>

Когда `ANTIZAPRET_WARP=y`, весь трафик AntiZapret-клиентов уже направляется через встроенный WARP автора. WARPER использует тот же механизм (fake-ip + туннель), что создаёт конфликт.

**Решение:** используйте `ANTIZAPRET_WARP=n` + `VPN_WARP=y`, если хотите:
- Точечно маршрутизировать домены через WARPER для AntiZapret-клиентов
- Направлять весь трафик FullVPN через WARP автора
</details>

<details>
<summary><b>Что делать если появилось предупреждение "Требуется перезапуск правил AntiZapret"?</b></summary>

Это означает, что вы отключили `VPN_WARP` или `ANTIZAPRET_WARP`, но старые правила от `up.sh` ещё активны.

Выполните:
```bash
/root/antizapret/down.sh
/root/antizapret/up.sh
```

Это перезапустит правила AntiZapret и позволит WARPER использовать локальные ключи.
</details>

<details>
<summary><b>Откуда WARPER берёт WARP-ключи?</b></summary>

WARPER автоматически ищет ключи в следующем порядке:

1. **`/etc/wireguard/warp.conf`** — системный файл от AntiZapret (приоритет)
2. **Конфиг sing-box** — если ключи уже были установлены
3. **`/root/warper/wgcf/wgcf-profile.conf`** — локальный профиль WARPER

При каждом запуске WARPER проверяет системный файл и автоматически синхронизирует ключи, если они изменились. Текущий источник ключей отображается в главном меню.
</details>

<details>
<summary><b>Зачем нужен jq?</b></summary>

`jq` используется для безопасного чтения и изменения JSON-конфигурации `sing-box`.
Это надёжнее, чем парсить JSON через `grep/sed`, особенно если форматирование файла изменится.
Через `jq` безопасно меняются log level, MTU и другие параметры.
</details>

<details>
<summary><b>Что значит конфликт fake-подсети?</b></summary>

Если fake-подсеть уже используется:

- на локальных интерфейсах (кроме `singbox-tun`),
- в маршрутах (кроме маршрута через `singbox-tun`),
- в Docker-сетях,

то это может ломать маршрутизацию.
WARPER умеет это выявлять и предупреждать.
</details>

<details>
<summary><b>Как изменить MTU?</b></summary>

Через меню:

```bash
warper
```

Затем: `9` (Настройки) → `6` (Изменить MTU)

Допустимые значения: 1280–1500. По умолчанию: 1420.
</details>

<details>
<summary><b>Как изменить log level?</b></summary>

Через меню:

```bash
warper
```

Затем: `9` (Настройки) → `5` (Изменить log level)

Доступные уровни: `debug`, `info`, `warn`, `error`. По умолчанию: `info`.

Рекомендуется `warn` для production — это снижает нагрузку на CPU и объём логов.
</details>

---

## ⚠️ Известные ограничения

- Проект работает только с **IPv4**-сценарием.
- Ожидается стандартная структура AntiZapret в `/root/antizapret`.
- **Не работает** при включённом `ANTIZAPRET_WARP=y` — конфликт архитектур.
- **Совместим** с `VPN_WARP=y` — WARPER работает только для AntiZapret-клиентов.
- При переключении `VPN_WARP` необходимо перезапустить правила: `down.sh && up.sh`.
- Если upstream AntiZapret сильно изменит структуру `kresd.conf`, патч может потребовать адаптации.
- На некоторых серверах Cloudflare может блокировать регистрацию WARP.
- Некоторые сервисы используют дополнительные CDN/endpoint-домены, которые может потребоваться вручную добавить в список.
- Используются `iptables`; в экзотических nft-only конфигурациях может потребоваться ручная адаптация.
- `sing-box` работает в userspace — при высокой нагрузке (например, 4K-видео через sing-box) CPU может быть заметным. Рекомендуется использовать `warn` log level и MTU 1420.

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

Если у вас уже есть `/etc/wireguard/warp.conf` (от VPN_WARP=y), можно использовать ключи оттуда:

```bash
# Извлечение из существующего warp.conf
WARP_PRIVATE_KEY=$(grep '^PrivateKey' /etc/wireguard/warp.conf | awk -F'= ' '{print $2}')
WARP_ADDRESS=$(grep '^Address' /etc/wireguard/warp.conf | awk -F'= ' '{print $2}')
```

Или сгенерировать новые:

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
echo "198.20.0.0/24" >> /root/antizapret/config/include-ips.txt
/root/antizapret/doall.sh
```

### Шаг 7. Установка WARPER

```bash
mkdir -p /root/warper
cat > /root/warper/warper.conf <<EOF
SUBNET=198.20.0.0/24
TUN_IP=198.20.0.1/24
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
- Чтение `warper.conf` переведено на безопасный парсинг без `source`.
- README полностью обновлён и приведён к актуальному поведению проекта.
