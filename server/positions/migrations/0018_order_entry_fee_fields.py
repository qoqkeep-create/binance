from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0017_order_stop_protection_error_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="entry_realized_fee",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="entry_fee_asset",
            field=models.CharField(blank=True, default="", max_length=16),
        ),
        migrations.AddField(
            model_name="order",
            name="entry_fee_status",
            field=models.CharField(
                choices=[
                    ("pending", "待同步"),
                    ("confirmed", "已确认"),
                    ("estimated", "估算"),
                    ("failed", "同步失败"),
                ],
                db_index=True,
                default="pending",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="order",
            name="entry_fee_synced_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="entry_fee_error",
            field=models.CharField(blank=True, default="", max_length=500),
        ),
    ]
