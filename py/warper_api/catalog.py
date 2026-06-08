"""
Каталог готовых списков доменов из v2fly/domain-list-community.
Поиск, предпросмотр, добавление, удаление, обновление.
"""

from __future__ import annotations

import json as _json

from ._runner import run_warper
from ._result import WarperResult


def search(query: str = "") -> WarperResult:
    """
    Поиск категорий в каталоге доменов.

    Args:
        query: Строка поиска. Пустая строка = популярные категории.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - name (str): имя категории
            - popular (bool): является ли популярной
            - installed (bool): установлена ли

    Example:
        >>> result = search("tiktok")
        >>> for cat in result.data:
        ...     print(cat["name"], cat["installed"])
    """
    args = ["catalog", "json", "search"]
    if query.strip():
        args.append(query.strip())

    result = run_warper(*args, timeout=45)
    if not result.ok:
        return result

    try:
        data = _json.loads(result.raw_stdout)
        if not isinstance(data, list):
            data = []
    except _json.JSONDecodeError:
        data = []

    return WarperResult(
        ok=True,
        message=f"Найдено: {len(data)}",
        data=data,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def show(name: str) -> WarperResult:
    """
    Предпросмотр доменов категории (без добавления).

    Скачивает файл с GitHub, рекурсивно разрешает include:,
    оптимизирует (убирает дубликаты и лишние поддомены).

    Args:
        name: Имя категории (например 'tiktok').

    Returns:
        WarperResult с data=dict:
            - name (str): имя категории
            - count (int): количество доменов
            - domains (list[str]): список доменов

    Example:
        >>> result = show("tiktok")
        >>> print(f"{result.data['count']} доменов")
        >>> for d in result.data["domains"][:5]:
        ...     print(d)
    """
    name = name.strip().lower()
    if not name:
        return WarperResult(ok=False, message="Имя категории не может быть пустым")

    result = run_warper("catalog", "json", "show", name, timeout=60)
    if not result.ok:
        return result

    try:
        data = _json.loads(result.raw_stdout)
    except _json.JSONDecodeError:
        return WarperResult(
            ok=False,
            message="Невалидный ответ",
            raw_stdout=result.raw_stdout,
        )

    if "error" in data:
        return WarperResult(ok=False, message=data["error"])

    return WarperResult(
        ok=True,
        message=f"{data.get('count', 0)} доменов в '{name}'",
        data=data,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def add(name: str) -> WarperResult:
    """
    Добавить каталог доменов в WARPER.

    Скачивает, резолвит include:, оптимизирует, добавляет в domains.txt.
    Не дублирует домены которые уже есть.
    Автоматически синхронизирует DNS.

    Args:
        name: Имя категории (например 'tiktok').

    Returns:
        WarperResult.

    Example:
        >>> result = add("tiktok")
        >>> if result:
        ...     print(result.message)
    """
    name = name.strip().lower()
    if not name:
        return WarperResult(ok=False, message="Имя категории не может быть пустым")
    return run_warper("catalog", "add", name, timeout=120)


def remove(name: str) -> WarperResult:
    """
    Удалить ранее добавленный каталог из WARPER.

    Удаляет домены из domains.txt и метаданные из catalog.json.

    Args:
        name: Имя каталога для удаления.

    Returns:
        WarperResult.
    """
    name = name.strip().lower()
    if not name:
        return WarperResult(ok=False, message="Имя категории не может быть пустым")
    return run_warper("catalog", "remove", name, timeout=60)


def update(name: str = "") -> WarperResult:
    """
    Обновить установленный каталог или все.

    Перескачивает домены из источника, обновляет domains.txt.

    Args:
        name: Имя конкретного каталога или пустая строка = обновить все.

    Returns:
        WarperResult.

    Example:
        >>> update()           # обновить все
        >>> update("tiktok")   # обновить только tiktok
    """
    if name:
        name = name.strip().lower()
        return run_warper("catalog", "update", name, timeout=300)
    return run_warper("catalog", "update", timeout=300)


def list_installed() -> WarperResult:
    """
    Список установленных каталогов с метаданными.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - name (str): имя категории
            - domains_count (int): количество доменов
            - added_at (str): дата добавления (ISO)
            - updated_at (str): дата последнего обновления (ISO)

    Example:
        >>> result = list_installed()
        >>> for cat in result.data:
        ...     print(f"{cat['name']}: {cat['domains_count']} доменов")
    """
    result = run_warper("catalog", "json", "installed", timeout=10)
    if not result.ok:
        return result

    try:
        data = _json.loads(result.raw_stdout)
        if not isinstance(data, list):
            data = []
    except _json.JSONDecodeError:
        data = []

    return WarperResult(
        ok=True,
        message=f"{len(data)} каталогов установлено",
        data=data,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def refresh_cache() -> WarperResult:
    """
    Принудительно обновить кэш списка категорий с GitHub.

    Returns:
        WarperResult.
    """
    return run_warper("catalog", "refresh", timeout=45)
