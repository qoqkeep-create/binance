from django.contrib.auth.base_user import BaseUserManager
from django.contrib.auth.models import AbstractBaseUser, PermissionsMixin
from django.db import models
from common.utils import normalize_email


class UserManager(BaseUserManager):
    def create_user(self, email, password=None, **extra_fields):
        if not email:
            raise ValueError("email is required")
        email = normalize_email(email)
        user = self.model(email=email, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password=None, **extra_fields):
        extra_fields.setdefault("is_staff", True)
        extra_fields.setdefault("is_superuser", True)
        return self.create_user(email, password, **extra_fields)


class User(AbstractBaseUser, PermissionsMixin):
    email = models.EmailField(unique=True, max_length=255)
    is_active = models.BooleanField(default=True)
    is_staff = models.BooleanField(default=False)
    # 应用内管理员标志：可访问“设置”（开放注册开关等），与 Django is_staff 无关
    is_admin = models.BooleanField(default=False)
    stop_loss_amount = models.DecimalField(max_digits=20, decimal_places=2, default=120)
    pending_stop_loss_amount = models.DecimalField(max_digits=20, decimal_places=2, null=True, blank=True)
    pending_stop_loss_from = models.DecimalField(max_digits=20, decimal_places=2, null=True, blank=True)
    pending_stop_loss_effective_at = models.DateTimeField(null=True, blank=True)
    # 资金归集目标：主账户归集时使用目标主账户 Spot 充值地址和网络，子账户不使用。
    capital_collect_account = models.CharField(max_length=128, blank=True, default="")
    capital_collect_network = models.CharField(max_length=32, blank=True, default="")
    preflight_completed_at = models.DateTimeField(null=True, blank=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = UserManager()

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = []

    class Meta:
        db_table = "user"

    def save(self, *args, **kwargs):
        self.email = normalize_email(self.email)
        super().save(*args, **kwargs)

    def __str__(self):
        return self.email


class SystemSetting(models.Model):
    """键值系统设置（如开放注册开关），避免为单个开关加 User 字段"""

    OPEN_REGISTRATION_KEY = "open_registration"

    key = models.CharField(max_length=64, unique=True)
    value = models.TextField(blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "system_setting"

    @classmethod
    def is_open_registration(cls) -> bool:
        row = cls.objects.filter(key=cls.OPEN_REGISTRATION_KEY).first()
        return bool(row and row.value == "1")

    @classmethod
    def set_open_registration(cls, enabled: bool) -> None:
        cls.objects.update_or_create(
            key=cls.OPEN_REGISTRATION_KEY,
            defaults={"value": "1" if enabled else "0"},
        )
