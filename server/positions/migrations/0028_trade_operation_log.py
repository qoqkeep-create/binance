import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("positions", "0027_external_position_protection")]

    operations = [
        migrations.CreateModel(
            name="TradeOperationLog",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("event_key", models.CharField(blank=True, max_length=64, null=True, unique=True)),
                ("actor", models.CharField(choices=[("system", "系统"), ("user", "用户")], max_length=16)),
                ("action", models.CharField(max_length=64)),
                ("status", models.CharField(choices=[("success", "成功"), ("pending", "待确认"), ("failed", "失败"), ("info", "记录")], max_length=16)),
                ("message", models.CharField(max_length=500)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("order", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="operation_logs", to="positions.order")),
            ],
            options={
                "db_table": "trade_operation_log",
                "ordering": ["-created_at", "-id"],
                "indexes": [models.Index(fields=["order", "-created_at", "-id"], name="trade_op_order_time_idx")],
            },
        ),
    ]
