from django.db import models


class MarketAnalysisSignal(models.Model):
    """One saved result per completed candle; intentionally a compact audit table."""

    symbol = models.CharField(max_length=32)
    interval = models.CharField(max_length=8)
    candle_close_time = models.DateTimeField(db_index=True)
    direction = models.CharField(max_length=12, default="neutral")
    opportunity_type = models.CharField(max_length=80)
    score = models.PositiveSmallIntegerField()
    final_action = models.CharField(max_length=32)
    analysis = models.JSONField(default=dict)
    ai_explanation = models.JSONField(default=dict, blank=True)
    ai_error = models.TextField(blank=True, default="")
    alert_sent = models.BooleanField(default=False)
    alert_error = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "market_analysis_signal"
        ordering = ["-candle_close_time", "-id"]
        constraints = [models.UniqueConstraint(fields=["symbol", "interval", "candle_close_time"], name="unique_market_analysis_candle")]
        indexes = [models.Index(fields=["symbol", "interval", "-candle_close_time"])]
