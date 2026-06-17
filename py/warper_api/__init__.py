"""
WARPER API — Python-интерфейс для управления WARPER (AZ-WARP).

Использование:
    from warper_api import WarperAPI

    w = WarperAPI()
    status = w.get_status()
    print(status.data["version"])

    result = w.add_domain("example.com")
    if result:
        print("Домен добавлен!")

Требования:
    - WARPER установлен на сервере (/usr/local/bin/warper)
    - Python 3.9+
    - Запуск от root

Репозиторий: https://github.com/Liafanx/AZ-WARP
"""

from __future__ import annotations

import os
from typing import Any

from ._result import WarperResult
from . import domains
from . import ip_ranges
from . import catalog
from . import singbox
from . import settings
from . import traffic
from . import status

__version__: str = "0.0.0"

# Читаем версию из файла WARPER
_VERSION_FILE = "/root/warper/version"
if os.path.exists(_VERSION_FILE):
    try:
        with open(_VERSION_FILE, "r") as _f:
            __version__ = _f.read().strip()
    except OSError:
        pass


class WarperAPI:
    """
    Фасад для управления WARPER из Python.

    Все методы возвращают WarperResult — объект с полями:
        .ok (bool) — успешно ли
        .message (str) — человекочитаемое сообщение
        .data (Any) — структурированные данные (если есть)

    WarperResult поддерживает bool: `if result:` эквивалентно `if result.ok:`.

    Example:
        >>> w = WarperAPI()
        >>> w.is_active()
        True
        >>> w.add_domain("openai.com")
        WarperResult(OK, 'Домен добавлен: openai.com')
    """

    def __init__(self) -> None:
        """Инициализация API. Не требует аргументов."""
        self._version = __version__

    @property
    def version(self) -> str:
        """Версия WARPER."""
        return self._version

    # ==================== Статус ====================

    def get_status(self) -> WarperResult:
        """
        Полный статус WARPER в JSON.

        Returns:
            WarperResult с data=dict со всеми параметрами.
        """
        return status.get_status()

    def is_active(self) -> bool:
        """Проверяет: WARPER полностью активен (sing-box + kresd patched)."""
        return status.is_active()

    def get_version(self) -> str:
        """Возвращает версию WARPER."""
        return self._version

    def doctor(self) -> WarperResult:
        """
        Запускает полную диагностику.

        Returns:
            WarperResult с data=list[dict] результатов проверок.
        """
        return status.doctor()

    # ==================== WARPER toggle ====================

    def toggle(self) -> WarperResult:
        """Включить или выключить WARPER целиком."""
        return status.toggle()

    def enable(self) -> WarperResult:
        """Включить WARPER (если выключен)."""
        if self.is_active():
            return WarperResult(ok=True, message="WARPER уже активен")
        return self.toggle()

    def disable(self) -> WarperResult:
        """Выключить WARPER (если включён)."""
        if not self.is_active():
            return WarperResult(ok=True, message="WARPER уже выключен")
        return self.toggle()

    # ==================== Домены ====================

    def add_domain(self, domain: str) -> WarperResult:
        """
        Добавить домен в список маршрутизации.

        Args:
            domain: Доменное имя (например 'openai.com').
        """
        return domains.add_domain(domain)

    def remove_domain(self, domain: str) -> WarperResult:
        """Удалить домен из списка маршрутизации."""
        return domains.remove_domain(domain)

    def list_domains(self) -> WarperResult:
        """
        Список всех доменов.

        Returns:
            WarperResult с data=list[dict] с полями name, type, enabled.
        """
        return domains.list_domains()

    def sync_domains(self) -> WarperResult:
        """Синхронизировать домены и применить патч DNS."""
        return domains.sync_domains()

    def enable_list(self, name: str) -> WarperResult:
        """
        Включить встроенный список доменов.

        Args:
            name: 'gemini' или 'chatgpt'.
        """
        return domains.enable_list(name)

    def disable_list(self, name: str) -> WarperResult:
        """Выключить встроенный список доменов."""
        return domains.disable_list(name)

    def patch_kresd(self) -> WarperResult:
        """Переприменить патч DNS (kresd)."""
        return domains.patch_kresd()

    def get_user_domains_text(self) -> WarperResult:
        """
        Возвращает текст domains.txt для редактирования в textarea.

        Returns:
            WarperResult с data=str — содержимое без шапки и встроенных блоков.
        """
        return domains.get_user_domains_text()

    def save_user_domains_text(self, text: str) -> WarperResult:
        """
        Сохраняет текст в domains.txt и запускает синхронизацию.

        Args:
            text: Содержимое для записи (с комментариями и пустыми строками).
        """
        return domains.save_user_domains_text(text)    

    # ==================== IP-подсети ====================

    def add_ip_range(self, cidr: str) -> WarperResult:
        """
        Добавить IP-подсеть для маршрутизации.

        Args:
            cidr: Подсеть в формате A.B.C.D/M (например '91.108.4.0/22').
        """
        return ip_ranges.add_ip_range(cidr)

    def remove_ip_range(self, cidr: str) -> WarperResult:
        """Удалить IP-подсеть."""
        return ip_ranges.remove_ip_range(cidr)

    def sync_ip_ranges(self) -> WarperResult:
        """Синхронизировать IP-маршруты (файл → ядро)."""
        return ip_ranges.sync_ip_ranges()

    def list_ip_ranges(self) -> WarperResult:
        """
        Список подсетей из файла.

        Returns:
            WarperResult с data=list[str] CIDR.
        """
        return ip_ranges.list_ip_ranges()

    def list_ip_routes(self) -> WarperResult:
        """
        Список применённых маршрутов в ядре.

        Returns:
            WarperResult с data=list[str] CIDR.
        """
        return ip_ranges.list_ip_routes()

    def set_ip_route_mode(self, mode: str) -> WarperResult:
        """
        Режим применения IP-маршрутов.

        Args:
            mode: 'antizapret' | 'all_vpn' | 'all'.
        """
        return ip_ranges.set_ip_route_mode(mode)

    def set_ip_export(self, enable: bool) -> WarperResult:
        """Включить/выключить экспорт CIDR в AntiZapret."""
        return ip_ranges.set_ip_export(enable)

    def get_ip_ranges_text(self) -> WarperResult:
        """
        Возвращает текст ip-ranges.txt для редактирования в textarea.

        Returns:
            WarperResult с data=str — содержимое без стандартной шапки.
        """
        return ip_ranges.get_ip_ranges_text()

    def save_ip_ranges_text(self, text: str) -> WarperResult:
        """
        Сохраняет текст в ip-ranges.txt и запускает синхронизацию маршрутов.

        Args:
            text: Содержимое для записи (с комментариями и пустыми строками).
        """
        return ip_ranges.save_ip_ranges_text(text)

    # ==================== Каталог ====================

    def catalog_search(self, query: str = "") -> WarperResult:
        """
        Поиск категорий в каталоге доменов.

        Args:
            query: Строка поиска (пустая = популярные).

        Returns:
            WarperResult с data=list[dict] найденных категорий.
        """
        return catalog.search(query)

    def catalog_show(self, name: str) -> WarperResult:
        """
        Предпросмотр доменов категории.

        Args:
            name: Имя категории (например 'tiktok').

        Returns:
            WarperResult с data=dict{name, count, domains}.
        """
        return catalog.show(name)

    def catalog_add(self, name: str) -> WarperResult:
        """Добавить каталог доменов в WARPER."""
        return catalog.add(name)

    def catalog_remove(self, name: str) -> WarperResult:
        """Удалить ранее добавленный каталог."""
        return catalog.remove(name)

    def catalog_update(self, name: str = "") -> WarperResult:
        """
        Обновить каталог(и).

        Args:
            name: Конкретный каталог или пустая строка = все.
        """
        return catalog.update(name)

    def catalog_list_installed(self) -> WarperResult:
        """
        Список установленных каталогов.

        Returns:
            WarperResult с data=list[dict].
        """
        return catalog.list_installed()

    def catalog_refresh_cache(self) -> WarperResult:
        """Принудительно обновить кэш списка категорий."""
        return catalog.refresh_cache()

    # ==================== Sing-box ====================

    def singbox_start(self) -> WarperResult:
        """Запустить sing-box."""
        return singbox.start()

    def singbox_stop(self) -> WarperResult:
        """Остановить sing-box."""
        return singbox.stop()

    def singbox_restart(self) -> WarperResult:
        """Перезапустить sing-box."""
        return singbox.restart()

    def singbox_enable(self) -> WarperResult:
        """Включить автозагрузку sing-box."""
        return singbox.enable()

    def singbox_disable(self) -> WarperResult:
        """Выключить автозагрузку sing-box."""
        return singbox.disable()

    def get_logs(self, lines: int = 100) -> WarperResult:
        """
        Получить логи sing-box.

        Args:
            lines: Количество строк (по умолчанию 100, макс 2000).

        Returns:
            WarperResult с data=list[str] строк лога.
        """
        return singbox.get_logs(lines)

    # ==================== Настройки ====================

    def set_mode_warp(self, key_source: str = "") -> WarperResult:
        """
        Переключить на режим WARP.

        Args:
            key_source: '' | 'system' | 'wgcf' | 'root' | 'generate'.
        """
        return settings.set_mode_warp(key_source)

    def set_mode_slave(
        self, server: str, port: str | int, password: str
    ) -> WarperResult:
        """
        Переключить на режим Slave.

        Args:
            server: IP или домен донор-сервера.
            port: Порт Shadowsocks.
            password: Ключ Shadowsocks.
        """
        return settings.set_mode_slave(server, port, password)

    def set_mode_wg(self, conf_path: str) -> WarperResult:
        """
        Переключить на режим WireGuard.

        Args:
            conf_path: Путь к .conf файлу WireGuard.
        """
        return settings.set_mode_wg(conf_path)

    def get_mode(self) -> str:
        """Текущий режим маршрутизации: 'warp' | 'slave' | 'wg'."""
        return settings.get_mode()

    def set_subnet(self, subnet: str) -> WarperResult:
        """
        Изменить fake-подсеть.

        Args:
            subnet: Подсеть формата X.X.X.0/M (например '198.20.0.0/24').
        """
        return settings.set_subnet(subnet)

    def set_mtu(self, mtu: int) -> WarperResult:
        """
        Изменить MTU sing-box (1280-1500).

        Args:
            mtu: Значение MTU.
        """
        return settings.set_mtu(mtu)

    def set_log_level(self, level: str) -> WarperResult:
        """
        Изменить log level sing-box.

        Args:
            level: 'debug' | 'info' | 'warn' | 'error'.
        """
        return settings.set_log_level(level)

    def set_autopatch(self, enable: bool) -> WarperResult:
        """Включить/выключить автопатч DNS при загрузке."""
        return settings.set_autopatch(enable)

    def set_fullvpn(self, enable: bool) -> WarperResult:
        """Включить/выключить FullVPN WARP-резолвинг."""
        return settings.set_fullvpn(enable)

    def list_warp_keys(self) -> WarperResult:
        """
        Доступные источники WARP-ключей.

        Returns:
            WarperResult с data=list[dict].
        """
        return settings.list_warp_keys()

    def list_wg_configs(self) -> WarperResult:
        """
        Доступные WireGuard-конфиги.

        Returns:
            WarperResult с data=list[dict].
        """
        return settings.list_wg_configs()

    # ==================== Трафик ====================

    def get_traffic(self, period: str = "today") -> WarperResult:
        """
        Статистика трафика за период.

        Args:
            period: 'today' | 'week' | 'month' | 'all'.

        Returns:
            WarperResult с data=dict с полями current_session, period_rx, period_tx и т.д.
        """
        return traffic.get_traffic(period)

    def get_traffic_today(self) -> str:
        """Краткая строка трафика за сегодня: '↑ 1.2 GB ↓ 3.4 GB'."""
        return traffic.get_traffic_today()
