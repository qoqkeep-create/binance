from datetime import timedelta
from pathlib import Path
import os
import warnings
from urllib.parse import urlsplit

from django.core.exceptions import ImproperlyConfigured
from corsheaders.defaults import default_headers
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-key")
_CONFIGURED_AES_SECRET_KEY = os.getenv("AES_SECRET_KEY", "").strip()
AES_SECRET_KEY = _CONFIGURED_AES_SECRET_KEY or SECRET_KEY
AES_PREVIOUS_SECRET_KEY = os.getenv("AES_PREVIOUS_SECRET_KEY", "").strip()
DEBUG = os.getenv("DEBUG", "False").lower() == "true"
ALLOWED_HOSTS = [h.strip() for h in os.getenv("ALLOWED_HOSTS", "*").split(",") if h.strip()]
DB_ENGINE = os.getenv("DB_ENGINE", "mysql")

if DB_ENGINE == "mysql" and not DEBUG:
    if SECRET_KEY in {"", "dev-secret-key", "dev-only-replace-with-long-secret"}:
        raise ImproperlyConfigured("生产环境必须配置独立且足够随机的 SECRET_KEY")
    if len(SECRET_KEY) < 32:
        raise ImproperlyConfigured("生产环境 SECRET_KEY 不得短于 32 字符")
    if not _CONFIGURED_AES_SECRET_KEY:
        raise ImproperlyConfigured("生产环境必须配置独立 AES_SECRET_KEY")
    if len(_CONFIGURED_AES_SECRET_KEY) < 32:
        raise ImproperlyConfigured("生产环境 AES_SECRET_KEY 不得短于 32 字符")
    if _CONFIGURED_AES_SECRET_KEY == SECRET_KEY:
        raise ImproperlyConfigured("生产环境 AES_SECRET_KEY 不得与 SECRET_KEY 相同")
    if AES_PREVIOUS_SECRET_KEY and AES_PREVIOUS_SECRET_KEY == _CONFIGURED_AES_SECRET_KEY:
        raise ImproperlyConfigured("AES_PREVIOUS_SECRET_KEY 不得与当前 AES_SECRET_KEY 相同")
    if "*" in ALLOWED_HOSTS:
        raise ImproperlyConfigured("生产环境 ALLOWED_HOSTS 不得包含通配符")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "corsheaders",
    "rest_framework",
    "rest_framework_simplejwt",
    "rest_framework_simplejwt.token_blacklist",
    "users",
    "invites",
    "api_bindings",
    "accounts",
    "trading",
    "positions",
    "market_analysis",
    "common",
    "market_stream",
    "mobile",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "api_bindings.mode_middleware.TradingModeMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "riskon.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "riskon.wsgi.application"
ASGI_APPLICATION = "riskon.asgi.application"

if DB_ENGINE == "mysql":
    configured_db_password = os.getenv("DB_PASSWORD", "dev-only-db-password").strip()
    if not DEBUG and configured_db_password in {
        "",
        "dev-only-db-password",
        "replace-with-db-password",
    }:
        raise ImproperlyConfigured("生产环境必须配置独立且非默认的 DB_PASSWORD")
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.mysql",
            "NAME": os.getenv("DB_NAME", "riskon"),
            "USER": os.getenv("DB_USER", "riskon"),
            "PASSWORD": configured_db_password,
            "HOST": os.getenv("DB_HOST", "127.0.0.1"),
            "PORT": os.getenv("DB_PORT", "3306"),
            "OPTIONS": {
                "charset": "utf8mb4",
            },
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
        }
    }

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator", "OPTIONS": {"min_length": 8}},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]
PASSWORD_HASHERS = []
try:
    import bcrypt  # noqa: F401

    PASSWORD_HASHERS.append("django.contrib.auth.hashers.BCryptSHA256PasswordHasher")
except Exception:
    warnings.warn("bcrypt not installed, fallback to PBKDF2PasswordHasher")

PASSWORD_HASHERS.append("django.contrib.auth.hashers.PBKDF2PasswordHasher")

LANGUAGE_CODE = "zh-hans"
TIME_ZONE = "Asia/Shanghai"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
AUTH_USER_MODEL = "users.User"
DATA_UPLOAD_MAX_MEMORY_SIZE = int(os.getenv("DATA_UPLOAD_MAX_MEMORY_SIZE", str(256 * 1024)))
FILE_UPLOAD_MAX_MEMORY_SIZE = DATA_UPLOAD_MAX_MEMORY_SIZE
SESSION_COOKIE_SECURE = os.getenv("SESSION_COOKIE_SECURE", str(not DEBUG)).lower() == "true"
CSRF_COOKIE_SECURE = os.getenv("CSRF_COOKIE_SECURE", str(not DEBUG)).lower() == "true"

CORS_ALLOW_ALL_ORIGINS = os.getenv("CORS_ALLOW_ALL_ORIGINS", "False").lower() == "true"
CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.getenv("CORS_ALLOWED_ORIGINS", "http://localhost:5173").split(",") if o.strip()
]
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOW_HEADERS = [*default_headers, "x-trading-mode"]
if DB_ENGINE == "mysql" and not DEBUG and CORS_ALLOW_ALL_ORIGINS:
    raise ImproperlyConfigured("生产环境不得启用 CORS_ALLOW_ALL_ORIGINS")
if DB_ENGINE == "mysql" and not DEBUG:
    insecure_cors_origins = [
        origin
        for origin in CORS_ALLOWED_ORIGINS
        if urlsplit(origin).scheme.lower() != "https" or not urlsplit(origin).hostname
    ]
    if insecure_cors_origins:
        raise ImproperlyConfigured("生产环境 CORS_ALLOWED_ORIGINS 仅允许 HTTPS 来源")

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": (
        "rest_framework.permissions.IsAuthenticated",
    ),
    "EXCEPTION_HANDLER": "common.exceptions.custom_exception_handler",
}

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=15),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=14),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
    "CHECK_REVOKE_TOKEN": True,
    "AUTH_HEADER_TYPES": ("Bearer",),
}

AUTH_REFRESH_COOKIE_NAME = os.getenv("AUTH_REFRESH_COOKIE_NAME", "riskon_refresh").strip() or "riskon_refresh"
AUTH_REFRESH_COOKIE_SECURE = os.getenv("AUTH_REFRESH_COOKIE_SECURE", str(not DEBUG)).lower() == "true"
AUTH_REFRESH_COOKIE_SAMESITE = "Lax"
AUTH_REFRESH_COOKIE_PATH = os.getenv("AUTH_REFRESH_COOKIE_PATH", "/")
if DB_ENGINE == "mysql" and not DEBUG:
    insecure_cookie_settings = [
        name
        for name, enabled in (
            ("AUTH_REFRESH_COOKIE_SECURE", AUTH_REFRESH_COOKIE_SECURE),
            ("SESSION_COOKIE_SECURE", SESSION_COOKIE_SECURE),
            ("CSRF_COOKIE_SECURE", CSRF_COOKIE_SECURE),
        )
        if not enabled
    ]
    if insecure_cookie_settings:
        raise ImproperlyConfigured(
            f"生产环境必须启用安全 Cookie: {', '.join(insecure_cookie_settings)}"
        )
PASSWORD_RESET_TIMEOUT = int(os.getenv("PASSWORD_RESET_TIMEOUT", "1800"))
AUTH_LOGIN_FAILURE_WINDOW_SECONDS = int(os.getenv("AUTH_LOGIN_FAILURE_WINDOW_SECONDS", "3600"))
AUTH_LOGIN_LOCK_SECONDS = int(os.getenv("AUTH_LOGIN_LOCK_SECONDS", "180"))
AUTH_LOGIN_ACCOUNT_MAX_FAILURES = int(os.getenv("AUTH_LOGIN_ACCOUNT_MAX_FAILURES", "10"))
AUTH_LOGIN_IP_MAX_FAILURES = int(os.getenv("AUTH_LOGIN_IP_MAX_FAILURES", "50"))
AUTH_REGISTER_IP_MAX_ATTEMPTS = int(os.getenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "10"))
AUTH_REGISTER_RATE_WINDOW_SECONDS = int(os.getenv("AUTH_REGISTER_RATE_WINDOW_SECONDS", "3600"))
PUBLIC_APP_URL = os.getenv("PUBLIC_APP_URL", "https://ba.wow211.com").strip().rstrip("/")
if DB_ENGINE == "mysql" and not DEBUG:
    public_app = urlsplit(PUBLIC_APP_URL)
    if public_app.scheme.lower() != "https" or not public_app.hostname:
        raise ImproperlyConfigured("生产环境 PUBLIC_APP_URL 必须使用 HTTPS")

USE_REDIS_CACHE = os.getenv("USE_REDIS_CACHE", "False").lower() == "true"
if DB_ENGINE == "mysql" and not DEBUG and not USE_REDIS_CACHE:
    raise ImproperlyConfigured("生产 MySQL 多进程部署必须启用 Redis 共享缓存、锁和请求预算")
if USE_REDIS_CACHE:
    REDIS_URL = os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0")
    CACHES = {
        "default": {
            "BACKEND": "django_redis.cache.RedisCache",
            "LOCATION": REDIS_URL,
            "OPTIONS": {
                "CLIENT_CLASS": "django_redis.client.DefaultClient",
            },
        }
    }
else:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "riskon-cache",
        }
    }

MARKET_QUOTE_ASSET = os.getenv("BINANCE_QUOTE_ASSET", "USDT").upper()
MARKET_WS_URL = os.getenv("MARKET_WS_URL", os.getenv("BINANCE_MARKET_WS_URL", "wss://fstream.binance.com/market"))
# Conservative stream reconnect budget, shared by market and account workers.
MARKET_WS_ATTEMPTS_PER_MINUTE = int(os.getenv("MARKET_WS_ATTEMPTS_PER_MINUTE", "30"))
MARKET_WS_CONNECT_SPACING_SECONDS = float(os.getenv("MARKET_WS_CONNECT_SPACING_SECONDS", "1"))
MARKET_REDIS_URL = os.getenv("MARKET_REDIS_URL", os.getenv("REDIS_URL", "redis://127.0.0.1:6379/0"))
MARKET_STREAM_ENABLED = os.getenv("MARKET_STREAM_ENABLED", "true").lower() == "true"
ACCOUNT_WS_URL = os.getenv("ACCOUNT_WS_URL", "wss://fstream.binance.com/private")
ACCOUNT_STREAM_ENABLED = os.getenv("ACCOUNT_STREAM_ENABLED", "false").lower() == "true"
CACHES["default"]["KEY_PREFIX"] = os.getenv("CACHE_KEY_PREFIX", "trade-integrated")

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
        }
    },
    "root": {
        "handlers": ["console"],
        "level": os.getenv("LOG_LEVEL", "INFO"),
    },
}

BINANCE_FUTURES_BASE_URL = os.getenv("BINANCE_FUTURES_BASE_URL", "https://fapi.binance.com").rstrip("/")
LEAD_TRADING_ENABLED = os.getenv("LEAD_TRADING_ENABLED", "false").lower() == "true"
BINANCE_SPOT_BASE_URL = os.getenv("BINANCE_SPOT_BASE_URL", "").strip().rstrip("/")
BINANCE_TIMEOUT_SECONDS = float(os.getenv("BINANCE_TIMEOUT_SECONDS", "10"))
BINANCE_RECV_WINDOW = int(os.getenv("BINANCE_RECV_WINDOW", "5000"))
BINANCE_DEFAULT_MAX_LEVERAGE = int(os.getenv("BINANCE_DEFAULT_MAX_LEVERAGE", "125"))
BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE = int(os.getenv("BINANCE_FUTURES_WEIGHT_LIMIT_PER_MINUTE", "2400"))
BINANCE_SPOT_WEIGHT_LIMIT_PER_MINUTE = int(os.getenv("BINANCE_SPOT_WEIGHT_LIMIT_PER_MINUTE", "6000"))
BINANCE_SAPI_WEIGHT_LIMIT_PER_MINUTE = int(os.getenv("BINANCE_SAPI_WEIGHT_LIMIT_PER_MINUTE", "12000"))
BINANCE_BACKGROUND_WEIGHT_RATIO = float(os.getenv("BINANCE_BACKGROUND_WEIGHT_RATIO", "0.65"))
BINANCE_NORMAL_WEIGHT_RATIO = float(os.getenv("BINANCE_NORMAL_WEIGHT_RATIO", "0.85"))
BINANCE_CRITICAL_WEIGHT_RATIO = float(os.getenv("BINANCE_CRITICAL_WEIGHT_RATIO", "0.96"))
BINANCE_ORDER_LIMIT_PER_MINUTE = int(os.getenv("BINANCE_ORDER_LIMIT_PER_MINUTE", "1200"))
BINANCE_ORDER_LIMIT_RATIO = float(os.getenv("BINANCE_ORDER_LIMIT_RATIO", "0.95"))
BINANCE_AUTH_FAILURE_THRESHOLD = int(os.getenv("BINANCE_AUTH_FAILURE_THRESHOLD", "3"))
BINANCE_AUTH_FAILURE_WINDOW_SECONDS = int(os.getenv("BINANCE_AUTH_FAILURE_WINDOW_SECONDS", "21600"))
SERVER_PUBLIC_IP = os.getenv("SERVER_PUBLIC_IP", "").strip()

MARKET_ANALYSIS_ALERT_URL = os.getenv("MARKET_ANALYSIS_ALERT_URL", "http://tradingview-webhook:3000/internal/market-scan").strip()
MARKET_ANALYSIS_ALERT_TOKEN = os.getenv("MARKET_ANALYSIS_ALERT_TOKEN", "").strip()
# 公开 K 线快照的 CDN 预热：按周期节奏请求主站公开 URL，使 CDN 副本保持常热，
# 消除大陆首屏历史 K 线的跨境回源。默认开启，只用公开行情、不带凭证。
MARKET_SNAPSHOT_PREWARM_ENABLED = os.getenv("MARKET_SNAPSHOT_PREWARM_ENABLED", "True").lower() == "true"
MARKET_SNAPSHOT_PREWARM_URL = os.getenv("MARKET_SNAPSHOT_PREWARM_URL", "https://ba.wow211.com").strip()
OPS_ALERT_URL = os.getenv(
    "OPS_ALERT_URL",
    "http://tradingview-webhook:3000/internal/ops-alert",
).strip()
OPS_ALERT_TOKEN = os.getenv("OPS_ALERT_TOKEN", "").strip() or MARKET_ANALYSIS_ALERT_TOKEN
OPS_ALERT_TIMEOUT_SECONDS = float(os.getenv("OPS_ALERT_TIMEOUT_SECONDS", "5"))
TRADE_NOTIFICATION_URL = os.getenv(
    "TRADE_NOTIFICATION_URL",
    "http://tradingview-webhook:3000/internal/trade-notification",
).strip()
TRADE_NOTIFICATION_TOKEN = os.getenv("TRADE_NOTIFICATION_TOKEN", "").strip() or MARKET_ANALYSIS_ALERT_TOKEN
TRADE_NOTIFICATION_TIMEOUT_SECONDS = float(os.getenv("TRADE_NOTIFICATION_TIMEOUT_SECONDS", "5"))
EXTERNAL_TRADE_SIGNAL_ENABLED = os.getenv("EXTERNAL_TRADE_SIGNAL_ENABLED", "False").lower() == "true"
EXTERNAL_TRADE_SIGNAL_URL = os.getenv("EXTERNAL_TRADE_SIGNAL_URL", "").strip()
EXTERNAL_TRADE_SIGNAL_API_KEY = os.getenv("EXTERNAL_TRADE_SIGNAL_API_KEY", "").strip()
EXTERNAL_TRADE_SIGNAL_TIMEOUT_SECONDS = float(os.getenv("EXTERNAL_TRADE_SIGNAL_TIMEOUT_SECONDS", "5"))
TV_WEBHOOK_API_KEY = os.getenv("TV_WEBHOOK_API_KEY", "").strip()

# 资金封顶提醒等系统邮件走 SMTP；凭据只存部署环境的 .env.docker，不进仓库。
# EMAIL_HOST 未配置时自动降级为控制台后端（仅记日志，不发信）。
EMAIL_HOST = os.getenv("EMAIL_HOST", "").strip()
EMAIL_PORT = int(os.getenv("EMAIL_PORT", "465"))
EMAIL_HOST_USER = os.getenv("EMAIL_HOST_USER", "").strip()
EMAIL_HOST_PASSWORD = os.getenv("EMAIL_HOST_PASSWORD", "").strip()
EMAIL_USE_SSL = os.getenv("EMAIL_USE_SSL", "True").lower() == "true"
EMAIL_USE_TLS = os.getenv("EMAIL_USE_TLS", "False").lower() == "true"
DEFAULT_FROM_EMAIL = os.getenv("EMAIL_FROM", "").strip() or EMAIL_HOST_USER
if EMAIL_HOST:
    EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
else:
    EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

# Independent mobile notifications; key material stays in a restricted mounted file.
APNS_ENABLED = os.getenv('APNS_ENABLED', 'False').lower() == 'true'
APNS_TEAM_ID = os.getenv('APNS_TEAM_ID', '').strip()
APNS_KEY_ID = os.getenv('APNS_KEY_ID', '').strip()
APNS_KEY_PATH = os.getenv('APNS_KEY_PATH', '').strip()
APNS_BUNDLE_ID = os.getenv('APNS_BUNDLE_ID', 'com.waibao2025.trade.integrated').strip()
POSITION_PROFIT_CALL_ENABLED = os.getenv('POSITION_PROFIT_CALL_ENABLED', 'False').lower() == 'true'
POSITION_PROFIT_CALL_USER_ID = int(os.getenv('POSITION_PROFIT_CALL_USER_ID', '0') or '0')
POSITION_PROFIT_CALL_URL = os.getenv('POSITION_PROFIT_CALL_URL', '').strip()
