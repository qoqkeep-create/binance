from django.conf import settings
from django.db import models


class SignalSample(models.Model):
    DIRECTION_LONG = "long"
    DIRECTION_SHORT = "short"
    DIRECTION_NEUTRAL = "neutral"
    DIRECTION_CHOICES = [(DIRECTION_LONG, "做多"), (DIRECTION_SHORT, "做空"), (DIRECTION_NEUTRAL, "仅观察")]
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="signal_samples")
    symbol = models.CharField(max_length=32)
    timeframe = models.CharField(max_length=8)
    expected_direction = models.CharField(max_length=12, choices=DIRECTION_CHOICES, default=DIRECTION_NEUTRAL)
    signal_time = models.DateTimeField(db_index=True, help_text="The closed candle's close time")
    note = models.TextField(blank=True, default="")
    trusted = models.BooleanField(null=True, blank=True)
    candles = models.JSONField(default=list, blank=True)
    features = models.JSONField(default=dict, blank=True)
    fetched_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "signal_research_sample"
        ordering = ["-signal_time", "-id"]
        indexes = [models.Index(fields=["user", "signal_time"])]


class ResearchStrategy(models.Model):
    STATUS_DRAFT = "draft"
    STATUS_PUBLISHED = "published"
    STATUS_CHOICES = [(STATUS_DRAFT, "草案"), (STATUS_PUBLISHED, "已发布")]

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="research_strategies")
    name = models.CharField(max_length=120)
    version = models.PositiveIntegerField(default=1)
    status = models.CharField(max_length=16, choices=STATUS_CHOICES, default=STATUS_DRAFT)
    provider = models.CharField(max_length=64, blank=True, default="")
    model = models.CharField(max_length=128, blank=True, default="")
    research_packet = models.JSONField(default=dict, blank=True)
    definition = models.JSONField(default=dict, blank=True)
    natural_rules = models.JSONField(default=list, blank=True)
    code = models.TextField(blank=True, default="")
    rationale = models.TextField(blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)
    published_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "signal_research_strategy"
        ordering = ["-created_at", "-id"]
        constraints = [models.UniqueConstraint(fields=["user", "name", "version"], name="unique_research_strategy_version")]


class ResearchAiModel(models.Model):
    name = models.CharField(max_length=80)
    provider = models.CharField(max_length=64, default="openai_compatible")
    base_url = models.URLField(max_length=300)
    model = models.CharField(max_length=128)
    api_key_encrypted = models.TextField()
    is_active = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "signal_research_ai_model"
        ordering = ["-is_active", "-id"]


class ResearchAiModelSelection(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="research_ai_model_selection")
    model = models.ForeignKey(ResearchAiModel, on_delete=models.SET_NULL, null=True, blank=True)
