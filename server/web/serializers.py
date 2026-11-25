from rest_framework import serializers

from web.validation import validate_patch


class SettingsPatchSerializer(serializers.Serializer):
    patch = serializers.JSONField()
    baseVersion = serializers.IntegerField(min_value=0)

    def validate_patch(self, value):
        return validate_patch(value)
