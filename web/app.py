"""
AZ-WARP Web Panel
Главное Flask-приложение с роутами и HTMX endpoints.
"""

import json as _json
import logging
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from flask import (
    Flask, abort, flash, make_response,
    redirect, render_template, request, url_for,
)
from flask_login import current_user, login_required, login_user, logout_user

sys.path.insert(0, str(Path(__file__).parent))

import warper_api as api
from auth import (
    AdminUser, init_auth, update_credentials, verify_credentials,
    get_or_create_secret_key, is_ip_blocked,
)


# ===== Инициализация =====

load_dotenv(Path(__file__).parent / ".env")

app = Flask(
    __name__,
    template_folder=str(Path(__file__).parent / "templates"),
    static_folder=str(Path(__file__).parent / "static"),
    static_url_path="/static",
)
from auth import get_or_create_secret_key
app.config["SECRET_KEY"] = get_or_create_secret_key()
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["MAX_CONTENT_LENGTH"] = 1 * 1024 * 1024

init_auth(app)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


# ===== Помощники =====

def _result_partial(ok, message, refresh_target=None):
    """
    204 + HX-Trigger для toast и обновления.
    КРИТИЧНО: HTTP заголовки требуют ASCII-only без переносов строк и спец-символов.
    """
    category = "success" if ok else "error"

    # Чистим сообщение: убираем переносы строк, табы, контрольные символы
    safe_msg = (message or ("Готово" if ok else "Ошибка"))
    # Убираем все управляющие символы (включая \r \n \t)
    safe_msg = "".join(ch if ch >= " " or ch == " " else " " for ch in str(safe_msg))
    # Сжимаем пробелы
    safe_msg = " ".join(safe_msg.split())
    # Обрезаем слишком длинные сообщения
    if len(safe_msg) > 500:
        safe_msg = safe_msg[:497] + "..."

    triggers = {
        "showToast": {"message": safe_msg, "category": category}
    }
    if ok and refresh_target:
        triggers[refresh_target] = True

    # ensure_ascii=True - ВАЖНО, иначе кириллица ломает HTTP заголовок
    header_value = _json.dumps(triggers, ensure_ascii=True)

    resp = make_response("", 204)
    resp.headers["HX-Trigger"] = header_value
    return resp


# ===== Страницы =====

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

        ok, error_msg = verify_credentials(username, password)
        if ok:
            login_user(AdminUser(username), remember=True)
            return redirect(url_for("dashboard"))

        flash(error_msg, "error")

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
    status = api.get_status()
    return render_template("ip_ranges.html", status=status)


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


# ===== HTMX: статус =====

@app.route("/htmx/status-summary")
@login_required
def htmx_status_summary():
    status = api.get_status()
    return render_template("partials/status_summary.html", status=status)


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


# ===== HTMX: домены =====

@app.route("/htmx/domains-list")
@login_required
def htmx_domains_list():
    filter_type = request.args.get("type") or None
    if filter_type == "all":
        filter_type = None
    search = request.args.get("q") or None

    # Получаем все домены ОДИН раз и сами фильтруем (быстрее)
    all_domains = api.get_domains()

    # Состояние списков для карточек Gemini/ChatGPT
    has_gemini = any(d["type"] == "gemini" for d in all_domains)
    has_chatgpt = any(d["type"] == "chatgpt" for d in all_domains)
    gemini_enabled = has_gemini and any(d["enabled"] for d in all_domains if d["type"] == "gemini")
    chatgpt_enabled = has_chatgpt and any(d["enabled"] for d in all_domains if d["type"] == "chatgpt")

    # Фильтрация
    domains = all_domains
    if filter_type:
        domains = [d for d in domains if d["type"] == filter_type]
    if search:
        s = search.lower()
        domains = [d for d in domains if s in d["name"].lower()]

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
    msg = "Добавлено: %d, пропущено: %d, ошибок: %d" % (
        result["added_count"], result["skipped_count"], result["error_count"]
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


@app.route("/htmx/domains/file-content")
@login_required
def htmx_domains_file_content():
    """Возвращает только пользовательские домены для редактирования."""
    text = api.get_user_domains_block()
    return text, 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/htmx/domains/file-save", methods=["POST"])
@login_required
def htmx_domains_file_save():
    """Сохраняет пользовательские домены и синкает."""
    text = request.form.get("content", "")
    ok, msg = api.save_user_domains_block(text)
    return _result_partial(ok, msg, "refreshDomains")

# ===== HTMX: IP-подсети =====

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
    msg = "Добавлено: %d, пропущено: %d, ошибок: %d" % (
        result["added_count"], result["skipped_count"], result["error_count"]
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

@app.route("/htmx/ip-ranges/file-content")
@login_required
def htmx_ip_ranges_file_content():
    text = api.get_ip_ranges_content()
    return text, 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.route("/htmx/ip-ranges/file-save", methods=["POST"])
@login_required
def htmx_ip_ranges_file_save():
    text = request.form.get("content", "")
    ok, msg = api.save_ip_ranges_content(text)
    return _result_partial(ok, msg, "refreshIpRanges")


# ===== HTMX: sing-box =====

@app.route("/htmx/singbox-status")
@login_required
def htmx_singbox_status():
    status = api.get_status()
    return render_template("partials/singbox_status.html", status=status)


@app.route("/htmx/singbox/<action>", methods=["POST"])
@login_required
def htmx_singbox_action(action):
    if action not in ("start", "stop", "restart", "enable", "disable"):
        abort(400)
    ok, msg = api.singbox_action(action)
    return _result_partial(ok, msg or "sing-box %s" % action, "refreshSingbox")


# ===== HTMX: логи =====

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


# ===== HTMX: диагностика =====

@app.route("/htmx/doctor")
@login_required
def htmx_doctor():
    results = api.get_doctor()
    return render_template("partials/doctor_results.html", results=results)


# ===== HTMX: настройки =====

@app.route("/htmx/settings/autopatch", methods=["POST"])
@login_required
def htmx_settings_autopatch():
    enable = request.form.get("enable", "0") == "1"
    ok, msg = api.set_autopatch(enable)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/fullvpn", methods=["POST"])
@login_required
def htmx_settings_fullvpn():
    enable = request.form.get("enable", "0") == "1"
    ok, msg = api.set_fullvpn(enable)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/log-level", methods=["POST"])
@login_required
def htmx_settings_log_level():
    level = request.form.get("level", "")
    ok, msg = api.set_log_level(level)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/mtu", methods=["POST"])
@login_required
def htmx_settings_mtu():
    try:
        mtu = int(request.form.get("mtu", "0"))
    except ValueError:
        return _result_partial(False, "MTU должен быть числом")
    ok, msg = api.set_mtu(mtu)
    return _result_partial(ok, msg, "refreshAll")


@app.route("/htmx/settings/subnet", methods=["POST"])
@login_required
def htmx_settings_subnet():
    subnet = request.form.get("subnet", "").strip()
    ok, msg = api.set_subnet(subnet)
    return _result_partial(ok, msg, "refreshAll")


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
        return _result_partial(False, "Файл не текстовый")

    ok, msg, path = api.upload_wg_config(file.filename, content)
    if not ok:
        return _result_partial(False, msg)

    ok2, msg2 = api.switch_to_wg(path)
    if ok2:
        return _result_partial(True, "%s; %s" % (msg, msg2), "refreshAll")
    return _result_partial(False, "Загружено, но не применено: %s" % msg2)


@app.route("/htmx/settings/credentials", methods=["POST"])
@login_required
def htmx_credentials():
    new_user = request.form.get("username", "")
    new_pass = request.form.get("password", "")
    ok, msg = update_credentials(new_user, new_pass, current_user.username)
    return _result_partial(ok, msg)


# ===== Контекст =====

@app.context_processor
def inject_globals():
    return {
        "current_user": current_user,
        "site_name": "AZ-WARP",
    }


# ===== Запуск =====

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 16060))
    debug = os.environ.get("DEBUG", "false").lower() == "true"
    app.run(host="127.0.0.1", port=port, debug=debug)
