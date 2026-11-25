from django.conf import settings
from django.db import models


class WebSettings(models.Model):
    """Versioned per-user preferences used by the Web terminal.

    Trading state remains owned by the existing trading and market_stream apps;
    this model only replaces the source Flask service's UI preference store.
    """

    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="web_settings")
    settings = models.JSONField(default=dict)
    version = models.PositiveBigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "web_settings"

    def __str__(self):
        return f"web settings for {self.user_id}"
