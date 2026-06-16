"""
web_api.py — обёртка для веб-панели.

Импортирует всё из пакета warper_api (/root/warper/py/warper_api/)
и адаптирует под формат Flask endpoints (tuple[bool, str]).

Web-специфичные функции (auth log, blocks, nginx, service info)
остаются здесь, так как они не нужны за пределами веб-панели.
"""

import json
import os
import re
import subprocess
import sys
import time as _time
from typing import Any

# Добавляем путь к warper_api пакету
_PY_PATH = "/root/warper/py"
if _PY_PATH not in sys.path:
    sys.path.insert(0, _PY_PATH)

from warper_api import WarperAPI
from warper_api._runner import run_warper, WARPER_BIN
from warper_api._result import _strip_ansi

_api = WarperAPI()

_status_cache: dict[str, Any] = {"ts": 0, "data": None}
_STATUS_CACHE_TTL = 10

# ===== Адаптер: WarperResult → tuple/dict для Flask =====

def _to_tuple(result) -> tuple[bool, str]:
    """Конвертирует WarperResult в (ok, message) для _result_partial()."""
    return result.ok, result.message


def _to_dict(result) -> dict[str, Any]:
    """Конвертирует WarperResult в dict для JSON-ответов."""
    if result.data is not None:
        return result.data
    if result.ok:
        return {"message": result.message}
    return {"error": result.message}


# =====================================================================
#  Статус
# =====================================================================

def get_status(force: bool = False) -> dict[str, Any]:
    global _status_cache

    now = _time.time()
    if not force and _status_cache["data"] is not None:
        if now - _status_cache["ts"] < _STATUS_CACHE_TTL:
            return _status_cache["data"]

    result = _api.get_status()
    if not result.ok:
        data = {"error": result.message, "raw": result.raw_stdout}
    else:
        data = result.data or {}

    _status_cache = {"ts": now, "data": data}
    return data


def get_doctor() -> list[dict[str, Any]]:
    result = _api.doctor()
    return result.data or []


def toggle_warper() -> tuple[bool, str]:
    return _to_tuple(_api.toggle())


def patch_kresd() -> tuple[bool, str]:
    return _to_tuple(_api.patch_kresd())


# =====================================================================
#  Домены
# =====================================================================

def get_domains(filter_type: str | None = None, search: str | None = None) -> list[dict]:
    result = _api.list_domains()
    if not result.ok:
        return []
    domains = result.data or []
    if filter_type:
        domains = [d for d in domains if d["type"] == filter_type]
    if search:
        s = search.lower()
        domains = [d for d in domains if s in d["name"].lower()]
    return domains


def add_domain(domain: str) -> tuple[bool, str]:
    return _to_tuple(_api.add_domain(domain))


def add_domains_bulk(domains: list[str]) -> dict[str, Any]:
    added, skipped, errors = [], [], []
    for raw in domains:
        d = raw.strip().lower()
        if not d or d.startswith("#"):
            continue
        result = _api.add_domain(d)
        if result.ok:
            if "уже есть" in result.message.lower() or "already" in result.message.lower():
                skipped.append(d)
            else:
                added.append(d)
        else:
            errors.append({"domain": d, "error": result.message[:200]})
    return {
        "added_count": len(added), "skipped_count": len(skipped),
        "error_count": len(errors), "added": added, "skipped": skipped, "errors": errors,
    }


def remove_domain(domain: str) -> tuple[bool, str]:
    return _to_tuple(_api.remove_domain(domain))


def toggle_list(list_name: str, enable: bool) -> tuple[bool, str]:
    if list_name not in ("gemini", "chatgpt"):
        return False, "Неизвестный список"
    if enable:
        return _to_tuple(_api.enable_list(list_name))
    return _to_tuple(_api.disable_list(list_name))


def sync_domains() -> tuple[bool, str]:
    return _to_tuple(_api.sync_domains())


def get_user_domains_block() -> str:
    """Возвращает пользовательский блок domains.txt (web-specific)."""
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

    for ln in lines:
        if skip_header:
            if ln.strip() == "# Пользовательские домены:":
                skip_header = False
            continue
        if re.match(r"^# --- [A-Z0-9_]+ ---$", ln.strip()):
            in_block = True
            continue
        if re.match(r"^# --- END [A-Z0-9_]+ ---$", ln.strip()):
            in_block = False
            continue
        if in_block:
            continue
        user_lines.append(ln)

    while user_lines and not user_lines[-1].strip():
        user_lines.pop()
    return "\n".join(user_lines)


def save_user_domains_block(text: str) -> tuple[bool, str]:
    """Сохраняет пользовательский блок domains.txt (web-specific)."""
    domains_file = "/root/warper/domains.txt"
    header_marker = "# Пользовательские домены:"

    raw_lines = [ln for ln in text.splitlines() if ln.strip() != header_marker]

    invalid = []
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

    while raw_lines and not raw_lines[-1].strip():
        raw_lines.pop()

    gemini_block, chatgpt_block = [], []
    if os.path.exists(domains_file):
        try:
            with open(domains_file, "r", encoding="utf-8") as f:
                existing = f.read().splitlines()
        except OSError:
            existing = []

        block = None
        for ln in existing:
            stripped = ln.strip()
            if stripped == "# --- GEMINI ---":
                block = "gemini"; gemini_block.append(ln); continue
            if stripped == "# --- END GEMINI ---":
                gemini_block.append(ln); block = None; continue
            if stripped == "# --- CHATGPT ---":
                block = "chatgpt"; chatgpt_block.append(ln); continue
            if stripped == "# --- END CHATGPT ---":
                chatgpt_block.append(ln); block = None; continue
            if block == "gemini":
                gemini_block.append(ln)
            elif block == "chatgpt":
                chatgpt_block.append(ln)

    out_lines = [
        "# ==========================================",
        "# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP",
        "# Строки, начинающиеся с '#', игнорируются.",
        "# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT",
        "# ==========================================",
        "",
        header_marker,
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

    ok, msg = sync_domains()
    if not ok:
        return False, f"Файл сохранён, но sync упал: {msg}"
    return True, f"Сохранено {valid_count} доменов, синхронизация выполнена"


def _validate_domain_format(domain: str) -> bool:
    if not domain or len(domain) > 253 or "." not in domain:
        return False
    parts = domain.split(".")
    if len(parts) < 2 or len(parts[-1]) < 2:
        return False
    for part in parts:
        if not part or len(part) > 63 or part.startswith("-") or part.endswith("-"):
            return False
        if not re.match(r"^[a-z0-9_-]+$", part):
            return False
    return True


# =====================================================================
#  IP-подсети
# =====================================================================

def get_ip_ranges(search: str | None = None) -> list[dict[str, str]]:
    result = _api.list_ip_ranges()
    if not result.ok:
        return []
    ranges = [{"cidr": c} for c in (result.data or [])]
    if search:
        ranges = [r for r in ranges if search in r["cidr"]]
    return ranges


def get_active_ip_routes() -> list[str]:
    result = _api.list_ip_routes()
    return result.data or []


def add_ip_range(cidr: str) -> tuple[bool, str]:
    return _to_tuple(_api.add_ip_range(cidr))


def add_ip_ranges_bulk(cidrs: list[str]) -> dict[str, Any]:
    added, skipped, errors = [], [], []
    for raw in cidrs:
        c = raw.strip()
        if not c or c.startswith("#"):
            continue
        result = _api.add_ip_range(c)
        if result.ok:
            if "уже есть" in result.message.lower():
                skipped.append(c)
            else:
                added.append(c)
        else:
            errors.append({"cidr": c, "error": result.message[:200]})
    return {
        "added_count": len(added), "skipped_count": len(skipped),
        "error_count": len(errors), "added": added, "skipped": skipped, "errors": errors,
    }


def remove_ip_range(cidr: str) -> tuple[bool, str]:
    return _to_tuple(_api.remove_ip_range(cidr))


def sync_ip_ranges() -> tuple[bool, str]:
    return _to_tuple(_api.sync_ip_ranges())


def set_ip_route_mode(mode: str) -> tuple[bool, str]:
    return _to_tuple(_api.set_ip_route_mode(mode))


def set_ip_export(enable: bool) -> tuple[bool, str]:
    return _to_tuple(_api.set_ip_export(enable))


def get_ip_ranges_content() -> str:
    result = run_warper("ipranges", "list", timeout=10)
    return result.raw_stdout if result.ok else ""


def save_ip_ranges_content(text: str) -> tuple[bool, str]:
    lines = text.splitlines()
    invalid = []
    valid_count = 0
    for raw in lines:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        cidr = s if "/" in s else f"{s}/32"
        m = re.match(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$", cidr)
        if not m or any(int(x) > 255 for x in m.groups()[:4]) or not 1 <= int(m.group(5)) <= 32:
            invalid.append(s)
        else:
            valid_count += 1

    if invalid:
        msg = "Некорректные CIDR: " + ", ".join(invalid[:5])
        if len(invalid) > 5:
            msg += f" (и ещё {len(invalid) - 5})"
        return False, msg

    content = text if text.endswith("\n") else text + "\n"
    try:
        proc = subprocess.run(
            [WARPER_BIN, "ipranges", "save"],
            input=content, capture_output=True, text=True, timeout=180,
        )
        if proc.returncode != 0:
            return False, _strip_ansi((proc.stderr or proc.stdout).strip()) or "Ошибка сохранения"
        return True, f"Сохранено {valid_count} подсетей"
    except subprocess.TimeoutExpired:
        return False, "Таймаут операции"
    except Exception as e:
        return False, str(e)


# =====================================================================
#  Sing-box
# =====================================================================

def singbox_action(action: str) -> tuple[bool, str]:
    if action == "start":
        return _to_tuple(_api.singbox_start())
    elif action == "stop":
        return _to_tuple(_api.singbox_stop())
    elif action == "restart":
        return _to_tuple(_api.singbox_restart())
    elif action == "enable":
        return _to_tuple(_api.singbox_enable())
    elif action == "disable":
        return _to_tuple(_api.singbox_disable())
    return False, "Недопустимое действие"


def get_logs(lines: int = 100, level_filter: str | None = None) -> list[dict[str, Any]]:
    result = _api.get_logs(lines)
    if not result.ok:
        return []
    parsed = []
    for line in (result.data or []):
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


# =====================================================================
#  Настройки
# =====================================================================

def set_log_level(level: str) -> tuple[bool, str]:
    return _to_tuple(_api.set_log_level(level))


def set_mtu(mtu: int) -> tuple[bool, str]:
    return _to_tuple(_api.set_mtu(mtu))


def set_subnet(subnet: str) -> tuple[bool, str]:
    return _to_tuple(_api.set_subnet(subnet))


def set_autopatch(enable: bool) -> tuple[bool, str]:
    return _to_tuple(_api.set_autopatch(enable))


def set_fullvpn(enable: bool) -> tuple[bool, str]:
    return _to_tuple(_api.set_fullvpn(enable))


def switch_to_warp(key_source: str = "") -> tuple[bool, str]:
    return _to_tuple(_api.set_mode_warp(key_source))


def switch_to_slave(server: str, port: str | int, password: str) -> tuple[bool, str]:
    return _to_tuple(_api.set_mode_slave(server, port, password))


def switch_to_wg(conf_path: str) -> tuple[bool, str]:
    return _to_tuple(_api.set_mode_wg(conf_path))


def list_warp_keys() -> list[dict[str, Any]]:
    result = _api.list_warp_keys()
    return result.data or []


def list_wg_configs() -> list[dict[str, str]]:
    result = _api.list_wg_configs()
    return result.data or []


def upload_wg_config(filename: str, content: str) -> tuple[bool, str, str]:
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(filename))
    if not safe_name.endswith(".conf"):
        safe_name += ".conf"

    if "[Peer]" not in content or "Endpoint" not in content or "PublicKey" not in content:
        return False, "Файл не похож на WireGuard конфиг", ""

    for m in ["engage.cloudflareclient.com", "162.159.192.1", "162.159.193.1",
              "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="]:
        if m in content:
            return False, "Это Cloudflare WARP конфиг, не подходит для режима WG", ""

    target_path = os.path.join("/root/warper", safe_name)
    try:
        with open(target_path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(target_path, 0o600)
    except OSError as e:
        return False, f"Ошибка сохранения: {e}", ""

    return True, f"Конфиг сохранён: {target_path}", target_path


# =====================================================================
#  Трафик
# =====================================================================

def get_traffic(period: str = "today") -> dict[str, Any]:
    result = _api.get_traffic(period)
    if not result.ok:
        return {"error": result.message}
    return result.data or {}


def get_traffic_history() -> dict[str, Any]:
    out = {}
    for p in ("today", "week", "month", "all"):
        data = get_traffic(p)
        out[p] = {"rx": data.get("period_rx", 0), "tx": data.get("period_tx", 0)}

    today = get_traffic("today")
    out["current_session"] = today.get("current_session", {"rx": 0, "tx": 0})
    out["uptime"] = today.get("uptime", "не запущен")
    return out


# =====================================================================
#  Каталог
# =====================================================================

_catalog_search_cache: dict[str, Any] = {"ts": 0, "data": {}}
_CATALOG_CACHE_TTL = 300


def catalog_search(query: str = "", force: bool = False) -> list[dict[str, Any]]:
    cache_key = query.strip().lower()
    now = _time.time()

    if not force and cache_key in _catalog_search_cache["data"]:
        cached = _catalog_search_cache["data"][cache_key]
        if now - cached["ts"] < _CATALOG_CACHE_TTL:
            return cached["result"]

    result = _api.catalog_search(query)
    data = result.data or []
    _catalog_search_cache["data"][cache_key] = {"ts": now, "result": data}
    return data


def catalog_get_installed() -> list[dict[str, Any]]:
    result = _api.catalog_list_installed()
    return result.data or []


def catalog_preview(name: str) -> dict[str, Any]:
    result = _api.catalog_show(name)
    if not result.ok:
        return {"error": result.message}
    return result.data or {"error": "Нет данных"}


def catalog_add(name: str) -> tuple[bool, str]:
    return _to_tuple(_api.catalog_add(name))


def catalog_remove(name: str) -> tuple[bool, str]:
    return _to_tuple(_api.catalog_remove(name))


def catalog_update(name: str = "") -> tuple[bool, str]:
    return _to_tuple(_api.catalog_update(name))


def catalog_refresh_cache() -> tuple[bool, str]:
    _catalog_search_cache["data"].clear()
    return _to_tuple(_api.catalog_refresh_cache())


# =====================================================================
#  Обновления
# =====================================================================

_version_cache: dict[str, Any] = {"checked_at": 0, "data": None}
_VERSION_CACHE_TTL = 60


def check_for_updates(force: bool = False) -> dict[str, Any]:
    import urllib.request
    import base64

    now = _time.time()
    if not force and _version_cache["data"] and \
       (now - _version_cache["checked_at"] < _VERSION_CACHE_TTL):
        return _version_cache["data"]

    result: dict[str, Any] = {"current": _api.version, "remote": None,
                               "update_available": False, "error": None}

    branch = _detect_warper_branch()
    api_url = f"https://api.github.com/repos/Liafanx/AZ-WARP/contents/version?ref={branch}"

    try:
        req = urllib.request.Request(api_url, headers={
            "User-Agent": "warper-web/1.0",
            "Accept": "application/vnd.github.v3+json",
        })
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content_b64 = data.get("content", "").replace("\n", "")
            if content_b64:
                remote = base64.b64decode(content_b64).decode("utf-8").strip()
                if re.match(r"^\d+\.\d+\.\d+$", remote):
                    result["remote"] = remote
                    result["update_available"] = _version_gt(remote, result["current"])
    except Exception as e:
        try:
            raw_url = f"https://raw.githubusercontent.com/Liafanx/AZ-WARP/{branch}/version?_={int(now)}"
            req = urllib.request.Request(raw_url, headers={
                "User-Agent": "warper-web/1.0", "Cache-Control": "no-cache"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                remote = resp.read().decode("utf-8").strip()
                if re.match(r"^\d+\.\d+\.\d+$", remote):
                    result["remote"] = remote
                    result["update_available"] = _version_gt(remote, result["current"])
        except Exception as e2:
            result["error"] = f"API: {str(e)[:80]} / RAW: {str(e2)[:80]}"

    _version_cache["checked_at"] = now
    _version_cache["data"] = result
    return result


def update_warper_from_web():
    try:
        env = os.environ.copy()
        env.update({"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                     "DEBIAN_FRONTEND": "noninteractive", "SYSTEMD_PAGER": "",
                     "TERM": "dumb", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"})
        proc = subprocess.Popen(
            [WARPER_BIN, "update"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, env=env,
            bufsize=1, text=True, start_new_session=True,
        )
        return proc, None
    except Exception as e:
        return None, f"Не удалось запустить обновление: {e}"


def invalidate_version_cache():
    global _version_cache
    _version_cache = {"checked_at": 0, "data": None}


def _detect_warper_branch() -> str:
    warper_sh = "/root/warper/warper.sh"
    if os.path.exists(warper_sh):
        try:
            with open(warper_sh, "r") as f:
                for line in f:
                    m = re.match(
                        r'^REPO_URL="https://raw\.githubusercontent\.com/[^/]+/[^/]+/([^"]+)"',
                        line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
    return "main"


def _version_gt(a: str, b: str) -> bool:
    try:
        return tuple(int(p) for p in a.split(".")) > tuple(int(p) for p in b.split("."))
    except (ValueError, AttributeError):
        return False


# =====================================================================
#  Web-специфичные функции (auth, blocks, nginx, service, HTTPS)
#  Эти функции НЕ входят в публичный warper_api пакет,
#  потому что они имеют смысл только при установленной веб-панели.
# =====================================================================

def _run(cmd: list[str], timeout: int = 60) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Таймаут"
    except FileNotFoundError as e:
        return 127, "", f"Не найдено: {e}"
    except Exception as e:
        return 1, "", str(e)


def get_auth_log(limit: int = 200, level_filter: str | None = None) -> dict[str, Any]:
    log_file = "/root/warper/web/data/auth.log"
    events: list[dict] = []
    stats = {"total": 0, "success": 0, "failed": 0, "blocked_attempts": 0,
             "blocks_set": 0, "last_24h_success": 0, "last_24h_failed": 0}

    if not os.path.exists(log_file):
        return {"events": events, "stats": stats}

    all_files = [log_file] + [f"{log_file}.{i}" for i in range(1, 4) if os.path.exists(f"{log_file}.{i}")]
    now = _time.time()
    cutoff_24h = now - 86400
    all_lines: list[str] = []

    for f_path in all_files:
        try:
            with open(f_path, "r", encoding="utf-8") as f:
                all_lines.extend(f.readlines())
        except OSError:
            continue

    for line in all_lines:
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:[,.]\d+)?\s+(.*)$", line)
        if not m:
            continue
        timestamp_str, rest = m.group(1), m.group(2)
        fields = dict(re.findall(r"(\w+)=(\S+)", rest))
        event = fields.get("event", "")
        if not event:
            continue

        stats["total"] += 1
        is_success = event == "login_success"
        is_blocked = event in ("blocked_attempt", "blocked_now")
        is_failed = event in ("login_failed", "empty_credentials",
                               "invalid_login_format", "invalid_password_length")

        if is_success: stats["success"] += 1
        if is_blocked:
            stats["blocked_attempts"] += 1
            if event == "blocked_now": stats["blocks_set"] += 1
        if is_failed: stats["failed"] += 1

        try:
            from datetime import datetime as _dt
            ts = _dt.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S").timestamp()
            if ts >= cutoff_24h:
                if is_success: stats["last_24h_success"] += 1
                if is_failed or is_blocked: stats["last_24h_failed"] += 1
        except (ValueError, OSError):
            pass

        if level_filter == "success" and not is_success: continue
        if level_filter == "failed" and not (is_failed or is_blocked): continue
        if level_filter == "blocked" and not is_blocked: continue

        events.append({
            "timestamp": timestamp_str, "ip": fields.get("ip", "?"),
            "event": event, "user": fields.get("user", ""),
            "extra": " ".join(f"{k}={v}" for k, v in fields.items() if k not in ("ip", "event", "user")),
        })

    events.sort(key=lambda e: e["timestamp"], reverse=True)
    return {"events": events[:limit], "stats": stats}


def get_active_blocks() -> list[dict[str, Any]]:
    blocks_file = "/root/warper/web/data/blocks.json"
    if not os.path.exists(blocks_file):
        return []
    try:
        with open(blocks_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    now = _time.time()
    return sorted(
        [{"ip": ip, "until": until, "seconds_left": int(until - now),
          "minutes_left": (int(until - now) + 59) // 60}
         for ip, until in data.get("blocks", {}).items() if until > now],
        key=lambda x: x["until"],
    )


def unblock_ip(ip: str) -> tuple[bool, str]:
    blocks_file = "/root/warper/web/data/blocks.json"
    if not os.path.exists(blocks_file):
        return True, "Нет активных блокировок"
    try:
        with open(blocks_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return False, "Не удалось прочитать blocks.json"
    data.get("blocks", {}).pop(ip, None)
    data.get("attempts", {}).pop(ip, None)
    try:
        tmp = blocks_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, blocks_file)
        return True, f"IP {ip} разблокирован"
    except OSError as e:
        return False, f"Ошибка: {e}"


def unblock_all_ips() -> tuple[bool, str]:
    blocks_file = "/root/warper/web/data/blocks.json"
    try:
        if os.path.exists(blocks_file):
            os.unlink(blocks_file)
        return True, "Все блокировки сняты"
    except OSError as e:
        return False, f"Ошибка: {e}"


def get_nginx_external_port() -> int | None:
    nginx_conf = "/etc/nginx/sites-available/warper-web"
    if not os.path.exists(nginx_conf):
        return None
    try:
        with open(nginx_conf, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return None
    for pattern in [r"^\s*listen\s+(\d+)\s+ssl\b", r"^\s*listen\s+(\d+)"]:
        matches = re.findall(pattern, content, re.MULTILINE)
        non_80 = [int(p) for p in matches if p != "80"]
        if non_80:
            return non_80[0]
    matches = re.findall(r"^\s*listen\s+(\d+)", content, re.MULTILINE)
    return int(matches[0]) if matches else None


def change_external_port(new_port: int) -> tuple[bool, str]:
    import shutil, socket
    if not 1 <= new_port <= 65535:
        return False, "Порт 1-65535"
    nginx_conf = "/etc/nginx/sites-available/warper-web"
    if not os.path.exists(nginx_conf):
        return False, "nginx конфиг не найден"
    current_port = get_nginx_external_port()
    if not current_port:
        return False, "Не удалось определить порт"
    if current_port == new_port:
        return False, f"Порт не изменился ({current_port})"
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1)
        if sock.connect_ex(("127.0.0.1", new_port)) == 0:
            sock.close()
            return False, f"Порт {new_port} занят"
        sock.close()
    except OSError:
        pass
    backup = nginx_conf + ".bak"
    shutil.copy2(nginx_conf, backup)
    try:
        with open(nginx_conf, "r") as f:
            content = f.read()
        new_content = re.sub(rf"^(\s*listen\s+){current_port}(\b)", rf"\g<1>{new_port}\g<2>",
                             content, flags=re.MULTILINE)
        if new_content == content:
            os.remove(backup)
            return False, "Не найдены строки listen"
        with open(nginx_conf, "w") as f:
            f.write(new_content)
    except OSError as e:
        return False, f"Ошибка: {e}"
    rc, _, err = _run(["nginx", "-t"], timeout=10)
    if rc != 0:
        shutil.copy2(backup, nginx_conf)
        os.remove(backup)
        return False, f"nginx -t: {err[:300]}"
    _run(["systemctl", "reload", "nginx"], timeout=15)
    try:
        os.remove(backup)
    except OSError:
        pass
    return True, f"Порт: {current_port} → {new_port}"


def restart_web_service() -> tuple[bool, str]:
    try:
        subprocess.Popen(
            ["nohup", "bash", "-c", "sleep 1 && systemctl restart warper-web"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        return True, "Перезапуск через 1 сек"
    except Exception as e:
        return False, f"Ошибка: {e}"


def get_service_info() -> dict[str, Any]:
    info: dict[str, Any] = {
        "python_version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "flask_version": "?", "gunicorn_version": "?",
        "service_active": False, "uptime": "?", "memory_mb": 0, "main_pid": None,
        "external_port": get_nginx_external_port(),
        "internal_port": int(os.environ.get("PORT", 16060)),
    }
    try:
        import flask; info["flask_version"] = flask.__version__
    except Exception: pass
    try:
        import gunicorn; info["gunicorn_version"] = gunicorn.__version__
    except Exception: pass
    rc, out, _ = _run(["systemctl", "show", "warper-web",
                        "--property=ActiveState,MainPID,ActiveEnterTimestamp"], timeout=5)
    if rc == 0:
        for line in out.splitlines():
            if "=" not in line: continue
            k, v = line.split("=", 1)
            if k == "ActiveState": info["service_active"] = v == "active"
            elif k == "MainPID":
                try: info["main_pid"] = int(v) if v != "0" else None
                except ValueError: pass
            elif k == "ActiveEnterTimestamp" and v:
                try:
                    from datetime import datetime as _dt
                    started = _dt.strptime(v, "%a %Y-%m-%d %H:%M:%S %Z")
                    secs = max(0, int((_dt.now() - started.replace(tzinfo=None)).total_seconds()))
                    d, h, m = secs // 86400, (secs % 86400) // 3600, (secs % 3600) // 60
                    parts = []
                    if d: parts.append(f"{d}д")
                    if h or d: parts.append(f"{h}ч")
                    parts.append(f"{m}м")
                    info["uptime"] = " ".join(parts)
                except (ValueError, AttributeError): pass
    if info["main_pid"]:
        try:
            rc, out, _ = _run(["ps", "-o", "rss=", "--pid", str(info["main_pid"]),
                                "--ppid", str(info["main_pid"])], timeout=3)
            if rc == 0:
                info["memory_mb"] = round(sum(int(l.strip()) for l in out.splitlines() if l.strip().isdigit()) / 1024, 1)
        except Exception: pass
    return info


# Security settings
def get_security_settings_api() -> dict:
    from auth import load_security_settings
    return load_security_settings()


def save_security_settings_api(settings: dict) -> tuple[bool, str]:
    from auth import save_security_settings
    return save_security_settings(settings)


def rotate_session_secret() -> tuple[bool, str]:
    from auth import rotate_secret_key
    return (True, "Все сессии сброшены") if rotate_secret_key() else (False, "Ошибка")


def get_recent_logins(limit: int = 20) -> list[dict]:
    data = get_auth_log(limit=500, level_filter="success")
    seen: dict[str, dict] = {}
    for e in data.get("events", []):
        ip = e.get("ip", "?")
        if ip not in seen:
            seen[ip] = {"ip": ip, "user": e.get("user", "?"),
                        "last_seen": e.get("timestamp", ""), "count": 1}
        else:
            seen[ip]["count"] += 1
    return sorted(seen.values(), key=lambda x: x["last_seen"], reverse=True)[:limit]


def healthcheck() -> dict:
    import socket
    result = {"overall": "ok", "checks": []}

    def _add(name, st, msg):
        result["checks"].append({"name": name, "status": st, "message": msg})
        if st == "error": result["overall"] = "error"
        elif st == "warn" and result["overall"] != "error": result["overall"] = "warn"

    port = int(os.environ.get("PORT", 16060))
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(2)
        _add("Gunicorn порт", "ok" if s.connect_ex(("127.0.0.1", port)) == 0 else "error", f"127.0.0.1:{port}")
        s.close()
    except Exception as e:
        _add("Gunicorn порт", "error", str(e))

    ext_port = get_nginx_external_port()
    if ext_port:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(2)
            _add(f"nginx порт {ext_port}", "ok" if s.connect_ex(("127.0.0.1", ext_port)) == 0 else "error", "")
            s.close()
        except Exception as e:
            _add(f"nginx порт {ext_port}", "error", str(e))

    for svc in ("warper-web", "nginx"):
        rc, out, _ = _run(["systemctl", "is-active", svc], timeout=3)
        _add(f"Сервис {svc}", "ok" if rc == 0 else "error", out.strip())

    uf = "/root/warper/web/data/users.json"
    if os.path.exists(uf):
        try:
            with open(uf) as f: d = json.loads(f.read())
            _add("БД пользователей", "ok" if d else "warn", f"{len(d)} аккаунтов" if d else "пустая")
        except Exception as e:
            _add("БД пользователей", "error", str(e)[:100])
    else:
        _add("БД пользователей", "error", "не существует")

    sf = "/root/warper/web/data/secret.key"
    if os.path.exists(sf):
        sz = os.path.getsize(sf)
        _add("SECRET_KEY", "ok" if sz >= 32 else "warn", f"{sz} байт")
    else:
        _add("SECRET_KEY", "error", "отсутствует")

    return result


# HTTPS
def get_https_status() -> dict[str, Any]:
    r = run_warper("webhttps", "status", timeout=10)
    if not r.ok: return {"mode": "unknown", "error": r.message}
    return dict(line.split("=", 1) for line in r.raw_stdout.splitlines() if "=" in line)


def set_https_selfsigned() -> tuple[bool, str]:
    return _to_tuple(run_warper("webhttps", "enable-selfsigned", timeout=30))


def set_https_letsencrypt(domain: str) -> tuple[bool, str]:
    if not domain or not re.match(r"^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$", domain):
        return False, "Некорректный домен"
    return _to_tuple(run_warper("webhttps", "enable-letsencrypt", domain, timeout=120))


def disable_https() -> tuple[bool, str]:
    return _to_tuple(run_warper("webhttps", "disable", timeout=15))


def renew_certificate() -> tuple[bool, str]:
    return _to_tuple(run_warper("webhttps", "renew", timeout=120))
