from io import StringIO

from django.core.management import call_command
from django.test import TestCase, override_settings

from api_bindings.models import ApiBinding
from common.utils import aes_decrypt_with_metadata, aes_encrypt
from users.models import User


CURRENT_KEY = "current-database-encryption-key-with-more-than-32-characters"
PREVIOUS_KEY = "previous-production-key"
SIGNING_KEY = "independent-django-signing-key"


@override_settings(
    SECRET_KEY=SIGNING_KEY,
    AES_SECRET_KEY=CURRENT_KEY,
    AES_PREVIOUS_SECRET_KEY=PREVIOUS_KEY,
)
class RotateEncryptedCredentialsCommandTests(TestCase):
    def _create_previous_key_records(self):
        with override_settings(AES_SECRET_KEY=PREVIOUS_KEY, AES_PREVIOUS_SECRET_KEY=""):
            user = User.objects.create_user(email="rotate@example.com", password="test-password")
            binding = ApiBinding.objects.create(
                user=user,
                api_key=aes_encrypt("api-key-value"),
                secret_key=aes_encrypt("secret-key-value"),
                passphrase=aes_encrypt("passphrase-value"),
                alias="rotation-test",
                status=1,
            )
        return binding

    def test_command_rewrites_all_supported_fields_and_verifies_current_key(self):
        binding = self._create_previous_key_records()
        output = StringIO()

        call_command("rotate_encrypted_credentials", stdout=output)

        self.assertIn("examined_records=1", output.getvalue())
        self.assertIn("rewritten_fields=3", output.getvalue())
        binding.refresh_from_db()
        with override_settings(AES_PREVIOUS_SECRET_KEY=""):
            values = (
                binding.api_key,
                binding.secret_key,
                binding.passphrase,
            )
            self.assertTrue(all(not aes_decrypt_with_metadata(value)[1] for value in values))
            verify_output = StringIO()
            call_command("rotate_encrypted_credentials", verify_only=True, stdout=verify_output)
        self.assertIn("rewritable_fields=0", verify_output.getvalue())

    def test_dry_run_does_not_change_ciphertext(self):
        binding = self._create_previous_key_records()
        original_values = (binding.api_key, binding.secret_key, binding.passphrase)

        output = StringIO()
        call_command("rotate_encrypted_credentials", dry_run=True, stdout=output)

        binding.refresh_from_db()
        self.assertEqual(
            (binding.api_key, binding.secret_key, binding.passphrase),
            original_values,
        )
        self.assertIn("rewritable_fields=3", output.getvalue())
        self.assertIn("rewritten_fields=0", output.getvalue())
