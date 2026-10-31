from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0009_order_estimated_total_fee"),
    ]

    operations = [
        migrations.RenameField(
            model_name="order",
            old_name="okx_order_id",
            new_name="binance_order_id",
        ),
        migrations.RenameField(
            model_name="order",
            old_name="okx_stop_order_id",
            new_name="binance_stop_order_id",
        ),
        migrations.RenameField(
            model_name="limitorder",
            old_name="okx_order_id",
            new_name="binance_order_id",
        ),
        migrations.RenameField(
            model_name="limitorder",
            old_name="okx_stop_order_id",
            new_name="binance_stop_order_id",
        ),
    ]
