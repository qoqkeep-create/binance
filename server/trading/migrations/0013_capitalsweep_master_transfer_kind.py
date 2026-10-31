from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("trading", "0012_tradingviewmessage_event_id_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="capitalsweep",
            name="master_transfer_kind",
            field=models.CharField(blank=True, default="", max_length=16),
        ),
    ]
