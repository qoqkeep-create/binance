from django.core.management.base import BaseCommand

from accounts.transfer_history import sync_all_transfer_histories


class Command(BaseCommand):
    help = "增量同步所有有效 Binance API 绑定的转账历史"

    def handle(self, *args, **options):
        result = sync_all_transfer_histories()
        message = (
            f"转账历史同步完成：尝试 {result['attempted']}，成功 {result['synced']}，"
            f"失败 {result['failed']}，写入或更新 {result['stored_records']} 条"
        )
        if result["failed"]:
            self.stdout.write(self.style.WARNING(message))
        else:
            self.stdout.write(self.style.SUCCESS(message))
