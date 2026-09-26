"""
Subprocess-обёртка для вызова CLI утилиты warper.
Все модули API используют этот единственный файл для выполнения команд.
"""

from __future__ import annotations

import json
import os
import subprocess

from ._result import WarperResult, _make_result

WARPER_BIN = os.environ.get("WARPER_BIN", "/usr/local/bin/warper")

# Процесс не от root (бот, веб-приложение): WARPER_SUDO=1 — вызывать через
# `sudo -n`, для этого нужно правило в sudoers (см. docs/python-api.md).
WARPER_SUDO = os.environ.get("WARPER_SUDO", "").lower() in ("1", "true", "yes")


def warper_command(*args: str) -> list[str]:
    """Командная строка вызова warper с учётом WARPER_SUDO."""
    base = [WARPER_BIN, *args]
    if WARPER_SUDO and os.geteuid() != 0:
        return ["sudo", "-n", *base]
    return base


def run_warper(
    *args: str,
    timeout: int = 60,
    input_data: str | None = None,
) -> WarperResult:
    """
    Вызывает `warper <args>` и возвращает WarperResult.

    Args:
        *args: Аргументы командной строки (без `warper`).
        timeout: Максимальное время выполнения в секундах.
        input_data: Данные для передачи через stdin.

    Returns:
        WarperResult с полями ok, message, raw_stdout, raw_stderr, return_code.

    Examples:
        >>> result = run_warper("add", "example.com")
        >>> result.ok
        True
        >>> result.message
        'Домен добавлен: example.com'
    """
    cmd = warper_command(*args)

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input_data,
        )
        return _make_result(proc.returncode, proc.stdout, proc.stderr)

    except subprocess.TimeoutExpired:
        return WarperResult(
            ok=False,
            message=f"Команда не завершилась за {timeout} сек",
            return_code=124,
        )
    except FileNotFoundError:
        return WarperResult(
            ok=False,
            message=f"warper не найден: {WARPER_BIN}",
            return_code=127,
        )
    except PermissionError:
        return WarperResult(
            ok=False,
            message="Нет прав на запуск warper: нужен root или WARPER_SUDO=1 и правило sudoers",
            return_code=126,
        )
    except Exception as e:
        return WarperResult(
            ok=False,
            message=f"Ошибка выполнения: {e}",
            return_code=1,
        )


def read_version() -> str:
    """
    Версия WARPER: из /root/warper/version, а без прав на /root
    (запуск не от root) — через `warper version`.
    """
    try:
        with open("/root/warper/version", "r") as f:
            v = f.read().strip()
            if v:
                return v
    except OSError:
        pass
    result = run_warper("version", timeout=10)
    v = result.raw_stdout.strip()
    return v if result.ok and v else "0.0.0"


def run_warper_json(
    *args: str,
    timeout: int = 60,
) -> WarperResult:
    """
    Вызывает warper и парсит stdout как JSON.
    Результат доступен через `result.data`.

    Args:
        *args: Аргументы командной строки.
        timeout: Максимальное время выполнения.

    Returns:
        WarperResult с data=parsed_json.
    """
    result = run_warper(*args, timeout=timeout)
    if not result.ok:
        return result

    try:
        parsed = json.loads(result.raw_stdout)
        return WarperResult(
            ok=True,
            message=result.message,
            data=parsed,
            raw_stdout=result.raw_stdout,
            raw_stderr=result.raw_stderr,
            return_code=result.return_code,
        )
    except json.JSONDecodeError as e:
        return WarperResult(
            ok=False,
            message=f"Невалидный JSON: {e}",
            data=None,
            raw_stdout=result.raw_stdout,
            raw_stderr=result.raw_stderr,
            return_code=result.return_code,
        )
