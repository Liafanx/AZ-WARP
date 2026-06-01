"""
warper_api.py
Обёртка над CLI командами утилиты warper.
Возвращает структурированные данные (dict) с обработкой ошибок.
"""

import json
import os
import re
import subprocess
import shlex
from typing import Any


WARPER_BIN = "/usr/local/bin/warper"
SINGBOX_LOG_UNIT = "sing-box"


# ===== Базовые помощники =====

def _run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    """Запускает команду, возвращает (rc, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Команда не завершилась за отведённое время"
    except FileNotFoundError as e:
        return 127, "", f"Файл не найден: {e}"
    except Exception as e:
        return 1, "", str(e)


def _run_warper(*args: str, timeout: int = 60) -> tuple[bool, str, str]:
    """Запускает warper с аргументами. Возвращает (ok, stdout, stderr)."""
    cmd = [WARPER_BIN, *args]
    rc, out, err = _run(cmd, timeout=timeout)
    return rc == 0, out.strip(), err.strip()


# ===== Статус =====

def get_status() -> dict[str, Any]:
    """
    Возвращает полный статус WARPER через `warper status json`.
    """
    ok, out, err = _run_warper("status", "json", timeout=30)
    if not ok:
        return {"error": err or "не удалось получить статус", "raw": out}
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        return {"error": f"невалидный JSON: {e}", "raw": out}


def get_doctor() -> list[dict[str, Any]]:
    """
    Запускает `warper doctor` и парсит результат построчно.
    Возвращает список { 'status': 'ok'|'warn'|'error'|'info', 'text': '...' }.
    """
    ok, out, _ = _run_warper("doctor", timeout=60)
    results: list[dict[str, Any]] = []
    # Удаляем ANSI-цвета
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    for raw_line in out.splitlines():
        line = ansi.sub("", raw_line).strip()
        if not line:
            continue
        # Игнорируем рамки и заголовки
        if line.startswith("==") or line.startswith("--") or "WARPER DOCTOR" in line:
            continue
        if "Диагностика завершена" in line:
            continue

        status = "info"
        if line.startswith("✔"):
            status = "ok"
        elif line.startswith("✘"):
            status = "error"
        elif line.startswith("!"):
            status = "warn"

        # Убираем символ статуса
        text = re.sub(r"^[✔✘!]\s*", "", line)
        results.append({"status": status, "text": text})
    return results


# ===== Логи =====

def get_logs(lines: int = 100, level_filter: str | None = None) -> list[dict[str, Any]]:
    """
    Возвращает логи sing-box. level_filter: None | 'INFO' | 'WARN' | 'ERROR'.
    """
    if lines < 1:
        lines = 100
    if lines > 2000:
        lines = 2000

    ok, out, _ = _run_warper("logs", str(lines), timeout=15)
    if not ok:
        return []

    parsed: list[dict[str, Any]] = []
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            continue

        # Определяем уровень
        level = "INFO"
        upper = line.upper()
        if "ERROR" in upper or " ERR " in upper:
            level = "ERROR"
        elif "WARN" in upper:
            level = "WARN"
        elif "DEBUG" in upper:
            level = "DEBUG"

        if level_filter and level != level_filter:
            continue

        parsed.append({"level": level, "text": line})
    return parsed


# ===== Домены =====

def get_domains(filter_type: str | None = None, search: str | None = None) -> list[dict[str, Any]]:
    """
    Возвращает список доменов через `warper domainslist`.
    filter_type: None | 'user' | 'gemini' | 'chatgpt'.
    """
    ok, out, _ = _run_warper("domainslist", timeout=10)
    if not ok:
        return []

    domains = []
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        name, dtype, enabled = parts
        if filter_type and dtype != filter_type:
            continue
        if search and search.lower() not in name.lower():
            continue
        domains.append({
            "name": name,
            "type": dtype,
            "enabled": enabled == "1",
        })
    return domains


def add_domain(domain: str) -> tuple[bool, str]:
    """Добавляет домен через `warper add`."""
    domain = domain.strip().lower()
    if not _validate_domain_format(domain):
        return False, f"Некорректный формат домена: {domain}"
    ok, out, err = _run_warper("add", domain, timeout=30)
    msg = (out or err).strip()
    return ok, msg


def add_domains_bulk(domains: list[str]) -> dict[str, Any]:
    """Массово добавляет домены."""
    added: list[str] = []
    skipped: list[str] = []
    errors: list[dict[str, str]] = []

    for raw in domains:
        d = raw.strip().lower()
        if not d or d.startswith("#"):
            continue
        if not _validate_domain_format(d):
            errors.append({"domain": d, "error": "некорректный формат"})
            continue
        ok, out, err = _run_warper("add", d, timeout=15)
        if ok:
            if "уже есть" in out.lower() or "already" in out.lower():
                skipped.append(d)
            else:
                added.append(d)
        else:
            errors.append({"domain": d, "error": (err or out).strip()[:200]})

    return {
        "added_count": len(added),
        "skipped_count": len(skipped),
        "error_count": len(errors),
        "added": added,
        "skipped": skipped,
        "errors": errors,
    }


def remove_domain(domain: str) -> tuple[bool, str]:
    """Удаляет домен через `warper remove`."""
    ok, out, err = _run_warper("remove", domain, timeout=60)  # было 30
    return ok, (out or err).strip()


def toggle_list(list_name: str, enable: bool) -> tuple[bool, str]:
    """Включает или выключает встроенный список (gemini/chatgpt)."""
    if list_name not in ("gemini", "chatgpt"):
        return False, "Неизвестный список"
    cmd = "enable" if enable else "disable"
    ok, out, err = _run_warper(cmd, list_name, timeout=60)  # было 30
    return ok, (out or err).strip()


def sync_domains() -> tuple[bool, str]:
    """Синхронизирует домены и патчит kresd."""
    ok, out, err = _run_warper("sync", timeout=120)  # было 60
    return ok, (out or err).strip()


def _validate_domain_format(domain: str) -> bool:
    """
    Проверяет формат домена:
    - минимум 2 уровня (example.com)
    - только латиница, цифры, точка, дефис
    - не начинается/заканчивается дефисом или точкой
    """
    if not domain or len(domain) > 253:
        return False
    if "." not in domain:
        return False
    parts = domain.split(".")
    if len(parts) < 2:
        return False
    if len(parts[-1]) < 2:  # TLD минимум 2 символа
        return False
    for part in parts:
        if not part or len(part) > 63:
            return False
        if part.startswith("-") or part.endswith("-"):
            return False
        if not re.match(r"^[a-z0-9_-]+$", part):
            return False
    return True

def get_user_domains_block() -> str:
    """
    Возвращает только пользовательский блок domains.txt
    БЕЗ служебного маркера '# Пользовательские домены:'.
    
    Сохраняет пользовательские комментарии и пустые строки.
    Исключает:
      - стандартную шапку файла (===== ... =====)
      - служебный маркер '# Пользовательские домены:'
      - блоки GEMINI/CHATGPT целиком
    """
    domains_file = "/root/warper/domains.txt"
    if not os.path.exists(domains_file):
        return ""
    try:
        with open(domains_file, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return ""

    lines = content.splitlines()
    user_lines: list[str] = []
    in_block = False
    skip_header = True
    header_marker = "# Пользовательские домены:"

    for ln in lines:
        # Пропускаем шапку до маркера "# Пользовательские домены:"
        if skip_header:
            if ln.strip() == header_marker:
                skip_header = False
                # сам маркер НЕ включаем в результат
            continue

        # Блоки GEMINI/CHATGPT — пропускаем целиком
        if re.match(r"^# --- [A-Z0-9_]+ ---$", ln.strip()):
            in_block = True
            continue
        if re.match(r"^# --- END [A-Z0-9_]+ ---$", ln.strip()):
            in_block = False
            continue
        if in_block:
            continue

        user_lines.append(ln)

    # Обрезаем хвостовые пустые строки
    while user_lines and not user_lines[-1].strip():
        user_lines.pop()

    return "\n".join(user_lines)
    
def save_user_domains_block(text: str) -> tuple[bool, str]:
    """
    Сохраняет пользовательский блок domains.txt с комментариями.
    Валидирует только строки-домены.
    Служебный маркер '# Пользовательские домены:' добавляется автоматически.
    Блоки GEMINI/CHATGPT остаются нетронутыми.
    """
    domains_file = "/root/warper/domains.txt"
    header_marker = "# Пользовательские домены:"

    # На всякий случай отфильтруем строку с маркером если пользователь её ввёл вручную
    raw_lines = [
        ln for ln in text.splitlines()
        if ln.strip() != header_marker
    ]

    # Валидация - только строки-домены, комментарии и пустые пропускаем
    invalid: list[str] = []
    valid_count = 0
    for raw in raw_lines:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if not _validate_domain_format(s.lower()):
            invalid.append(s)
        else:
            valid_count += 1

    if invalid:
        msg = "Некорректные домены: " + ", ".join(invalid[:5])
        if len(invalid) > 5:
            msg += f" (и ещё {len(invalid) - 5})"
        return False, msg

    # Обрезаем хвостовые пустые строки
    while raw_lines and not raw_lines[-1].strip():
        raw_lines.pop()

    # Читаем существующий файл, сохраняем блоки GEMINI/CHATGPT
    gemini_block: list[str] = []
    chatgpt_block: list[str] = []
    if os.path.exists(domains_file):
        try:
            with open(domains_file, "r", encoding="utf-8") as f:
                existing = f.read().splitlines()
        except OSError:
            existing = []

        block: str | None = None
        for ln in existing:
            stripped = ln.strip()
            if stripped == "# --- GEMINI ---":
                block = "gemini"
                gemini_block.append(ln)
                continue
            if stripped == "# --- END GEMINI ---":
                gemini_block.append(ln)
                block = None
                continue
            if stripped == "# --- CHATGPT ---":
                block = "chatgpt"
                chatgpt_block.append(ln)
                continue
            if stripped == "# --- END CHATGPT ---":
                chatgpt_block.append(ln)
                block = None
                continue
            if block == "gemini":
                gemini_block.append(ln)
            elif block == "chatgpt":
                chatgpt_block.append(ln)

    # Собираем файл
    out_lines = [
        "# ==========================================",
        "# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP",
        "# Строки, начинающиеся с '#', игнорируются.",
        "# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT",
        "# ==========================================",
        "",
        header_marker,  # служебный маркер - всегда добавляем сами
    ]
    out_lines.extend(raw_lines)
    if gemini_block:
        out_lines.append("")
        out_lines.extend(gemini_block)
    if chatgpt_block:
        out_lines.append("")
        out_lines.extend(chatgpt_block)

    try:
        with open(domains_file, "w", encoding="utf-8") as f:
            f.write("\n".join(out_lines) + "\n")
    except OSError as e:
        return False, f"Ошибка записи: {e}"

    ok_sync, out, err = _run_warper("sync", timeout=120)
    if not ok_sync:
        return False, f"Файл сохранён, но sync упал: {(err or out).strip()}"

    return True, f"Сохранено {valid_count} доменов, синхронизация выполнена"


# ===== IP-подсети =====

def get_ip_ranges(search: str | None = None) -> list[dict[str, str]]:
    """Возвращает список CIDR из ip-ranges.txt."""
    ok, out, _ = _run_warper("iplist", timeout=10)
    if not ok:
        return []
    ranges = []
    for line in out.splitlines():
        cidr = line.strip()
        if not cidr:
            continue
        if search and search not in cidr:
            continue
        ranges.append({"cidr": cidr})
    return ranges


def get_active_ip_routes() -> list[str]:
    """Возвращает список применённых маршрутов."""
    ok, out, _ = _run_warper("iproutes", timeout=10)
    if not ok:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def add_ip_range(cidr: str) -> tuple[bool, str]:
    """Добавляет CIDR. Если без маски — добавится /32."""
    cidr = cidr.strip()
    # Если без маски - предполагаем /32
    if "/" not in cidr:
        cidr = f"{cidr}/32"
    if not _validate_cidr_format(cidr):
        return False, f"Некорректный формат CIDR: {cidr}"
    ok, out, err = _run_warper("ipadd", cidr, timeout=30)
    return ok, (out or err).strip()


def add_ip_ranges_bulk(cidrs: list[str]) -> dict[str, Any]:
    """Массово добавляет CIDR."""
    added: list[str] = []
    skipped: list[str] = []
    errors: list[dict[str, str]] = []

    for raw in cidrs:
        c = raw.strip()
        if not c or c.startswith("#"):
            continue
        if "/" not in c:
            c = f"{c}/32"
        if not _validate_cidr_format(c):
            errors.append({"cidr": c, "error": "некорректный формат"})
            continue
        ok, out, err = _run_warper("ipadd", c, timeout=15)
        if ok:
            if "уже есть" in out.lower():
                skipped.append(c)
            else:
                added.append(c)
        else:
            errors.append({"cidr": c, "error": (err or out).strip()[:200]})

    return {
        "added_count": len(added),
        "skipped_count": len(skipped),
        "error_count": len(errors),
        "added": added,
        "skipped": skipped,
        "errors": errors,
    }


def remove_ip_range(cidr: str) -> tuple[bool, str]:
    """Удаляет CIDR."""
    ok, out, err = _run_warper("ipremove", cidr, timeout=30)
    return ok, (out or err).strip()


def sync_ip_ranges() -> tuple[bool, str]:
    """Синхронизирует kernel routes с файлом."""
    ok, out, err = _run_warper("ipsync", timeout=60)
    return ok, (out or err).strip()


def set_ip_route_mode(mode: str) -> tuple[bool, str]:
    """Меняет режим IP-маршрутов: antizapret | all_vpn | all."""
    if mode not in ("antizapret", "all_vpn", "all"):
        return False, "Недопустимый режим"
    ok, out, err = _run_warper("iproutemode", mode, timeout=30)
    return ok, (out or err).strip()


def set_ip_export(enable: bool) -> tuple[bool, str]:
    """Включает/выключает экспорт CIDR в AntiZapret."""
    val = "on" if enable else "off"
    ok, out, err = _run_warper("ipexport", val, timeout=30)
    return ok, (out or err).strip()


def _validate_cidr_format(cidr: str) -> bool:
    """Проверяет формат A.B.C.D/M с валидными октетами."""
    m = re.match(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$", cidr)
    if not m:
        return False
    octets = [int(x) for x in m.groups()[:4]]
    mask = int(m.group(5))
    for o in octets:
        if o > 255:
            return False
    if not 1 <= mask <= 32:
        return False
    # Не loopback / multicast / link-local
    if octets[0] in (0, 127) or octets[0] >= 224:
        return False
    if octets[0] == 169 and octets[1] == 254:
        return False
    return True


# ===== Sing-box =====

def singbox_action(action: str) -> tuple[bool, str]:
    """start / stop / restart / enable / disable."""
    if action not in ("start", "stop", "restart", "enable", "disable"):
        return False, "Недопустимое действие"
    # enable/disable - быстрые, start/stop/restart - могут быть медленнее
    timeout = 30 if action in ("enable", "disable") else 90
    rc, out, err = _run(["systemctl", action, "sing-box"], timeout=timeout)
    if rc != 0:
        return False, (err or out).strip() or f"sing-box {action} failed"
    return True, f"sing-box {action}: ok"

# ===== WARPER toggle =====

def toggle_warper() -> tuple[bool, str]:
    """Включает или выключает WARPER целиком."""
    ok, out, err = _run_warper("toggle", timeout=180)  # было 60
    return ok, (out or err).strip()


def patch_kresd() -> tuple[bool, str]:
    """Применяет патч DNS."""
    ok, out, err = _run_warper("patch", timeout=30)
    return ok, (out or err or "kresd пропатчен").strip()


# ===== Настройки =====

def set_log_level(level: str) -> tuple[bool, str]:
    if level not in ("debug", "info", "warn", "error"):
        return False, "Недопустимый log level"
    ok, out, err = _run_warper("loglevel", level, timeout=30)
    return ok, (out or err).strip()


def set_mtu(mtu: int) -> tuple[bool, str]:
    if not 1280 <= mtu <= 1500:
        return False, "MTU должен быть от 1280 до 1500"
    ok, out, err = _run_warper("mtu", str(mtu), timeout=30)
    return ok, (out or err).strip()


def set_subnet(subnet: str) -> tuple[bool, str]:
    """Меняет fake-подсеть."""
    if not re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.0/\d{1,2}$", subnet):
        return False, "Формат: X.X.X.0/M (например 198.20.0.0/24)"
    ok, out, err = _run_warper("subnet", subnet, timeout=300)  # было 120
    return ok, (out or err).strip()


def set_autopatch(enable: bool) -> tuple[bool, str]:
    val = "on" if enable else "off"
    ok, out, err = _run_warper("autopatch", val, timeout=15)
    return ok, (out or err).strip()


def set_fullvpn(enable: bool) -> tuple[bool, str]:
    val = "on" if enable else "off"
    ok, out, err = _run_warper("fullvpn", val, timeout=30)
    return ok, (out or err).strip()


# ===== Режим маршрутизации =====

def switch_to_warp(key_source: str = "") -> tuple[bool, str]:
    """key_source: '' | 'system' | 'wgcf' | 'root' | 'generate'."""
    args = ["mode", "warp"]
    if key_source:
        if key_source not in ("system", "wgcf", "root", "generate"):
            return False, "Недопустимый источник ключей"
        args.append(key_source)
    timeout = 180 if key_source == "generate" else 120  # было 90/60
    ok, out, err = _run_warper(*args, timeout=timeout)
    return ok, (out or err).strip()


def switch_to_slave(server: str, port: str | int, password: str) -> tuple[bool, str]:
    """Переключает на режим Slave."""
    server = server.strip()
    password = password.strip()

    # Валидация порта
    try:
        port_int = int(str(port).strip())
    except ValueError:
        return False, "Порт должен быть числом"
    if not 1 <= port_int <= 65535:
        return False, "Порт должен быть от 1 до 65535"

    # Валидация сервера
    if not server:
        return False, "Адрес сервера не может быть пустым"
    # IP или валидный домен (RFC 1123)
    ip_re = r"^(?:\d{1,3}\.){3}\d{1,3}$"
    domain_re = r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if re.match(ip_re, server):
        # Проверка октетов
        octets = server.split(".")
        for o in octets:
            if int(o) > 255:
                return False, "Некорректный IP-адрес"
    elif not re.match(domain_re, server):
        return False, "Некорректный адрес — IP или домен (example.com)"

    # Валидация ключа Shadowsocks
    if not password:
        return False, "Ключ Shadowsocks не может быть пустым"
    # Минимум 16 символов (короткие ключи небезопасны)
    if len(password) < 16:
        return False, "Ключ Shadowsocks должен быть минимум 16 символов"
    if len(password) > 256:
        return False, "Ключ Shadowsocks слишком длинный (>256 симв.)"

    ok, out, err = _run_warper("mode", "slave", server, str(port_int), password, timeout=120)
    return ok, (out or err).strip()


def switch_to_wg(conf_path: str) -> tuple[bool, str]:
    """Переключает на WG режим из указанного конфига."""
    conf_path = conf_path.strip()
    if not conf_path:
        return False, "Не указан путь к конфигу"
    if not os.path.isfile(conf_path):
        return False, f"Файл не найден: {conf_path}"
    ok, out, err = _run_warper("mode", "wg", conf_path, timeout=120)  # было 60
    return ok, (out or err).strip()


# ===== WARP-ключи =====

def list_warp_keys() -> list[dict[str, Any]]:
    """Возвращает доступные источники WARP-ключей."""
    ok, out, _ = _run_warper("warpkey", "list", timeout=10)
    if not ok:
        return []
    keys = []
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 4:
            continue
        keys.append({
            "source": parts[0],
            "path": parts[1],
            "address": parts[2],
            "is_current": parts[3] == "1",
        })
    return keys


# ===== WG-конфиги =====

def list_wg_configs() -> list[dict[str, str]]:
    """Возвращает список WG-конфигов в /root/ и /root/warper/."""
    ok, out, _ = _run_warper("wgconfig", "list", timeout=10)
    if not ok:
        return []
    configs = []
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 2:
            continue
        configs.append({
            "path": parts[0],
            "endpoint": parts[1],
            "name": os.path.basename(parts[0]),
        })
    return configs


def upload_wg_config(filename: str, content: str) -> tuple[bool, str, str]:
    """
    Сохраняет загруженный WG-конфиг в /root/warper/<safe_name>.
    Возвращает (ok, message, saved_path).
    """
    # Очищаем имя файла
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(filename))
    if not safe_name.endswith(".conf"):
        safe_name += ".conf"

    target_dir = "/root/warper"
    os.makedirs(target_dir, exist_ok=True)
    target_path = os.path.join(target_dir, safe_name)

    # Базовая валидация содержимого
    if "[Peer]" not in content or "Endpoint" not in content or "PublicKey" not in content:
        return False, "Файл не похож на WireGuard конфиг", ""

    # Cloudflare WARP - запрещено
    cf_markers = [
        "engage.cloudflareclient.com",
        "162.159.192.1",
        "162.159.193.1",
        "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
    ]
    for m in cf_markers:
        if m in content:
            return False, "Это Cloudflare WARP конфиг, не подходит для режима WG", ""

    try:
        with open(target_path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(target_path, 0o600)
    except OSError as e:
        return False, f"Ошибка сохранения: {e}", ""

    return True, f"Конфиг сохранён: {target_path}", target_path

# ===== Редактирование ip-ranges.txt напрямую =====

def get_ip_ranges_content() -> str:
    """Возвращает содержимое ip-ranges.txt (без шапки)."""
    ok, out, _ = _run_warper("ipranges", "list", timeout=10)
    if not ok:
        return ""
    return out


def save_ip_ranges_content(text: str) -> tuple[bool, str]:
    """
    Сохраняет ip-ranges.txt и запускает sync.
    Сохраняет пользовательские комментарии (#) и пустые строки.
    Валидирует только CIDR-строки.
    """
    lines = text.splitlines()
    valid_count = 0
    invalid: list[str] = []

    for raw in lines:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue  # пустые и комментарии пропускаем при валидации
        cidr = s if "/" in s else f"{s}/32"
        if not _validate_cidr_format(cidr):
            invalid.append(s)
        else:
            valid_count += 1

    if invalid:
        msg = "Некорректные CIDR: " + ", ".join(invalid[:5])
        if len(invalid) > 5:
            msg += f" (и ещё {len(invalid) - 5})"
        return False, msg

    # Передаём через stdin как есть — bash сохранит комментарии
    content = text if text.endswith("\n") else text + "\n"
    try:
        proc = subprocess.run(
            [WARPER_BIN, "ipranges", "save"],
            input=content,
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            return False, (proc.stderr or proc.stdout).strip() or "Ошибка сохранения"
        return True, f"Сохранено {valid_count} подсетей"
    except subprocess.TimeoutExpired:
        return False, "Таймаут операции"
    except Exception as e:
        return False, str(e)

# ===== ПРОВЕРКА ОБНОВЛЕНИЙ =====

_version_cache: dict[str, Any] = {"checked_at": 0, "data": None}
_VERSION_CACHE_TTL = 60  # 1 минута


def check_for_updates(force: bool = False) -> dict[str, Any]:
    """
    Проверяет наличие новой версии WARPER на GitHub.
    Результат кэшируется на _VERSION_CACHE_TTL секунд.
    force=True — игнорировать кэш.
    """
    import time
    now = time.time()

    # Используем кэш если можно
    if not force and _version_cache["data"] and \
       (now - _version_cache["checked_at"] < _VERSION_CACHE_TTL):
        return _version_cache["data"]

    result: dict[str, Any] = {
        "current": "0.0.0",
        "remote": None,
        "update_available": False,
        "error": None,
    }

    # Текущая версия из файла (читаем каждый раз заново)
    version_file = "/root/warper/version"
    if os.path.exists(version_file):
        try:
            with open(version_file, "r") as f:
                result["current"] = f.read().strip() or "0.0.0"
        except OSError:
            pass

    # Версия с GitHub
    branch = _detect_warper_branch()
    # ВАЖНО: добавляем рандомный query чтобы обойти CDN-кэш GitHub
    url = f"https://raw.githubusercontent.com/Liafanx/AZ-WARP/{branch}/version?_={int(now)}"

    try:
        import urllib.request
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "warper-web/1.0",
                "Cache-Control": "no-cache",
                "Pragma": "no-cache",
            },
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            remote = resp.read().decode("utf-8").strip()
            if re.match(r"^\d+\.\d+\.\d+$", remote):
                result["remote"] = remote
                result["update_available"] = _version_gt(remote, result["current"])
    except Exception as e:
        result["error"] = str(e)[:200]
        # При ошибке - не кэшируем ошибку надолго, чтобы пользователь мог быстро повторить
        _version_cache["checked_at"] = now - _VERSION_CACHE_TTL + 10  # повторить через 10 сек
        _version_cache["data"] = result
        return result

    _version_cache["checked_at"] = now
    _version_cache["data"] = result
    return result

def _detect_warper_branch() -> str:
    """Извлекает ветку из REPO_URL в warper.sh (default: main)."""
    warper_sh = "/root/warper/warper.sh"
    if os.path.exists(warper_sh):
        try:
            with open(warper_sh, "r") as f:
                for line in f:
                    m = re.match(r'^REPO_URL="https://raw\.githubusercontent\.com/[^/]+/[^/]+/([^"]+)"', line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
    return "main"


def _version_gt(a: str, b: str) -> bool:
    """a > b ?"""
    def _parse(v):
        return tuple(int(p) for p in v.split("."))
    try:
        return _parse(a) > _parse(b)
    except (ValueError, AttributeError):
        return False


def update_warper_from_web():
    """
    Запускает `warper update` через subprocess и возвращает Popen-объект
    для стриминга stdout/stderr в браузер через SSE.
    Возвращает (popen_obj, error_message).
    """
    try:
        import subprocess
        import os as _os

        # Полное окружение чтобы warper.sh не падал
        env = _os.environ.copy()
        env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        env["DEBIAN_FRONTEND"] = "noninteractive"
        env["SYSTEMD_PAGER"] = ""
        env["TERM"] = "dumb"
        env["LANG"] = "C.UTF-8"
        env["LC_ALL"] = "C.UTF-8"

        # Запускаем `warper update` напрямую (НЕ через nohup),
        # подключаем stdout/stderr к pipe чтобы их можно было стримить
        proc = subprocess.Popen(
            ["/usr/local/bin/warper", "update"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,  # склеиваем stderr в stdout
            stdin=subprocess.DEVNULL,
            env=env,
            bufsize=1,                  # line-buffered
            text=True,
            start_new_session=True,
        )
        return proc, None
    except Exception as e:
        return None, f"Не удалось запустить обновление: {e}"


def invalidate_version_cache():
    """Сбросить кэш проверки версии (вызывать после обновления)."""
    global _version_cache
    _version_cache = {"checked_at": 0, "data": None}
