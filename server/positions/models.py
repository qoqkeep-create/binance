from django.conf import settings
from django.db import models
from common.trading_mode import TradingMode


class Order(models.Model):
    ORIGIN_WEB = "web"
    ORIGIN_EXTERNAL = "exchange_external"
    position_origin = models.CharField(
        max_length=24,
        choices=[(ORIGIN_WEB, "Web 开仓"), (ORIGIN_EXTERNAL, "手动仓")],
        default=ORIGIN_WEB, db_default=ORIGIN_WEB, db_index=True,
    )
    # Only live external positions occupy a slot; closed rows release it to NULL.
    external_active_key = models.CharField(max_length=64, null=True, blank=True, unique=True, default=None)
    external_stop_request = models.JSONField(default=dict, db_default={}, blank=True)
    external_close_request = models.JSONField(default=dict, db_default={}, blank=True)
    trading_mode = models.CharField(max_length=16, choices=TradingMode.choices, default=TradingMode.ORDINARY, db_default="ordinary", db_index=True)
    STOP_PROTECTION_COMPLETE = "complete"
    STOP_PROTECTION_PENDING = "pending"
    STOP_PROTECTION_ALERTED = "alerted"
    STOP_PROTECTION_EMERGENCY = "emergency_close"
    STRATEGY_STATUS_UNBOUND = 0
    STRATEGY_STATUS_RUNNING = 1
    STRATEGY_STATUS_CANCELLED = 2
    SETTLEMENT_STATUS_PENDING = 0
    SETTLEMENT_STATUS_SETTLED = 1
    SETTLEMENT_STATUS_FAILED = 2
    SETTLEMENT_STATUS_ESTIMATED = 3
    ENTRY_FEE_STATUS_PENDING = "pending"
    ENTRY_FEE_STATUS_CONFIRMED = "confirmed"
    ENTRY_FEE_STATUS_ESTIMATED = "estimated"
    ENTRY_FEE_STATUS_FAILED = "failed"

    STRATEGY_STATUS_CHOICES = [
        (STRATEGY_STATUS_UNBOUND, "未绑定"),
        (STRATEGY_STATUS_RUNNING, "运行中"),
        (STRATEGY_STATUS_CANCELLED, "已取消"),
    ]
    SETTLEMENT_STATUS_CHOICES = [
        (SETTLEMENT_STATUS_PENDING, "待结算"),
        (SETTLEMENT_STATUS_SETTLED, "已结算"),
        (SETTLEMENT_STATUS_FAILED, "结算失败"),
        (SETTLEMENT_STATUS_ESTIMATED, "估算结算"),
    ]
    ENTRY_FEE_STATUS_CHOICES = [
        (ENTRY_FEE_STATUS_PENDING, "待同步"),
        (ENTRY_FEE_STATUS_CONFIRMED, "已确认"),
        (ENTRY_FEE_STATUS_ESTIMATED, "估算"),
        (ENTRY_FEE_STATUS_FAILED, "同步失败"),
    ]
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="orders")
    api_key_fingerprint = models.CharField(max_length=64, blank=True, null=True, default=None, db_index=True)
    binance_order_id = models.CharField(max_length=255, null=True, blank=True)
    binance_stop_order_id = models.CharField(max_length=255, blank=True, default="")
    # 当前主止损使用触发市价单；保留旧字段名以兼容历史记录。
    binance_stop_market_order_id = models.CharField(max_length=255, blank=True, default="")
    stop_protection_status = models.CharField(max_length=24, default=STOP_PROTECTION_COMPLETE)
    stop_protection_error = models.CharField(max_length=500, blank=True, default="")
    stop_protection_first_failed_at = models.DateTimeField(null=True, blank=True)
    stop_protection_retry_count = models.PositiveIntegerField(default=0)
    stop_protection_last_retry_at = models.DateTimeField(null=True, blank=True)
    stop_protection_alerted_at = models.DateTimeField(null=True, blank=True)
    stop_loss_order_created_at = models.DateTimeField(null=True, blank=True)
    symbol = models.CharField(max_length=50)
    side = models.SmallIntegerField()  # 0 long, 1 short
    open_price = models.DecimalField(max_digits=20, decimal_places=8)
    initial_stop_price = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    stop_loss_price = models.DecimalField(max_digits=20, decimal_places=8)
    stop_loss_amount = models.DecimalField(max_digits=20, decimal_places=2)
    size = models.DecimalField(max_digits=20, decimal_places=8)
    exchange_size = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    has_manual_addition = models.BooleanField(default=False)
    leverage = models.IntegerField()
    status = models.SmallIntegerField(default=0)  # 0 opened, 1 closed
    created_at = models.DateTimeField(auto_now_add=True)
    closed_at = models.DateTimeField(null=True, blank=True)
    # T021: 新增字段
    close_price = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    position_amount = models.DecimalField(max_digits=20, decimal_places=2, null=True, blank=True)
    estimated_total_fee = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    pnl = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    pnl_ratio = models.DecimalField(max_digits=10, decimal_places=4, null=True, blank=True)
    close_binance_order_id = models.CharField(max_length=255, blank=True, default="")
    realized_pnl = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    realized_fee = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    realized_funding_fee = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    entry_realized_fee = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    entry_fee_asset = models.CharField(max_length=16, blank=True, default="")
    entry_fee_status = models.CharField(
        max_length=16,
        default=ENTRY_FEE_STATUS_PENDING,
        choices=ENTRY_FEE_STATUS_CHOICES,
        db_index=True,
    )
    entry_fee_synced_at = models.DateTimeField(null=True, blank=True)
    entry_fee_error = models.CharField(max_length=500, blank=True, default="")
    settlement_status = models.SmallIntegerField(
        default=SETTLEMENT_STATUS_PENDING,
        choices=SETTLEMENT_STATUS_CHOICES,
    )
    settled_at = models.DateTimeField(null=True, blank=True)
    settlement_error = models.CharField(max_length=500, blank=True, default="")
    settlement_retry_count = models.PositiveIntegerField(default=0)
    settlement_next_retry_at = models.DateTimeField(null=True, blank=True, db_index=True)
    # RISKON 策略字段
    strategy_snapshot_id = models.BigIntegerField(null=True, blank=True)
    strategy_status = models.SmallIntegerField(
        default=STRATEGY_STATUS_UNBOUND,
        choices=STRATEGY_STATUS_CHOICES,
    )
    strategy_tp_algo_ids = models.JSONField(default=list, blank=True)
    manual_take_profit_algo_id = models.CharField(max_length=255, blank=True, default="")
    manual_take_profit_price = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    manual_take_profit_order_type = models.CharField(max_length=16, blank=True, default="")
    current_stop_price = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)
    last_extreme_price = models.DecimalField(max_digits=20, decimal_places=8, null=True, blank=True)

    class Meta:
        db_table = "order"
        ordering = ["-created_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["api_key_fingerprint", "symbol", "binance_order_id"],
                name="uniq_order_exchange_identity",
            ),
        ]

    def __str__(self):
        return f"{self.symbol}:{self.binance_order_id}"


class LimitOrder(models.Model):
    """限价委托单表"""
    trading_mode = models.CharField(max_length=16, choices=TradingMode.choices, default=TradingMode.ORDINARY, db_default="ordinary", db_index=True)
    STATUS_PENDING = 0      # 待成交
    STATUS_FILLED = 1       # 已成交
    STATUS_CANCELLED = 2    # 已撤销
    STATUS_EXPIRED = 3      # 已过期

    STATUS_CHOICES = [
        (STATUS_PENDING, "待成交"),
        (STATUS_FILLED, "已成交"),
        (STATUS_CANCELLED, "已撤销"),
        (STATUS_EXPIRED, "已过期"),
    ]

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="limit_orders")
    api_key_fingerprint = models.CharField(max_length=64, blank=True, null=True, default=None, db_index=True)
    binance_order_id = models.CharField(max_length=255, db_index=True)
    binance_client_order_id = models.CharField(max_length=64, blank=True, default="", db_index=True)
    binance_stop_order_id = models.CharField(max_length=255, blank=True, default="")
    binance_stop_market_order_id = models.CharField(max_length=255, blank=True, default="")
    symbol = models.CharField(max_length=50, db_index=True)
    side = models.SmallIntegerField()  # 0 long, 1 short
    limit_price = models.DecimalField(max_digits=20, decimal_places=8)
    stop_loss_price = models.DecimalField(max_digits=20, decimal_places=8)
    stop_loss_amount = models.DecimalField(max_digits=20, decimal_places=2)
    size = models.DecimalField(max_digits=20, decimal_places=8)
    filled_size = models.DecimalField(max_digits=20, decimal_places=8, default=0)
    leverage = models.IntegerField()
    strategy_id = models.CharField(max_length=64, blank=True, default="")
    strategy_name = models.CharField(max_length=50, blank=True, default="")
    strategy_config = models.JSONField(null=True, blank=True)
    status = models.SmallIntegerField(default=STATUS_PENDING, choices=STATUS_CHOICES, db_index=True)
    # 成交后关联的持仓订单
    order = models.ForeignKey(Order, on_delete=models.SET_NULL, null=True, blank=True, related_name="limit_order_source")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "limit_order"
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["user", "status"]),
            models.Index(fields=["user", "symbol", "status"]),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["api_key_fingerprint", "symbol", "binance_order_id"],
                name="uniq_limit_order_exchange_identity",
            ),
        ]

    def __str__(self):
        return f"{self.symbol}:{self.binance_order_id}"

    @property
    def can_chase(self) -> bool:
        """是否可追单：仅完全未成交的待成交订单可追单"""
        return self.status == self.STATUS_PENDING and self.filled_size == 0


class OrderStrategySnapshot(models.Model):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="strategy_snapshots")
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="order_strategy_snapshots")
    strategy_id = models.CharField(max_length=64)
    strategy_name = models.CharField(max_length=50)
    strategy_config = models.JSONField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "order_strategy_snapshot"
        ordering = ["-created_at"]


class OrderStrategyLog(models.Model):
    RESULT_SUCCESS = "成功"
    RESULT_FAILED = "失败"
    RESULT_SKIPPED = "跳过"

    RESULT_CHOICES = [
        (RESULT_SUCCESS, RESULT_SUCCESS),
        (RESULT_FAILED, RESULT_FAILED),
        (RESULT_SKIPPED, RESULT_SKIPPED),
    ]

    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="strategy_logs")
    snapshot = models.ForeignKey(OrderStrategySnapshot, on_delete=models.CASCADE, related_name="logs")
    behavior_desc = models.CharField(max_length=200)
    trigger_r = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True)
    result = models.CharField(max_length=20, choices=RESULT_CHOICES, default=RESULT_SUCCESS)
    error = models.CharField(max_length=500, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "order_strategy_log"
        ordering = ["-created_at"]


class OrderStrategyTechnicalEvent(models.Model):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="strategy_technical_events")
    snapshot = models.ForeignKey(
        OrderStrategySnapshot,
        on_delete=models.CASCADE,
        related_name="technical_events",
    )
    behavior_desc = models.CharField(max_length=200)
    error_signature = models.CharField(max_length=255)
    error_sample = models.CharField(max_length=500, null=True, blank=True)
    occurrence_count = models.PositiveIntegerField(default=1)
    first_occurred_at = models.DateTimeField(auto_now_add=True)
    last_occurred_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "order_strategy_technical_event"
        ordering = ["-last_occurred_at"]
        constraints = [
            models.UniqueConstraint(
                fields=["order", "snapshot", "behavior_desc", "error_signature"],
                name="uniq_strategy_tech_event_signature",
            ),
        ]


class TradeNotificationEvent(models.Model):
    TYPE_OPEN = "open"
    TYPE_STOP_LOSS = "stop_loss"
    TYPE_STRATEGY_TAKE_PROFIT = "strategy_take_profit"
    TYPE_MANUAL_TAKE_PROFIT = "manual_take_profit"
    TYPE_REDUCTION = "reduction"

    TYPE_CHOICES = [
        (TYPE_OPEN, "开单成功"),
        (TYPE_STOP_LOSS, "止损成交"),
        (TYPE_STRATEGY_TAKE_PROFIT, "策略挂单止盈成交"),
        (TYPE_MANUAL_TAKE_PROFIT, "手动止盈成交"),
        (TYPE_REDUCTION, "减仓成功"),
    ]

    STATUS_PENDING = "pending"
    STATUS_SENDING = "sending"
    STATUS_SENT = "sent"
    STATUS_FAILED = "failed"
    STATUS_EXHAUSTED = "exhausted"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待发送"),
        (STATUS_SENDING, "发送中"),
        (STATUS_SENT, "已发送"),
        (STATUS_FAILED, "发送失败"),
        (STATUS_EXHAUSTED, "重试耗尽"),
    ]

    event_key = models.CharField(max_length=191, unique=True)
    order = models.ForeignKey(
        Order,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="notification_events",
    )
    event_type = models.CharField(max_length=32, choices=TYPE_CHOICES)
    title = models.CharField(max_length=100)
    content = models.TextField()
    context = models.JSONField(default=dict, blank=True)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING, db_index=True)
    attempt_count = models.PositiveIntegerField(default=0)
    next_retry_at = models.DateTimeField(null=True, blank=True, db_index=True)
    lease_expires_at = models.DateTimeField(null=True, blank=True, db_index=True)
    last_error = models.CharField(max_length=500, blank=True, default="")
    sent_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "trade_notification_event"
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["status", "next_retry_at"], name="trade_notify_status_retry_idx"),
            models.Index(fields=["order", "event_type"], name="trade_notify_order_type_idx"),
        ]


class ExternalTradeSignalDelivery(models.Model):
    STATUS_PENDING = "pending"
    STATUS_SENDING = "sending"
    STATUS_SENT = "sent"
    STATUS_FAILED = "failed"
    STATUS_EXHAUSTED = "exhausted"
    STATUS_CHOICES = [
        (STATUS_PENDING, "待发送"),
        (STATUS_SENDING, "发送中"),
        (STATUS_SENT, "已发送"),
        (STATUS_FAILED, "发送失败"),
        (STATUS_EXHAUSTED, "重试耗尽"),
    ]

    event = models.OneToOneField(
        TradeNotificationEvent,
        on_delete=models.CASCADE,
        related_name="external_signal_delivery",
    )
    payload = models.JSONField(default=dict, blank=True)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_PENDING, db_index=True)
    attempt_count = models.PositiveIntegerField(default=0)
    next_retry_at = models.DateTimeField(null=True, blank=True, db_index=True)
    lease_expires_at = models.DateTimeField(null=True, blank=True, db_index=True)
    last_error = models.CharField(max_length=500, blank=True, default="")
    sent_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "external_trade_signal_delivery"
        ordering = ["created_at", "id"]
        indexes = [
            models.Index(fields=["status", "next_retry_at"], name="ext_trade_status_retry_idx"),
        ]


class TradeOperationLog(models.Model):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name="operation_logs")
    event_key = models.CharField(max_length=64, unique=True, null=True, blank=True)
    actor = models.CharField(max_length=16, choices=[("system", "系统"), ("user", "用户")])
    action = models.CharField(max_length=64)
    status = models.CharField(max_length=16, choices=[
        ("success", "成功"), ("pending", "待确认"), ("failed", "失败"), ("info", "记录"),
    ])
    message = models.CharField(max_length=500)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "trade_operation_log"
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["order", "-created_at", "-id"], name="trade_op_order_time_idx"),
        ]


class PositionProfitWatch(models.Model):
    """Frozen R denominator; independent of stop/strategy mutations."""
    order = models.OneToOneField(Order, on_delete=models.CASCADE, related_name="profit_watch")
    risk_amount = models.DecimalField(max_digits=26, decimal_places=8)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "position_profit_watch"


class PositionProfitAlert(models.Model):
    """One automatic send attempt per order and R threshold, across restarts."""
    watch = models.ForeignKey(PositionProfitWatch, on_delete=models.CASCADE, related_name="alerts")
    threshold = models.DecimalField(max_digits=3, decimal_places=1)
    status = models.CharField(max_length=16, default="pending", db_index=True)
    payload = models.JSONField(default=dict)
    observed_pnl = models.DecimalField(max_digits=30, decimal_places=8)
    created_at = models.DateTimeField(auto_now_add=True)
    attempted_at = models.DateTimeField(null=True, blank=True, db_index=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    last_error = models.CharField(max_length=80, blank=True, default="")

    class Meta:
        db_table = "position_profit_alert"
        constraints = [models.UniqueConstraint(fields=["watch", "threshold"], name="uniq_position_profit_threshold")]
