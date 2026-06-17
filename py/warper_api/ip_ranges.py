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

# ===== Редактирование ip-ranges.txt как текст =====

def get_ip_ranges_text() -> WarperResult:
    """
    Возвращает текст ip-ranges.txt без стандартной шапки-инструкции.

    Сохраняет:
        - пользовательские комментарии (# ...)
        - пустые строки
        - порядок строк

    Используется для отображения в textarea для ручного редактирования
    с сохранением комментариев групп вида '# Telegram CIDRs'.

    Returns:
        WarperResult с data=str — содержимое для редактирования.

    Example:
        >>> result = get_ip_ranges_text()
        >>> print(result.data)
        # Telegram
        91.108.4.0/22
        91.108.8.0/22
        149.154.160.0/20

        # Discord
        162.159.128.0/19
    """
    result = run_warper("ipranges", "list", timeout=10)
    if not result.ok:
        return WarperResult(
            ok=False,
            message=result.message,
            data="",
        )

    return WarperResult(
        ok=True,
        message=f"{len([l for l in result.raw_stdout.splitlines() if l.strip() and not l.strip().startswith('#')])} подсетей",
        data=result.raw_stdout,
    )


def save_ip_ranges_text(text: str) -> WarperResult:
    """
    Сохраняет текст в ip-ranges.txt и запускает синхронизацию маршрутов.

    Сохраняет:
        - пользовательские комментарии (# ...)
        - пустые строки
        - порядок строк

    Валидирует только CIDR-строки. Комментарии и пустые строки сохраняются как есть.
    Если CIDR указан без маски — автоматически добавляется /32.

    Args:
        text: Содержимое для записи в ip-ranges.txt.

    Returns:
        WarperResult.

    Example:
        >>> text = '''# Telegram
        ... 91.108.4.0/22
        ... 91.108.8.0/22
        ...
        ... # Один IP
        ... 1.2.3.4'''
        >>> result = save_ip_ranges_text(text)
        >>> if result:
        ...     print(result.message)
        'Сохранено 3 подсетей'
    """
    import subprocess
    import re

    # Валидация только CIDR (комментарии и пустые пропускаем)
    invalid: list[str] = []
    valid_count = 0

    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue

        cidr = s if "/" in s else f"{s}/32"
        if not _is_valid_cidr_format(cidr):
            invalid.append(s)
        else:
            valid_count += 1

    if invalid:
        msg = "Некорректные CIDR: " + ", ".join(invalid[:5])
        if len(invalid) > 5:
            msg += f" (и ещё {len(invalid) - 5})"
        return WarperResult(ok=False, message=msg)

    # Передаём через stdin в warper ipranges save
    content = text if text.endswith("\n") else text + "\n"

    try:
        from ._runner import WARPER_BIN
        proc = subprocess.run(
            [WARPER_BIN, "ipranges", "save"],
            input=content,
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            from ._result import _strip_ansi
            err_msg = _strip_ansi((proc.stderr or proc.stdout).strip())
            return WarperResult(
                ok=False,
                message=err_msg or "Ошибка сохранения",
                raw_stdout=proc.stdout,
                raw_stderr=proc.stderr,
                return_code=proc.returncode,
            )
    except subprocess.TimeoutExpired:
        return WarperResult(ok=False, message="Таймаут операции (>180с)")
    except Exception as e:
        return WarperResult(ok=False, message=str(e))

    return WarperResult(
        ok=True,
        message=f"Сохранено {valid_count} подсетей",
        data={"count": valid_count},
    )


def _is_valid_cidr_format(cidr: str) -> bool:
    """
    Базовая валидация формата CIDR A.B.C.D/M.
    Отклоняет loopback, multicast, link-local, нулевой октет.
    """
    import re

    m = re.match(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$", cidr)
    if not m:
        return False

    octets = [int(x) for x in m.groups()[:4]]
    mask = int(m.group(5))

    if any(o > 255 for o in octets):
        return False
    if not 1 <= mask <= 32:
        return False
    # Loopback / нулевой / multicast
    if octets[0] in (0, 127) or octets[0] >= 224:
        return False
    # Link-local
    if octets[0] == 169 and octets[1] == 254:
        return False

    return True
