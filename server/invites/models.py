from django.conf import settings
from django.db import models


class InviteCode(models.Model):
    code = models.CharField(max_length=10, unique=True)
    status = models.SmallIntegerField(default=0)  # 0 unused, 1 used
    used_by = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="used_invite_codes",
    )
    used_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "invite_code"

    def __str__(self):
        return self.code
