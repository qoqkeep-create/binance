from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [("signal_research", "0001_initial"), migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [migrations.CreateModel(
        name="ResearchStrategy",
        fields=[
            ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
            ("name", models.CharField(max_length=120)), ("version", models.PositiveIntegerField(default=1)),
            ("status", models.CharField(choices=[("draft", "草案"), ("published", "已发布")], default="draft", max_length=16)),
            ("provider", models.CharField(blank=True, default="", max_length=64)), ("model", models.CharField(blank=True, default="", max_length=128)),
            ("research_packet", models.JSONField(blank=True, default=dict)), ("definition", models.JSONField(blank=True, default=dict)),
            ("natural_rules", models.JSONField(blank=True, default=list)), ("code", models.TextField(blank=True, default="")), ("rationale", models.TextField(blank=True, default="")),
            ("created_at", models.DateTimeField(auto_now_add=True)), ("published_at", models.DateTimeField(blank=True, null=True)),
            ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="research_strategies", to=settings.AUTH_USER_MODEL)),
        ], options={"db_table": "signal_research_strategy", "ordering": ["-created_at", "-id"]},
    ), migrations.AddConstraint(model_name="researchstrategy", constraint=models.UniqueConstraint(fields=("user", "name", "version"), name="unique_research_strategy_version"))]
