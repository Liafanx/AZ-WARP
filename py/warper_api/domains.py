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
    Возвращает текст пользовательского блока domains.txt
    БЕЗ шапки и БЕЗ блоков GEMINI/CHATGPT.

    Сохраняет:
        - пользовательские комментарии (# ...)
        - пустые строки
        - порядок строк

    Используется для отображения в textarea для ручного редактирования
    с сохранением комментариев каталогов вида '# Discord (catalog: discord)'.

    Returns:
        WarperResult с data=str — содержимое для редактирования.

    Example:
        >>> result = get_user_domains_text()
        >>> print(result.data)
        # Discord (catalog: discord)
        airhorn.solutions
        airhornbot.com
        ...

        # Telegram (catalog: telegram)
        telegram.org
        ...
    """
    import os
    import re

    domains_file = "/root/warper/domains.txt"

    if not os.path.exists(domains_file):
        return WarperResult(ok=True, message="Файл доменов отсутствует", data="")

    try:
        with open(domains_file, "r", encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        return WarperResult(ok=False, message=f"Ошибка чтения: {e}", data="")

    lines = content.splitlines()
    user_lines: list[str] = []
    in_block = False
    skip_header = True
    header_marker = "# Пользовательские домены:"

    for ln in lines:
        # Пропускаем шапку до маркера
        if skip_header:
            if ln.strip() == header_marker:
                skip_header = False
            continue

        # Пропускаем блоки GEMINI/CHATGPT целиком
        if re.match(r"^# --- [A-Z0-9_]+ ---$", ln.strip()):
            in_block = True
            continue
        if re.match(r"^# --- END [A-Z0-9_]+ ---$", ln.strip()):
            in_block = False
            continue
        if in_block:
            continue

        user_lines.append(ln)

    # Убираем хвостовые пустые строки
    while user_lines and not user_lines[-1].strip():
        user_lines.pop()

    text = "\n".join(user_lines)

    return WarperResult(
        ok=True,
        message=f"{len([l for l in user_lines if l.strip() and not l.strip().startswith('#')])} доменов",
        data=text,
    )


def save_user_domains_text(text: str) -> WarperResult:
    """
    Сохраняет текст пользовательского блока в domains.txt и запускает синхронизацию.

    Сохраняет:
        - пользовательские комментарии (# ...)
        - пустые строки
        - порядок строк

    Восстанавливает:
        - шапку файла
        - блоки GEMINI/CHATGPT из существующего файла

    Валидирует только строки-домены. Комментарии и пустые строки сохраняются как есть.

    Args:
        text: Содержимое для записи в пользовательский блок.

    Returns:
        WarperResult.

    Example:
        >>> text = '''# Мои домены
        ... example.com
        ... openai.com
        ...
        ... # Discord
        ... discord.com'''
        >>> result = save_user_domains_text(text)
        >>> if result:
        ...     print(result.message)
        'Сохранено 3 доменов, синхронизация выполнена'
    """
    import os
    import re

    domains_file = "/root/warper/domains.txt"
    header_marker = "# Пользовательские домены:"

    # Фильтруем строку маркера если пользователь её ввёл вручную
    raw_lines = [ln for ln in text.splitlines() if ln.strip() != header_marker]

    # Валидация только доменов
    invalid: list[str] = []
    valid_count = 0

    for raw in raw_lines:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if not _is_valid_domain_format(s.lower()):
            invalid.append(s)
        else:
            valid_count += 1

    if invalid:
        msg = "Некорректные домены: " + ", ".join(invalid[:5])
        if len(invalid) > 5:
            msg += f" (и ещё {len(invalid) - 5})"
        return WarperResult(ok=False, message=msg)

    # Убираем хвостовые пустые строки
    while raw_lines and not raw_lines[-1].strip():
        raw_lines.pop()

    # Читаем существующие блоки GEMINI/CHATGPT
    gemini_block: list[str] = []
    chatgpt_block: list[str] = []

    if os.path.exists(domains_file):
        try:
            with open(domains_file, "r", encoding="utf-8") as f:
                existing = f.read().splitlines()
        except OSError:
            existing = []

        block: str | None = None
        for ln in existing:
            stripped = ln.strip()
            if stripped == "# --- GEMINI ---":
                block = "gemini"
                gemini_block.append(ln)
                continue
            if stripped == "# --- END GEMINI ---":
                gemini_block.append(ln)
                block = None
                continue
            if stripped == "# --- CHATGPT ---":
                block = "chatgpt"
                chatgpt_block.append(ln)
                continue
            if stripped == "# --- END CHATGPT ---":
                chatgpt_block.append(ln)
                block = None
                continue
            if block == "gemini":
                gemini_block.append(ln)
            elif block == "chatgpt":
                chatgpt_block.append(ln)

    # Собираем итоговый файл
    out_lines = [
        "# ==========================================",
        "# СПИСОК ДОМЕНОВ ДЛЯ МАРШРУТИЗАЦИИ WARP",
        "# Строки, начинающиеся с '#', игнорируются.",
        "# ⚠️ НЕ удаляйте служебные маркеры блоков GEMINI/CHATGPT",
        "# ==========================================",
        "",
        header_marker,
    ]
    out_lines.extend(raw_lines)

    if gemini_block:
        out_lines.append("")
        out_lines.extend(gemini_block)
    if chatgpt_block:
        out_lines.append("")
        out_lines.extend(chatgpt_block)

    # Записываем файл
    try:
        with open(domains_file, "w", encoding="utf-8") as f:
            f.write("\n".join(out_lines) + "\n")
    except OSError as e:
        return WarperResult(ok=False, message=f"Ошибка записи: {e}")

    # Запускаем sync
    sync_result = sync_domains()
    if not sync_result.ok:
        return WarperResult(
            ok=False,
            message=f"Файл сохранён, но sync упал: {sync_result.message}",
        )

    return WarperResult(
        ok=True,
        message=f"Сохранено {valid_count} доменов, синхронизация выполнена",
        data={"count": valid_count},
    )


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
