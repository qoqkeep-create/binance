from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0013_limitorder_api_key_fingerprint_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="exchange_size",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="has_manual_addition",
            field=models.BooleanField(default=False),
        ),
    ]
