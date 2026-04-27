# 🚀 WARPER для AntiZapret VPN

Точечная маршрутизация сервисов вроде **Gemini**, **ChatGPT** и других доменов через **Cloudflare WARP** или **внешний донор-сервер** на сервере с **AntiZapret VPN**.

Основной проект AntiZapret VPN: https://github.com/GubernievS/AntiZapret-VPN

---

## 📋 Оглавление

1. [О проекте](#-о-проекте)
2. [Как это работает](#-как-это-работает)
3. [Режимы работы](#-режимы-работы)
4. [Системные требования](#-системные-требования)
5. [Установка WARPER](#-установка-warper)
6. [Установка WARPERSLAVE](#-установка-warperslave)
7. [Быстрая проверка](#-быстрая-проверка)
8. [Команды управления](#-команды-управления)
9. [Удаление](#-удаление)
10. [FAQ](#-faq)
11. [Известные ограничения](#-известные-ограничения)
12. [Документация](#-документация)

---

## ℹ️ О проекте

### Проблема

У вас настроен сервер с **AntiZapret**. Заблокированные сайты открываются. Но при попытке зайти на **Gemini**, **ChatGPT** или другие AI-сервисы — ошибка:

- сервис недоступен в вашей стране
- IP вашего VPS заблокирован
- сервис режет доступ по GEO

### Решение

WARPER позволяет **точечно направлять только нужные домены** через Cloudflare WARP или внешний донор-сервер, не меняя остальной сценарий работы AntiZapret.

Гибридная схема:

- обычные блокировки → **AntiZapret**
- "проблемные" домены → **WARP** или **донор-сервер**

---

## ⚙️ Как это работает

Когда вы добавляете домен в WARPER:

1. Домен попадает в список маршрутизации
2. `kresd` (только для AntiZapret-клиентов) отдаёт для него **fake-ip** из подсети `198.20.0.0/24`
3. Трафик к fake-ip перехватывает `sing-box`
4. `sing-box` отправляет его в **WARP-туннель** или на **донор-сервер**
5. Сайт видит IP Cloudflare/донора, а не IP вашего VPS

---

## 🔀 Режимы работы

### Режим WARP (локальный)

```
Клиент → AntiZapret → kresd → fake-ip → sing-box → Cloudflare WARP → Интернет
```

Трафик указанных доменов идёт через Cloudflare WARP напрямую с вашего сервера.

### Режим Slave (донор-сервер)

```
Сервер 1 (WARPER)                    Сервер 2 (WARPERSLAVE)
Клиент → AntiZapret → kresd →        → sing-box (ss-in) →
  fake-ip → sing-box (ss-out) ──────→   direct / WARP → Интернет
```

Трафик идёт через второй сервер (донор) по зашифрованному Shadowsocks-каналу. На доноре трафик может выходить напрямую (Direct) или через WARP.

**Когда нужен Slave:**
- IP основного сервера заблокирован сервисом
- Нужен выход через конкретную страну/IP
- WARP на основном сервере не работает

### Совместимость с VPN_WARP

| Параметр | Поведение |
|---|---|
| `ANTIZAPRET_WARP=n` + `VPN_WARP=n` | WARPER работает для AntiZapret-клиентов |
| `ANTIZAPRET_WARP=n` + `VPN_WARP=y` | ✅ WARPER для AntiZapret, FullVPN через встроенный WARP |
| `ANTIZAPRET_WARP=y` | ❌ Конфликт — WARPER не работает |

---

## 📦 Системные требования

### WARPER (основной сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 22.04/24.04, Debian 12/13 |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Установлен **AntiZapret VPN** |

### WARPERSLAVE (донор-сервер)

| Параметр | Значение |
|---|---|
| **ОС** | Ubuntu 20.04+, Debian 10+ |
| **Архитектура** | x86_64, aarch64, armv7l |
| **Права** | root |
| **Обязательно** | Открытый порт (по умолчанию 8444) |

---

## ⚡ Установка WARPER

На сервере с AntiZapret от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install.sh | bash
```

После установки:

```bash
warper
```

> После установки warper клиентам нужно переподключиться по OpenVPN к серверу чтобы, Fake подсеть запушилась в route. Если вы используете AWG/WG, нужно вписать в конфиг новую подсеть/ выдать конфиг с учетом нового IP в Include IP. Аналогично с роутерами где Route прописываются вручную.

---

## 🔧 Установка WARPERSLAVE

На **втором сервере** (донор) от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/install-slave.sh | bash
```

Установщик спросит:
- **Режим**: Direct (трафик через IP донора) или WARP (через Cloudflare)
- **Порт**: по умолчанию 8444
- **Ключ Shadowsocks**: сгенерировать новый или ввести существующий

После установки будут показаны данные для настройки основного сервера:

```
IP:    <IPv4 донор-сервера>
Порт:  8444
Ключ:  <ключ Shadowsocks>
```

### Подключение WARPER к донору

На основном сервере:

```bash
warper
```

→ `Настройки (9)` → `Режим маршрутизации (7)` → `Slave (2)`

Введите IP, порт и ключ донор-сервера.

### Управление донором

```bash
warperslave          # интерактивное меню
warperslave status   # статус
warperslave switch   # переключить Direct ↔ WARP
warperslave doctor   # диагностика
warperslave update   # обновление
```

---

## ✅ Быстрая проверка

### WARPER

```bash
warper doctor    # полная диагностика
warper status    # краткий статус
```

### WARPERSLAVE

```bash
warperslave doctor
warperslave status
```

---

## 🧰 Команды управления

### WARPER

```bash
warper                      # главное меню
warper add openai.com       # добавить домен
warper remove openai.com    # удалить домен
warper enable gemini        # включить список Gemini
warper enable chatgpt       # включить список ChatGPT
warper disable gemini       # выключить список
warper sync                 # синхронизировать и применить
warper patch                # переприменить патч DNS
warper doctor               # диагностика
warper status               # краткий статус
```

### WARPERSLAVE

```bash
warperslave                 # главное меню
warperslave status          # статус
warperslave switch          # переключить режим
warperslave port            # изменить порт
warperslave key             # изменить ключ
warperslave doctor          # диагностика
warperslave update          # обновление
warperslave uninstall       # удаление
```

---

## 🗑 Удаление

### WARPER

```bash
warper
# Затем: U
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstaller.sh | bash
```

### WARPERSLAVE

```bash
warperslave
# Затем: U
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/Liafanx/AZ-WARP/main/uninstall-slave.sh | bash
```

---

## ❓ FAQ

<details>
<summary><b>Что делает WARPER?</b></summary>

WARPER — менеджер доменной маршрутизации. Когда вы добавляете домен, система возвращает для него fake-ip, перенаправляет трафик в sing-box и отправляет его в WARP или на донор-сервер. Остальной трафик работает через AntiZapret как обычно. Пока что не работает для типа подключения FullVPN, так как патч kresd не затрагивает модуль DNS (kresd@2) который отвечает за полный VPN. Данный режим пока в разработке.
</details>

<details>
<summary><b>Можно ли использовать WARPER вместе с VPN_WARP=y?</b></summary>

Да. AntiZapret-клиенты используют WARPER, FullVPN-клиенты — встроенный WARP. WARPER патчит только `kresd@1`, не затрагивая `kresd@2`.
</details>

<details>
<summary><b>Зачем нужен WARPERSLAVE?</b></summary>

Если IP основного сервера заблокирован сервисом, или WARP на нём не работает, или нужен выход через конкретную страну — трафик можно направить через второй сервер (донор). На доноре трафик может выходить напрямую или через WARP.
</details>

<details>
<summary><b>Можно ли WARPER и WARPERSLAVE на одном сервере?</b></summary>

Да. Они используют разные экземпляры sing-box с разными конфигами и портами, не конфликтуют.
</details>

<details>
<summary><b>Что значит конфликт fake-подсети?</b></summary>

Если fake-подсеть уже используется на локальных интерфейсах (кроме singbox-tun), в маршрутах или Docker-сетях — это может ломать маршрутизацию. WARPER умеет это выявлять и предупреждать.
</details>

<details>
<summary><b>Как переключаться между WARP и Slave?</b></summary>

`warper` → `Настройки (9)` → `Режим маршрутизации (7)`. При переключении обратно на Slave предлагается использовать сохранённое подключение или ввести новый сервер.
</details>

<details>
<summary><b>Как изменить MTU / log level?</b></summary>

`warper` → `Настройки (9)` → `Изменить MTU (6)` или `Изменить log level (5)`.
</details>

---

## ⚠️ Известные ограничения

- Работает только с **IPv4**
- Ожидается стандартная структура AntiZapret в `/root/antizapret`
- **Не работает** при `ANTIZAPRET_WARP=y`
- **Совместим** с `VPN_WARP=y`
- При переключении `VPN_WARP` нужен перезапуск: `down.sh && up.sh` или лучше reboot сервера.
- Используются `iptables`; nft-only конфигурации могут требовать адаптации
- `sing-box` работает в userspace — при высокой нагрузке CPU может быть заметным

---

## 📚 Документация

Расширенная документация доступна в директории [`docs/`](docs/):

- [Ручная установка WARPER](docs/manual-install.md)
- [Ручная установка WARPERSLAVE](docs/manual-install-slave.md)
- [Архитектура и совместимость с VPN_WARP](docs/architecture.md)
- [Устранение неполадок](docs/troubleshooting.md)

---

## ⭐ Поддержать проект

Если проект помог вам:

- поставьте ⭐ репозиторию
- расскажите другим пользователям AntiZapret
- создавайте issue и pull request'ы
