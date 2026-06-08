"""
Статус и диагностика WARPER.
Полный статус в JSON, проверка активности, doctor.
"""

from __future__ import annotations

import json as _json
import subprocess

from ._runner import run_warper, run_warper_json
from ._result import WarperResult, _strip_ansi


def get_status() -> WarperResult:
    """
    Полный статус WARPER в JSON.

    Returns:
        WarperResult с data=dict со всеми параметрами системы.

    Example:
        >>> result = get_status()
        >>> print(result.data["version"])
        '1.3.8'
        >>> print(result.data["singbox"]["running"])
        True
        >>> print(result.data["outbound_mode"])
        'warp'
    """
    return run_warper_json("status", "json", timeout=30)


def is_active() -> bool:
    """
    Проверяет: WARPER полностью активен
    (sing-box запущен И kresd.conf пропатчен).

    Returns:
        True если WARPER активен.

    Example:
        >>> if is_active():
        ...     print("WARPER работает")
    """
    result = get_status()
    if not result.ok or not result.data:
        return False

    sb = result.data.get("singbox", {})
    kr = result.data.get("kresd", {})
    return bool(sb.get("running")) and bool(kr.get("patched"))


def toggle() -> WarperResult:
    """
    Включить или выключить WARPER целиком.

    Если WARPER активен — выключает (sing-box stop, unpatch kresd, удаление маршрутов).
    Если неактивен — включает (sing-box start, patch kresd, синхронизация маршрутов).

    Returns:
        WarperResult.
    """
    return run_warper("toggle", timeout=180)


def doctor() -> WarperResult:
    """
    Запускает полную диагностику всех компонентов WARPER.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - status (str): 'ok' | 'warn' | 'error' | 'info'
            - text (str): описание проверки

    Example:
        >>> result = doctor()
        >>> for check in result.data:
        ...     icon = "✓" if check["status"] == "ok" else "✕"
        ...     print(f"{icon} {check['text']}")
    """
    import re

    result = run_warper("doctor", timeout=60)

    checks: list[dict] = []
    ansi_re = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")

    for raw_line in result.raw_stdout.splitlines():
        line = ansi_re.sub("", raw_line).strip()
        if not line:
            continue
        if line.startswith("==") or line.startswith("--") or "WARPER DOCTOR" in line:
            continue
        if "Диагностика завершена" in line:
            continue

        check_status = "info"
        if line.startswith("✔"):
            check_status = "ok"
        elif line.startswith("✘"):
            check_status = "error"
        elif line.startswith("!"):
            check_status = "warn"

        text = re.sub(r"^[✔✘!]\s*", "", line)
        checks.append({"status": check_status, "text": text})

    return WarperResult(
        ok=result.ok,
        message=_strip_ansi(result.message),
        data=checks,
        raw_stdout=result.raw_stdout,
        raw_stderr=result.raw_stderr,
        return_code=result.return_code,
    )
