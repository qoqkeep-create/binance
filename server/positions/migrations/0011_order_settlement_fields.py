from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0010_rename_exchange_fields_to_binance"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="close_binance_order_id",
            field=models.CharField(blank=True, default="", max_length=255),
        ),
        migrations.AddField(
            model_name="order",
            name="realized_fee",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="realized_funding_fee",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="realized_pnl",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="settled_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="settlement_error",
            field=models.CharField(blank=True, default="", max_length=500),
        ),
        migrations.AddField(
            model_name="order",
            name="settlement_status",
            field=models.SmallIntegerField(
                choices=[(0, "待结算"), (1, "已结算"), (2, "结算失败")],
                default=0,
            ),
        ),
    ]
