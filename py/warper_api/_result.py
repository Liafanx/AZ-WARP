"""
Объект результата для всех операций WARPER API.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any


@dataclass
class WarperResult:
    """
    Результат выполнения команды WARPER.

    Attributes:
        ok: True если команда выполнена успешно.
        message: Человекочитаемое сообщение (без ANSI-цветов).
        data: Произвольные структурированные данные (dict, list, ...).
        raw_stdout: Сырой stdout процесса.
        raw_stderr: Сырой stderr процесса.
        return_code: Код возврата процесса.
    """

    ok: bool
    message: str = ""
    data: Any = None
    raw_stdout: str = ""
    raw_stderr: str = ""
    return_code: int = 0

    def __bool__(self) -> bool:
        """Позволяет использовать `if result:` вместо `if result.ok:`."""
        return self.ok

    def __str__(self) -> str:
        return self.message

    def __repr__(self) -> str:
        status = "OK" if self.ok else "FAIL"
        return f"WarperResult({status}, {self.message!r})"


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def _strip_ansi(text: str) -> str:
    """Убирает ANSI escape-последовательности из текста."""
    if not text:
        return ""
    return _ANSI_RE.sub("", text)


def _make_result(
    rc: int,
    stdout: str,
    stderr: str,
    data: Any = None,
) -> WarperResult:
    """Создаёт WarperResult из результата subprocess."""
    ok = rc == 0
    raw_out = stdout.strip()
    raw_err = stderr.strip()

    message = _strip_ansi(raw_out or raw_err)
    # Сжимаем многострочные сообщения до первых 3 строк
    lines = message.splitlines()
    if len(lines) > 3:
        message = "\n".join(lines[:3]) + f"\n... ({len(lines)} строк всего)"

    return WarperResult(
        ok=ok,
        message=message,
        data=data,
        raw_stdout=raw_out,
        raw_stderr=raw_err,
        return_code=rc,
    )
