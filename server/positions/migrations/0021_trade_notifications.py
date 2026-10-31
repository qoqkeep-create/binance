from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0020_order_stop_protection_alerted_at_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="order",
            name="close_reason",
            field=models.CharField(
                blank=True,
                choices=[
                    ("stop_loss", "止损成交"),
                    ("strategy_take_profit", "策略挂单止盈成交"),
                    ("manual_take_profit", "手动止盈成交"),
                    ("manual_close", "手动平仓成交"),
                    ("external_close", "交易所外部平仓"),
                ],
                default="",
                max_length=32,
            ),
        ),
        migrations.AddField(
            model_name="order",
            name="close_size",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.AddField(
            model_name="order",
            name="close_trigger_algo_id",
            field=models.CharField(blank=True, default="", max_length=255),
        ),
        migrations.AddField(
            model_name="order",
            name="close_trigger_price",
            field=models.DecimalField(blank=True, decimal_places=8, max_digits=20, null=True),
        ),
        migrations.CreateModel(
            name="TradeNotificationEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("event_key", models.CharField(max_length=191, unique=True)),
                (
                    "event_type",
                    models.CharField(
                        choices=[
                            ("open", "开单成功"),
                            ("stop_loss", "止损成交"),
                            ("strategy_take_profit", "策略挂单止盈成交"),
                            ("manual_take_profit", "手动止盈成交"),
                            ("reduction", "减仓成功"),
                        ],
                        max_length=32,
                    ),
                ),
                ("title", models.CharField(max_length=100)),
                ("content", models.TextField()),
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
                    "order",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="notification_events",
                        to="positions.order",
                    ),
                ),
            ],
            options={
                "db_table": "trade_notification_event",
                "ordering": ["-created_at", "-id"],
            },
        ),
        migrations.AddIndex(
            model_name="tradenotificationevent",
            index=models.Index(fields=["status", "next_retry_at"], name="trade_notify_status_retry_idx"),
        ),
        migrations.AddIndex(
            model_name="tradenotificationevent",
            index=models.Index(fields=["order", "event_type"], name="trade_notify_order_type_idx"),
        ),
    ]
