from django.conf import settings
from django.db import models


class TradingExperience(models.Model):
    """A journal entry kept separate from executable trading plans."""

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="trading_experiences",
    )
    title = models.CharField(max_length=120)
    body = models.TextField(max_length=20000)
    # Images are uploaded by the web client (OSS in production) and stored as
    # URLs here. Keeping the list on this model avoids coupling experience
    # content to the order/position tables.
    images = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "trading_experience"
        ordering = ["-created_at", "-id"]
        indexes = [models.Index(fields=["user", "created_at"], name="trading_exp_user_id_0f4c9e_idx")]

    def __str__(self):
        return self.title
