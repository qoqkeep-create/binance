from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient


class WebSettingsTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.first = get_user_model().objects.create_user(email="web-one@example.com", password="StrongPassword8!")
        self.second = get_user_model().objects.create_user(email="web-two@example.com", password="StrongPassword8!")
        self.client.force_authenticate(self.first)

    def test_settings_are_created_and_patched_with_optimistic_version(self):
        initial = self.client.get("/api/web/settings")
        self.assertEqual(initial.status_code, 200)
        self.assertEqual(initial.data["data"]["version"], 0)
        saved = self.client.patch("/api/web/settings", {"patch": {"theme": "light", "chart": {"interval": "15"}}, "baseVersion": 0}, format="json")
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(saved.data["data"]["version"], 1)
        self.assertEqual(saved.data["data"]["settings"], {"theme": "light", "chart": {"interval": "15"}})
        conflict = self.client.patch("/api/web/settings", {"patch": {"theme": "dark"}, "baseVersion": 0}, format="json")
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(conflict.data["data"]["version"], 1)

    def test_settings_are_isolated_and_validation_rejects_unknown_fields(self):
        self.client.patch("/api/web/settings", {"patch": {"selectedSymbol": "BTCUSDT"}, "baseVersion": 0}, format="json")
        self.client.force_authenticate(self.second)
        self.assertEqual(self.client.get("/api/web/settings").data["data"]["settings"], {})
        invalid = self.client.patch("/api/web/settings", {"patch": {"role": "admin"}, "baseVersion": 0}, format="json")
        self.assertEqual(invalid.status_code, 400)

    def test_chart_rejects_empty_indicator_input_names(self):
        response = self.client.patch(
            "/api/web/settings",
            {"patch": {"chart": {"studies": [{"id": "STD;MA", "inputs": {"": 12}}]}}, "baseVersion": 0},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
