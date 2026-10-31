from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0011_order_settlement_fields"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="settlement_next_retry_at",
            field=models.DateTimeField(blank=True, db_index=True, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="settlement_retry_count",
            field=models.PositiveIntegerField(default=0),
        ),
    ]
