from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("signal_research", "0002_researchstrategy")]
    operations = [migrations.AddField(model_name="signalsample", name="expected_direction", field=models.CharField(choices=[("long", "做多"), ("short", "做空"), ("neutral", "仅观察")], default="neutral", max_length=12))]
