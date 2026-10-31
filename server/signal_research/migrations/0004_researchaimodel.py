from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [("signal_research", "0003_signalsample_expected_direction"), migrations.swappable_dependency(settings.AUTH_USER_MODEL)]
    operations = [migrations.CreateModel(name="ResearchAiModel", fields=[
        ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
        ("name", models.CharField(max_length=80)), ("provider", models.CharField(default="openai_compatible", max_length=64)),
        ("base_url", models.URLField(max_length=300)), ("model", models.CharField(max_length=128)),
        ("api_key_encrypted", models.TextField()), ("is_active", models.BooleanField(default=False)),
        ("created_at", models.DateTimeField(auto_now_add=True)),
    ], options={"db_table": "signal_research_ai_model", "ordering": ["-is_active", "-id"]}), migrations.CreateModel(name="ResearchAiModelSelection", fields=[
        ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
        ("model", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, to="signal_research.researchaimodel")),
        ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="research_ai_model_selection", to=settings.AUTH_USER_MODEL)),
    ])]
