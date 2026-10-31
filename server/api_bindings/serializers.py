from rest_framework import serializers


class ApiBindSerializer(serializers.Serializer):
    api_key = serializers.CharField(max_length=512)
    secret_key = serializers.CharField(max_length=512)
    passphrase = serializers.CharField(required=False, allow_blank=True, default="", max_length=512)
    alias = serializers.CharField(max_length=20)

    default_error_messages = {
        "alias_blank": "API备注不能为空",
    }

    def validate_alias(self, value):
        value = (value or "").strip()
        if not value:
            self.fail("alias_blank")
        return value
