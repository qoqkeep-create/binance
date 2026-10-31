from django.db import models


class LeadTradingSettings(models.Model):
    user = models.OneToOneField("users.User", on_delete=models.CASCADE, related_name="lead_trading_settings")
    stop_loss_amount = models.DecimalField(max_digits=20, decimal_places=2, default=0)

    class Meta:
        db_table = "lead_trading_settings"


class TransferHistoryRecord(models.Model):
    user = models.ForeignKey(
        "users.User",
        on_delete=models.CASCADE,
        related_name="transfer_history_records",
    )
    api_key_fingerprint = models.CharField(max_length=64, db_index=True)
    account_type = models.CharField(max_length=16)
    record_id = models.CharField(max_length=96)
    direction = models.CharField(max_length=16)
    amount = models.DecimalField(max_digits=36, decimal_places=18)
    asset = models.CharField(max_length=16, default="USDT")
    occurred_at = models.DateTimeField(db_index=True)
    route = models.CharField(max_length=128)
    channel = models.CharField(max_length=128)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "transfer_history_record"
        constraints = [
            models.UniqueConstraint(
                fields=["user", "api_key_fingerprint", "record_id"],
                name="acct_th_user_fp_record_uniq",
            )
        ]
        indexes = [
            models.Index(
                fields=["user", "api_key_fingerprint", "-occurred_at"],
                name="acct_th_user_fp_time_idx",
            )
        ]


class TransferHistorySyncState(models.Model):
    user = models.ForeignKey(
        "users.User",
        on_delete=models.CASCADE,
        related_name="transfer_history_sync_states",
    )
    api_key_fingerprint = models.CharField(max_length=64, db_index=True)
    account_type = models.CharField(max_length=16, blank=True, default="")
    source_version = models.PositiveSmallIntegerField(default=0, db_default=0)
    synced_through = models.DateTimeField(null=True, blank=True)
    last_synced_at = models.DateTimeField(null=True, blank=True)
    last_error = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "transfer_history_sync_state"
        constraints = [
            models.UniqueConstraint(
                fields=["user", "api_key_fingerprint"],
                name="acct_th_state_user_fp_uniq",
            )
        ]
