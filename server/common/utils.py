import hashlib
import secrets
from base64 import b64decode, b64encode

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from django.conf import settings


_AES_GCM_PREFIX = "v2"
_AES_GCM_NONCE_BYTES = 12
_AES_GCM_AAD = b"tradetools:aes:v2"


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def mask_email(email: str) -> str:
    if "@" not in email:
        return email
    name, domain = email.split("@", 1)
    if len(name) <= 2:
        return f"{name[0]}***@{domain}"
    return f"{name[0]}***{name[-1]}@{domain}"


def mask_api_key(api_key: str) -> str:
    if len(api_key) <= 8:
        return "****"
    return f"{api_key[:4]}****{api_key[-4:]}"


def _derive_key(raw_key: str) -> bytes:
    return hashlib.sha256(raw_key.encode("utf-8")).digest()


def _primary_encryption_key() -> bytes:
    raw_key = str(
        getattr(settings, "AES_SECRET_KEY", "")
        or getattr(settings, "SECRET_KEY", "dev-secret-key")
    )
    return _derive_key(raw_key)


def _decryption_keys() -> tuple[bytes, ...]:
    values = (
        str(
            getattr(settings, "AES_SECRET_KEY", "")
            or getattr(settings, "SECRET_KEY", "dev-secret-key")
        ),
        str(getattr(settings, "AES_PREVIOUS_SECRET_KEY", "") or ""),
        str(getattr(settings, "SECRET_KEY", "dev-secret-key") or ""),
    )
    unique_values = tuple(dict.fromkeys(value for value in values if value))
    return tuple(_derive_key(value) for value in unique_values)


def aes_encrypt(plain_text: str) -> str:
    key = _primary_encryption_key()
    nonce = secrets.token_bytes(_AES_GCM_NONCE_BYTES)
    encrypted = AESGCM(key).encrypt(nonce, plain_text.encode("utf-8"), _AES_GCM_AAD)
    ciphertext, tag = encrypted[:-16], encrypted[-16:]
    return ":".join(
        (
            _AES_GCM_PREFIX,
            b64encode(nonce).decode("ascii"),
            b64encode(tag).decode("ascii"),
            b64encode(ciphertext).decode("ascii"),
        )
    )


def aes_decrypt_with_metadata(cipher_text: str) -> tuple[str, bool]:
    """Return plaintext and whether it should be rewritten with the primary key."""
    keys = _decryption_keys()
    if cipher_text.startswith(f"{_AES_GCM_PREFIX}:"):
        parts = cipher_text.split(":")
        if len(parts) != 4:
            raise ValueError("invalid encrypted value")
        try:
            nonce = b64decode(parts[1], validate=True)
            tag = b64decode(parts[2], validate=True)
            ciphertext = b64decode(parts[3], validate=True)
            if len(nonce) != _AES_GCM_NONCE_BYTES or len(tag) != 16:
                raise ValueError("invalid encrypted value")
        except (TypeError, ValueError) as exc:
            raise ValueError("encrypted value authentication failed") from exc
        for index, key in enumerate(keys):
            try:
                plaintext = AESGCM(key).decrypt(nonce, ciphertext + tag, _AES_GCM_AAD)
                return plaintext.decode("utf-8"), index > 0
            except (InvalidTag, TypeError, ValueError, UnicodeDecodeError):
                continue
        raise ValueError("encrypted value authentication failed")

    # Read-only compatibility for ciphertext written by the former fixed-IV CBC format.
    try:
        encrypted = b64decode(cipher_text, validate=True)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid legacy encrypted value") from exc
    for key in keys:
        try:
            decryptor = Cipher(algorithms.AES(key), modes.CBC(key[:16])).decryptor()
            padded_plaintext = decryptor.update(encrypted) + decryptor.finalize()
            unpadder = padding.PKCS7(algorithms.AES.block_size).unpadder()
            plaintext = unpadder.update(padded_plaintext) + unpadder.finalize()
            return plaintext.decode("utf-8"), True
        except (TypeError, ValueError, UnicodeDecodeError):
            continue
    raise ValueError("invalid legacy encrypted value")


def aes_decrypt(cipher_text: str) -> str:
    plaintext, _is_legacy = aes_decrypt_with_metadata(cipher_text)
    return plaintext
