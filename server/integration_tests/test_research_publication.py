import os
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework.test import APIRequestFactory, force_authenticate

from signal_research.ai import validate_definition
from signal_research.models import ResearchStrategy
from signal_research.views import StrategyDetailView, StrategyPublishView
from users.models import User


@unittest.skipUnless(os.getenv("RUN_INTEGRATION_TESTS") == "1", "requires isolated MySQL")
class ResearchPublicationMySQLTests(TransactionTestCase):
    def test_published_definition_survives_an_edit_started_on_another_connection(self):
        self.assertEqual(connection.vendor, "mysql", "requires isolated MySQL")
        user = User.objects.create_user(email="research-race@example.invalid", password="test-only-password")
        original = validate_definition({"flip_window": 8})
        strategy = ResearchStrategy.objects.create(user=user, name="Publication race", definition=original)
        edit_preparing, published = threading.Event(), threading.Event()

        def hold_edit(value):
            edit_preparing.set()
            if not published.wait(timeout=10):
                raise TimeoutError("publication did not finish")
            return validate_definition(value)

        def edit():
            close_old_connections()
            try:
                request = APIRequestFactory().patch("/", {"definition": {"flip_window": 12}}, format="json")
                force_authenticate(request, user=user)
                return StrategyDetailView.as_view()(request, strategy_id=strategy.pk).status_code
            finally:
                close_old_connections()

        def publish():
            close_old_connections()
            try:
                if not edit_preparing.wait(timeout=10):
                    raise TimeoutError("edit did not start")
                request = APIRequestFactory().post("/")
                force_authenticate(request, user=user)
                return StrategyPublishView.as_view()(request, strategy_id=strategy.pk).status_code
            finally:
                published.set()
                close_old_connections()

        with patch("signal_research.views.validate_definition", side_effect=hold_edit), ThreadPoolExecutor(max_workers=2) as executor:
            editor = executor.submit(edit)
            publisher = executor.submit(publish)
            self.assertEqual(publisher.result(timeout=15), 200)
            self.assertEqual(editor.result(timeout=15), 400)
        strategy.refresh_from_db()
        self.assertEqual(strategy.status, ResearchStrategy.STATUS_PUBLISHED)
        self.assertEqual(strategy.definition, original)
        self.assertIsNotNone(strategy.published_at)
