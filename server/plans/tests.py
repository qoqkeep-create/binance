from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

User = get_user_model()

PLAN_PAYLOAD = {
    "symbol": "btcusdt",
    "direction": "long",
    "timeframe": "1h",
    "entry": "98400",
    "stop": "96900",
    "target": "103800",
    "risk": "120",
    "thesis": " 回踩需求区 ",
    "images": [],
}


class TradingPlanAPITests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="plan-owner@example.invalid", password="test-only-password")
        self.client.force_authenticate(self.user)

    def test_create_list_and_normalize(self):
        response = self.client.post("/v1/plan/create", PLAN_PAYLOAD, format="json")
        self.assertEqual(response.status_code, 200)
        data = response.data["data"]
        self.assertEqual(data["symbol"], "BTCUSDT")
        self.assertEqual(data["thesis"], "回踩需求区")
        self.assertEqual(data["status"], "undone")
        listing = self.client.get("/v1/plan/list")
        self.assertEqual(len(listing.data["data"]), 1)

    def test_requires_authentication(self):
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/v1/plan/list").status_code, 401)
        self.assertEqual(self.client.post("/v1/plan/create", PLAN_PAYLOAD, format="json").status_code, 401)

    def test_cannot_cross_user_boundary(self):
        created = self.client.post("/v1/plan/create", PLAN_PAYLOAD, format="json")
        other = User.objects.create_user(email="plan-other@example.invalid", password="test-only-password")
        self.client.force_authenticate(other)
        self.assertEqual(self.client.get("/v1/plan/list").data["data"], [])
        plan_id = created.data["data"]["id"]
        self.assertEqual(self.client.get(f"/v1/plan/{plan_id}").status_code, 404)
        self.assertEqual(self.client.patch(f"/v1/plan/{plan_id}", {"status": "done"}, format="json").status_code, 404)
        self.assertEqual(self.client.delete(f"/v1/plan/{plan_id}").status_code, 404)

    def test_status_toggle_and_delete(self):
        created = self.client.post("/v1/plan/create", PLAN_PAYLOAD, format="json")
        plan_id = created.data["data"]["id"]
        updated = self.client.patch(f"/v1/plan/{plan_id}", {"status": "done"}, format="json")
        self.assertEqual(updated.data["data"]["status"], "done")
        self.assertEqual(self.client.delete(f"/v1/plan/{plan_id}").status_code, 200)
        self.assertEqual(self.client.get("/v1/plan/list").data["data"], [])

    def test_rejects_invalid_direction_and_images(self):
        bad = dict(PLAN_PAYLOAD, direction="sideways")
        self.assertEqual(self.client.post("/v1/plan/create", bad, format="json").status_code, 400)
        bad = dict(PLAN_PAYLOAD, images=["javascript:alert(1)"])
        self.assertEqual(self.client.post("/v1/plan/create", bad, format="json").status_code, 400)
        bad = dict(PLAN_PAYLOAD, images=["https://example.invalid/a.png"] * 6)
        self.assertEqual(self.client.post("/v1/plan/create", bad, format="json").status_code, 400)