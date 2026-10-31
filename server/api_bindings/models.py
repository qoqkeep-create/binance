from django.conf import settings
from django.db import models
from common.trading_mode import TradingMode


class ApiBinding(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="api_bindings")
    trading_mode = models.CharField(max_length=16, choices=TradingMode.choices, default=TradingMode.ORDINARY, db_default="ordinary")
    api_key = models.TextField()
    api_key_fingerprint = models.CharField(
        max_length=64,
        blank=True,
        null=True,
        default=None,
        unique=True,
    )
    secret_key = models.TextField()
    passphrase = models.TextField()
    binance_uid = models.CharField(max_length=64, blank=True, default="", db_index=True)
    binance_label = models.CharField(max_length=100, blank=True, default="")
    alias = models.CharField(max_length=50)
    status = models.SmallIntegerField(default=1)  # 0 invalid, 1 valid
    consecutive_auth_failures = models.PositiveSmallIntegerField(default=0)
    last_auth_failure_at = models.DateTimeField(null=True, blank=True)
    status_reason = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "api_binding"
        constraints = [models.UniqueConstraint(fields=["user", "trading_mode"], name="binding_user_mode_uniq")]

    def __str__(self):
        return f"{self.user_id}:{self.alias}"
