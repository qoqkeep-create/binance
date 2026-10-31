from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("trading", "0007_capitalsweep_wallet_stages"),
    ]

    operations = [
        migrations.AddField(
            model_name="capitalsweep",
            name="master_destination_address",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="master_destination_network",
            field=models.CharField(blank=True, default="", max_length=32),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="master_withdraw_order_id",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
    ]
