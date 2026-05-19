"""
auth.py
Безопасная авторизация:
- Хеш пароля хранится в БД (web/data/users.json) с правами 600
- SECRET_KEY в отдельном файле web/data/secret.key (600)
- Защита от brute-force: 5 попыток → блокировка IP на 15 минут
- Валидация логина регулярным выражением
- Сравнение паролей с защитой от timing-атак
- Аудит-лог входов/неудач
"""

import hmac
import json
import logging
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

# Пути к файлам данных
DATA_DIR = Path(__file__).parent / "data"
USERS_FILE = DATA_DIR / "users.json"
SECRET_FILE = DATA_DIR / "secret.key"
AUTH_LOG = DATA_DIR / "auth.log"
ADMIN_PASS_FILE = Path("/root/warper/web_admin_pass.txt")

# Защита от brute-force
MAX_ATTEMPTS = 5
BLOCK_DURATION = 15 * 60  # 15 минут
_attempts_lock = Lock()
_failed_attempts: dict[str, list[float]] = {}
_blocked_ips: dict[str, float] = {}

# Валидация логина: 3-32 символа, латиница/цифры/_-
LOGIN_RE = re.compile(r"^[A-Za-z0-9_-]{3,32}$")
PASSWORD_MIN_LEN = 6
PASSWORD_MAX_LEN = 256

# Дефолтные учётные данные при первом запуске (если БД пуста)
DEFAULT_USER = "admin"
DEFAULT_PASSWORD = "admin"


def _ensure_data_dir() -> None:
    """Создаёт data/ с правильными правами (700)."""
    DATA_DIR.mkdir(mode=0o700, exist_ok=True)
    try:
        os.chmod(DATA_DIR, 0o700)
    except OSError:
        pass


def _audit_log(event: str, ip: str, username: str = "", extra: str = "") -> None:
    """Аудит-лог авторизации."""
    try:
        _ensure_data_dir()
        with open(AUTH_LOG, "a", encoding="utf-8") as f:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            user_part = f" user={username}" if username else ""
            extra_part = f" {extra}" if extra else ""
            f.write(f"{ts} ip={ip} event={event}{user_part}{extra_part}\n")
        os.chmod(AUTH_LOG, 0o600)
    except OSError:
        pass


def get_or_create_secret_key() -> str:
    """
    Читает SECRET_KEY из web/data/secret.key или создаёт новый.
    Файл всегда с правами 600.
    """
    _ensure_data_dir()

    if SECRET_FILE.exists():
        try:
            key = SECRET_FILE.read_text(encoding="utf-8").strip()
            if len(key) >= 32:
                return key
        except OSError:
            pass

    new_key = secrets.token_hex(32)
    try:
        SECRET_FILE.write_text(new_key + "\n", encoding="utf-8")
        os.chmod(SECRET_FILE, 0o600)
    except OSError as e:
        logger.error("Не удалось сохранить SECRET_KEY: %s", e)
    return new_key


def rotate_secret_key() -> str:
    """
    Генерирует новый SECRET_KEY и сохраняет в web/data/secret.key.
    Используется при смене пароля или сбросе сессий.
    Возвращает новый ключ.
    """
    _ensure_data_dir()
    new_key = secrets.token_hex(32)
    try:
        SECRET_FILE.write_text(new_key + "\n", encoding="utf-8")
        os.chmod(SECRET_FILE, 0o600)
        logger.info("SECRET_KEY ротирован (все активные сессии будут сброшены)")
    except OSError as e:
        logger.error("Не удалось ротировать SECRET_KEY: %s", e)
    return new_key

def _load_users() -> dict:
    """Читает БД пользователей."""
    if not USERS_FILE.exists():
        return {}
    try:
        with open(USERS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_users(users: dict) -> bool:
    """Атомарно сохраняет БД с правами 600."""
    _ensure_data_dir()
    try:
        tmp = USERS_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(users, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        tmp.replace(USERS_FILE)
        os.chmod(USERS_FILE, 0o600)
        return True
    except OSError as e:
        logger.error("Не удалось сохранить users.json: %s", e)
        return False


def _ensure_default_user() -> None:
    """
    Создаёт пользователя admin со случайным паролем если БД пуста.
    Пароль выводится в лог systemd — администратор увидит его при первом запуске.
    """
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

            # Генерируем случайный безопасный пароль
            generated_pass = secrets.token_urlsafe(9)  # ~12 символов

            try:
                hashed = bcrypt.generate_password_hash(generated_pass).decode("utf-8")
            except Exception as e:
                logger.error("Ошибка хеширования дефолтного пароля: %s", e)
                return

            users = {
                DEFAULT_USER: {
                    "password_hash": hashed,
                    "created_at": datetime.now().isoformat(timespec="seconds"),
                    "last_login": None,
                }
            }
            if _save_users(users):
                # Заметное предупреждение в логи systemd
                logger.warning("=" * 60)
                logger.warning("БД пользователей не найдена — создан администратор")
                logger.warning("  Логин:  %s", DEFAULT_USER)
                logger.warning("  Пароль: %s", generated_pass)
                logger.warning("Смените пароль командой: warper webpass")
                logger.warning("Логи: journalctl -u warper-web | grep -i 'Пароль'")
                logger.warning("=" * 60)
    except OSError as e:
        logger.error("Не удалось создать lock-файл для инициализации: %s", e)
    finally:
        try:
            lock_file.unlink()
        except OSError:
            pass

class AdminUser(UserMixin):
    """Пользователь системы."""

    def __init__(self, username: str):
        self.id = username
        self.username = username


def init_auth(app: Flask) -> None:
    """Инициализирует Flask-Login и Flask-Bcrypt."""
    _ensure_data_dir()
    bcrypt.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "login"
    login_manager.login_message = "Требуется авторизация"
    login_manager.login_message_category = "warning"

    # Создаём дефолтного пользователя если БД пуста
    _ensure_default_user()

    @login_manager.user_loader
    def load_user(user_id: str) -> AdminUser | None:
        if not LOGIN_RE.match(user_id):
            return None
        users = _load_users()
        if user_id in users:
            return AdminUser(user_id)
        return None


# ===== Brute-force защита =====

def _cleanup_old_attempts(now: float) -> None:
    """Удаляет старые попытки и истёкшие блокировки."""
    expired = [ip for ip, until in _blocked_ips.items() if until <= now]
    for ip in expired:
        del _blocked_ips[ip]

    window = BLOCK_DURATION
    for ip in list(_failed_attempts.keys()):
        _failed_attempts[ip] = [t for t in _failed_attempts[ip] if now - t < window]
        if not _failed_attempts[ip]:
            del _failed_attempts[ip]


def is_ip_blocked(ip: str) -> tuple[bool, int]:
    """Возвращает (blocked, seconds_left)."""
    with _attempts_lock:
        now = time.time()
        _cleanup_old_attempts(now)
        if ip in _blocked_ips:
            return True, int(_blocked_ips[ip] - now)
        return False, 0


def _register_failed_attempt(ip: str) -> tuple[int, bool]:
    """Регистрирует неудачную попытку."""
    with _attempts_lock:
        now = time.time()
        _cleanup_old_attempts(now)
        attempts = _failed_attempts.setdefault(ip, [])
        attempts.append(now)
        if len(attempts) >= MAX_ATTEMPTS:
            _blocked_ips[ip] = now + BLOCK_DURATION
            del _failed_attempts[ip]
            return MAX_ATTEMPTS, True
        return len(attempts), False


def _clear_attempts(ip: str) -> None:
    with _attempts_lock:
        _failed_attempts.pop(ip, None)


def _get_client_ip() -> str:
    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    return request.remote_addr or "unknown"


# ===== Проверка =====

def verify_credentials(username: str, password: str) -> tuple[bool, str]:
    """Проверяет логин и пароль с защитой от brute-force и timing-атак."""
    ip = _get_client_ip()

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

    # Защита от timing-атак: всегда выполняем bcrypt
    fake_hash = "$2b$12$fakefakefakefakefakefakefakefakefakefakefakefakefakefakefa"
    stored_hash = user_data["password_hash"] if user_data else fake_hash

    try:
        password_ok = bcrypt.check_password_hash(stored_hash, password)
    except ValueError:
        password_ok = False

    if not user_data or not password_ok:
        attempts, just_blocked = _register_failed_attempt(ip)
        if just_blocked:
            _audit_log("blocked_now", ip, username, f"after {MAX_ATTEMPTS} attempts")
            return False, f"Превышено число попыток. IP заблокирован на {BLOCK_DURATION // 60} мин."
        _audit_log("login_failed", ip, username, f"attempt={attempts}/{MAX_ATTEMPTS}")
        remaining = MAX_ATTEMPTS - attempts
        return False, f"Неверный логин или пароль (осталось попыток: {remaining})"

    # Успех
    user_data["last_login"] = datetime.now().isoformat(timespec="seconds")
    users[username] = user_data
    _save_users(users)

    _clear_attempts(ip)
    _audit_log("login_success", ip, username)

    if ADMIN_PASS_FILE.exists():
        try:
            ADMIN_PASS_FILE.unlink()
            logger.info("web_admin_pass.txt удалён после первого входа")
        except OSError:
            pass

    return True, ""


def update_credentials(new_username: str, new_password: str, current_username: str) -> tuple[bool, str]:
    """Меняет логин и пароль текущего пользователя + ротирует SECRET_KEY."""
    new_username = new_username.strip()

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

    # Ротируем SECRET_KEY — все активные сессии станут невалидными
    rotate_secret_key()

    return True, "Учётные данные обновлены. Сервис перезапускается, войдите заново."
