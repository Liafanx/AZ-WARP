"""
Настройки WARPER.
Режим маршрутизации, подсеть, MTU, log level, автопатч, FullVPN,
WARP-ключи, WG-конфиги.
"""

from __future__ import annotations

from ._runner import run_warper
from ._result import WarperResult


# ==================== Режим маршрутизации ====================

def set_mode_warp(key_source: str = "") -> WarperResult:
    """
    Переключить на режим WARP.

    Args:
        key_source: Источник WARP-ключей.
            '' — автоматический выбор.
            'system' — /etc/wireguard/warp.conf.
            'wgcf' — локальный wgcf-profile.conf.
            'root' — /root/wgcf-profile.conf.
            'generate' — сгенерировать новый.

    Returns:
        WarperResult.

    Example:
        >>> set_mode_warp()
        WarperResult(OK, 'Mode switched to WARP')
        >>> set_mode_warp("system")
        WarperResult(OK, 'Mode switched to WARP')
    """
    args = ["mode", "warp"]
    if key_source:
        valid = ("system", "wgcf", "root", "generate")
        if key_source not in valid:
            return WarperResult(
                ok=False,
                message=f"Недопустимый источник: {key_source}. Допустимо: {', '.join(valid)}",
            )
        args.append(key_source)

    timeout = 180 if key_source == "generate" else 120
    return run_warper(*args, timeout=timeout)


def set_mode_slave(server: str, port: str | int, password: str) -> WarperResult:
    """
    Переключить на режим Slave (донор-сервер через Shadowsocks).

    Args:
        server: IP или домен донор-сервера.
        port: Порт Shadowsocks (1-65535).
        password: Ключ Shadowsocks.

    Returns:
        WarperResult.

    Example:
        >>> set_mode_slave("1.2.3.4", 8444, "my-secret-key-here")
        WarperResult(OK, 'Mode switched to Slave (1.2.3.4:8444)')
    """
    server = str(server).strip()
    port = str(port).strip()
    password = str(password).strip()

    if not server:
        return WarperResult(ok=False, message="Адрес сервера не может быть пустым")
    if not port:
        return WarperResult(ok=False, message="Порт не может быть пустым")
    if not password:
        return WarperResult(ok=False, message="Ключ Shadowsocks не может быть пустым")

    return run_warper("mode", "slave", server, port, password, timeout=120)


def set_mode_wg(conf_path: str) -> WarperResult:
    """
    Переключить на режим WireGuard.

    Args:
        conf_path: Путь к .conf файлу WireGuard на сервере.

    Returns:
        WarperResult.

    Example:
        >>> set_mode_wg("/root/my-wg.conf")
        WarperResult(OK, 'Mode switched to WG (vpn.example.com:51820)')
    """
    conf_path = str(conf_path).strip()
    if not conf_path:
        return WarperResult(ok=False, message="Путь к конфигу не может быть пустым")
    return run_warper("mode", "wg", conf_path, timeout=120)


def get_mode() -> str:
    """
    Текущий режим маршрутизации.

    Returns:
        'warp' | 'slave' | 'wg' | 'unknown'.

    Example:
        >>> get_mode()
        'warp'
    """
    result = run_warper("config", "get", "OUTBOUND_MODE", timeout=10)
    if result.ok and result.raw_stdout.strip():
        return result.raw_stdout.strip()
    return "unknown"


# ==================== Подсеть ====================

def set_subnet(subnet: str) -> WarperResult:
    """
    Изменить fake-подсеть WARPER.

    Операция пересобирает конфиг sing-box и обновляет маршруты AntiZapret.
    Может занять 30-60 секунд.

    Args:
        subnet: Подсеть формата X.X.X.0/M (например '198.20.0.0/24').

    Returns:
        WarperResult.
    """
    subnet = str(subnet).strip()
    if not subnet:
        return WarperResult(ok=False, message="Подсеть не может быть пустой")
    return run_warper("subnet", subnet, timeout=300)


# ==================== MTU ====================

def set_mtu(mtu: int) -> WarperResult:
    """
    Изменить MTU sing-box.

    Args:
        mtu: Значение MTU (1280-1500).

    Returns:
        WarperResult.

    Example:
        >>> set_mtu(1420)
        WarperResult(OK, 'MTU set to: 1420')
    """
    if not isinstance(mtu, int) or mtu < 1280 or mtu > 1500:
        return WarperResult(ok=False, message="MTU должен быть числом 1280-1500")
    return run_warper("mtu", str(mtu), timeout=30)


def get_mtu() -> int:
    """
    Текущий MTU sing-box.

    Returns:
        Значение MTU (int). При ошибке — 1420.

    Example:
        >>> get_mtu()
        1420
    """
    result = run_warper("config", "get", "MTU", timeout=10)
    if result.ok and result.raw_stdout.strip():
        try:
            return int(result.raw_stdout.strip())
        except ValueError:
            pass
    return 1420


# ==================== Log level ====================

def set_log_level(level: str) -> WarperResult:
    """
    Изменить log level sing-box.

    Args:
        level: 'debug' | 'info' | 'warn' | 'error'.

    Returns:
        WarperResult.

    Example:
        >>> set_log_level("debug")
        WarperResult(OK, 'Log level set to: debug')
    """
    level = str(level).strip().lower()
    valid = ("debug", "info", "warn", "error")
    if level not in valid:
        return WarperResult(
            ok=False,
            message=f"Недопустимый log level: {level}. Допустимо: {', '.join(valid)}",
        )
    return run_warper("loglevel", level, timeout=30)


def get_log_level() -> str:
    """
    Текущий log level sing-box.

    Returns:
        'debug' | 'info' | 'warn' | 'error'. При ошибке — 'info'.

    Example:
        >>> get_log_level()
        'info'
    """
    result = run_warper("config", "get", "LOG_LEVEL", timeout=10)
    if result.ok and result.raw_stdout.strip():
        return result.raw_stdout.strip()
    return "info"


# ==================== Автопатч ====================

def set_autopatch(enable: bool) -> WarperResult:
    """
    Включить/выключить автопатч DNS при загрузке системы.

    Args:
        enable: True — включить, False — выключить.

    Returns:
        WarperResult.
    """
    val = "on" if enable else "off"
    return run_warper("autopatch", val, timeout=15)


# ==================== FullVPN ====================

def set_fullvpn(enable: bool) -> WarperResult:
    """
    Включить/выключить FullVPN WARP-резолвинг.

    При включении WARPER патчит kresd@2 для FullVPN-клиентов.
    Требует VPN_WARP=n в AntiZapret.

    Args:
        enable: True — включить, False — выключить.

    Returns:
        WarperResult.
    """
    val = "on" if enable else "off"
    return run_warper("fullvpn", val, timeout=30)


# ==================== WARP-ключи ====================

def list_warp_keys() -> WarperResult:
    """
    Доступные источники WARP-ключей.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - source (str): 'system' | 'wgcf' | 'root'
            - path (str): путь к файлу
            - address (str): WARP-адрес
            - is_current (bool): используется ли сейчас

    Example:
        >>> result = list_warp_keys()
        >>> for key in result.data:
        ...     mark = " ← текущий" if key["is_current"] else ""
        ...     print(f"{key['source']}: {key['path']}{mark}")
    """
    result = run_warper("warpkey", "list", timeout=10)
    if not result.ok:
        return result

    keys = []
    for line in result.raw_stdout.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 4:
            continue
        keys.append({
            "source": parts[0],
            "path": parts[1],
            "address": parts[2],
            "is_current": parts[3] == "1",
        })

    return WarperResult(
        ok=True,
        message=f"{len(keys)} источников",
        data=keys,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


# ==================== WG-конфиги ====================

def list_wg_configs() -> WarperResult:
    """
    Доступные WireGuard-конфиги в /root/ и /root/warper/.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - path (str): полный путь к файлу
            - endpoint (str): endpoint из конфига

    Example:
        >>> result = list_wg_configs()
        >>> for cfg in result.data:
        ...     print(f"{cfg['path']} → {cfg['endpoint']}")
    """
    result = run_warper("wgconfig", "list", timeout=10)
    if not result.ok:
        return result

    configs = []
    for line in result.raw_stdout.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 2:
            continue
        configs.append({
            "path": parts[0],
            "endpoint": parts[1],
        })

    return WarperResult(
        ok=True,
        message=f"{len(configs)} конфигов",
        data=configs,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )
