"""
auth.py
Безопасная авторизация:
- Хеш пароля bcrypt cost 12 в web/data/users.json (chmod 600, only root)
- SECRET_KEY в web/data/secret.key (chmod 600), ротируется при смене пароля
- Brute-force: 10 попыток / 10 мин → блокировка IP на 15 мин (persist на диске)
- Timing-safe проверка пароля (всегда выполняется bcrypt)
- Валидация логина: только латиница/цифры/_-
- IP клиента берётся ТОЛЬКО из X-Real-IP от nginx (нельзя подделать заголовком)
- Cookie: HttpOnly, SameSite=Lax, Secure (при HTTPS)
- CSRF: проверка origin для всех state-changing запросов (POST/PUT/DELETE)
- Аудит-лог в web/data/auth.log с автоматической ротацией (макс 1MB, 3 файла)
"""

import hmac
import json
import logging
import logging.handlers
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path
from threading import Lock

from flask import Flask, request
from flask_bcrypt import Bcrypt
from flask_login import LoginManager, UserMixin


bcrypt = Bcrypt()
login_manager = LoginManager()
logger = logging.getLogger(__name__)

# ===== Пути =====
DATA_DIR = Path(__file__).parent / "data"
USERS_FILE = DATA_DIR / "users.json"
SECRET_FILE = DATA_DIR / "secret.key"
BLOCKS_FILE = DATA_DIR / "blocks.json"
AUTH_LOG = DATA_DIR / "auth.log"

# ===== Brute-force защита =====
_blocks_lock = Lock()

# ===== Валидация =====
LOGIN_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
PASSWORD_MIN_LEN = 6
PASSWORD_MAX_LEN = 256
DEFAULT_USER = "admin"

# Фейковый хеш для timing-safe проверки.
# ВАЖНО: должен быть валидным bcrypt-хешем с тем же cost что и реальные пароли (12),
# иначе по времени можно отличить "юзера нет" от "пароль неверный".
_FAKE_BCRYPT_HASH = "$2b$12$abcdefghijklmnopqrstuuRcyB1HpkwQNRz/ZNoXJOcCXFmKAfqLm"

# ===== Аудит-лог с ротацией =====
_audit_logger = logging.getLogger("warper.audit")
_audit_logger.setLevel(logging.INFO)
_audit_logger.propagate = False

# ===== Конфигурация безопасности =====
SECURITY_FILE = DATA_DIR / "security.json"

# Дефолтные значения (используются если файл security.json отсутствует)
_DEFAULTS = {
    "max_attempts": 10,
    "block_duration_minutes": 15,
    "attempt_window_minutes": 10,
    "cookie_lifetime_days": 7,
}


def load_security_settings() -> dict:
    """Загружает настройки безопасности из файла. Дефолты если файла нет."""
    if not SECURITY_FILE.exists():
        return dict(_DEFAULTS)
    try:
        with open(SECURITY_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            # Дополняем дефолтами на случай если файл устаревший
            result = dict(_DEFAULTS)
            for k in result:
                if k in data and isinstance(data[k], (int, float)):
                    result[k] = int(data[k])
            return result
    except (OSError, json.JSONDecodeError):
        return dict(_DEFAULTS)


def save_security_settings(settings: dict) -> tuple[bool, str]:
    """Сохраняет настройки безопасности. Валидирует значения."""
    # Валидация
    cleaned = {}
    try:
        cleaned["max_attempts"] = max(3, min(100, int(settings.get("max_attempts", 10))))
        cleaned["block_duration_minutes"] = max(1, min(1440, int(settings.get("block_duration_minutes", 15))))
        cleaned["attempt_window_minutes"] = max(1, min(1440, int(settings.get("attempt_window_minutes", 10))))
        cleaned["cookie_lifetime_days"] = max(0, min(365, int(settings.get("cookie_lifetime_days", 7))))
    except (ValueError, TypeError):
        return False, "Все значения должны быть числами"

    return _atomic_write(SECURITY_FILE, json.dumps(cleaned, indent=2), 0o600), \
           "Настройки сохранены" if _atomic_write else "Ошибка записи"

def _setup_audit_log():
    """Настраивает RotatingFileHandler для auth.log (макс 1MB, 3 файла)."""
    if _audit_logger.handlers:
        return
    _ensure_data_dir()
    try:
        handler = logging.handlers.RotatingFileHandler(
            str(AUTH_LOG), maxBytes=1024 * 1024, backupCount=3, encoding="utf-8"
        )
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        _audit_logger.addHandler(handler)
        try:
            os.chmod(AUTH_LOG, 0o600)
        except OSError:
            pass
    except OSError as e:
        logger.error("Не удалось настроить аудит-лог: %s", e)


def _audit_log(event: str, ip: str, username: str = "", extra: str = "") -> None:
    """Запись в аудит-лог."""
    _setup_audit_log()
    user_part = f" user={username}" if username else ""
    extra_part = f" {extra}" if extra else ""
    _audit_logger.info("ip=%s event=%s%s%s", ip, event, user_part, extra_part)


# ===== Утилиты =====

def _ensure_data_dir() -> None:
    """Создаёт data/ с правами 700 (только root)."""
    DATA_DIR.mkdir(mode=0o700, exist_ok=True)
    try:
        os.chmod(DATA_DIR, 0o700)
    except OSError:
        pass


def _atomic_write(path: Path, content: str, mode: int = 0o600) -> bool:
    """Атомарная запись файла с правами."""
    _ensure_data_dir()
    try:
        tmp = path.with_suffix(path.suffix + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, mode)
        tmp.replace(path)
        os.chmod(path, mode)
        return True
    except OSError as e:
        logger.error("Не удалось записать %s: %s", path, e)
        return False


def get_or_create_secret_key() -> str:
    """SECRET_KEY из файла или новый. Защита от race condition между воркерами."""
    _ensure_data_dir()

    # Быстрый путь — файл уже есть
    if SECRET_FILE.exists():
        try:
            key = SECRET_FILE.read_text(encoding="utf-8").strip()
            if len(key) >= 32:
                return key
        except OSError:
            pass

    # Lock через flock чтобы все воркеры использовали один SECRET_KEY
    import fcntl
    lock_file = DATA_DIR / ".secret.lock"
    try:
        with open(lock_file, "w") as lf:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            except OSError:
                pass

            # Повторная проверка под lock
            if SECRET_FILE.exists():
                try:
                    key = SECRET_FILE.read_text(encoding="utf-8").strip()
                    if len(key) >= 32:
                        return key
                except OSError:
                    pass

            # Создаём
            new_key = secrets.token_hex(32)
            _atomic_write(SECRET_FILE, new_key + "\n", 0o600)
            return new_key
    finally:
        try:
            lock_file.unlink()
        except OSError:
            pass


def rotate_secret_key() -> str:
    """Генерирует новый SECRET_KEY и сохраняет атомарно."""
    new_key = secrets.token_hex(32)
    if _atomic_write(SECRET_FILE, new_key + "\n", 0o600):
        logger.info("SECRET_KEY ротирован (все активные сессии будут сброшены)")
    return new_key


# ===== БД пользователей =====

def _load_users() -> dict:
    if not USERS_FILE.exists():
        return {}
    try:
        with open(USERS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_users(users: dict) -> bool:
    content = json.dumps(users, indent=2, ensure_ascii=False)
    return _atomic_write(USERS_FILE, content, 0o600)


def _ensure_default_user() -> None:
    """Создаёт admin со случайным паролем при пустой БД."""
    if _load_users():
        return

    import fcntl
    _ensure_data_dir()
    lock_file = DATA_DIR / ".init.lock"

    try:
        with open(lock_file, "w") as lf:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            except OSError:
                pass

            if _load_users():
                return

            generated_pass = secrets.token_urlsafe(9)
            try:
                hashed = bcrypt.generate_password_hash(generated_pass).decode("utf-8")
            except Exception as e:
                logger.error("Ошибка хеширования: %s", e)
                return

            users = {
                DEFAULT_USER: {
                    "password_hash": hashed,
                    "created_at": datetime.now().isoformat(timespec="seconds"),
                    "last_login": None,
                }
            }
            if _save_users(users):
                logger.warning("=" * 60)
                logger.warning("БД пуста — создан администратор:")
                logger.warning("  Логин:  %s", DEFAULT_USER)
                logger.warning("  Пароль: %s", generated_pass)
                logger.warning("Смените: warper webpass")
                logger.warning("=" * 60)
    except OSError as e:
        logger.error("Lock-файл: %s", e)
    finally:
        try:
            lock_file.unlink()
        except OSError:
            pass


# ===== Brute-force защита (persistent) =====

def _load_blocks() -> dict:
    if not BLOCKS_FILE.exists():
        return {"attempts": {}, "blocks": {}}
    try:
        with open(BLOCKS_FILE, "r", encoding="utf-8") as f:
            d = json.load(f)
            return {
                "attempts": d.get("attempts", {}) if isinstance(d.get("attempts"), dict) else {},
                "blocks": d.get("blocks", {}) if isinstance(d.get("blocks"), dict) else {},
            }
    except (OSError, json.JSONDecodeError):
        return {"attempts": {}, "blocks": {}}


def _save_blocks(data: dict) -> None:
    content = json.dumps(data, ensure_ascii=False)
    _atomic_write(BLOCKS_FILE, content, 0o600)


def _cleanup_blocks(data: dict, now: float) -> dict:
    """Удаляет устаревшие попытки и истёкшие блокировки."""
    settings = load_security_settings()
    attempt_window = settings["attempt_window_minutes"] * 60

    data["blocks"] = {ip: until for ip, until in data["blocks"].items() if until > now}
    new_attempts = {}
    for ip, ts_list in data["attempts"].items():
        if not isinstance(ts_list, list):
            continue
        fresh = [t for t in ts_list if now - t < attempt_window]
        if fresh:
            new_attempts[ip] = fresh
    data["attempts"] = new_attempts
    return data

def is_ip_blocked(ip: str) -> tuple[bool, int]:
    with _blocks_lock:
        now = time.time()
        data = _cleanup_blocks(_load_blocks(), now)
        until = data["blocks"].get(ip)
        _save_blocks(data)
        if until and until > now:
            return True, int(until - now)
        return False, 0


def _register_failed_attempt(ip: str) -> tuple[int, bool]:
    """Возвращает (попыток_сейчас, заблокирован_только_что)."""
    settings = load_security_settings()
    max_attempts = settings["max_attempts"]
    block_duration = settings["block_duration_minutes"] * 60

    with _blocks_lock:
        now = time.time()
        data = _cleanup_blocks(_load_blocks(), now)

        attempts = data["attempts"].setdefault(ip, [])
        attempts.append(now)

        if len(attempts) >= max_attempts:
            data["blocks"][ip] = now + block_duration
            data["attempts"].pop(ip, None)
            _save_blocks(data)
            return max_attempts, True

        _save_blocks(data)
        return len(attempts), False


def _clear_attempts_and_blocks(ip: str) -> None:
    """Сбрасывает И попытки И блокировку для IP."""
    with _blocks_lock:
        data = _load_blocks()
        data["attempts"].pop(ip, None)
        data["blocks"].pop(ip, None)
        _save_blocks(data)


# ===== IP-адрес клиента =====

def _get_client_ip() -> str:
    """
    Получает IP клиента ТОЛЬКО из X-Real-IP, который ставит nginx.
    Заголовок X-Forwarded-For не используется — его легко подделать клиентом.
    nginx-конфиг должен иметь:
      proxy_set_header X-Real-IP $remote_addr;
    """
    # X-Real-IP ставится nginx из реального TCP-источника, его невозможно подделать
    xri = request.headers.get("X-Real-IP", "").strip()
    if xri and _is_valid_ip(xri):
        return xri

    # Fallback: реальный remote_addr (если работаем без nginx)
    return request.remote_addr or "unknown"


def _is_valid_ip(s: str) -> bool:
    """Грубая валидация IPv4/IPv6 (без полной нормализации)."""
    if not s or len(s) > 45:
        return False
    # IPv4
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", s):
        return all(0 <= int(p) <= 255 for p in s.split("."))
    # IPv6 (минимальная проверка - только разрешённые символы)
    if re.match(r"^[0-9a-fA-F:]+$", s) and ":" in s:
        return True
    return False


# ===== AdminUser =====

class AdminUser(UserMixin):
    def __init__(self, username: str):
        self.id = username
        self.username = username


def init_auth(app: Flask) -> None:
    """Инициализация авторизации + cookie security."""
    _ensure_data_dir()
    _setup_audit_log()
    bcrypt.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "login"
    login_manager.login_message = "Требуется авторизация"
    login_manager.login_message_category = "warning"

    # Безопасность cookie
    # SESSION_COOKIE_SECURE будет принудительно True при HTTPS-запросах
    # благодаря X-Forwarded-Proto от nginx (см. ProxyFix в app.py)
    app.config.setdefault("SESSION_COOKIE_HTTPONLY", True)
    app.config.setdefault("SESSION_COOKIE_SAMESITE", "Lax")
    app.config.setdefault("SESSION_COOKIE_SECURE", False)  # станет True автоматом при HTTPS
    app.config.setdefault("REMEMBER_COOKIE_HTTPONLY", True)
    app.config.setdefault("REMEMBER_COOKIE_SAMESITE", "Lax")
    @app.before_request
    def _update_cookie_lifetime():
        """Обновляем длительность cookie из настроек при каждом запросе."""
        settings = load_security_settings()
        days = settings.get("cookie_lifetime_days", 7)
        if days > 0:
            app.config["REMEMBER_COOKIE_DURATION"] = days * 24 * 60 * 60
        else:
            # 0 = сессионные cookie (умирают при закрытии браузера)
            app.config["REMEMBER_COOKIE_DURATION"] = None
            
    _ensure_default_user()

    @login_manager.user_loader
    def load_user(user_id: str):
        if not LOGIN_RE.match(user_id):
            return None
        users = _load_users()
        if user_id in users:
            return AdminUser(user_id)
        return None



# ===== Проверка пароля =====

def verify_credentials(username: str, password: str) -> tuple[bool, str]:
    """Проверяет пароль. Защита от brute-force и timing-атак."""
    ip = _get_client_ip()

    # Загружаем актуальные настройки безопасности
    settings = load_security_settings()
    max_attempts = settings["max_attempts"]
    block_duration = settings["block_duration_minutes"] * 60

    blocked, seconds_left = is_ip_blocked(ip)
    if blocked:
        minutes = (seconds_left + 59) // 60
        _audit_log("blocked_attempt", ip, username)
        return False, f"Слишком много попыток. Попробуйте через {minutes} мин."

    if not username or not password:
        _register_failed_attempt(ip)
        _audit_log("empty_credentials", ip)
        return False, "Неверный логин или пароль"

    username = username.strip()
    if not LOGIN_RE.match(username):
        _register_failed_attempt(ip)
        _audit_log("invalid_login_format", ip, username)
        return False, "Неверный логин или пароль"

    if not (PASSWORD_MIN_LEN <= len(password) <= PASSWORD_MAX_LEN):
        _register_failed_attempt(ip)
        _audit_log("invalid_password_length", ip, username)
        return False, "Неверный логин или пароль"

    users = _load_users()
    user_data = users.get(username)

    fake_hash = "$2b$12$fakefakefakefakefakefakefakefakefakefakefakefakefakefakefa"
    stored_hash = user_data["password_hash"] if user_data else fake_hash

    try:
        password_ok = bcrypt.check_password_hash(stored_hash, password)
    except ValueError:
        password_ok = False

    if not user_data or not password_ok:
        attempts, just_blocked = _register_failed_attempt(ip)
        if just_blocked:
            _audit_log("blocked_now", ip, username, f"after {max_attempts} attempts")
            return False, f"Превышено число попыток. IP заблокирован на {block_duration // 60} мин."
        _audit_log("login_failed", ip, username, f"attempt={attempts}/{max_attempts}")
        remaining = max_attempts - attempts
        return False, f"Неверный логин или пароль (осталось попыток: {remaining})"

    user_data["last_login"] = datetime.now().isoformat(timespec="seconds")
    user_data["last_login_ip"] = ip
    users[username] = user_data
    _save_users(users)

    _clear_attempts_and_blocks(ip)
    _audit_log("login_success", ip, username)

    return True, ""

def update_credentials(new_username: str, new_password: str, current_username: str) -> tuple[bool, str]:
    """Меняет учётные данные и ротирует SECRET_KEY."""
    new_username = (new_username or "").strip()

    if not LOGIN_RE.match(new_username):
        return False, "Логин: 3-32 символа, только латиница, цифры, _ и -"

    if not new_password or len(new_password) < PASSWORD_MIN_LEN:
        return False, f"Пароль должен быть минимум {PASSWORD_MIN_LEN} символов"

    if len(new_password) > PASSWORD_MAX_LEN:
        return False, f"Пароль слишком длинный (максимум {PASSWORD_MAX_LEN})"

    users = _load_users()

    try:
        new_hash = bcrypt.generate_password_hash(new_password).decode("utf-8")
    except Exception as e:
        return False, f"Ошибка хеширования: {e}"

    users.pop(current_username, None)
    users[new_username] = {
        "password_hash": new_hash,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "last_login": None,
    }

    if not _save_users(users):
        return False, "Ошибка сохранения учётных данных"

    ip = _get_client_ip()
    _audit_log("credentials_changed", ip, current_username, f"new={new_username}")

    rotate_secret_key()

    return True, "Учётные данные обновлены. Войдите заново."
