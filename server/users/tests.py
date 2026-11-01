from datetime import datetime, timedelta
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

from django.contrib.auth.tokens import default_token_generator
from django.core.cache import cache
from django.core import mail
from django.db import IntegrityError
from django.test import override_settings
from django.utils.http import urlsafe_base64_encode
from rest_framework import status
from rest_framework.test import APIClient, APITestCase
from rest_framework_simplejwt.tokens import RefreshToken

from users.models import SystemSetting, User
from users.views import _clear_local_auth_cache_state


class AuthApiTests(APITestCase):
    def setUp(self):
        cache.clear()
        _clear_local_auth_cache_state()
        SystemSetting.set_open_registration(True)

    def test_register_success_when_open(self):
        resp = self.client.post(
            "/v1/auth/register",
            {
                "email": "new_user@example.com",
                "password": "Strong-pass-2026!",
                "confirm_password": "Strong-pass-2026!",
                "agreed": True,
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data["code"], 200)
        self.assertTrue(User.objects.filter(email="new_user@example.com").exists())

    @patch("users.views.RegisterSerializer.save")
    def test_register_returns_stable_error_when_concurrent_request_wins(self, mock_save):
        def concurrent_insert():
            User.objects.create_user(
                email="racing_user@example.com",
                password="Strong-pass-2026!",
            )
            raise IntegrityError("duplicate email")

        mock_save.side_effect = concurrent_insert
        response = self.client.post(
            "/v1/auth/register",
            {
                "email": "racing_user@example.com",
                "password": "Strong-pass-2026!",
                "confirm_password": "Strong-pass-2026!",
                "agreed": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "该邮箱已注册，请直接登录")

    @patch("users.views.RegisterSerializer.save", side_effect=IntegrityError("database failure"))
    def test_register_does_not_misreport_unrelated_integrity_error(self, _mock_save):
        with self.assertRaises(IntegrityError):
            self.client.post(
                "/v1/auth/register",
                {
                    "email": "database_failure@example.com",
                    "password": "Strong-pass-2026!",
                    "confirm_password": "Strong-pass-2026!",
                    "agreed": True,
                },
                format="json",
            )

    def test_register_blocked_when_closed(self):
        SystemSetting.set_open_registration(False)
        resp = self.client.post(
            "/v1/auth/register",
            {
                "email": "new_user2@example.com",
                "password": "Strong-pass-2026!",
                "confirm_password": "Strong-pass-2026!",
                "agreed": True,
            },
            format="json",
        )
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("暂未开放注册", resp.data["message"])
        self.assertFalse(User.objects.filter(email="new_user2@example.com").exists())

    @override_settings(
        AUTH_REGISTER_IP_MAX_ATTEMPTS=2,
        AUTH_REGISTER_RATE_WINDOW_SECONDS=3600,
    )
    def test_register_is_rate_limited_by_ip(self):
        payload = {
            "email": "invalid",
            "password": "Strong-pass-2026!",
            "confirm_password": "Strong-pass-2026!",
            "agreed": True,
        }
        for _ in range(2):
            response = self.client.post(
                "/v1/auth/register",
                payload,
                format="json",
                REMOTE_ADDR="203.0.113.40",
            )
            self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        blocked = self.client.post(
            "/v1/auth/register",
            payload,
            format="json",
            REMOTE_ADDR="203.0.113.40",
        )

        self.assertEqual(blocked.status_code, status.HTTP_429_TOO_MANY_REQUESTS)
        self.assertIn("请求过于频繁", blocked.data["message"])

    @override_settings(
        AUTH_REGISTER_IP_MAX_ATTEMPTS=2,
        AUTH_REGISTER_RATE_WINDOW_SECONDS=3600,
    )
    @patch("users.views.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_register_uses_process_local_rate_limit_when_cache_fails(self, _cache_add):
        payload = {
            "email": "invalid",
            "password": "Strong-pass-2026!",
            "confirm_password": "Strong-pass-2026!",
            "agreed": True,
        }
        for _ in range(2):
            self.client.post(
                "/v1/auth/register",
                payload,
                format="json",
                REMOTE_ADDR="203.0.113.41",
            )

        blocked = self.client.post(
            "/v1/auth/register",
            payload,
            format="json",
            REMOTE_ADDR="203.0.113.41",
        )

        self.assertEqual(blocked.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    @patch("users.views._LOCAL_AUTH_CACHE_MAX_ENTRIES", 1)
    @patch("users.views.cache.add", side_effect=ConnectionError("redis unavailable"))
    def test_register_fails_closed_when_local_fallback_capacity_is_full(self, _cache_add):
        payload = {
            "email": "invalid",
            "password": "Strong-pass-2026!",
            "confirm_password": "Strong-pass-2026!",
            "agreed": True,
        }
        first = self.client.post(
            "/v1/auth/register",
            payload,
            format="json",
            REMOTE_ADDR="203.0.113.42",
        )
        blocked = self.client.post(
            "/v1/auth/register",
            payload,
            format="json",
            REMOTE_ADDR="203.0.113.43",
        )

        self.assertEqual(first.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(blocked.status_code, status.HTTP_429_TOO_MANY_REQUESTS)

    def test_admin_settings_toggle_only_for_admin_flag(self):
        # 管理员基于 is_admin 标志位，而非邮箱硬编码
        admin = User.objects.create_user(email="admin@example.com", password="123456", is_admin=True)
        other = User.objects.create_user(email="other@example.com", password="123456")

        # 非管理员：看不到开关，也无权修改
        self.client.force_authenticate(other)
        got = self.client.get("/v1/auth/admin-settings")
        self.assertEqual(got.data["data"]["is_admin"], False)
        denied = self.client.post("/v1/auth/admin-settings", {"open_registration": True}, format="json")
        self.assertEqual(denied.status_code, status.HTTP_403_FORBIDDEN)

        # 管理员：可读可写
        self.client.force_authenticate(admin)
        opened = self.client.post("/v1/auth/admin-settings", {"open_registration": True}, format="json")
        self.assertEqual(opened.status_code, status.HTTP_200_OK)
        self.assertTrue(SystemSetting.is_open_registration())
        closed = self.client.post("/v1/auth/admin-settings", {"open_registration": False}, format="json")
        self.assertEqual(closed.status_code, status.HTTP_200_OK)
        self.assertFalse(SystemSetting.is_open_registration())

    def test_admin_settings_rejects_string_false(self):
        admin = User.objects.create_user(email="strict-admin@example.com", password="123456", is_admin=True)
        self.client.force_authenticate(admin)
        response = self.client.post(
            "/v1/auth/admin-settings",
            {"open_registration": "false"},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_object_only_auth_endpoints_reject_json_arrays(self):
        for path in ("/v1/auth/login", "/v1/auth/refresh", "/v1/auth/logout"):
            with self.subTest(path=path):
                response = self.client.post(path, [], format="json")
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertEqual(response.data["message"], "请求参数必须是对象")

    def test_admin_settings_rejects_json_array(self):
        admin = User.objects.create_user(email="array-admin@example.com", password="123456", is_admin=True)
        self.client.force_authenticate(admin)

        response = self.client.post("/v1/auth/admin-settings", [], format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["message"], "请求参数必须是对象")

    @override_settings(AUTH_REFRESH_COOKIE_SECURE=True)
    def test_login_sets_http_only_refresh_cookie_and_refresh_rotates_it(self):
        user = User.objects.create_user(email="refresh@example.com", password="123456")
        login = self.client.post(
            "/v1/auth/login",
            {"email": "refresh@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        self.assertNotIn("refresh_token", login.data["data"])
        self.assertEqual(login.data["data"]["user_id"], str(user.pk))
        self.assertEqual(login.data["data"]["email"], "refresh@example.com")
        login_cookie = login.cookies["riskon_refresh"]
        self.assertTrue(login_cookie["httponly"])
        self.assertTrue(login_cookie["secure"])
        self.assertEqual(login_cookie["samesite"], "Lax")

        previous_refresh = login_cookie.value
        refreshed = self.client.post("/v1/auth/refresh", {}, format="json")

        self.assertEqual(refreshed.status_code, status.HTTP_200_OK)
        self.assertTrue(refreshed.data["data"]["token"])
        self.assertNotEqual(refreshed.cookies["riskon_refresh"].value, previous_refresh)

    def test_legacy_refresh_body_is_migrated_to_cookie(self):
        user = User.objects.create_user(email="legacy-refresh@example.com", password="123456")
        legacy_refresh = str(RefreshToken.for_user(user))

        response = self.client.post(
            "/v1/auth/refresh",
            {"refresh_token": legacy_refresh},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.cookies["riskon_refresh"].value)

    def test_logout_clears_and_blacklists_refresh_cookie(self):
        user = User.objects.create_user(email="logout@example.com", password="123456")
        refresh = str(RefreshToken.for_user(user))
        self.client.cookies["riskon_refresh"] = refresh

        response = self.client.post("/v1/auth/logout", {}, format="json")
        replay_client = APIClient()
        replay_client.cookies["riskon_refresh"] = refresh
        replay = replay_client.post("/v1/auth/refresh", {}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.cookies["riskon_refresh"]["max-age"], 0)
        self.assertEqual(replay.status_code, status.HTTP_401_UNAUTHORIZED)

    @override_settings(
        EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend",
        PUBLIC_APP_URL="https://example.test",
    )
    def test_password_reset_request_hides_account_existence(self):
        User.objects.create_user(email="known@example.com", password="123456")

        known = self.client.post(
            "/v1/auth/password-reset/request",
            {"email": "known@example.com"},
            format="json",
        )
        unknown = self.client.post(
            "/v1/auth/password-reset/request",
            {"email": "unknown@example.com"},
            format="json",
        )

        self.assertEqual(known.data["message"], unknown.data["message"])
        self.assertEqual(len(mail.outbox), 1)
        self.assertIn("https://example.test/login?reset_uid=", mail.outbox[0].body)

    @override_settings(
        EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend",
        PUBLIC_APP_URL="https://example.test",
    )
    def test_password_reset_token_is_single_use(self):
        user = User.objects.create_user(email="reset@example.com", password="123456")
        self.client.post(
            "/v1/auth/password-reset/request",
            {"email": user.email},
            format="json",
        )
        reset_url = next(line for line in mail.outbox[0].body.splitlines() if line.startswith("https://"))
        query = parse_qs(urlparse(reset_url).query)
        payload = {
            "uid": query["reset_uid"][0],
            "token": query["reset_token"][0],
            "new_password": "Reset-pass-2026!",
            "confirm_password": "Reset-pass-2026!",
        }

        first = self.client.post("/v1/auth/password-reset/confirm", payload, format="json")
        second = self.client.post("/v1/auth/password-reset/confirm", payload, format="json")
        user.refresh_from_db()

        self.assertEqual(first.status_code, status.HTTP_200_OK)
        self.assertEqual(second.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertTrue(user.check_password("Reset-pass-2026!"))

    def test_password_reset_locks_user_before_rechecking_token(self):
        user = User.objects.create_user(email="locked-reset@example.com", password="123456")
        uid = urlsafe_base64_encode(str(user.pk).encode("utf-8"))
        token = default_token_generator.make_token(user)

        with patch.object(
            User.objects,
            "select_for_update",
            wraps=User.objects.select_for_update,
        ) as select_for_update:
            response = self.client.post(
                "/v1/auth/password-reset/confirm",
                {
                    "uid": uid,
                    "token": token,
                    "new_password": "Locked-reset-2026!",
                    "confirm_password": "Locked-reset-2026!",
                },
                format="json",
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        select_for_update.assert_called_once_with()

    @override_settings(PASSWORD_RESET_TIMEOUT=60)
    def test_password_reset_token_expires(self):
        user = User.objects.create_user(email="expired-reset@example.com", password="123456")
        issued_at = datetime(2026, 9, 5, 10, 0, 0)
        with patch.object(default_token_generator, "_now", return_value=issued_at):
            uid = urlsafe_base64_encode(str(user.pk).encode("utf-8"))
            token = default_token_generator.make_token(user)

        with patch.object(default_token_generator, "_now", return_value=issued_at + timedelta(seconds=61)):
            response = self.client.post(
                "/v1/auth/password-reset/confirm",
                {
                    "uid": uid,
                    "token": token,
                    "new_password": "Reset-pass-2026!",
                    "confirm_password": "Reset-pass-2026!",
                },
                format="json",
            )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("无效或已过期", response.data["message"])

    def test_login_locks_after_max_failures(self):
        User.objects.create_user(email="lock@example.com", password="123456")
        payload = {"email": "lock@example.com", "password": "bad", "agreed": True}
        for _ in range(10):
            self.client.post("/v1/auth/login", payload, format="json")

        last = self.client.post("/v1/auth/login", payload, format="json")
        self.assertEqual(last.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("3分钟后再试", last.data["message"])

    @override_settings(
        AUTH_LOGIN_ACCOUNT_MAX_FAILURES=10,
        AUTH_LOGIN_IP_MAX_FAILURES=3,
    )
    def test_login_ip_limit_applies_across_account_names(self):
        User.objects.create_user(email="valid@example.com", password="123456")
        for index in range(3):
            response = self.client.post(
                "/v1/auth/login",
                {
                    "email": f"missing-{index}@example.com",
                    "password": "bad",
                    "agreed": True,
                },
                format="json",
                REMOTE_ADDR="203.0.113.8",
            )
        blocked = self.client.post(
            "/v1/auth/login",
            {"email": "valid@example.com", "password": "123456", "agreed": True},
            format="json",
            REMOTE_ADDR="203.0.113.8",
        )

        self.assertIn("3分钟后再试", response.data["message"])
        self.assertEqual(blocked.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("3分钟后再试", blocked.data["message"])

    @override_settings(
        AUTH_LOGIN_ACCOUNT_MAX_FAILURES=2,
        AUTH_LOGIN_IP_MAX_FAILURES=20,
    )
    @patch("users.views.cache.delete_many", side_effect=ConnectionError("redis unavailable"))
    @patch("users.views.cache.set", side_effect=ConnectionError("redis unavailable"))
    @patch("users.views.cache.incr", side_effect=ConnectionError("redis unavailable"))
    @patch("users.views.cache.add", side_effect=ConnectionError("redis unavailable"))
    @patch("users.views.cache.get", side_effect=ConnectionError("redis unavailable"))
    def test_login_keeps_process_local_lock_when_cache_fails(
        self,
        _cache_get,
        _cache_add,
        _cache_incr,
        _cache_set,
        _cache_delete_many,
    ):
        User.objects.create_user(email="cache-down@example.com", password="correct-password")
        bad_payload = {
            "email": "cache-down@example.com",
            "password": "wrong-password",
            "agreed": True,
        }
        self.client.post("/v1/auth/login", bad_payload, format="json")
        locked = self.client.post("/v1/auth/login", bad_payload, format="json")

        blocked_valid_password = self.client.post(
            "/v1/auth/login",
            {
                "email": "cache-down@example.com",
                "password": "correct-password",
                "agreed": True,
            },
            format="json",
        )

        self.assertIn("3分钟后再试", locked.data["message"])
        self.assertIn("3分钟后再试", blocked_valid_password.data["message"])

    @override_settings(
        AUTH_LOGIN_ACCOUNT_MAX_FAILURES=2,
        AUTH_LOGIN_IP_MAX_FAILURES=20,
    )
    def test_login_keeps_local_lock_after_shared_cache_recovers(self):
        User.objects.create_user(email="cache-recovery@example.com", password="correct-password")
        bad_payload = {
            "email": "cache-recovery@example.com",
            "password": "wrong-password",
            "agreed": True,
        }
        with (
            patch("users.views.cache.get", side_effect=ConnectionError("redis unavailable")),
            patch("users.views.cache.add", side_effect=ConnectionError("redis unavailable")),
            patch("users.views.cache.set", side_effect=ConnectionError("redis unavailable")),
        ):
            self.client.post("/v1/auth/login", bad_payload, format="json")
            locked = self.client.post("/v1/auth/login", bad_payload, format="json")

        blocked_after_recovery = self.client.post(
            "/v1/auth/login",
            {
                "email": "cache-recovery@example.com",
                "password": "correct-password",
                "agreed": True,
            },
            format="json",
        )

        self.assertIn("3分钟后再试", locked.data["message"])
        self.assertIn("3分钟后再试", blocked_after_recovery.data["message"])

    def test_register_rejects_weak_password(self):
        response = self.client.post(
            "/v1/auth/register",
            {
                "email": "weak@example.com",
                "password": "12345678",
                "confirm_password": "12345678",
                "agreed": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("密码", response.data["message"])

    def test_register_uses_bcrypt_hasher(self):
        try:
            import bcrypt  # noqa: F401
        except Exception:
            self.skipTest("bcrypt not installed in current environment")

        self.client.post(
            "/v1/auth/register",
            {
                "email": "bcrypt@example.com",
                "password": "Strong-pass-2026!",
                "confirm_password": "Strong-pass-2026!",
                "agreed": True,
            },
            format="json",
        )
        user = User.objects.get(email="bcrypt@example.com")
        self.assertTrue(user.password.startswith("bcrypt_sha256$"))
