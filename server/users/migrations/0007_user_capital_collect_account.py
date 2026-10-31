# Generated manually for User.capital_collect_account (capital collection destination)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("users", "0006_seed_admin_flags"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="capital_collect_account",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
    ]
