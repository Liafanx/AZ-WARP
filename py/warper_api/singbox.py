"""
Управление службой sing-box.
Запуск, остановка, перезапуск, автозагрузка, логи.
"""

from __future__ import annotations

from ._runner import run_warper
from ._result import WarperResult


def start() -> WarperResult:
    """
    Запустить sing-box.

    Returns:
        WarperResult.

    Example:
        >>> start()
        WarperResult(OK, 'sing-box start: ok')
    """
    return _action("start")


def stop() -> WarperResult:
    """
    Остановить sing-box.

    Returns:
        WarperResult.
    """
    return _action("stop")


def restart() -> WarperResult:
    """
    Перезапустить sing-box.

    Returns:
        WarperResult.
    """
    return _action("restart")


def enable() -> WarperResult:
    """
    Включить автозагрузку sing-box.

    Returns:
        WarperResult.
    """
    return _action("enable")


def disable() -> WarperResult:
    """
    Выключить автозагрузку sing-box.

    Returns:
        WarperResult.
    """
    return _action("disable")


def get_logs(lines: int = 100) -> WarperResult:
    """
    Получить последние строки логов sing-box.

    Args:
        lines: Количество строк (1-2000, по умолчанию 100).

    Returns:
        WarperResult с data=list[str] строк лога.

    Example:
        >>> result = get_logs(50)
        >>> for line in result.data:
        ...     print(line)
    """
    if not isinstance(lines, int) or lines < 1:
        lines = 100
    if lines > 2000:
        lines = 2000

    result = run_warper("logs", str(lines), timeout=15)
    if not result.ok:
        return result

    log_lines = [
        line for line in result.raw_stdout.splitlines()
        if line.strip()
    ]

    return WarperResult(
        ok=True,
        message=f"{len(log_lines)} строк",
        data=log_lines,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def _action(action: str) -> WarperResult:
    """Выполняет systemctl action для sing-box через warper."""
    import subprocess

    valid = ("start", "stop", "restart", "enable", "disable")
    if action not in valid:
        return WarperResult(ok=False, message=f"Недопустимое действие: {action}")

    timeout = 30 if action in ("enable", "disable") else 90

    try:
        proc = subprocess.run(
            ["systemctl", action, "sing-box"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        ok = proc.returncode == 0
        msg = f"sing-box {action}: {'ok' if ok else 'ошибка'}"
        if not ok and proc.stderr:
            msg += f" ({proc.stderr.strip()[:200]})"
        return WarperResult(
            ok=ok,
            message=msg,
            raw_stdout=proc.stdout,
            raw_stderr=proc.stderr,
            return_code=proc.returncode,
        )
    except subprocess.TimeoutExpired:
        return WarperResult(ok=False, message=f"Таймаут: sing-box {action}")
    except Exception as e:
        return WarperResult(ok=False, message=f"Ошибка: {e}")
