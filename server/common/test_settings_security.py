import os
import subprocess
import sys

from django.test import SimpleTestCase


class ProductionSettingsSecurityTests(SimpleTestCase):
    @staticmethod
    def _load_settings(
        *,
        aes_key: str,
        previous_key: str = "",
        **overrides: str,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "DB_ENGINE": "mysql",
                "DEBUG": "False",
                "SECRET_KEY": "independent-django-signing-key-for-tests",
                "AES_SECRET_KEY": aes_key,
                "AES_PREVIOUS_SECRET_KEY": previous_key,
                "ALLOWED_HOSTS": "example.test",
                "CORS_ALLOW_ALL_ORIGINS": "False",
                "CORS_ALLOWED_ORIGINS": "https://example.test",
                "PUBLIC_APP_URL": "https://example.test",
                "AUTH_REFRESH_COOKIE_SECURE": "True",
                "SESSION_COOKIE_SECURE": "True",
                "CSRF_COOKIE_SECURE": "True",
                "DB_PASSWORD": "independent-database-password-for-tests",
                "USE_REDIS_CACHE": "True",
            }
        )
        env.update(overrides)
        return subprocess.run(
            [sys.executable, "-c", "import riskon.settings"],
            cwd=os.path.dirname(os.path.dirname(__file__)),
            env=env,
            capture_output=True,
            check=False,
            text=True,
        )

    def test_production_rejects_missing_or_short_aes_key(self):
        missing = self._load_settings(aes_key="")
        short = self._load_settings(aes_key="short-key")

        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("必须配置独立 AES_SECRET_KEY", missing.stderr)
        self.assertNotEqual(short.returncode, 0)
        self.assertIn("不得短于 32 字符", short.stderr)

    def test_production_rejects_redundant_previous_key(self):
        current = "current-database-encryption-key-with-more-than-32-characters"
        result = self._load_settings(aes_key=current, previous_key=current)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不得与当前 AES_SECRET_KEY 相同", result.stderr)

    def test_production_accepts_independent_strong_aes_key(self):
        result = self._load_settings(
            aes_key="current-database-encryption-key-with-more-than-32-characters"
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_production_rejects_weak_django_secret_and_database_password(self):
        aes_key = "current-database-encryption-key-with-more-than-32-characters"
        weak_secret = self._load_settings(aes_key=aes_key, SECRET_KEY="too-short")
        default_db_password = self._load_settings(
            aes_key=aes_key,
            DB_PASSWORD="dev-only-db-password",
        )

        self.assertNotEqual(weak_secret.returncode, 0)
        self.assertIn("SECRET_KEY 不得短于 32 字符", weak_secret.stderr)
        self.assertNotEqual(default_db_password.returncode, 0)
        self.assertIn("DB_PASSWORD", default_db_password.stderr)

    def test_production_rejects_insecure_public_urls(self):
        aes_key = "current-database-encryption-key-with-more-than-32-characters"
        public_url = self._load_settings(
            aes_key=aes_key,
            PUBLIC_APP_URL="http://example.test",
        )
        cors_origin = self._load_settings(
            aes_key=aes_key,
            CORS_ALLOWED_ORIGINS="https://example.test,http://192.0.2.10",
        )

        self.assertNotEqual(public_url.returncode, 0)
        self.assertIn("PUBLIC_APP_URL 必须使用 HTTPS", public_url.stderr)
        self.assertNotEqual(cors_origin.returncode, 0)
        self.assertIn("CORS_ALLOWED_ORIGINS 仅允许 HTTPS", cors_origin.stderr)

    def test_production_rejects_insecure_auth_cookies(self):
        aes_key = "current-database-encryption-key-with-more-than-32-characters"
        for setting_name in (
            "AUTH_REFRESH_COOKIE_SECURE",
            "SESSION_COOKIE_SECURE",
            "CSRF_COOKIE_SECURE",
        ):
            with self.subTest(setting_name=setting_name):
                result = self._load_settings(aes_key=aes_key, **{setting_name: "False"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(setting_name, result.stderr)
