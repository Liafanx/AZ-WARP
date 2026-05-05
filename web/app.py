"""
AZ-WARP Web Panel
Главный Flask-приложение с роутами и HTMX endpoints.
"""

import logging
import os
import sys
from functools import wraps
from pathlib import Path

from dotenv import load_dotenv
from flask import (
    Flask, abort, flash, jsonify, make_response,
    redirect, render_template, request, url_for,
)
from flask_login import current_user, login_required, login_user, logout_user

# Добавляем текущую директорию в path
sys.path.insert(0, str(Path(__file__).parent))

import warper_api as api
from auth import (
    AdminUser, init_auth, update_credentials, verify_credentials,
)


# ===== Инициализация =====

load_dotenv(Path(__file__).parent / ".env")

app = Flask(
    __name__,
    template_folder=str(Path(__file__).parent / "templates"),
    static_folder=str(Path(__file__).parent / "static"),
    static_url_path="/static",
)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", os.urandom(32).hex())
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["MAX_CONTENT_LENGTH"] = 1 * 1024 * 1024  # 1 MB на загрузку WG конфига

init_auth(app)

# Логирование
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


# ===== Утилиты ответов =====

def _is_htmx() -> bool:
    return request.headers.get("HX-Request") == "true"


def _flash_partial(message: str, category: str = "success"):
    """Возвращает HTML-фрагмент с уведомлением для HTMX (через HX-Trigger)."""
    resp = make_response("")
    # Используем HX-Trigger для показа toast через JS
    import json as _json
    payload = _json.dumps({"showToast": {"message": message, "category": category}})
    resp.headers["HX-Trigger"] = payload
    return resp


def _result_partial(ok: bool, message: str, refresh_target: str | None = None):
    """
    Универсальный ответ на HTMX-действие.
    Возвращает фрагмент уведомления и опционально триггерит обновление.
    """
    import json as _json
    category = "success" if ok else "error"
    triggers: dict = {"showToast": {"message": message, "category": category}}
    if ok and refresh_target:
        triggers[refresh_target] = True

    resp = make_response("")
    resp.headers["HX-Trigger"] = _json.dumps(triggers)
    return resp


# ===== Роуты страниц =====

@app.route("/")
@login_required
def index():
    return redirect(url_for("dashboard"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard"))

    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if verify_credentials(username, password):
            login_user(AdminUser(username), remember=True)
            logger.info("Успешный вход: %s", username)
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль", "error")
        logger.warning("Неудачная попытка входа: %s", username)

    return render_template("login.html")


@app.route("/logout")
@login_required
def logout():
    logout_user()
    flash("Вы вышли из системы", "info")
    return redirect(url_for("login"))


@app.route("/dashboard")
@login_required
def dashboard():
    status = api.get_status()
    return render_template("dashboard.html", status=status)


@app.route("/domains")
@login_required
def domains_page():
    return render_template("domains.html")


@app.route("/ip-ranges")
@login_required
def ip_ranges_page():
    return render_template("ip_ranges.html")


@app.route("/singbox")
@login_required
def singbox_page():
    return render_template("singbox.html")


@app.route("/logs")
@login_required
def logs_page():
    return render_template("logs.html")


@app.route("/diagnostics")
@login_required
def diagnostics_page():
    return render_template("diagnostics.html")


@app.route("/settings")
@login_required
def settings_page():
    status = api.get_status()
    warp_keys = api.list_warp_keys()
    wg_configs = api.list_wg_configs()
    return render_template(
        "settings.html",
        status=status,
        warp_keys=warp_keys,
        wg_configs=wg_configs,
    )


# ===== HTMX endpoints: статус =====

@app.route("/htmx/status-summary")
@login_required
def htmx_status_summary():
    status = api.get_status()
    return render_template("partials/status_summary.html", status=status)


# ===== HTMX endpoints: домены =====

@app.route("/htmx/domains-list")
@login_required
def htmx_domains_list():
    filter_type = request.args.get("type") or None
    if filter_type == "all":
        filter_type = None
    search = request.args.get("q") or None
    domains = api.get_domains(filter_type=filter_type, search=search)

    # Также узнаём состояние списков
    all_domains = api.get_domains()
    gemini_enabled = any(d["enabled"] for d in all_domains if d["type"] == "gemini")
    chatgpt_enabled = any(d["enabled"] for d in all_domains if d["type"] == "chatgpt")
    has_gemini = any(d["type"] == "gemini" for d in all_domains)
    has_chatgpt = any(d["type"] == "chatgpt" for d in all_domains)

    return render_template(
        "partials/domains_list.html",
        domains=domains,
        gemini_enabled=gemini_enabled,
        chatgpt_enabled=chatgpt_enabled,
        has_gemini=has_gemini,
        has_chatgpt=has_chatgpt,
        current_filter=filter_type or "all",
        current_search=search or "",
    )


@app.route("/htmx/domains/add", methods=["POST"])
@login_required
def htmx_domain_add():
    domain = request.form.get("domain", "").strip()
    if not domain:
        return _result_partial(False, "Введите домен")
    ok, msg = api.add_domain(domain)
    return _result_partial(ok, msg or ("Домен добавлен" if ok else "Ошибка"), "refreshDomains")


@app.route("/htmx/domains/bulk-add", methods=["POST"])
@login_required
def htmx_domain_bulk_add():
    raw = request.form.get("domains", "")
    domains = [line.strip() for line in raw.splitlines() if line.strip()]
    if not domains:
        return _result_partial(False, "Список пуст")
    result = api.add_domains_bulk(domains)
    msg = (
        f"Добавлено: {result['added_count']}, "
        f"пропущено: {result['skipped_count']}, "
        f"ошибок: {result['error_count']}"
    )
    return _result_partial(True, msg, "refreshDomains")


@app.route("/htmx/domains/delete", methods=["POST"])
@login_required
def htmx_domain_delete():
    domain = request.form.get("domain", "").strip()
    if not domain:
        return _result_partial(False, "Не указан домен")
    ok, msg = api.remove_domain(domain)
    return _result_partial(ok, msg or "Удалено", "refreshDomains")


@app.route("/htmx/domains/list-toggle", methods=["POST"])
@login_required
def htmx_list_toggle():
    list_name = request.form.get("list", "")
    enable = request.form.get("enable", "0") == "1"
    if list_name not in ("gemini", "chatgpt"):
        return _result_partial(False, "Неизвестный список")
    ok, msg = api.toggle_list(list_name, enable)
    return _result_partial(ok, msg or "Готово", "refreshDomains")


@app.route("/htmx/domains/sync", methods=["POST"])
@login_required
def htmx_domain_sync():
    ok, msg = api.sync_domains()
    return _result_partial(ok, msg or "Синхронизация завершена", "refreshDomains")


# ===== HTMX endpoints: IP-подсети =====

@app.route("/htmx/ip-ranges-list")
@login_required
def htmx_ip_ranges_list():
    search = request.args.get("q") or None
    ranges = api.get_ip_ranges(search=search)
    routes = api.get_active_ip_routes()
    return render_template(
        "partials/ip_ranges_list.html",
        ranges=ranges,
        routes_count=len(routes),
        current_search=search or "",
    )


@app.route("/htmx/ip-ranges/add", methods=["POST"])
@login_required
def htmx_ip_add():
    cidr = request.form.get("cidr", "").strip()
    if not cidr:
        return _result_partial(False, "Введите CIDR")
    ok, msg = api.add_ip_range(cidr)
    return _result_partial(ok, msg or "Добавлено", "refreshIpRanges")


@app.route("/htmx/ip-ranges/bulk-add", methods=["POST"])
@login_required
def htmx_ip_bulk_add():
    raw = request.form.get("cidrs", "")
    cidrs = [line.strip() for line in raw.splitlines() if line.strip()]
    if not cidrs:
        return _result_partial(False, "Список пуст")
    result = api.add_ip_ranges_bulk(cidrs)
    msg = (
        f"Добавлено: {result['added_count']}, "
        f"пропущено: {result['skipped_count']}, "
        f"ошибок: {result['error_count']}"
    )
    return _result_partial(True, msg, "refreshIpRanges")


@app.route("/htmx/ip-ranges/delete", methods=["POST"])
@login_required
def htmx_ip_delete():
    cidr = request.form.get("cidr", "").strip()
    if not cidr:
        return _result_partial(False, "Не указан CIDR")
    ok, msg = api.remove_ip_range(cidr)
    return _result_partial(ok, msg or "Удалено", "refreshIpRanges")


@app.route("/htmx/ip-ranges/sync", methods=["POST"])
@login_required
def htmx_ip_sync():
    ok, msg = api.sync_ip_ranges()
    return _result_partial(ok, msg or "Синхронизировано", "refreshIpRanges")


@app.route("/htmx/ip-ranges/mode", methods=["POST"])
@login_required
def htmx_ip_mode():
    mode = request.form.get("mode", "")
    ok, msg = api.set_ip_route_mode(mode)
    return _result_partial(ok, msg, "refreshIpRanges")


@app.route("/htmx/ip-ranges/export-toggle", methods=["POST"])
@login_required
def htmx_ip_export_toggle():
    enable = request.form.get("enable", "0") == "1"
    ok, msg = api.set_ip_export(enable)
    return _result_partial(ok, msg, "refreshIpRanges")


# ===== HTMX endpoints: sing-box =====

@app.route("/htmx/singbox-status")
@login_required
def htmx_singbox_status():
    status = api.get_status()
    return render_template("partials/singbox_status.html", status=status)


@app.route("/htmx/singbox/<action>", methods=["POST"])
@login_required
def htmx_singbox_action(action: str):
    if action not in ("start", "stop", "restart", "enable", "disable"):
        abort(400)
    ok, msg = api.singbox_action(action)
    return _result_partial(ok, msg or f"sing-box {action}", "refreshSingbox")


@app.route("/htmx/toggle-warper", methods=["POST"])
@login_required
def htmx_toggle_warper():
    ok, msg = api.toggle_warper()
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/patch-kresd", methods=["POST"])
@login_required
def htmx_patch_kresd():
    ok, msg = api.patch_kresd()
    return _result_partial(ok, msg, "refreshAll")


# ===== HTMX endpoints: логи =====

@app.route("/htmx/logs")
@login_required
def htmx_logs():
    try:
        lines = int(request.args.get("lines", 200))
    except ValueError:
        lines = 200
    level = request.args.get("level") or None
    if level == "ALL":
        level = None
    logs = api.get_logs(lines=lines, level_filter=level)
    return render_template("partials/logs_content.html", logs=logs)


# ===== HTMX endpoints: диагностика =====

@app.route("/htmx/doctor")
@login_required
def htmx_doctor():
    results = api.get_doctor()
    return render_template("partials/doctor_results.html", results=results)


# ===== HTMX endpoints: настройки =====

@app.route("/htmx/settings/autopatch", methods=["POST"])
@login_required
def htmx_settings_autopatch():
    enable = request.form.get("enable", "0") == "1"
    ok, msg = api.set_autopatch(enable)
    return _result_partial(ok, msg, "refreshSettings")


@app.route("/htmx/settings/fullvpn", methods=["POST"])
@login_required
def htmx_settings_fullvpn():
    enable = request.form.get("enable", "0") == "1"
    ok, msg = api.set_fullvpn(enable)
    return _result_partial(ok, msg, "refreshSettings")


@app.route("/htmx/settings/log-level", methods=["POST"])
@login_required
def htmx_settings_log_level():
    level = request.form.get("level", "")
    ok, msg = api.set_log_level(level)
    return _result_partial(ok, msg, "refreshSettings")


@app.route("/htmx/settings/mtu", methods=["POST"])
@login_required
def htmx_settings_mtu():
    try:
        mtu = int(request.form.get("mtu", "0"))
    except ValueError:
        return _result_partial(False, "MTU должен быть числом")
    ok, msg = api.set_mtu(mtu)
    return _result_partial(ok, msg, "refreshSettings")


@app.route("/htmx/settings/subnet", methods=["POST"])
@login_required
def htmx_settings_subnet():
    subnet = request.form.get("subnet", "").strip()
    ok, msg = api.set_subnet(subnet)
    return _result_partial(ok, msg, "refreshSettings")


@app.route("/htmx/settings/mode/warp", methods=["POST"])
@login_required
def htmx_mode_warp():
    key_source = request.form.get("key_source", "").strip()
    ok, msg = api.switch_to_warp(key_source)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/mode/slave", methods=["POST"])
@login_required
def htmx_mode_slave():
    server = request.form.get("server", "")
    port = request.form.get("port", "")
    password = request.form.get("password", "")
    ok, msg = api.switch_to_slave(server, port, password)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/mode/wg", methods=["POST"])
@login_required
def htmx_mode_wg():
    conf_path = request.form.get("conf_path", "").strip()
    ok, msg = api.switch_to_wg(conf_path)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/wg-upload", methods=["POST"])
@login_required
def htmx_wg_upload():
    if "wg_file" not in request.files:
        return _result_partial(False, "Файл не выбран")
    file = request.files["wg_file"]
    if not file.filename:
        return _result_partial(False, "Файл не выбран")
    try:
        content = file.read().decode("utf-8")
    except UnicodeDecodeError:
        return _result_partial(False, "Файл не является текстовым")

    ok, msg, path = api.upload_wg_config(file.filename, content)
    if not ok:
        return _result_partial(False, msg)

    # Сразу применяем
    ok2, msg2 = api.switch_to_wg(path)
    if ok2:
        return _result_partial(True, f"{msg}; {msg2}", "refreshAll")
    return _result_partial(False, f"Загружено, но не применено: {msg2}")


@app.route("/htmx/settings/credentials", methods=["POST"])
@login_required
def htmx_credentials():
    new_user = request.form.get("username", "")
    new_pass = request.form.get("password", "")
    ok, msg = update_credentials(new_user, new_pass)
    return _result_partial(ok, msg)


# ===== Контекст шаблонов =====

@app.context_processor
def inject_globals():
    """Доступно во всех шаблонах."""
    return {
        "current_user": current_user,
        "site_name": "AZ-WARP",
    }


# ===== Запуск =====

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 16060))
    debug = os.environ.get("DEBUG", "false").lower() == "true"
    app.run(host="127.0.0.1", port=port, debug=debug)
