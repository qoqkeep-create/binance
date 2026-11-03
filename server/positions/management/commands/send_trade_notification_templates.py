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
    help = "向指定账号的 App 通知队列添加五类模板测试（不读取或修改真实仓位）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--confirm",
            action="store_true",
            help="确认向指定账号添加五条 App【模板测试】消息",
        )
        parser.add_argument("--user-id", type=int, help="明确指定接收 App 通知的用户 ID")

    def handle(self, *args, **options):
        if not options["confirm"]:
            raise CommandError("该命令会发送五条 App 消息；确认后请添加 --confirm")
        if not options["user_id"] or options["user_id"] <= 0:
            raise CommandError("必须使用 --user-id 指定接收账号，不允许广播通知")

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
                ),
                recipient_user_id=options["user_id"],
            )
            self.stdout.write(self.style.SUCCESS(f"已加入 App 通知队列：{title}"))
