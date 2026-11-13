from rest_framework import serializers

from common.images import validate_image_urls
from experiences.models import TradingExperience


class TradingExperienceSerializer(serializers.ModelSerializer):
    class Meta:
        model = TradingExperience
        fields = ("id", "title", "body", "images", "created_at", "updated_at")
        read_only_fields = ("id", "created_at", "updated_at")

    def validate_title(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("标题不能为空")
        return value

    def validate_body(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("正文不能为空")
        return value

    def validate_images(self, value):
        try:
            return validate_image_urls(value)
        except ValueError as exc:
            raise serializers.ValidationError(str(exc))
