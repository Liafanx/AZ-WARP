"""
Управление веб-панелью WARPER.
Установка, служба, порт, логи.
"""

from __future__ import annotations

from ._runner import run_warper
from ._result import WarperResult


def status() -> WarperResult:
    """
    Состояние веб-панели.

    Returns:
        WarperResult с data=dict: installed, active, enabled, mode,
        external_port.
    """
    result = run_warper("web", "status")
    if result.ok:
        data = {}
        for line in result.raw_stdout.splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                data[key.strip()] = value.strip()
        result.data = data
    return result


def install(timeout: int = 900) -> WarperResult:
    """
    Установить веб-панель.

    Установщик интерактивный — вызов из кода имеет смысл только если
    stdin подготовлен заранее.

    Args:
        timeout: Таймаут в секундах.
    """
    return run_warper("web", "install", timeout=timeout)


def uninstall(timeout: int = 300) -> WarperResult:
    """Удалить веб-панель."""
    return run_warper("web", "uninstall", timeout=timeout)


def start() -> WarperResult:
    """Запустить службу панели."""
    return run_warper("web", "start", timeout=60)


def stop() -> WarperResult:
    """Остановить службу панели."""
    return run_warper("web", "stop", timeout=60)


def restart() -> WarperResult:
    """Перезапустить службу панели."""
    return run_warper("web", "restart", timeout=60)


def set_autostart(enabled: bool) -> WarperResult:
    """Включить или выключить автозагрузку панели."""
    return run_warper("web", "enable" if enabled else "disable")


def get_port() -> WarperResult:
    """Внешний порт панели: message — строка, data — int (None, если не задан)."""
    result = run_warper("web", "port")
    if result.ok:
        port = result.message.strip()
        result.data = int(port) if port.isdigit() else None
    return result


def set_port(port: int) -> WarperResult:
    """
    Сменить внешний порт панели.

    В режиме без nginx порт задаётся при установке и здесь не меняется.

    Args:
        port: Новый порт 1-65535.
    """
    return run_warper("web", "port", str(port), timeout=60)


def get_logs(lines: int = 50) -> WarperResult:
    """
    Логи службы панели.

    Args:
        lines: Количество строк.
    """
    result = run_warper("web", "logs", str(lines))
    if result.ok:
        result.data = result.raw_stdout.splitlines()
    return result


def get_auth_log(lines: int = 30) -> WarperResult:
    """
    Журнал авторизаций панели.

    Args:
        lines: Количество строк.
    """
    result = run_warper("web", "authlog", str(lines))
    if result.ok:
        result.data = result.raw_stdout.splitlines()
    return result


def update(timeout: int = 600) -> WarperResult:
    """Обновить файлы панели из репозитория."""
    return run_warper("webupdate", timeout=timeout)
