from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("api_bindings", "0005_apibinding_api_key_fingerprint"),
    ]

    operations = [
        migrations.AddField(
            model_name="apibinding",
            name="consecutive_auth_failures",
            field=models.PositiveSmallIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="apibinding",
            name="last_auth_failure_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="apibinding",
            name="status_reason",
            field=models.CharField(blank=True, default="", max_length=200),
        ),
    ]
