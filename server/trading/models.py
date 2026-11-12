from django.conf import settings
from django.db import models


class Strategy(models.Model):
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="strategies")
    name = models.CharField(max_length=100)
    is_active = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "strategy"
        ordering = ["-updated_at", "-created_at"]
        indexes = [
            models.Index(fields=["user", "is_active"]),
        ]


class StrategyLevel(models.Model):
    STOP_LOSS_TYPE_NONE = "none"
    STOP_LOSS_TYPE_FIXED_RR = "fixedRR"
    STOP_LOSS_TYPE_ABSOLUTE_RR = "absoluteRR"

    STOP_LOSS_TYPE_CHOICES = [
        (STOP_LOSS_TYPE_NONE, STOP_LOSS_TYPE_NONE),
        (STOP_LOSS_TYPE_FIXED_RR, STOP_LOSS_TYPE_FIXED_RR),
        (STOP_LOSS_TYPE_ABSOLUTE_RR, STOP_LOSS_TYPE_ABSOLUTE_RR),
    ]

    strategy = models.ForeignKey(Strategy, on_delete=models.CASCADE, related_name="levels")
    sort_order = models.PositiveSmallIntegerField(default=1)
    profit_rr = models.DecimalField(max_digits=10, decimal_places=4)
    reduce_position = models.DecimalField(max_digits=8, decimal_places=2, default=0)
    stop_loss_type = models.CharField(max_length=20, choices=STOP_LOSS_TYPE_CHOICES, default=STOP_LOSS_TYPE_NONE)
    stop_loss_rr = models.DecimalField(max_digits=10, decimal_places=4, null=True, blank=True)
    stop_loss_absolute_rr = models.DecimalField(max_digits=10, decimal_places=4, null=True, blank=True)

    class Meta:
        db_table = "strategy_level"
        ordering = ["sort_order", "id"]
        indexes = [
            models.Index(fields=["strategy", "sort_order"]),
        ]


class TradingViewMessage(models.Model):
    SOURCE_EXTERNAL = "external"
    SOURCE_INTERNAL = "internal"
    SOURCE_TRADINGVIEW = "tradingview"
    SOURCE_CHOICES = [
        (SOURCE_EXTERNAL, "外部"),
        (SOURCE_INTERNAL, "内部"),
        (SOURCE_TRADINGVIEW, "TradingView"),
    ]

    STATUS_PENDING = "pending"
    STATUS_ACKED = "acked"

    STATUS_CHOICES = [
        (STATUS_PENDING, "待处理"),
        (STATUS_ACKED, "已处理"),
    ]

    raw_payload = models.JSONField(default=dict)
    normalized_payload = models.JSONField(default=dict)
    event_id = models.CharField(max_length=191, blank=True, null=True, default=None, db_index=True)
    source = models.CharField(
        max_length=16,
        choices=SOURCE_CHOICES,
        default=SOURCE_EXTERNAL,
        db_index=True,
    )
    downstream_wecom_ok = models.BooleanField(default=False)
    downstream_telegram_ok = models.BooleanField(default=False)
    downstream_error = models.TextField(blank=True, default="")
    qoderwork_status = models.CharField(max_length=20, choices=STATUS_CHOICES, default=STATUS_PENDING)
    received_at = models.DateTimeField(auto_now_add=True)
    acked_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "tradingview_message"
        ordering = ["-received_at", "-id"]
        indexes = [
            models.Index(fields=["qoderwork_status", "-received_at"], name="tradingview_qoderwo_34f017_idx"),
        ]
        constraints = [
            models.UniqueConstraint(fields=["source", "event_id"], name="uniq_signal_source_event_id"),
        ]


class TradeOpenRequest(models.Model):
    trading_mode = models.CharField(max_length=16, default="ordinary", db_default="ordinary", db_index=True)
    api_key_fingerprint = models.CharField(max_length=64, default="", db_default="", blank=True)
    STATUS_PENDING = "pending"
    STATUS_SUBMITTED = "submitted"
    STATUS_RECOVERED = "recovered"
    STATUS_FAILED = "failed"
    STATUS_COMPLETED = "completed"

    STATUS_CHOICES = [
        (STATUS_PENDING, "待提交"),
        (STATUS_SUBMITTED, "已提交"),
        (STATUS_RECOVERED, "已恢复"),
        (STATUS_FAILED, "失败"),
        (STATUS_COMPLETED, "已完成"),
    ]

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="trade_open_requests")
    symbol = models.CharField(max_length=50)
    client_request_id = models.CharField(max_length=64)
    client_order_id = models.CharField(max_length=64, unique=True)
    binance_order_id = models.CharField(max_length=255, blank=True, default="")
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING)
    request_payload = models.JSONField(default=dict, blank=True)
    error = models.CharField(max_length=500, blank=True, default="")
    order_id = models.BigIntegerField(null=True, blank=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "trade_open_request"
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["user", "symbol", "-created_at"]),
            models.Index(fields=["status", "-created_at"]),
        ]


class CapitalSweep(models.Model):
    STATUS_FUNDING_REFILL_PENDING = "funding_refill_pending"
    STATUS_SPOT_REFILL_PENDING = "spot_refill_pending"
    STATUS_FUTURES_PENDING = "futures_pending"
    STATUS_FUNDING_PENDING = "funding_pending"
    STATUS_SPOT_PENDING = "spot_pending"
    STATUS_COMPLETED = "completed"
    STATUS_FAILED = "failed"
    MASTER_TRANSFER_INTERNAL = "internal"
    MASTER_TRANSFER_ONCHAIN = "onchain"

    STATUS_CHOICES = [
        (STATUS_FUNDING_REFILL_PENDING, "资金转合约待确认"),
        (STATUS_SPOT_REFILL_PENDING, "现货转合约待确认"),
        (STATUS_FUTURES_PENDING, "合约转现货待确认"),
        (STATUS_FUNDING_PENDING, "资金转现货待确认"),
        (STATUS_SPOT_PENDING, "现货转主账户待确认"),
        (STATUS_COMPLETED, "归集完成"),
        (STATUS_FAILED, "归集失败"),
    ]

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="capital_sweeps")
    api_key_fingerprint = models.CharField(max_length=64, blank=True, null=True, db_index=True)
    operation = models.CharField(max_length=24, blank=True, default="", db_default="")
    request_id = models.UUIDField(null=True, blank=True, db_index=True)
    asset = models.CharField(max_length=16, default="USDT")
    amount = models.DecimalField(max_digits=24, decimal_places=8)
    target_balance = models.DecimalField(max_digits=24, decimal_places=8)
    futures_amount = models.DecimalField(max_digits=24, decimal_places=8, default=0)
    funding_amount = models.DecimalField(max_digits=24, decimal_places=8, default=0)
    spot_amount = models.DecimalField(max_digits=24, decimal_places=8, default=0)
    funding_refill_amount = models.DecimalField(max_digits=24, decimal_places=8, default=0)
    spot_refill_amount = models.DecimalField(max_digits=24, decimal_places=8, default=0)
    funding_refill_tran_id = models.CharField(max_length=128, blank=True, default="")
    spot_refill_tran_id = models.CharField(max_length=128, blank=True, default="")
    funding_refill_attempted_at = models.DateTimeField(null=True, blank=True)
    spot_refill_attempted_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=24, choices=STATUS_CHOICES, default=STATUS_FUTURES_PENDING)
    futures_tran_id = models.CharField(max_length=128, blank=True, default="")
    futures_attempted_at = models.DateTimeField(null=True, blank=True)
    funding_tran_id = models.CharField(max_length=128, blank=True, default="")
    funding_attempted_at = models.DateTimeField(null=True, blank=True)
    master_txn_id = models.CharField(max_length=128, blank=True, default="")
    master_attempted_at = models.DateTimeField(null=True, blank=True)
    master_withdraw_order_id = models.CharField(max_length=128, blank=True, default="")
    master_destination_address = models.CharField(max_length=128, blank=True, default="")
    master_destination_network = models.CharField(max_length=32, blank=True, default="")
    master_transfer_kind = models.CharField(max_length=16, blank=True, default="")
    active_slot = models.PositiveSmallIntegerField(null=True, blank=True, default=1, editable=False)
    error = models.CharField(max_length=500, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "capital_sweep"
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["user", "status", "-created_at"], name="capital_swe_user_id_538615_idx")]
        constraints = [
            models.UniqueConstraint(fields=["user", "active_slot"], name="capital_sweep_one_active_per_user"),
        ]

    def save(self, *args, **kwargs):
        self.active_slot = None if self.status in {self.STATUS_COMPLETED, self.STATUS_FAILED} else 1
        update_fields = kwargs.get("update_fields")
        if update_fields is not None and "active_slot" not in update_fields:
            kwargs["update_fields"] = [*update_fields, "active_slot"]
        super().save(*args, **kwargs)
