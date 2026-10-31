from datetime import datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch

from django.test import TestCase
from rest_framework.test import APIClient

from signal_research.ai import validate_definition
from signal_research.models import ResearchStrategy, SignalSample
from signal_research.services import enrich_candles
from users.models import User


class ResearchSafetyTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="research-safety@example.invalid", password="test-only-password")
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.now = datetime(2026, 9, 30, 8, tzinfo=dt_timezone.utc)

    def sample(self, signal_time=None):
        return SignalSample.objects.create(
            user=self.user, symbol="BTCUSDT", timeframe="1m", signal_time=signal_time or self.now
        )

    def candles(self, *, closed_at, count=180):
        end_ms = int(closed_at.timestamp() * 1000)
        return enrich_candles([
            {
                "open_time": end_ms - (count - index) * 60_000,
                "close_time": end_ms - (count - index - 1) * 60_000 - 1,
                "open": str(100 + index), "high": str(102 + index),
                "low": str(99 + index), "close": str(101 + index), "volume": "10",
            }
            for index in range(count)
        ])

    @patch("signal_research.views.timezone.now")
    def test_create_rejects_future_sample(self, clock):
        clock.return_value = self.now
        response = self.client.post("/v1/signal-research/samples", {
            "symbol": "BTCUSDT", "timeframe": "1m",
            "signal_time": (self.now + timedelta(seconds=1)).isoformat(),
        }, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertFalse(SignalSample.objects.exists())

    @patch("signal_research.views.generate_strategy_draft")
    @patch("signal_research.views.timezone.now")
    def test_previously_fetched_future_samples_are_excluded_from_research(self, clock, generate):
        clock.return_value = self.now
        sample = self.sample(self.now + timedelta(hours=1))
        sample.features, sample.trusted, sample.fetched_at = {"ready": True}, True, self.now
        sample.save(update_fields=["features", "trusted", "fetched_at"])
        generate.return_value = {
            "name": "Future input", "definition": {}, "natural_rules": [], "code": "", "rationale": "",
        }
        with self.subTest(endpoint="rules"):
            response = self.client.get("/v1/signal-research/rules")
            self.assertEqual(response.data["data"]["trusted_sample_count"], 0)
        with self.subTest(endpoint="preview"):
            response = self.client.get("/v1/signal-research/strategies/preview")
            self.assertEqual(response.data["data"]["packet"]["trusted_count"], 0)
        with self.subTest(endpoint="generate"):
            response = self.client.post("/v1/signal-research/strategies/generate", {}, format="json")
            self.assertEqual(response.status_code, 400)
        generate.assert_not_called()

    @patch("signal_research.views.generate_strategy_draft")
    @patch("signal_research.views.fetch_candles")
    @patch("signal_research.views.timezone.now")
    def test_legacy_early_fetch_requires_recapture_before_ready_features_are_consumed(self, clock, fetch, generate):
        clock.return_value = self.now
        signal_time = self.now - timedelta(minutes=1)
        sample = self.sample(signal_time)
        sample.features, sample.trusted = {"ready": True}, True
        sample.fetched_at = signal_time - timedelta(minutes=1)
        sample.save(update_fields=["features", "trusted", "fetched_at"])
        generate.return_value = {
            "name": "Recaptured", "definition": {}, "natural_rules": [], "code": "", "rationale": "",
        }
        self.assertEqual(self.client.get("/v1/signal-research/rules").data["data"]["trusted_sample_count"], 0)
        self.assertEqual(self.client.get("/v1/signal-research/strategies/preview").data["data"]["packet"]["trusted_count"], 0)
        self.assertEqual(self.client.post("/v1/signal-research/strategies/generate", {}, format="json").status_code, 400)
        generate.assert_not_called()

        fetch.return_value = self.candles(closed_at=signal_time)
        self.assertEqual(self.client.post(f"/v1/signal-research/samples/{sample.pk}/fetch").status_code, 200)
        self.assertEqual(self.client.get("/v1/signal-research/rules").data["data"]["trusted_sample_count"], 1)
        self.assertEqual(self.client.get("/v1/signal-research/strategies/preview").data["data"]["packet"]["trusted_count"], 1)
        self.assertEqual(self.client.post("/v1/signal-research/strategies/generate", {}, format="json").status_code, 200)
        generate.assert_called_once()

    @patch("signal_research.views.timezone.now")
    def test_ready_feature_without_capture_metadata_is_not_research_evidence(self, clock):
        clock.return_value = self.now
        sample = self.sample(self.now - timedelta(minutes=1))
        sample.features, sample.trusted = {"ready": True}, True
        sample.save(update_fields=["features", "trusted"])
        response = self.client.get("/v1/signal-research/strategies/preview")
        self.assertEqual(response.data["data"]["packet"]["sample_count"], 0)

    @patch("signal_research.views.fetch_candles")
    @patch("signal_research.views.timezone.now")
    def test_existing_future_sample_cannot_fetch_or_build_research_data(self, clock, fetch):
        clock.return_value = self.now
        sample = self.sample(self.now + timedelta(hours=1))
        fetch.return_value = self.candles(closed_at=self.now + timedelta(hours=1))
        response = self.client.post(f"/v1/signal-research/samples/{sample.pk}/fetch")
        self.assertEqual(response.status_code, 400)
        fetch.assert_not_called()
        sample.refresh_from_db()
        self.assertIsNone(sample.fetched_at)

    @patch("signal_research.views.fetch_candles")
    @patch("signal_research.views.timezone.now")
    def test_no_closed_candle_returns_error_instead_of_using_last_open_bar(self, clock, fetch):
        clock.return_value = self.now
        sample = self.sample()
        fetch.return_value = self.candles(closed_at=self.now + timedelta(minutes=1), count=1)
        response = self.client.post(f"/v1/signal-research/samples/{sample.pk}/fetch")
        self.assertEqual(response.status_code, 400)
        sample.refresh_from_db()
        self.assertEqual(sample.candles, [])
        self.assertEqual(sample.features, {})
        self.assertIsNone(sample.fetched_at)

    @patch("signal_research.views.fetch_candles")
    @patch("signal_research.views.timezone.now")
    def test_fetch_persists_only_bars_closed_by_sample_and_current_time(self, clock, fetch):
        clock.return_value = self.now
        signal_time = self.now - timedelta(minutes=1)
        sample = self.sample(signal_time)
        fetch.return_value = self.candles(closed_at=self.now + timedelta(minutes=1), count=182)
        response = self.client.post(f"/v1/signal-research/samples/{sample.pk}/fetch")
        self.assertEqual(response.status_code, 200)
        sample.refresh_from_db()
        self.assertEqual(len(sample.candles), 180)
        self.assertTrue(sample.features["ready"])
        self.assertTrue(all(bar["close_time"] <= int(signal_time.timestamp() * 1000) for bar in sample.candles))

    def test_publication_between_draft_read_and_edit_cannot_rewrite_published_version(self):
        original_definition = validate_definition({"flip_window": 8})
        strategy = ResearchStrategy.objects.create(user=self.user, name="Immutable", definition=original_definition)

        def publish_while_edit_is_preparing(value):
            response = self.client.post(f"/v1/signal-research/strategies/{strategy.pk}/publish")
            self.assertEqual(response.status_code, 200)
            return validate_definition(value)

        with patch("signal_research.views.validate_definition", side_effect=publish_while_edit_is_preparing):
            response = self.client.patch(f"/v1/signal-research/strategies/{strategy.pk}", {
                "name": "Rewritten", "definition": {"flip_window": 12},
            }, format="json")
        self.assertEqual(response.status_code, 400)
        strategy.refresh_from_db()
        self.assertEqual(strategy.status, ResearchStrategy.STATUS_PUBLISHED)
        self.assertEqual(strategy.name, "Immutable")
        self.assertEqual(strategy.definition, original_definition)
        self.assertIsNotNone(strategy.published_at)

    def test_completed_edit_is_in_publication_and_repeat_publish_keeps_timestamp(self):
        strategy = ResearchStrategy.objects.create(user=self.user, name="Draft")
        response = self.client.patch(f"/v1/signal-research/strategies/{strategy.pk}", {
            "definition": {"flip_window": 12},
        }, format="json")
        self.assertEqual(response.status_code, 200)
        published = self.client.post(f"/v1/signal-research/strategies/{strategy.pk}/publish")
        again = self.client.post(f"/v1/signal-research/strategies/{strategy.pk}/publish")
        self.assertEqual(published.data["data"]["definition"]["flip_window"], 12)
        self.assertEqual(published.data["data"]["published_at"], again.data["data"]["published_at"])
        response = self.client.patch(f"/v1/signal-research/strategies/{strategy.pk}", {"name": "Cannot change"}, format="json")
        self.assertEqual(response.status_code, 400)
