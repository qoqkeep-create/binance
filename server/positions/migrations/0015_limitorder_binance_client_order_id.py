from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0014_order_exchange_size_order_has_manual_addition"),
    ]

    operations = [
        migrations.AddField(
            model_name="limitorder",
            name="binance_client_order_id",
            field=models.CharField(blank=True, db_index=True, default="", max_length=64),
        ),
    ]
