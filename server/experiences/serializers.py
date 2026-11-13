from rest_framework import serializers

from experiences.models import TradingExperience


MAX_EXPERIENCE_IMAGES = 5


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
        if value is None:
            return []
        if not isinstance(value, list):
            raise serializers.ValidationError("图片必须是 URL 数组")
        if len(value) > MAX_EXPERIENCE_IMAGES:
            raise serializers.ValidationError("最多上传 5 张图片")
        cleaned = []
        for image in value:
            if not isinstance(image, str) or not image.strip():
                raise serializers.ValidationError("图片地址格式错误")
            image = image.strip()
            if not (image.startswith(("https://", "http://", "data:image/"))):
                raise serializers.ValidationError("图片地址必须是 HTTP(S) 或图片 Data URL")
            # Prevent accidental multi-megabyte JSON records when a browser
            # falls back to a pasted data URL before OSS is configured.
            if len(image) > 2_000_000:
                raise serializers.ValidationError("单张图片不能超过 2 MB")
            cleaned.append(image)
        return cleaned
