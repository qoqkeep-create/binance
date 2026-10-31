from django.db import migrations, models


def separate_external_and_tradingview_sources(apps, schema_editor):
    message_model = apps.get_model("trading", "TradingViewMessage")
    for message in message_model.objects.all().iterator(chunk_size=500):
        normalized = message.normalized_payload if isinstance(message.normalized_payload, dict) else {}
        normalized = dict(normalized)
        raw_source = str(normalized.get("source") or "").strip().lower()
        message_format = str(normalized.get("format") or "").strip().lower()

        if raw_source == "internal" or message.source == "internal":
            source = "internal"
        elif message_format == "external_signal_v1":
            source = "external"
        elif raw_source in {"tv", "tradingview"} or message_format == "tradingview_signal_v1":
            source = "tradingview"
        elif raw_source == "external":
            source = "external"
        else:
            source = "tradingview"

        normalized["source"] = source
        message_model.objects.filter(pk=message.pk).update(
            source=source,
            normalized_payload=normalized,
        )


class Migration(migrations.Migration):
    dependencies = [("trading", "0009_tradingviewmessage_source")]

    operations = [
        migrations.AlterField(
            model_name="tradingviewmessage",
            name="source",
            field=models.CharField(
                choices=[
                    ("external", "外部"),
                    ("internal", "内部"),
                    ("tradingview", "TradingView"),
                ],
                db_index=True,
                default="external",
                max_length=16,
            ),
        ),
        migrations.RunPython(
            separate_external_and_tradingview_sources,
            migrations.RunPython.noop,
        ),
    ]
