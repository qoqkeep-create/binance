from importlib import import_module
from unittest.mock import patch

from django.apps import apps
from django.db import IntegrityError, transaction
from django.test import override_settings
from rest_framework.test import APITestCase

from trading.models import TradingViewMessage
from users.models import User


class SignalListTests(APITestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="signals@example.com", password="123456")
        self.client.force_authenticate(self.user)

    def _message(self, source=None, **extra):
        source = source or TradingViewMessage.SOURCE_EXTERNAL
        payload = {
            "symbol": extra.pop("symbol", "BTCUSDT"),
            "signal": extra.pop("signal", "BUY"),
            "source": source,
            **extra,
        }
        return TradingViewMessage.objects.create(
            raw_payload=payload,
            normalized_payload=payload,
            source=source,
        )

    def test_filters_external_signals_by_database_source(self):
        external = self._message("external", provider="partner")
        self._message("internal", symbol="XRPUSDT")
        self._message("tradingview", symbol="ETHUSDT")

        response = self.client.get("/v1/trade/tradingview/signals?source=external")

        self.assertEqual(response.status_code, 200)
        rows = response.data["data"]
        self.assertEqual([row["id"] for row in rows], [external.id])
        self.assertTrue(all(row["source"] == "external" for row in rows))
        self.assertEqual(next(row for row in rows if row["id"] == external.id)["provider"], "partner")

    def test_filters_internal_signals(self):
        internal = self._message("internal", score=86)
        self._message("external", symbol="ETHUSDT")

        response = self.client.get("/v1/trade/tradingview/signals?source=internal")

        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.data["data"]], [internal.id])
        self.assertEqual(response.data["data"][0]["source"], "internal")

    def test_rejects_unknown_source_filter(self):
        response = self.client.get("/v1/trade/tradingview/signals?source=partner")

        self.assertEqual(response.status_code, 400)

    def test_unknown_external_symbol_is_returned_as_stable_fallback(self):
        message = self._message("external", symbol="Unknown", signal="INFO", comment="待适配")

        response = self.client.get("/v1/trade/tradingview/signals?source=external")

        self.assertEqual(response.status_code, 200)
        row = next(item for item in response.data["data"] if item["id"] == message.id)
        self.assertEqual(row["symbol"], "Unknown")


@override_settings(EXTERNAL_SIGNAL_INGEST_ENABLED=True)
class ExternalSignalIngestTests(APITestCase):
    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_internal_message_token_is_accepted_only_from_header(self):
        body = {
            "token": "test-ingest-token",
            "raw_payload": {"event_id": "body-token"},
            "normalized_payload": {
                "source": "external",
                "event_id": "body-token",
                "symbol": "BTCUSDT",
                "signal": "BUY",
            },
        }

        body_response = self.client.post(
            "/v1/trade/tradingview/messages/ingest",
            body,
            format="json",
        )
        query_response = self.client.post(
            "/v1/trade/tradingview/messages/ingest?token=test-ingest-token",
            {**body, "token": ""},
            format="json",
        )

        self.assertEqual(body_response.status_code, 403)
        self.assertEqual(query_response.status_code, 403)
        self.assertFalse(TradingViewMessage.objects.exists())

    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_event_id_is_idempotent(self):
        body = {
            "raw_payload": {"event_id": "evt-001"},
            "normalized_payload": {
                "source": "external",
                "event_id": "evt-001",
                "symbol": "BTCUSDT",
                "signal": "BUY",
            },
        }
        self.client.credentials(HTTP_X_TV_MESSAGE_TOKEN="test-ingest-token")

        first = self.client.post("/v1/trade/tradingview/messages/ingest", body, format="json")
        second = self.client.post("/v1/trade/tradingview/messages/ingest", body, format="json")

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertFalse(first.data["data"]["duplicate"])
        self.assertTrue(second.data["data"]["duplicate"])
        self.assertEqual(first.data["data"]["id"], second.data["data"]["id"])
        self.assertEqual(TradingViewMessage.objects.count(), 1)
        message = TradingViewMessage.objects.get()
        self.assertEqual(message.source, TradingViewMessage.SOURCE_EXTERNAL)
        self.assertEqual(message.event_id, "evt-001")
        self.assertEqual(message.normalized_payload["source"], TradingViewMessage.SOURCE_EXTERNAL)

        with self.assertRaises(IntegrityError), transaction.atomic():
            TradingViewMessage.objects.create(
                raw_payload={},
                normalized_payload={},
                source=TradingViewMessage.SOURCE_EXTERNAL,
                event_id="evt-001",
            )

    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_legacy_tv_source_is_stored_as_tradingview(self):
        body = {
            "raw_payload": {"event_id": "legacy-tv-001"},
            "normalized_payload": {
                "source": "tv",
                "event_id": "legacy-tv-001",
                "symbol": "ETHUSDT",
                "signal": "SELL",
            },
        }
        self.client.credentials(HTTP_X_TV_MESSAGE_TOKEN="test-ingest-token")

        response = self.client.post("/v1/trade/tradingview/messages/ingest", body, format="json")

        self.assertEqual(response.status_code, 200)
        message = TradingViewMessage.objects.get()
        self.assertEqual(message.source, TradingViewMessage.SOURCE_TRADINGVIEW)
        self.assertEqual(message.normalized_payload["source"], TradingViewMessage.SOURCE_TRADINGVIEW)

    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_internal_message_rejects_oversized_payload(self):
        self.client.credentials(HTTP_X_TV_MESSAGE_TOKEN="test-ingest-token")

        response = self.client.post(
            "/v1/trade/tradingview/messages/ingest",
            {
                "raw_payload": {"text": "x" * (64 * 1024)},
                "normalized_payload": {"source": "external"},
            },
            format="json",
        )

        self.assertEqual(response.status_code, 400)
        self.assertFalse(TradingViewMessage.objects.exists())


@override_settings(EXTERNAL_SIGNAL_INGEST_ENABLED=False)
class PausedExternalSignalIngestTests(APITestCase):
    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_paused_external_sources_are_rejected_without_touching_history_or_push(self):
        historical = TradingViewMessage.objects.create(
            source="external", event_id="existing-external", raw_payload={}, normalized_payload={}
        )
        self.client.credentials(HTTP_X_TV_MESSAGE_TOKEN="test-ingest-token")
        for source in ["external", "tradingview", "tv", "", "unrecognized"]:
            with self.subTest(source=source):
                response = self.client.post(
                    "/v1/trade/tradingview/messages/ingest",
                    {"raw_payload": {"source": source}, "normalized_payload": {
                        "source": source, "event_id": f"paused-{source}",
                        "symbol": "BTCUSDT", "signal": "BUY",
                    }}, format="json",
                )
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.data["message"], "外部信号接收已暂停")
        self.assertEqual(list(TradingViewMessage.objects.values_list("id", flat=True)), [historical.id])
        from mobile.models import NotificationDelivery, NotificationEvent
        self.assertFalse(NotificationEvent.objects.exists())
        self.assertFalse(NotificationDelivery.objects.exists())

    @patch("trading.views.TV_MESSAGE_API_TOKEN", "test-ingest-token")
    def test_http_caller_cannot_bypass_pause_by_claiming_internal_source(self):
        self.client.credentials(HTTP_X_TV_MESSAGE_TOKEN="test-ingest-token")
        response = self.client.post(
            "/v1/trade/tradingview/messages/ingest",
            {"raw_payload": {"source": "internal"}, "normalized_payload": {
                "source": "internal", "event_id": "internal-still-accepted",
                "symbol": "BTCUSDT", "signal": "BUY",
            }}, format="json",
        )
        self.assertEqual(response.status_code, 503)
        self.assertFalse(TradingViewMessage.objects.exists())


class SignalSourceMigrationTests(APITestCase):
    def test_correction_migration_separates_external_and_tradingview(self):
        internal = TradingViewMessage.objects.create(
            raw_payload={},
            normalized_payload={"source": "internal", "format": "tradingview_signal_v1"},
            source=TradingViewMessage.SOURCE_INTERNAL,
        )
        legacy_tv = TradingViewMessage.objects.create(
            raw_payload={},
            normalized_payload={"source": "external", "format": "tradingview_signal_v1"},
        )
        external = TradingViewMessage.objects.create(
            raw_payload={},
            normalized_payload={"source": "external", "format": "external_signal_v1"},
        )

        migration = import_module("trading.migrations.0010_separate_external_and_tradingview_sources")
        migration.separate_external_and_tradingview_sources(apps, None)

        internal.refresh_from_db()
        legacy_tv.refresh_from_db()
        external.refresh_from_db()
        self.assertEqual(internal.source, TradingViewMessage.SOURCE_INTERNAL)
        self.assertEqual(internal.normalized_payload["source"], TradingViewMessage.SOURCE_INTERNAL)
        self.assertEqual(legacy_tv.source, TradingViewMessage.SOURCE_TRADINGVIEW)
        self.assertEqual(legacy_tv.normalized_payload["source"], TradingViewMessage.SOURCE_TRADINGVIEW)
        self.assertEqual(external.source, TradingViewMessage.SOURCE_EXTERNAL)
        self.assertEqual(external.normalized_payload["source"], TradingViewMessage.SOURCE_EXTERNAL)
