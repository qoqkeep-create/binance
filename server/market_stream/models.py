from django.conf import settings
from django.db import models


class MarketSymbol(models.Model):
    """Durable public contract directory, refreshed by the market collector."""
    symbol = models.CharField(max_length=32, primary_key=True)
    quote_asset = models.CharField(max_length=16)
    onboard_date = models.BigIntegerField(default=0)
    active = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)


class MarketCandle(models.Model):
    symbol = models.CharField(max_length=32)
    interval = models.CharField(max_length=4)
    open_time = models.BigIntegerField()
    close_time = models.BigIntegerField()
    open_price = models.DecimalField(max_digits=38, decimal_places=18)
    high_price = models.DecimalField(max_digits=38, decimal_places=18)
    low_price = models.DecimalField(max_digits=38, decimal_places=18)
    close_price = models.DecimalField(max_digits=38, decimal_places=18)
    volume = models.DecimalField(max_digits=38, decimal_places=18)
    quote_volume = models.DecimalField(max_digits=38, decimal_places=18)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["symbol", "interval", "open_time"], name="market_candle_identity")]
        indexes = [models.Index(fields=["symbol", "interval", "-open_time"], name="market_candle_recent")]


class MarketHistoryTask(models.Model):
    """Public market reads only; a lease survives collector restarts."""
    key = models.CharField(max_length=64, unique=True)
    symbol = models.CharField(max_length=32)
    interval = models.CharField(max_length=4)
    kind = models.CharField(max_length=32, default="history")
    before = models.BigIntegerField(default=0)
    limit = models.PositiveSmallIntegerField(default=1500)
    priority = models.PositiveSmallIntegerField(default=10)
    due_at = models.FloatField(default=0)
    lease_until = models.FloatField(default=0)
    completed_at = models.FloatField(default=0)
    attempts = models.PositiveSmallIntegerField(default=0)
    exhausted = models.BooleanField(default=False)

    class Meta:
        indexes = [models.Index(fields=["due_at", "lease_until"], name="market_repair_due")]


class ChartLoadReport(models.Model):
    """Client diagnostics, independent of trading and candle persistence."""
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    trace_id = models.UUIDField()
    app_build = models.CharField(max_length=10, db_index=True)
    symbol = models.CharField(max_length=32)
    interval = models.CharField(max_length=4)
    outcome = models.CharField(max_length=16)
    duration_ms = models.FloatField()
    received_at = models.DateTimeField(auto_now_add=True, db_index=True)
    payload = models.JSONField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=["user", "trace_id"], name="chart_report_owner_trace")]
