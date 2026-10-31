from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0018_order_entry_fee_fields"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="manual_take_profit_algo_id",
            field=models.CharField(blank=True, default="", max_length=255),
        ),
        migrations.AddField(
            model_name="order",
            name="manual_take_profit_price",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="manual_take_profit_order_type",
            field=models.CharField(blank=True, default="", max_length=16),
        ),
    ]
