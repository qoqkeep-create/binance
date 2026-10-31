from django.db import migrations, models
from django.db.models import Count


DUPLICATE_API_KEY_REASON = "检测到同一 Binance API Key 重复绑定，请解绑后使用唯一 API Key 重新绑定"


def empty_fingerprints_to_null(apps, schema_editor):
    api_binding = apps.get_model("api_bindings", "ApiBinding")
    api_binding.objects.filter(api_key_fingerprint="").update(api_key_fingerprint=None)


def null_fingerprints_to_empty(apps, schema_editor):
    api_binding = apps.get_model("api_bindings", "ApiBinding")
    api_binding.objects.filter(api_key_fingerprint__isnull=True).update(api_key_fingerprint="")


def disable_duplicate_fingerprints(apps, schema_editor):
    api_binding = apps.get_model("api_bindings", "ApiBinding")
    duplicates = (
        api_binding.objects.exclude(api_key_fingerprint__isnull=True)
        .exclude(api_key_fingerprint="")
        .values("api_key_fingerprint")
        .annotate(total=Count("id"))
        .filter(total__gt=1)
    )
    for duplicate in duplicates.iterator():
        rows = api_binding.objects.filter(
            api_key_fingerprint=duplicate["api_key_fingerprint"]
        ).order_by("created_at", "id")
        keeper_id = rows.values_list("id", flat=True).first()
        rows.exclude(id=keeper_id).update(
            api_key_fingerprint=None,
            status=0,
            status_reason=DUPLICATE_API_KEY_REASON,
        )


class Migration(migrations.Migration):
    dependencies = [
        ("api_bindings", "0006_apibinding_health_state"),
    ]

    operations = [
        migrations.AlterField(
            model_name="apibinding",
            name="api_key_fingerprint",
            field=models.CharField(
                blank=True,
                db_index=True,
                default=None,
                max_length=64,
                null=True,
            ),
        ),
        migrations.RunPython(empty_fingerprints_to_null, null_fingerprints_to_empty),
        migrations.RunPython(disable_duplicate_fingerprints, migrations.RunPython.noop),
        migrations.AlterField(
            model_name="apibinding",
            name="api_key_fingerprint",
            field=models.CharField(
                blank=True,
                default=None,
                max_length=64,
                null=True,
                unique=True,
            ),
        ),
    ]
