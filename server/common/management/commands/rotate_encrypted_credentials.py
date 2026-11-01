from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from api_bindings.models import ApiBinding
from common.utils import aes_decrypt_with_metadata, aes_encrypt


class Command(BaseCommand):
    help = "Rewrite active API binding credentials with the current AES_SECRET_KEY."

    def add_arguments(self, parser):
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument(
            "--dry-run",
            action="store_true",
            help="Count values requiring rewrite without changing the database.",
        )
        mode.add_argument(
            "--verify-only",
            action="store_true",
            help="Fail unless every active API binding credential is already readable by the current key.",
        )

    def handle(self, *args, **options):
        current_key = str(getattr(settings, "AES_SECRET_KEY", "") or "")
        signing_key = str(getattr(settings, "SECRET_KEY", "") or "")
        if len(current_key) < 32:
            raise CommandError("AES_SECRET_KEY must contain at least 32 characters")
        if current_key == signing_key:
            raise CommandError("AES_SECRET_KEY must be independent from SECRET_KEY")

        dry_run = bool(options["dry_run"])
        verify_only = bool(options["verify_only"])
        counters = {
            "records": 0,
            "fields": 0,
            "rewritable": 0,
            "rewritten": 0,
        }

        try:
            with transaction.atomic():
                self._process_api_bindings(counters, write=not dry_run and not verify_only)
        except Exception as exc:
            raise CommandError(
                f"encrypted credential migration failed ({type(exc).__name__}); no changes committed"
            ) from None

        if verify_only and counters["rewritable"]:
            raise CommandError(
                f"verification failed: {counters['rewritable']} encrypted fields still require the previous key"
            )

        self.stdout.write(
            " ".join(
                (
                    f"examined_records={counters['records']}",
                    f"encrypted_fields={counters['fields']}",
                    f"rewritable_fields={counters['rewritable']}",
                    f"rewritten_fields={counters['rewritten']}",
                )
            )
        )

    @staticmethod
    def _rewrite_value(encrypted: str, counters: dict[str, int], *, write: bool) -> str:
        if not encrypted:
            return encrypted
        counters["fields"] += 1
        plaintext, needs_rewrite = aes_decrypt_with_metadata(encrypted)
        if not needs_rewrite:
            return encrypted
        counters["rewritable"] += 1
        if not write:
            return encrypted
        rewritten = aes_encrypt(plaintext)
        _, still_needs_rewrite = aes_decrypt_with_metadata(rewritten)
        if still_needs_rewrite:
            raise ValueError("rewritten value did not use the current key")
        counters["rewritten"] += 1
        return rewritten

    def _process_api_bindings(self, counters: dict[str, int], *, write: bool) -> None:
        fields = ("api_key", "secret_key", "passphrase")
        queryset = ApiBinding.objects.select_for_update().only("id", *fields)
        for binding in queryset.iterator():
            counters["records"] += 1
            updates = {
                field: self._rewrite_value(str(getattr(binding, field) or ""), counters, write=write)
                for field in fields
            }
            if write and any(updates[field] != getattr(binding, field) for field in fields):
                updates["updated_at"] = timezone.now()
                ApiBinding.objects.filter(pk=binding.pk).update(**updates)
