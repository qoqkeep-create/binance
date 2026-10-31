from django.contrib.auth import authenticate, password_validation
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from rest_framework import serializers

from common.utils import normalize_email
from users.models import SystemSetting, User


class RegisterSerializer(serializers.Serializer):
    email = serializers.EmailField()
    password = serializers.CharField(min_length=8, max_length=128)
    confirm_password = serializers.CharField(min_length=8, max_length=128)
    agreed = serializers.BooleanField()

    default_error_messages = {
        "email_exists": "该邮箱已注册，请直接登录",
        "registration_closed": "暂未开放注册，请联系管理员",
        "password_mismatch": "两次输入的密码不一致，请重新输入",
        "password_short": "密码长度不能少于8位，请重新设置",
        "password_weak": "密码过于简单，请使用至少8位且不易猜测的密码",
        "agreement": "请先阅读并同意用户协议和隐私政策",
    }

    def validate(self, attrs):
        attrs["email"] = normalize_email(attrs["email"])
        if not attrs["agreed"]:
            self.fail("agreement")
        if len(attrs["password"]) < 8:
            self.fail("password_short")
        if attrs["password"] != attrs["confirm_password"]:
            self.fail("password_mismatch")
        candidate_user = User(email=attrs["email"])
        try:
            password_validation.validate_password(attrs["password"], user=candidate_user)
        except DjangoValidationError:
            self.fail("password_weak")
        # 开放注册开关：关闭时拒绝一切新注册（由管理员账号在设置中控制）
        if not SystemSetting.is_open_registration():
            self.fail("registration_closed")
        if User.objects.filter(email=attrs["email"]).exists():
            self.fail("email_exists")
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        return User.objects.create_user(
            email=validated_data["email"],
            password=validated_data["password"],
        )


class LoginSerializer(serializers.Serializer):
    email = serializers.EmailField()
    password = serializers.CharField(max_length=128)
    agreed = serializers.BooleanField()

    default_error_messages = {
        "agreement": "请先阅读并同意用户协议和隐私政策",
        "invalid": "账号或密码错误",
    }

    def validate(self, attrs):
        if not attrs["agreed"]:
            self.fail("agreement")

        email = normalize_email(attrs["email"])
        user = authenticate(request=self.context.get("request"), username=email, password=attrs["password"])
        if not user:
            self.fail("invalid")

        attrs["user"] = user
        return attrs


class PasswordResetRequestSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=255)

    def validate_email(self, value):
        return normalize_email(value)


class PasswordResetConfirmSerializer(serializers.Serializer):
    uid = serializers.CharField(max_length=128)
    token = serializers.CharField(max_length=256)
    new_password = serializers.CharField(min_length=8, max_length=128)
    confirm_password = serializers.CharField(min_length=8, max_length=128)

    def validate(self, attrs):
        if attrs["new_password"] != attrs["confirm_password"]:
            raise serializers.ValidationError({"confirm_password": "两次输入的密码不一致，请重新输入"})
        return attrs
