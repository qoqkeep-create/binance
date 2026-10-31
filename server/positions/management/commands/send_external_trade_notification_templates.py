from uuid import uuid4

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from positions.external_trade_signals import send_external_trade_signal
from positions.notifications import (
    build_trade_notification,
    build_trade_notification_payload,
    trade_notification_template_samples,
)


class Command(BaseCommand):
    help = "发送五类外部交易通知模板测试（不读取或修改真实仓位）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--confirm",
            action="store_true",
            help="确认向已配置的外部通道发送五条【模板测试】消息",
        )

    def handle(self, *args, **options):
        if not options["confirm"]:
            raise CommandError("该命令会发送五条外部通知；确认后请添加 --confirm")

        occurred_at = timezone.now()
        run_id = uuid4().hex
        failures = []
        for event_type, fields in trade_notification_template_samples():
            title, content = build_trade_notification(event_type, fields, template_test=True)
            payload = build_trade_notification_payload(
                event_id=f"template:{event_type}:{run_id}",
                event_type=event_type,
                title=title,
                content=content,
                occurred_at=occurred_at,
            )
            try:
                send_external_trade_signal(payload)
            except Exception as exc:  # noqa: BLE001
                failures.append(f"{event_type}: {exc}")
                self.stderr.write(self.style.ERROR(f"发送失败：{title}（{exc}）"))
            else:
                self.stdout.write(self.style.SUCCESS(f"已发送：{title}"))

        if failures:
            raise CommandError(f"五类外部通知均已尝试，其中 {len(failures)} 类失败：{'；'.join(failures)}")
