"""
Управление обновлениями WARPER.
Проверка наличия новой версии и запуск обновления.
"""

from __future__ import annotations

import base64
import json as _json
import os
import re
import subprocess
import time as _time
import urllib.request

from ._runner import run_warper, WARPER_BIN
from ._result import WarperResult


# ===== Кэш проверки версии =====

_version_cache: dict = {"checked_at": 0, "data": None}
_VERSION_CACHE_TTL = 60  # секунд


def check_for_updates(force: bool = False) -> WarperResult:
    """
    Проверяет наличие новой версии WARPER через GitHub API.

    Кэширует результат на 60 секунд чтобы не дёргать GitHub при каждом вызове.

    Args:
        force: True — игнорировать кэш и сделать новый запрос.

    Returns:
        WarperResult с data=dict:
            - current (str): текущая версия (например "1.4.0")
            - remote (str | None): доступная версия (например "1.4.1")
            - update_available (bool): есть ли обновление
            - error (str | None): описание ошибки если проверка не удалась

    Example:
        >>> result = check_for_updates()
        >>> if result.data["update_available"]:
        ...     print(f"Доступно обновление: {result.data['remote']}")
    """
    now = _time.time()

    if not force and _version_cache["data"] and \
       (now - _version_cache["checked_at"] < _VERSION_CACHE_TTL):
        return WarperResult(
            ok=True,
            message=_format_update_message(_version_cache["data"]),
            data=_version_cache["data"],
        )

    result_data: dict = {
        "current": _get_current_version(),
        "remote": None,
        "update_available": False,
        "error": None,
    }

    branch = _detect_warper_branch()

    # Сначала пробуем GitHub API (актуальные данные без CDN-задержки)
    api_url = f"https://api.github.com/repos/Liafanx/AZ-WARP/contents/version?ref={branch}"

    try:
        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "warper-api/1.0",
                "Accept": "application/vnd.github.v3+json",
            },
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = _json.loads(resp.read().decode("utf-8"))
            content_b64 = data.get("content", "").replace("\n", "")
            if content_b64:
                remote = base64.b64decode(content_b64).decode("utf-8").strip()
                if re.match(r"^\d+\.\d+\.\d+$", remote):
                    result_data["remote"] = remote
                    result_data["update_available"] = _version_gt(
                        remote, result_data["current"]
                    )
    except Exception as e:
        # Fallback: raw.githubusercontent.com (с задержкой CDN до 5 минут)
        try:
            raw_url = (
                f"https://raw.githubusercontent.com/Liafanx/AZ-WARP/"
                f"{branch}/version?_={int(now)}"
            )
            req = urllib.request.Request(
                raw_url,
                headers={
                    "User-Agent": "warper-api/1.0",
                    "Cache-Control": "no-cache",
                },
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                remote = resp.read().decode("utf-8").strip()
                if re.match(r"^\d+\.\d+\.\d+$", remote):
                    result_data["remote"] = remote
                    result_data["update_available"] = _version_gt(
                        remote, result_data["current"]
                    )
        except Exception as e2:
            result_data["error"] = f"API: {str(e)[:80]} / RAW: {str(e2)[:80]}"

    _version_cache["checked_at"] = now
    _version_cache["data"] = result_data

    return WarperResult(
        ok=result_data["error"] is None,
        message=_format_update_message(result_data),
        data=result_data,
    )


def update(timeout: int = 600) -> WarperResult:
    """
    Запускает обновление WARPER (blocking).

    Скачивает новые файлы, проверяет валидность, устанавливает с откатом
    при ошибке, перезапускает sing-box при необходимости.

    ВНИМАНИЕ: операция может занять до 5 минут. На время обновления
    WARPER и веб-панель могут быть временно недоступны.

    Args:
        timeout: Максимальное время выполнения в секундах (по умолчанию 600).

    Returns:
        WarperResult.

    Example:
        >>> result = update()
        >>> if result:
        ...     print("Обновление успешно")
        ... else:
        ...     print(f"Ошибка: {result.message}")
    """
    invalidate_version_cache()
    return run_warper("update", timeout=timeout)


def update_async() -> WarperResult:
    """
    Запускает обновление WARPER в фоне (non-blocking).

    Возвращает управление сразу, не дожидаясь завершения.
    Используйте если нужно показать пользователю прогресс через другой механизм
    (например стрим логов через subprocess.Popen).

    Returns:
        WarperResult с data={"pid": int} — PID процесса обновления.

    Example:
        >>> result = update_async()
        >>> pid = result.data["pid"]
        >>> # Дальше можно мониторить через `ps -p <pid>` или journalctl
    """
    invalidate_version_cache()

    try:
        env = os.environ.copy()
        env.update({
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "DEBIAN_FRONTEND": "noninteractive",
            "SYSTEMD_PAGER": "",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        })

        proc = subprocess.Popen(
            [WARPER_BIN, "update"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )

        return WarperResult(
            ok=True,
            message=f"Обновление запущено в фоне (PID {proc.pid})",
            data={"pid": proc.pid},
        )
    except Exception as e:
        return WarperResult(
            ok=False,
            message=f"Не удалось запустить обновление: {e}",
        )


def update_stream():
    """
    Запускает обновление WARPER и возвращает Popen-объект для стриминга.

    Используйте если нужно показать пользователю реал-тайм логи
    (например через Server-Sent Events в веб-приложении).

    Returns:
        tuple[subprocess.Popen | None, str | None]:
            (proc, None) при успехе — читайте proc.stdout построчно
            (None, error_message) при ошибке запуска

    Example:
        >>> proc, err = update_stream()
        >>> if err:
        ...     print(f"Ошибка: {err}")
        ... else:
        ...     for line in iter(proc.stdout.readline, ""):
        ...         print(line.strip())
        ...     rc = proc.wait()
    """
    invalidate_version_cache()

    try:
        env = os.environ.copy()
        env.update({
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "DEBIAN_FRONTEND": "noninteractive",
            "SYSTEMD_PAGER": "",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        })

        proc = subprocess.Popen(
            [WARPER_BIN, "update"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            env=env,
            bufsize=1,
            text=True,
            start_new_session=True,
        )
        return proc, None
    except Exception as e:
        return None, f"Не удалось запустить обновление: {e}"


def invalidate_version_cache() -> None:
    """Сбрасывает кэш проверки версии."""
    global _version_cache
    _version_cache = {"checked_at": 0, "data": None}


# ===== Helpers =====

def _get_current_version() -> str:
    """Читает текущую версию из /root/warper/version."""
    version_file = "/root/warper/version"
    if os.path.exists(version_file):
        try:
            with open(version_file, "r") as f:
                v = f.read().strip()
                if v:
                    return v
        except OSError:
            pass
    return "0.0.0"


def _detect_warper_branch() -> str:
    """Извлекает ветку из REPO_URL в warper.sh (по умолчанию main)."""
    warper_sh = "/root/warper/warper.sh"
    if os.path.exists(warper_sh):
        try:
            with open(warper_sh, "r") as f:
                for line in f:
                    m = re.match(
                        r'^REPO_URL="https://raw\.githubusercontent\.com/[^/]+/[^/]+/([^"]+)"',
                        line,
                    )
                    if m:
                        return m.group(1)
        except OSError:
            pass
    return "main"


def _version_gt(a: str, b: str) -> bool:
    """Проверяет: a > b в semver."""
    try:
        return tuple(int(p) for p in a.split(".")) > tuple(int(p) for p in b.split("."))
    except (ValueError, AttributeError):
        return False


def _format_update_message(data: dict) -> str:
    """Формирует человекочитаемое сообщение."""
    if data.get("error"):
        return f"Ошибка проверки: {data['error']}"
    if data.get("update_available"):
        return f"Доступно обновление: {data['current']} → {data['remote']}"
    return f"Установлена актуальная версия: {data['current']}"
