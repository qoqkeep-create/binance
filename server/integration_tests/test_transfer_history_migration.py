import os
import unittest
from datetime import datetime, timezone

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase

from accounts.models import TransferHistorySyncState
from users.models import User


@unittest.skipUnless(
    os.getenv("RUN_INTEGRATION_TESTS") == "1",
    "Requires isolated MySQL with RUN_INTEGRATION_TESTS=1",
)
class TransferHistoryMigrationTests(TransactionTestCase):
    def test_preserves_old_cursor_and_accepts_old_orm_after_upgrade(self):
        self.assertEqual(connection.vendor, "mysql", "Requires isolated MySQL")
        user = User.objects.create_user(email="migration-test@example.com", password="test-only")
        previous = datetime(2026, 9, 29, tzinfo=timezone.utc)
        old_target = [("accounts", "0002_lead_settings")]
        new_target = [("accounts", "0003_transfer_history_source_version")]
        executor = MigrationExecutor(connection)
        executor.migrate(old_target)
        try:
            old_model = executor.loader.project_state(old_target).apps.get_model(
                "accounts", "TransferHistorySyncState"
            )
            legacy = old_model.objects.create(
                user_id=user.pk,
                api_key_fingerprint="migration-existing-key",
                account_type="sub",
                synced_through=previous,
                last_synced_at=previous,
            )
            MigrationExecutor(connection).migrate(new_target)

            upgraded = TransferHistorySyncState.objects.get(pk=legacy.pk)
            self.assertEqual(upgraded.source_version, 0)
            self.assertEqual(upgraded.synced_through, previous)
            self.assertEqual(upgraded.last_synced_at, previous)

            created_by_old_worker = old_model.objects.create(
                user_id=user.pk,
                api_key_fingerprint="migration-new-key",
                account_type="master",
            )
            current = TransferHistorySyncState.objects.get(pk=created_by_old_worker.pk)
            self.assertEqual(current.source_version, 0)
            created_by_old_worker.last_error = "test-only failure"
            created_by_old_worker.save(update_fields=["last_error"])
            current.refresh_from_db()
            self.assertEqual(current.last_error, "test-only failure")
            self.assertEqual(current.source_version, 0)
        finally:
            MigrationExecutor(connection).migrate(new_target)
