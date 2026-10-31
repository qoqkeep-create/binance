from django.apps import AppConfig


class TradingConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'trading'

    def ready(self):
        import os

        # Docker 部署下由独立 scheduler 容器显式启动，避免 web 多副本重复执行。
        if os.getenv("RUN_SCHEDULER_IN_WEB", "false").lower() != "true":
            return

        from trading.scheduler import start_scheduler
        start_scheduler()
