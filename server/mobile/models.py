import uuid
from django.conf import settings
from django.db import models


class TradingCommand(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    binding_id_snapshot = models.BigIntegerField()
    binding_fingerprint = models.CharField(max_length=64)
    binding_created_at = models.DateTimeField()
    trading_mode = models.CharField(max_length=16)
    idempotency_key = models.CharField(max_length=128)
    request_hash = models.CharField(max_length=64)
    action = models.CharField(max_length=32)
    payload = models.JSONField()
    status = models.CharField(max_length=16, default="PENDING", db_index=True)
    fence = models.BigIntegerField(default=0)
    result = models.JSONField(null=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "idempotency_key"], name="mobile_command_idempotency")]
        indexes = [models.Index(fields=["binding_id_snapshot", "status", "created_at"], name="mobile_command_pending")]


class AccountWorkerState(models.Model):
    binding_id_snapshot = models.BigIntegerField(unique=True)
    fence = models.BigIntegerField(default=0)


class AccountInbox(models.Model):
    event_key = models.CharField(max_length=64, unique=True)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    binding_id_snapshot = models.BigIntegerField()
    trading_mode = models.CharField(max_length=16)
    event_time = models.BigIntegerField()
    payload = models.JSONField()
    processed = models.BooleanField(default=False, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)


class AccountFact(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    binding_id_snapshot = models.BigIntegerField()
    trading_mode = models.CharField(max_length=16)
    kind = models.CharField(max_length=16)
    identity = models.CharField(max_length=100)
    event_time = models.BigIntegerField()
    payload = models.JSONField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=["binding_id_snapshot", "kind", "identity"], name="mobile_account_fact_identity")]


class AccountOutbox(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    trading_mode = models.CharField(max_length=16)
    channel = models.CharField(max_length=32)
    event_key = models.CharField(max_length=100)
    payload = models.JSONField()
    published_at = models.DateTimeField(null=True)
    created_at = models.DateTimeField(auto_now_add=True)
