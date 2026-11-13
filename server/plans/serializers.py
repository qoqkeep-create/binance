from rest_framework import serializers

from common.images import validate_image_urls
from plans.models import TradingPlan


class TradingPlanSerializer(serializers.ModelSerializer):
    class Meta:
        model = TradingPlan
        fields = (
            "id", "symbol", "direction", "timeframe", "entry", "stop", "target",
            "risk", "thesis", "status", "images", "created_at", "updated_at",
        )
        read_only_fields = ("id", "created_at", "updated_at")

    def validate_symbol(self, value):
        value = value.strip().upper()
        if not value:
            raise serializers.ValidationError("交易标的不能为空")
        return value

    def validate_thesis(self, value):
        return value.strip()

    def validate_images(self, value):
        try:
            return validate_image_urls(value)
        except ValueError as exc:
            raise serializers.ValidationError(str(exc))