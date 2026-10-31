from rest_framework import status
from rest_framework.test import APITestCase
from django.utils import timezone

from users.models import User


class WatchPlanApiTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="watch_plan_test@example.com", password="123456")
        login_resp = self.client.post(
            "/v1/auth/login",
            {"email": "watch_plan_test@example.com", "password": "123456", "agreed": True},
            format="json",
        )
        token = login_resp.data["data"]["token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")

    def test_watch_plan_crud(self):
        create = self.client.post(
            "/v1/watch-plan/create",
            {
                "symbol": "BTCUSDT",
                "plan_date": "2026-05-19",
                "plan_type": 1,
                "timeframe": "1h",
                "direction": 0,
                "content": "test content",
                "take_profit_expectation": "test target",
            },
            format="json",
        )
        self.assertEqual(create.status_code, status.HTTP_200_OK)
        item_id = int(create.data["data"]["id"])
        self.assertGreater(item_id, 0)
        self.assertEqual(create.data["data"]["status"], 0)
        self.assertEqual(create.data["data"]["result"], 0)
        self.assertEqual(create.data["data"]["result_amount"], "")
        self.assertEqual(create.data["data"]["plan_date"], "2026-05-19")
        self.assertEqual(create.data["data"]["plan_type"], 1)
        self.assertEqual(create.data["data"]["take_profit_expectation"], "test target")

        listed = self.client.get("/v1/watch-plan/list")
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual(len(listed.data["data"]), 1)

        invalid_result = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "result": 1},
            format="json",
        )
        self.assertEqual(invalid_result.status_code, status.HTTP_200_OK)
        self.assertEqual(invalid_result.data["data"]["result"], 1)
        self.assertEqual(invalid_result.data["data"]["result_amount"], "")

        mark_done = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "status": 1},
            format="json",
        )
        self.assertEqual(mark_done.status_code, status.HTTP_200_OK)
        self.assertEqual(mark_done.data["data"]["status"], 1)
        self.assertEqual(mark_done.data["data"]["result"], 1)
        self.assertEqual(mark_done.data["data"]["review_content"], "")

        set_result = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "result": 2, "result_amount": "30"},
            format="json",
        )
        self.assertEqual(set_result.status_code, status.HTTP_200_OK)
        self.assertEqual(set_result.data["data"]["status"], 1)
        self.assertEqual(set_result.data["data"]["result"], 2)
        self.assertEqual(set_result.data["data"]["result_amount"], "30.00")

        mark_undone = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "status": 0},
            format="json",
        )
        self.assertEqual(mark_undone.status_code, status.HTTP_200_OK)
        self.assertEqual(mark_undone.data["data"]["status"], 0)
        self.assertEqual(mark_undone.data["data"]["result"], 2)
        self.assertEqual(mark_undone.data["data"]["result_amount"], "30.00")

        set_zero_result = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "result": 1, "result_amount": "0"},
            format="json",
        )
        self.assertEqual(set_zero_result.status_code, status.HTTP_200_OK)
        self.assertEqual(set_zero_result.data["data"]["result"], 1)
        self.assertEqual(set_zero_result.data["data"]["result_amount"], "0.00")

        clear_amount_only = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "result_amount": ""},
            format="json",
        )
        self.assertEqual(clear_amount_only.status_code, status.HTTP_200_OK)
        self.assertEqual(clear_amount_only.data["data"]["result"], 1)
        self.assertEqual(clear_amount_only.data["data"]["result_amount"], "")

        clear_result = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "result": 0},
            format="json",
        )
        self.assertEqual(clear_result.status_code, status.HTTP_200_OK)
        self.assertEqual(clear_result.data["data"]["result"], 0)
        self.assertEqual(clear_result.data["data"]["result_amount"], "")

        set_score = self.client.post(
            "/v1/watch-plan/update",
            {
                "id": item_id,
                "score": 92,
                "score_payload": {
                    "checks": ["trend-aligned", "ema-aligned"],
                    "vetoes": [],
                },
            },
            format="json",
        )
        self.assertEqual(set_score.status_code, status.HTTP_200_OK)
        self.assertEqual(set_score.data["data"]["score"], 92)
        self.assertEqual(set_score.data["data"]["score_payload"]["checks"], ["trend-aligned", "ema-aligned"])

        clear_score = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "score": "", "score_payload": ""},
            format="json",
        )
        self.assertEqual(clear_score.status_code, status.HTTP_200_OK)
        self.assertIsNone(clear_score.data["data"]["score"])
        self.assertEqual(clear_score.data["data"]["score_payload"], {})

        update_review = self.client.post(
            "/v1/watch-plan/update",
            {"id": item_id, "review_content": "review"},
            format="json",
        )
        self.assertEqual(update_review.status_code, status.HTTP_200_OK)
        self.assertEqual(update_review.data["data"]["review_content"], "review")

        update_content = self.client.post(
            "/v1/watch-plan/update",
            {
                "id": item_id,
                "content": "updated",
                "take_profit_expectation": "target updated",
                "symbol": "ETHUSDT",
                "plan_date": "2026-05-20",
                "plan_type": 0,
                "timeframe": "4h",
                "direction": 1,
            },
            format="json",
        )
        self.assertEqual(update_content.status_code, status.HTTP_200_OK)
        self.assertEqual(update_content.data["data"]["content"], "updated")
        self.assertEqual(update_content.data["data"]["take_profit_expectation"], "target updated")
        self.assertEqual(update_content.data["data"]["symbol"], "ETHUSDT")
        self.assertEqual(update_content.data["data"]["plan_date"], "2026-05-20")
        self.assertEqual(update_content.data["data"]["plan_type"], 0)
        self.assertEqual(update_content.data["data"]["timeframe"], "4h")
        self.assertEqual(update_content.data["data"]["direction"], 1)

        deleted = self.client.post("/v1/watch-plan/delete", {"id": item_id}, format="json")
        self.assertEqual(deleted.status_code, status.HTTP_200_OK)
        after = self.client.get("/v1/watch-plan/list")
        self.assertEqual(after.status_code, status.HTTP_200_OK)
        self.assertEqual(after.data["data"], [])

    def test_watch_plan_create_defaults_plan_date_to_today(self):
        today = timezone.localdate().isoformat()
        create = self.client.post(
            "/v1/watch-plan/create",
            {
                "symbol": "DOGEUSDT",
                "plan_type": 0,
                "timeframe": "1h",
                "direction": 0,
                "content": "today",
                "take_profit_expectation": "tp",
            },
            format="json",
        )
        self.assertEqual(create.status_code, status.HTTP_200_OK)
        self.assertEqual(create.data["data"]["plan_date"], today)
        self.assertEqual(create.data["data"]["plan_type"], 0)
