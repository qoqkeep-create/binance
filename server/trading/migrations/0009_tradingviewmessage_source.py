from django.db import migrations, models


def normalize_message_sources(apps, schema_editor):
    message_model = apps.get_model("trading", "TradingViewMessage")
    for message in message_model.objects.all().iterator(chunk_size=500):
        normalized = message.normalized_payload if isinstance(message.normalized_payload, dict) else {}
        normalized = dict(normalized)
        raw_source = str(normalized.get("source") or "").strip().lower()
        source = "internal" if raw_source == "internal" else "external"
        normalized["source"] = source
        message_model.objects.filter(pk=message.pk).update(
            source=source,
            normalized_payload=normalized,
        )


class Migration(migrations.Migration):
    dependencies = [("trading", "0008_capitalsweep_master_withdraw_fields")]

    operations = [
        migrations.AddField(
            model_name="tradingviewmessage",
            name="source",
            field=models.CharField(
                choices=[("external", "外部"), ("internal", "内部")],
                db_index=True,
                default="external",
                max_length=16,
            ),
        ),
        migrations.RunPython(normalize_message_sources, migrations.RunPython.noop),
    ]
