from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("positions", "0024_externaltradesignaldelivery_lease_expires_at_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="stop_loss_order_created_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
