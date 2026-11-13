from django.conf import settings
from django.db import models


class TradingPlan(models.Model):
    """A journal-level trade plan owned by one user, never an executable order."""

    DIRECTION_CHOICES = [("long", "Long"), ("short", "Short")]
    TIMEFRAME_CHOICES = [("3m", "3m"), ("15m", "15m"), ("1h", "1h"), ("4h", "4h"), ("1d", "1d")]
    STATUS_CHOICES = [("undone", "Undone"), ("done", "Done")]

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="trading_plans",
    )
    symbol = models.CharField(max_length=20)
    direction = models.CharField(max_length=5, choices=DIRECTION_CHOICES, default="long")
    timeframe = models.CharField(max_length=4, choices=TIMEFRAME_CHOICES, default="1h")
    entry = models.DecimalField(max_digits=24, decimal_places=8)
    stop = models.DecimalField(max_digits=24, decimal_places=8)
    target = models.DecimalField(max_digits=24, decimal_places=8)
    risk = models.DecimalField(max_digits=24, decimal_places=8)
    thesis = models.TextField(max_length=4000, blank=True, default="")
    status = models.CharField(max_length=6, choices=STATUS_CHOICES, default="undone")
    images = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "trading_plan"
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["user", "created_at"], name="trading_plan_user_created_idx")]

    def __str__(self):
        return f"{self.symbol} {self.direction}"