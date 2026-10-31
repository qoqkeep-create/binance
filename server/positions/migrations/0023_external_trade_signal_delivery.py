from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0022_move_close_notification_context"),
    ]

    operations = [
        migrations.CreateModel(
            name="ExternalTradeSignalDelivery",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("payload", models.JSONField(blank=True, default=dict)),
                (
                    "status",
                    models.CharField(
                        choices=[("pending", "待发送"), ("sent", "已发送"), ("failed", "发送失败")],
                        db_index=True,
                        default="pending",
                        max_length=16,
                    ),
                ),
                ("attempt_count", models.PositiveIntegerField(default=0)),
                ("next_retry_at", models.DateTimeField(blank=True, db_index=True, null=True)),
                ("last_error", models.CharField(blank=True, default="", max_length=500)),
                ("sent_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "event",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="external_signal_delivery",
                        to="positions.tradenotificationevent",
                    ),
                ),
            ],
            options={
                "db_table": "external_trade_signal_delivery",
                "ordering": ["created_at", "id"],
            },
        ),
        migrations.AddIndex(
            model_name="externaltradesignaldelivery",
            index=models.Index(fields=["status", "next_retry_at"], name="ext_trade_status_retry_idx"),
        ),
    ]
