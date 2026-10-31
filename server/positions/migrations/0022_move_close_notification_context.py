from django.db import migrations, models


CLOSE_EVENT_TYPES = ("stop_loss", "strategy_take_profit", "manual_take_profit")
EVENT_TYPE_BY_CLOSE_REASON = {
    "stop_loss": "stop_loss",
    "strategy_take_profit": "strategy_take_profit",
    "manual_take_profit": "manual_take_profit",
    "manual_close": "manual_take_profit",
    "external_close": "manual_take_profit",
}
TITLE_BY_EVENT_TYPE = {
    "stop_loss": "止损成交",
    "strategy_take_profit": "策略挂单止盈成交",
    "manual_take_profit": "手动止盈成交",
}


def move_close_context_to_notification_events(apps, schema_editor):
    Order = apps.get_model("positions", "Order")
    TradeNotificationEvent = apps.get_model("positions", "TradeNotificationEvent")

    orders = Order.objects.exclude(close_reason="").only(
        "id",
        "close_reason",
        "close_trigger_price",
    )
    for order in orders.iterator():
        event_type = EVENT_TYPE_BY_CLOSE_REASON.get(order.close_reason, "manual_take_profit")
        trigger_price = str(order.close_trigger_price) if order.close_trigger_price is not None else ""
        event = (
            TradeNotificationEvent.objects.filter(
                order_id=order.id,
                event_type__in=CLOSE_EVENT_TYPES,
            )
            .order_by("created_at", "id")
            .first()
        )
        if event:
            context = dict(event.context or {})
            if trigger_price and not context.get("trigger_price"):
                context["trigger_price"] = trigger_price
                event.context = context
                event.save(update_fields=["context"])
            continue

        TradeNotificationEvent.objects.get_or_create(
            event_key=f"trade:close:{order.id}",
            defaults={
                "order_id": order.id,
                "event_type": event_type,
                "title": TITLE_BY_EVENT_TYPE[event_type],
                "content": "",
                "context": {"trigger_price": trigger_price},
            },
        )


class Migration(migrations.Migration):

    dependencies = [
        ("positions", "0021_trade_notifications"),
    ]

    operations = [
        migrations.AddField(
            model_name="tradenotificationevent",
            name="context",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.RunPython(move_close_context_to_notification_events, migrations.RunPython.noop),
        migrations.RemoveField(model_name="order", name="close_reason"),
        migrations.RemoveField(model_name="order", name="close_size"),
        migrations.RemoveField(model_name="order", name="close_trigger_algo_id"),
        migrations.RemoveField(model_name="order", name="close_trigger_price"),
    ]
