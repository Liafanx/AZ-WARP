"""
Управление IP-подсетями (CIDR) WARPER.
Добавление, удаление, синхронизация, режим маршрутов, экспорт в AntiZapret.
"""

from __future__ import annotations

from ._runner import run_warper
from ._result import WarperResult


def add_ip_range(cidr: str) -> WarperResult:
    """
    Добавить IP-подсеть для маршрутизации через WARPER.

    Args:
        cidr: Подсеть в формате A.B.C.D/M (например '91.108.4.0/22').
              Без маски — будет /32.

    Returns:
        WarperResult.

    Example:
        >>> add_ip_range("91.108.4.0/22")
        WarperResult(OK, 'Подсеть 91.108.4.0/22 добавлена.')
    """
    cidr = cidr.strip()
    if not cidr:
        return WarperResult(ok=False, message="CIDR не может быть пустым")
    if "/" not in cidr:
        cidr = f"{cidr}/32"
    return run_warper("ipadd", cidr, timeout=30)


def remove_ip_range(cidr: str) -> WarperResult:
    """
    Удалить IP-подсеть.

    Args:
        cidr: Подсеть для удаления.

    Returns:
        WarperResult.
    """
    cidr = cidr.strip()
    if not cidr:
        return WarperResult(ok=False, message="CIDR не может быть пустым")
    return run_warper("ipremove", cidr, timeout=30)


def sync_ip_ranges() -> WarperResult:
    """
    Синхронизировать IP-маршруты (файл ip-ranges.txt → kernel routes).

    Returns:
        WarperResult.
    """
    return run_warper("ipsync", timeout=60)


def list_ip_ranges() -> WarperResult:
    """
    Список подсетей из файла ip-ranges.txt.

    Returns:
        WarperResult с data=list[str] — список CIDR.

    Example:
        >>> result = list_ip_ranges()
        >>> for cidr in result.data:
        ...     print(cidr)
        '91.108.4.0/22'
    """
    result = run_warper("iplist", timeout=10)
    if not result.ok:
        return result

    cidrs = [
        line.strip()
        for line in result.raw_stdout.splitlines()
        if line.strip()
    ]

    return WarperResult(
        ok=True,
        message=f"{len(cidrs)} подсетей",
        data=cidrs,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def list_ip_routes() -> WarperResult:
    """
    Список применённых WARPER-маршрутов в ядре Linux.

    Returns:
        WarperResult с data=list[str] — список CIDR.
    """
    result = run_warper("iproutes", timeout=10)
    if not result.ok:
        return result

    routes = [
        line.strip()
        for line in result.raw_stdout.splitlines()
        if line.strip()
    ]

    return WarperResult(
        ok=True,
        message=f"{len(routes)} маршрутов",
        data=routes,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def set_ip_route_mode(mode: str) -> WarperResult:
    """
    Установить режим применения IP-маршрутов.

    Args:
        mode: 'antizapret' — только AntiZapret-клиенты.
              'all_vpn' — AntiZapret + FullVPN.
              'all' — весь трафик сервера (Beta).

    Returns:
        WarperResult.
    """
    if mode not in ("antizapret", "all_vpn", "all"):
        return WarperResult(ok=False, message=f"Недопустимый режим: {mode}")
    return run_warper("iproutemode", mode, timeout=30)


def set_ip_export(enable: bool) -> WarperResult:
    """
    Включить/выключить экспорт CIDR в AntiZapret.

    При включении — CIDR из ip-ranges.txt записываются в
    /root/antizapret/config/warper-include-ips.txt и подхватываются
    AntiZapret-клиентами.

    Args:
        enable: True — включить, False — выключить.

    Returns:
        WarperResult.
    """
    val = "on" if enable else "off"
    return run_warper("ipexport", val, timeout=30)
