from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("users", "0007_user_capital_collect_account"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="capital_collect_network",
            field=models.CharField(blank=True, default="", max_length=32),
        ),
    ]
