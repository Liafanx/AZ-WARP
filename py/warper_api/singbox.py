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
    """
    Выполняет действие над службой через CLI.

    Через `warper singbox`, а не systemctl напрямую: CLI дополнительно
    переприменяет правила FORWARD и маршруты, иначе после старта они
    остались бы несинхронизированными.
    """
    valid = ("start", "stop", "restart", "enable", "disable")
    if action not in valid:
        return WarperResult(ok=False, message=f"Недопустимое действие: {action}")

    timeout = 30 if action in ("enable", "disable") else 120
    return run_warper("singbox", action, timeout=timeout)


def status() -> WarperResult:
    """
    Состояние службы sing-box: active, enabled, version, log_level, mtu.

    Returns:
        WarperResult с data=dict разобранных полей.
    """
    result = run_warper("singbox", "status")
    if result.ok:
        data = {}
        for line in result.raw_stdout.splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                data[key.strip()] = value.strip()
        result.data = data
    return result


def version() -> WarperResult:
    """
    Установленная версия sing-box.

    Returns:
        WarperResult, где message и data — строка версии (например "1.14.1").

    Example:
        >>> version()
        WarperResult(OK, '1.14.1')
    """
    result = run_warper("singbox", "version")
    if result.ok:
        result.data = result.message.strip()
    return result


def upgrade(target: str | None = None, timeout: int = 300) -> WarperResult:
    """
    Обновить бинарь sing-box.

    Бинарь общий с sing-box-slave, поэтому перезапускаются обе службы.
    Конфиг проверяется до рестарта: при ошибке службы не трогаются.

    Args:
        target: Версия (например "1.14.1"). По умолчанию — версия из установщика.
        timeout: Таймаут в секундах.

    Returns:
        WarperResult.
    """
    args = ["singbox", "upgrade"]
    if target:
        args.append(target)
    return run_warper(*args, timeout=timeout)
