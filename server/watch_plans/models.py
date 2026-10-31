from django.conf import settings
from django.db import models
from django.utils import timezone


class WatchPlan(models.Model):
    PLAN_TYPE_LEFT = 0
    PLAN_TYPE_RIGHT = 1

    STATUS_DEFAULT = 0
    STATUS_DONE = 1
    STATUS_SKIPPED = 2

    RESULT_NONE = 0
    RESULT_STOP_LOSS = 1
    RESULT_TAKE_PROFIT = 2

    TIMEFRAME_15M = "15m"
    TIMEFRAME_1H = "1h"
    TIMEFRAME_4H = "4h"
    TIMEFRAME_1D = "1d"

    DIRECTION_LONG = 0
    DIRECTION_SHORT = 1

    TIMEFRAME_CHOICES = [
        (TIMEFRAME_15M, "15分钟"),
        (TIMEFRAME_1H, "1小时"),
        (TIMEFRAME_4H, "4小时"),
        (TIMEFRAME_1D, "1天"),
    ]

    STATUS_CHOICES = [
        (STATUS_DEFAULT, "未标记"),
        (STATUS_DONE, "已做单"),
        (STATUS_SKIPPED, "未做单"),
    ]

    RESULT_CHOICES = [
        (RESULT_NONE, "无"),
        (RESULT_STOP_LOSS, "止损"),
        (RESULT_TAKE_PROFIT, "止盈"),
    ]

    PLAN_TYPE_CHOICES = [
        (PLAN_TYPE_LEFT, "计划左侧单"),
        (PLAN_TYPE_RIGHT, "确认右侧单"),
    ]

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="watch_plans")
    symbol = models.CharField(max_length=50)
    plan_date = models.DateField(default=timezone.localdate, db_index=True)
    plan_type = models.SmallIntegerField(default=PLAN_TYPE_LEFT, choices=PLAN_TYPE_CHOICES)
    timeframe = models.CharField(max_length=8, choices=TIMEFRAME_CHOICES)
    direction = models.SmallIntegerField(default=DIRECTION_LONG)
    content = models.TextField(blank=True, default="")
    take_profit_expectation = models.TextField(blank=True, default="")
    review_content = models.TextField(blank=True, default="")
    status = models.SmallIntegerField(default=STATUS_DEFAULT, choices=STATUS_CHOICES)
    result = models.SmallIntegerField(default=RESULT_NONE, choices=RESULT_CHOICES)
    result_amount = models.DecimalField(max_digits=20, decimal_places=2, null=True, blank=True)
    score = models.SmallIntegerField(null=True, blank=True)
    score_payload = models.JSONField(default=dict, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "watch_plan"
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["user", "created_at"]),
            models.Index(fields=["user", "status"]),
        ]
