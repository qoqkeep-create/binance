from uuid import uuid4

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from positions.notifications import (
    build_trade_notification,
    build_trade_notification_payload,
    send_trade_notification,
    trade_notification_template_samples,
)


class Command(BaseCommand):
    help = "发送五类企业微信交易通知模板测试（不读取或修改真实仓位）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--confirm",
            action="store_true",
            help="确认向已配置的企业微信机器人发送五条【模板测试】消息",
        )

    def handle(self, *args, **options):
        if not options["confirm"]:
            raise CommandError("该命令会发送五条企业微信消息；确认后请添加 --confirm")

        occurred_at = timezone.now()
        run_id = uuid4().hex
        for event_type, fields in trade_notification_template_samples():
            title, content = build_trade_notification(event_type, fields, template_test=True)
            send_trade_notification(
                build_trade_notification_payload(
                    event_id=f"template:{event_type}:{run_id}",
                    event_type=event_type,
                    title=title,
                    content=content,
                    occurred_at=occurred_at,
                )
            )
            self.stdout.write(self.style.SUCCESS(f"已发送：{title}"))
