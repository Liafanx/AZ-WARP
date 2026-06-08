"""
Статистика трафика через WARPER (singbox-tun).
Текущая сессия, данные за период, краткая сводка.
"""

from __future__ import annotations

import json as _json

from ._runner import run_warper
from ._result import WarperResult


def get_traffic(period: str = "today") -> WarperResult:
    """
    Статистика трафика за указанный период.

    Args:
        period: 'today' | 'week' | 'month' | 'all'.

    Returns:
        WarperResult с data=dict:
            - current_session: {rx, tx} — текущая сессия (байты)
            - uptime: str — аптайм sing-box
            - period: str — запрошенный период
            - period_rx: int — входящий за период (байты)
            - period_tx: int — исходящий за период (байты)
            - today_rx: int — входящий за сегодня (байты)
            - today_tx: int — исходящий за сегодня (байты)

    Example:
        >>> result = get_traffic("today")
        >>> rx = result.data["period_rx"]
        >>> print(f"Получено сегодня: {rx / 1024 / 1024:.1f} MB")
    """
    if period not in ("today", "week", "month", "all"):
        period = "today"

    result = run_warper("traffic", period, "json", timeout=15)
    if not result.ok:
        return result

    try:
        data = _json.loads(result.raw_stdout)
    except _json.JSONDecodeError:
        return WarperResult(
            ok=False,
            message="Невалидный JSON",
            raw_stdout=result.raw_stdout,
        )

    return WarperResult(
        ok=True,
        message=_format_traffic_message(data, period),
        data=data,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def get_traffic_today() -> str:
    """
    Краткая строка трафика за сегодня.

    Returns:
        Строка вида '↑ 1.2 GB ↓ 3.4 GB' или 'нет данных'.

    Example:
        >>> print(get_traffic_today())
        '↑ 500 MB ↓ 1.2 GB'
    """
    result = get_traffic("today")
    if not result.ok or not result.data:
        return "нет данных"

    rx = result.data.get("today_rx", 0)
    tx = result.data.get("today_tx", 0)
    return f"↑ {_format_bytes(tx)} ↓ {_format_bytes(rx)}"


def _format_bytes(b: int) -> str:
    """Форматирует байты в человекочитаемый вид."""
    if b <= 0:
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            if b == int(b):
                return f"{int(b)} {unit}"
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def _format_traffic_message(data: dict, period: str) -> str:
    """Формирует сообщение из данных трафика."""
    labels = {
        "today": "Сегодня",
        "week": "За неделю",
        "month": "За месяц",
        "all": "За всё время",
    }
    label = labels.get(period, period)
    rx = data.get("period_rx", 0)
    tx = data.get("period_tx", 0)
    return f"{label}: ↑ {_format_bytes(tx)} ↓ {_format_bytes(rx)}"
