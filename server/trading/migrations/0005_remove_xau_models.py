from django.db import migrations


class Migration(migrations.Migration):
    """移除 XAU 黄金数据链路相关表（后续在其他服务器完成核心后再重新接入）。"""

    dependencies = [
        ("trading", "0004_xaucandlesyncday_xaum1candle"),
    ]

    operations = [
        migrations.DeleteModel(
            name="XauCandleSyncDay",
        ),
        migrations.DeleteModel(
            name="XauM1Candle",
        ),
    ]
