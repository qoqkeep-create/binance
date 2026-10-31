from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("trading", "0006_capitalsweep")]

    operations = [
        migrations.AddField(
            model_name="capitalsweep",
            name="futures_amount",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=24),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_amount",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=24),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="spot_amount",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=24),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_tran_id",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_attempted_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AlterField(
            model_name="capitalsweep",
            name="status",
            field=models.CharField(
                choices=[
                    ("futures_pending", "合约转现货待确认"),
                    ("funding_pending", "资金转现货待确认"),
                    ("spot_pending", "现货转主账户待确认"),
                    ("completed", "归集完成"),
                    ("failed", "归集失败"),
                ],
                default="futures_pending",
                max_length=24,
            ),
        ),
    ]
