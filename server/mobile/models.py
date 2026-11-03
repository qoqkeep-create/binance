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


class PushDevice(models.Model):
    installation_id = models.UUIDField(unique=True)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    token = models.CharField(max_length=256)
    environment = models.CharField(max_length=16)
    bundle_id = models.CharField(max_length=128)
    active = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['token', 'environment', 'bundle_id'], name='mobile_push_device_token')]


class NotificationEvent(models.Model):
    event_key = models.CharField(max_length=191, unique=True)
    payload = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)


class NotificationDelivery(models.Model):
    event = models.ForeignKey(NotificationEvent, on_delete=models.CASCADE)
    device = models.ForeignKey(PushDevice, null=True, on_delete=models.CASCADE)
    user_id_snapshot = models.BigIntegerField(null=True)
    target = models.CharField(max_length=80)
    status = models.CharField(max_length=16, default='pending', db_index=True)
    attempts = models.PositiveSmallIntegerField(default=0)
    lease_until = models.DateTimeField(null=True)
    retry_at = models.DateTimeField(null=True)
    last_error = models.CharField(max_length=80, default='')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['event', 'target'], name='mobile_notification_target')]


class LiveActivityRegistration(models.Model):
    """One owner-scoped ActivityKit update token, separate from alert devices."""
    installation_id = models.UUIDField(unique=True)
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    activity_id = models.CharField(max_length=128)
    push_token = models.CharField(max_length=512)
    environment = models.CharField(max_length=16)
    bundle_id = models.CharField(max_length=128)
    trading_mode = models.CharField(max_length=16)
    binding_id_snapshot = models.BigIntegerField()
    binding_fingerprint = models.CharField(max_length=64)
    binding_created_at = models.DateTimeField()
    activity_started_at = models.DateTimeField()
    token_updated_at = models.DateTimeField()
    expires_at = models.DateTimeField()
    frequent_updates = models.BooleanField(default=False)
    active = models.BooleanField(default=True)
    end_requested = models.BooleanField(default=False)
    next_update_at = models.DateTimeField(db_index=True)
    lease_until = models.DateTimeField(null=True)
    fence = models.PositiveBigIntegerField(default=0)
    last_timestamp = models.BigIntegerField(default=0)
    consecutive_failures = models.PositiveSmallIntegerField(default=0)
    last_error = models.CharField(max_length=80, default='')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['push_token', 'environment', 'bundle_id'],
            name='mobile_live_activity_token')]
