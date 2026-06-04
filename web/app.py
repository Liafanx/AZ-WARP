"""
AZ-WARP Web Panel
Главное Flask-приложение с роутами и HTMX endpoints.
"""

import json as _json
import logging
import os
import sys
from pathlib import Path
from werkzeug.middleware.proxy_fix import ProxyFix

from dotenv import load_dotenv
from flask import (
    Flask, Response, abort, flash, jsonify, make_response,
    redirect, render_template, request, stream_with_context, url_for,
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

# Доверяем заголовкам от nginx (X-Forwarded-Proto, X-Real-IP).
# Это нужно чтобы Flask понимал что мы за реверс-прокси.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1)

app.config["SECRET_KEY"] = get_or_create_secret_key()
app.config["MAX_CONTENT_LENGTH"] = 1 * 1024 * 1024

# Cookie настраиваются в auth.init_auth()
init_auth(app)


# ===== CSRF защита (origin check) =====
# Любой POST/PUT/DELETE/PATCH должен иметь Origin или Referer
# с того же хоста что и наш сервер. Это блокирует CSRF атаки
# через сторонние сайты.

@app.before_request
def _csrf_origin_check():
    """
    CSRF защита: проверка Origin/Referer для state-changing запросов.
    Срабатывает ДО проверки авторизации.
    """
    if request.method not in ("POST", "PUT", "DELETE", "PATCH"):
        return None

    if request.path == "/login":
        return None

    origin = request.headers.get("Origin", "").strip()
    referer = request.headers.get("Referer", "").strip()

    # Нет ни Origin ни Referer = это не браузер с активной сессией, риск CSRF нулевой
    # (если кто-то делает curl - у него нет cookie, login_required отшибёт)
    if not origin and not referer:
        return None

    # Собираем все возможные варианты "нашего" хоста
    # request.host - то что Flask видит (за ProxyFix - это X-Forwarded-Host от nginx)
    # request.headers['Host'] - оригинальный Host header
    flask_host = request.host or ""
    orig_host = request.headers.get("Host", "").strip()
    fwd_host = request.headers.get("X-Forwarded-Host", "").strip()

    allowed_hosts = set()
    for h in (flask_host, orig_host, fwd_host):
        if not h:
            continue
        allowed_hosts.add(h)
        # Добавляем варианты с/без порта
        if ":" in h:
            allowed_hosts.add(h.split(":")[0])
        else:
            # Без порта - могут быть стандартные порты
            allowed_hosts.add(f"{h}:80")
            allowed_hosts.add(f"{h}:443")

    def _check_url(url):
        if not url:
            return False
        from urllib.parse import urlparse
        try:
            parsed = urlparse(url)
            netloc = parsed.netloc
            if not netloc:
                return False
            # Проверяем разные комбинации
            if netloc in allowed_hosts:
                return True
            # Без порта тоже сравним
            host_only = netloc.split(":")[0] if ":" in netloc else netloc
            for allowed in allowed_hosts:
                allowed_host_only = allowed.split(":")[0] if ":" in allowed else allowed
                if host_only == allowed_host_only:
                    return True
            return False
        except Exception:
            return False

    if origin:
        if _check_url(origin):
            return None
        logger.warning(
            "CSRF blocked: bad Origin. method=%s path=%s origin=%r allowed_hosts=%r",
            request.method, request.path, origin, allowed_hosts,
        )
        abort(403, description="CSRF check failed: invalid Origin")

    if referer:
        if _check_url(referer):
            return None
        logger.warning(
            "CSRF blocked: bad Referer. method=%s path=%s referer=%r allowed_hosts=%r",
            request.method, request.path, referer, allowed_hosts,
        )
        abort(403, description="CSRF check failed: invalid Referer")

    return None


# ===== Безопасные cookie при HTTPS =====
@app.before_request
def _set_cookie_security_flags():
    """
    На HTTPS cookie должны быть Secure, на HTTP — нет.
    Иначе после перехода HTTPS -> HTTP будет цикл логина.
    """
    secure = bool(request.is_secure)
    app.config["SESSION_COOKIE_SECURE"] = secure
    app.config["REMEMBER_COOKIE_SECURE"] = secure

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

def _absolute_web_settings_url(scheme: str, host: str | None = None) -> str:
    status = api.get_https_status()
    port = status.get("port")
    if not port:
        if ":" in request.host:
            port = request.host.split(":", 1)[1]
        else:
            port = "6060"

    host = host or request.host.split(":", 1)[0]
    return f"{scheme}://{host}:{port}/web-settings"

def _get_public_ipv4() -> str:
    import subprocess

    for cmd in (
        ["curl", "-s", "-4", "--connect-timeout", "3", "ifconfig.me"],
        ["hostname", "-I"],
    ):
        try:
            out = subprocess.check_output(cmd, text=True, timeout=5).strip()
            if out:
                return out.split()[0]
        except Exception:
            pass
    return request.host.split(":", 1)[0]


def _absolute_panel_url(scheme: str, host: str | None = None, path: str = "/login") -> str:
    status = api.get_https_status()
    port = status.get("port")

    if not port:
        if ":" in request.host:
            port = request.host.split(":", 1)[1]
        else:
            port = "6060"

    host = host or request.host.split(":", 1)[0]
    return f"{scheme}://{host}:{port}{path}"


def _clear_auth_cookies(resp):
    session_name = app.config.get("SESSION_COOKIE_NAME", "session")
    remember_name = app.config.get("REMEMBER_COOKIE_NAME", "remember_token")

    session_path = app.config.get("SESSION_COOKIE_PATH", "/")
    remember_path = app.config.get("REMEMBER_COOKIE_PATH", "/")

    session_domain = app.config.get("SESSION_COOKIE_DOMAIN")
    remember_domain = app.config.get("REMEMBER_COOKIE_DOMAIN")

    resp.delete_cookie(session_name, path=session_path, domain=session_domain)
    resp.delete_cookie(remember_name, path=remember_path, domain=remember_domain)
    return resp


def _https_switch_response(message: str, scheme: str, host: str | None = None):
    """
    После смены HTTP/HTTPS:
    - показываем toast
    - сбрасываем текущую авторизацию
    - редиректим на login по НОВОМУ абсолютному URL
    """
    url = _absolute_panel_url(scheme, host=host, path="/login")

    triggers = {
        "showToast": {"message": message, "category": "success"},
        "redirectAfter": {"url": url, "delay": 2500},
    }

    logout_user()
    resp = make_response("", 204)
    resp.headers["HX-Trigger"] = _json.dumps(triggers, ensure_ascii=True)
    _clear_auth_cookies(resp)
    return resp

# ===== Страницы =====

@app.route("/")
@login_required
def index():
    return redirect(url_for("dashboard"))

@app.route("/health")
def healthcheck_endpoint():
    """
    Простой healthcheck-endpoint для внутренних проверок.
    Не требует авторизации. Возвращает JSON.
    """
    return jsonify({"status": "ok", "service": "warper-web"})

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

@app.route("/web-settings")
@login_required
def web_settings_page():
    return render_template("web_settings.html")

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
    # Возвращаем как plain text, JS сам подставит в textarea.value
    return text, 200, {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store",
    }


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
    return text, 200, {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store",
    }


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

    if ok:
        # Делаем logout текущего пользователя
        logout_user()
        # Триггерим клиентский редирект на /login
        resp = make_response("", 204)
        triggers = {
            "showToast": {"message": msg, "category": "success"},
            "redirectAfter": {"url": "/login", "delay": 1500},
        }
        resp.headers["HX-Trigger"] = _json.dumps(triggers, ensure_ascii=True)
        return resp

    return _result_partial(False, msg)

@app.route("/htmx/check-updates")
@login_required
def htmx_check_updates():
    force = request.args.get("force") == "1"
    result = api.check_for_updates(force=force)
    return render_template("partials/updates_status.html", upd=result)


@app.route("/htmx/update-warper", methods=["POST"])
@login_required
def htmx_update_warper():
    """
    Возвращает HTML-блок с консолью прогресса обновления.
    Реальный лог стримится через SSE endpoint /api/update-stream.
    """
    return render_template("partials/update_progress.html")


@app.route("/api/update-stream")
@login_required
def api_update_stream():
    """
    SSE-стрим: запускает `warper update` и шлёт каждую строку stdout
    как Server-Sent Event в браузер. По завершении — финальное событие.
    """
    proc, err = api.update_warper_from_web()
    if err or not proc:
        def _err_stream():
            import json as _j
            yield "event: error\n"
            yield f"data: {_j.dumps({'message': err or 'Unknown error'})}\n\n"
        return Response(
            _err_stream(),
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",  # отключаем буферизацию nginx
            },
        )

    @stream_with_context
    def _stream():
        import json as _j

        # Стартовое событие
        yield "event: start\n"
        yield f"data: {_j.dumps({'message': 'Запуск обновления...'})}\n\n"

        try:
            # Читаем построчно — каждую строку шлём как SSE
            assert proc.stdout is not None
            for line in iter(proc.stdout.readline, ""):
                # Убираем ANSI escape-последовательности (цвета bash)
                import re as _re
                clean = _re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", line).rstrip()
                if not clean:
                    continue
                yield "event: log\n"
                yield f"data: {_j.dumps({'line': clean})}\n\n"

            # Ждём завершения
            rc = proc.wait(timeout=600)

            # Финальное событие
            if rc == 0:
                # Инвалидируем кэш версии чтобы dashboard сразу увидел новую
                api.invalidate_version_cache()
                yield "event: done\n"
                yield f"data: {_j.dumps({'rc': rc, 'success': True})}\n\n"
            else:
                yield "event: done\n"
                yield f"data: {_j.dumps({'rc': rc, 'success': False})}\n\n"
        except Exception as e:
            yield "event: error\n"
            yield f"data: {_j.dumps({'message': str(e)})}\n\n"
            try:
                proc.kill()
            except Exception:
                pass

    return Response(
        _stream(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )

# ===== HTMX: настройки веб-панели =====

@app.route("/htmx/web/info")
@login_required
def htmx_web_info():
    info = api.get_service_info()
    return render_template("partials/web_service_info.html", info=info)


@app.route("/htmx/web/auth-log")
@login_required
def htmx_web_auth_log():
    filter_type = request.args.get("filter") or None
    if filter_type == "all":
        filter_type = None
    try:
        limit = int(request.args.get("limit", 100))
    except ValueError:
        limit = 100
    if limit < 1 or limit > 500:
        limit = 100

    data = api.get_auth_log(limit=limit, level_filter=filter_type)
    return render_template(
        "partials/web_auth_log.html",
        events=data["events"],
        stats=data["stats"],
        current_filter=filter_type or "all",
        current_limit=limit,
    )


@app.route("/htmx/web/blocks")
@login_required
def htmx_web_blocks():
    blocks = api.get_active_blocks()
    return render_template("partials/web_blocks.html", blocks=blocks)


@app.route("/htmx/web/unblock", methods=["POST"])
@login_required
def htmx_web_unblock():
    ip = request.form.get("ip", "").strip()
    if not ip:
        return _result_partial(False, "IP не указан")
    ok, msg = api.unblock_ip(ip)
    return _result_partial(ok, msg, "refreshWebBlocks")


@app.route("/htmx/web/unblock-all", methods=["POST"])
@login_required
def htmx_web_unblock_all():
    ok, msg = api.unblock_all_ips()
    return _result_partial(ok, msg, "refreshWebBlocks")


@app.route("/htmx/web/change-port", methods=["POST"])
@login_required
def htmx_web_change_port():
    try:
        new_port = int(request.form.get("port", "0"))
    except ValueError:
        return _result_partial(False, "Порт должен быть числом")
    ok, msg = api.change_external_port(new_port)
    if ok:
        # Редирект на новый порт через 2 секунды
        import json as _j
        host = request.host.split(":")[0]
        scheme = "https" if request.is_secure else "http"
        new_url = f"{scheme}://{host}:{new_port}/web-settings"
        triggers = {
            "showToast": {"message": msg, "category": "success"},
            "redirectAfter": {"url": new_url, "delay": 3000},
        }
        resp = make_response("", 204)
        resp.headers["HX-Trigger"] = _json.dumps(triggers, ensure_ascii=True)
        return resp
    return _result_partial(False, msg)


@app.route("/htmx/web/restart", methods=["POST"])
@login_required
def htmx_web_restart():
    ok, msg = api.restart_web_service()
    if ok:
        # Браузер ждёт 5 секунд и перезагружает страницу
        triggers = {
            "showToast": {"message": msg, "category": "info"},
            "redirectAfter": {"url": "/web-settings", "delay": 5000},
        }
        resp = make_response("", 204)
        resp.headers["HX-Trigger"] = _json.dumps(triggers, ensure_ascii=True)
        return resp
    return _result_partial(False, msg)

@app.route("/htmx/web/security-settings")
@login_required
def htmx_web_security_settings():
    settings = api.get_security_settings_api()
    return render_template("partials/web_security_form.html", s=settings)


@app.route("/htmx/web/security-settings/save", methods=["POST"])
@login_required
def htmx_web_security_save():
    settings = {
        "max_attempts": request.form.get("max_attempts", "10"),
        "block_duration_minutes": request.form.get("block_duration_minutes", "15"),
        "attempt_window_minutes": request.form.get("attempt_window_minutes", "10"),
        "cookie_lifetime_days": request.form.get("cookie_lifetime_days", "7"),
    }
    ok, msg = api.save_security_settings_api(settings)
    return _result_partial(ok, msg)


@app.route("/htmx/web/sessions")
@login_required
def htmx_web_sessions():
    sessions = api.get_recent_logins(limit=20)
    return render_template("partials/web_sessions.html", sessions=sessions)


@app.route("/htmx/web/sessions/revoke-all", methods=["POST"])
@login_required
def htmx_web_revoke_sessions():
    """Ротирует ключ и ПЕРЕЗАПУСКАЕТ сервис."""
    ok, msg = api.rotate_session_secret()
    if ok:
        # Планируем перезапуск через 1 сек, чтобы успеть отправить ответ
        api.restart_web_service() 
        
        triggers = {
            "showToast": {"message": "Все сессии аннулированы. Перезапуск...", "category": "success"},
            "redirectAfter": {"url": "/login", "delay": 2000},
        }
        resp = make_response("", 204)
        resp.headers["HX-Trigger"] = _json.dumps(triggers, ensure_ascii=True)
        return resp
    return _result_partial(False, msg)


@app.route("/htmx/web/healthcheck")
@login_required
def htmx_web_healthcheck():
    result = api.healthcheck()
    return render_template("partials/web_healthcheck.html", h=result)

# ===== HTMX: HTTPS управление =====

@app.route("/htmx/web/https-status")
@login_required
def htmx_web_https_status():
    status = api.get_https_status()
    return render_template("partials/web_https_status.html", s=status)


@app.route("/htmx/web/https/selfsigned", methods=["POST"])
@login_required
def htmx_web_https_selfsigned():
    ok, msg = api.set_https_selfsigned()
    if ok:
        return _https_switch_response(msg, "https", host=_get_public_ipv4())
    return _result_partial(False, msg)


@app.route("/htmx/web/https/letsencrypt", methods=["POST"])
@login_required
def htmx_web_https_letsencrypt():
    domain = request.form.get("domain", "").strip()
    if not domain:
        return _result_partial(False, "Введите домен")
    ok, msg = api.set_https_letsencrypt(domain)
    if ok:
        return _https_switch_response(msg, "https", host=domain)
    return _result_partial(False, msg)


@app.route("/htmx/web/https/disable", methods=["POST"])
@login_required
def htmx_web_https_disable():
    ok, msg = api.disable_https()
    if ok:
        return _https_switch_response(msg, "http", host=_get_public_ipv4())
    return _result_partial(False, msg)


@app.route("/htmx/web/https/renew", methods=["POST"])
@login_required
def htmx_web_https_renew():
    ok, msg = api.renew_certificate()
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
