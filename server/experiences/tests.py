from django.test import override_settings
from rest_framework.test import APITestCase

from users.models import User


class TradingExperienceApiTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(
            email="experience@example.invalid",
            password="test-only-password",
        )
        self.client.force_authenticate(self.user)

    def test_create_and_list_are_scoped_to_user(self):
        response = self.client.post(
            "/v1/experience/create",
            {
                "title": "复盘止损",
                "body": "没有等待确认就追单，下一次先等收盘。",
                "images": ["https://cdn.example.invalid/review.png"],
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["data"]["title"], "复盘止损")
        listed = self.client.get("/v1/experience/list")
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(len(listed.data["data"]), 1)

    def test_images_are_limited_to_five(self):
        response = self.client.post(
            "/v1/experience/create",
            {"title": "图片", "body": "正文", "images": [f"https://cdn.invalid/{i}.png" for i in range(6)]},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("最多上传 5 张", response.data["message"])

    def test_detail_cannot_cross_user_boundary(self):
        created = self.client.post(
            "/v1/experience/create",
            {"title": "只属于我", "body": "正文"},
            format="json",
        )
        other = User.objects.create_user(email="other-experience@example.invalid", password="test-only-password")
        self.client.force_authenticate(other)
        response = self.client.get(f"/v1/experience/{created.data['data']['id']}")
        self.assertEqual(response.status_code, 404)

    def test_upload_url_requires_oss_configuration(self):
        response = self.client.post(
            "/v1/experience/upload-url",
            {"filename": "chart.png", "content_type": "image/png", "size": 128},
            format="json",
        )
        self.assertEqual(response.status_code, 503)

    @override_settings(
        OSS_ENDPOINT="https://oss-cn-seoul.aliyuncs.com",
        OSS_BUCKET="trade-plan-test",
        OSS_ACCESS_KEY_ID="test-key",
        OSS_ACCESS_KEY_SECRET="test-secret",
        OSS_PUBLIC_BASE_URL="https://cdn.example.invalid/trade-plan",
        OSS_KEY_PREFIX="trade-plan",
        OSS_SIGNED_URL_TTL=600,
        OSS_MAX_IMAGE_BYTES=4 * 1024 * 1024,
    )
    def test_upload_url_is_scoped_and_signed(self):
        response = self.client.post(
            "/v1/experience/upload-url",
            {"filename": "chart.png", "content_type": "image/png", "size": 128},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        data = response.data["data"]
        self.assertTrue(data["url"].startswith("https://trade-plan-test.oss-cn-seoul.aliyuncs.com/"))
        self.assertIn(f"/{self.user.id}/", data["object_key"])
        self.assertEqual(data["headers"], {"Content-Type": "image/png"})
        self.assertTrue(data["public_url"].startswith("https://cdn.example.invalid/trade-plan/"))
