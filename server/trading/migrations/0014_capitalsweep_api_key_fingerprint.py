from django.db import migrations, models


def backfill_api_key_fingerprints(apps, schema_editor):
    CapitalSweep = apps.get_model("trading", "CapitalSweep")
    ApiBinding = apps.get_model("api_bindings", "ApiBinding")
    bindings = {
        user_id: (fingerprint, binding_created_at)
        for user_id, fingerprint, binding_created_at in ApiBinding.objects.exclude(
            api_key_fingerprint__isnull=True,
        ).exclude(
            api_key_fingerprint="",
        ).values_list("user_id", "api_key_fingerprint", "created_at")
    }
    for user_id, (fingerprint, binding_created_at) in bindings.items():
        CapitalSweep.objects.filter(
            user_id=user_id,
            created_at__gte=binding_created_at,
        ).update(
            api_key_fingerprint=fingerprint,
        )


class Migration(migrations.Migration):
    dependencies = [
        ("api_bindings", "0007_unique_api_key_fingerprint"),
        ("trading", "0013_capitalsweep_master_transfer_kind"),
    ]

    operations = [
        migrations.AddField(
            model_name="capitalsweep",
            name="api_key_fingerprint",
            field=models.CharField(
                blank=True,
                db_index=True,
                max_length=64,
                null=True,
            ),
        ),
        migrations.RunPython(
            backfill_api_key_fingerprints,
            migrations.RunPython.noop,
        ),
    ]
