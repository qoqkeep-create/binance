from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("users", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="stop_loss_amount",
            field=models.DecimalField(decimal_places=2, default=120, max_digits=20),
        ),
        migrations.AddField(
            model_name="user",
            name="pending_stop_loss_amount",
            field=models.DecimalField(blank=True, decimal_places=2, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="user",
            name="pending_stop_loss_from",
            field=models.DecimalField(blank=True, decimal_places=2, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="user",
            name="pending_stop_loss_effective_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
