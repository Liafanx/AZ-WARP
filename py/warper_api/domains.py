"""
Управление доменами WARPER.
Добавление, удаление, синхронизация, встроенные списки.
"""

from __future__ import annotations

from ._runner import run_warper, run_warper_json
from ._result import WarperResult


def add_domain(domain: str) -> WarperResult:
    """
    Добавить домен в список маршрутизации.

    Args:
        domain: Доменное имя (например 'openai.com').

    Returns:
        WarperResult.

    Example:
        >>> add_domain("openai.com")
        WarperResult(OK, 'Домен добавлен: openai.com')
    """
    domain = domain.strip().lower()
    if not domain:
        return WarperResult(ok=False, message="Домен не может быть пустым")
    return run_warper("add", domain, timeout=30)


def remove_domain(domain: str) -> WarperResult:
    """
    Удалить домен из списка маршрутизации.

    Args:
        domain: Доменное имя для удаления.

    Returns:
        WarperResult.
    """
    domain = domain.strip().lower()
    if not domain:
        return WarperResult(ok=False, message="Домен не может быть пустым")
    return run_warper("remove", domain, timeout=60)


def list_domains() -> WarperResult:
    """
    Список всех доменов с типами и статусами.

    Returns:
        WarperResult с data=list[dict].
        Каждый dict содержит:
            - name (str): доменное имя
            - type (str): 'user' | 'gemini' | 'chatgpt'
            - enabled (bool): включён ли

    Example:
        >>> result = list_domains()
        >>> for d in result.data:
        ...     print(d["name"], d["type"])
    """
    result = run_warper("domainslist", timeout=10)
    if not result.ok:
        return result

    domains = []
    for line in result.raw_stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        domains.append({
            "name": parts[0],
            "type": parts[1],
            "enabled": parts[2] == "1",
        })

    return WarperResult(
        ok=True,
        message=f"{len(domains)} доменов",
        data=domains,
        raw_stdout=result.raw_stdout,
        return_code=0,
    )


def sync_domains() -> WarperResult:
    """
    Синхронизировать домены и применить патч DNS.

    Если WARPER активен — вызывает patch_kresd.
    Если выключен — только синхронизирует файлы.

    Returns:
        WarperResult.
    """
    return run_warper("sync", timeout=120)


def enable_list(name: str) -> WarperResult:
    """
    Включить встроенный список доменов.

    Args:
        name: 'gemini' или 'chatgpt'.

    Returns:
        WarperResult.
    """
    if name not in ("gemini", "chatgpt"):
        return WarperResult(ok=False, message=f"Неизвестный список: {name}")
    return run_warper("enable", name, timeout=60)


def disable_list(name: str) -> WarperResult:
    """
    Выключить встроенный список доменов.

    Args:
        name: 'gemini' или 'chatgpt'.

    Returns:
        WarperResult.
    """
    if name not in ("gemini", "chatgpt"):
        return WarperResult(ok=False, message=f"Неизвестный список: {name}")
    return run_warper("disable", name, timeout=60)


def patch_kresd() -> WarperResult:
    """
    Переприменить патч DNS (kresd).

    Returns:
        WarperResult.
    """
    return run_warper("patch", timeout=30)

# ===== Редактирование domains.txt как текст =====

def get_user_domains_text() -> WarperResult:
    """
    Пользовательский блок domains.txt как текст.

    Без шапки файла и без блоков GEMINI/CHATGPT. Сохраняет комментарии,
    пустые строки и порядок — подходит для редактирования в textarea.

    Returns:
        WarperResult с data=str — содержимое для редактирования.
    """
    result = run_warper("domains", "list")
    if result.ok:
        result.data = result.raw_stdout.rstrip("\n")
    return result


def save_user_domains_text(text: str) -> WarperResult:
    """
    Заменяет пользовательский блок domains.txt текстом.

    Комментарии и пустые строки сохраняются, встроенные списки
    GEMINI/CHATGPT не трогаются. После записи выполняется синхронизация.

    Args:
        text: Новое содержимое пользовательского блока.

    Returns:
        WarperResult.
    """
    return run_warper("domains", "save", timeout=120,
                      input_data=text if text.endswith("\n") else text + "\n")


def update_lists() -> WarperResult:
    """
    Обновляет встроенные списки доменов (gemini/chatgpt) из репозитория
    и переприменяет их к DNS.

    Returns:
        WarperResult.
    """
    return run_warper("listupdate", timeout=120)


def _is_valid_domain_format(domain: str) -> bool:
    """Базовая валидация формата доменного имени."""
    import re

    if not domain or len(domain) > 253:
        return False
    if "." not in domain:
        return False
    parts = domain.split(".")
    if len(parts) < 2 or len(parts[-1]) < 2:
        return False
    for part in parts:
        if not part or len(part) > 63:
            return False
        if part.startswith("-") or part.endswith("-"):
            return False
        if not re.match(r"^[a-z0-9_-]+$", part):
            return False
    return True
