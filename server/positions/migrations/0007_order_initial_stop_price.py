from django.db import migrations, models


def backfill_initial_stop_price(apps, schema_editor):
    Order = apps.get_model("positions", "Order")
    Order.objects.filter(initial_stop_price__isnull=True).update(initial_stop_price=models.F("stop_loss_price"))


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0006_order_strategy_tp_algo_ids"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="initial_stop_price",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.RunPython(backfill_initial_stop_price, migrations.RunPython.noop),
    ]
