from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = []
    operations = [
        migrations.CreateModel(
            name="MarketAnalysisSignal",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("symbol", models.CharField(max_length=32)),
                ("interval", models.CharField(max_length=8)),
                ("candle_close_time", models.DateTimeField(db_index=True)),
                ("direction", models.CharField(default="neutral", max_length=12)),
                ("opportunity_type", models.CharField(max_length=80)),
                ("score", models.PositiveSmallIntegerField()),
                ("final_action", models.CharField(max_length=32)),
                ("analysis", models.JSONField(default=dict)),
                ("ai_explanation", models.JSONField(blank=True, default=dict)),
                ("ai_error", models.TextField(blank=True, default="")),
                ("alert_sent", models.BooleanField(default=False)),
                ("alert_error", models.TextField(blank=True, default="")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"db_table": "market_analysis_signal", "ordering": ["-candle_close_time", "-id"]},
        ),
        migrations.AddConstraint(model_name="marketanalysissignal", constraint=models.UniqueConstraint(fields=("symbol", "interval", "candle_close_time"), name="unique_market_analysis_candle")),
        migrations.AddIndex(model_name="marketanalysissignal", index=models.Index(fields=["symbol", "interval", "-candle_close_time"], name="market_analy_symbol__ca5e6f_idx")),
    ]
