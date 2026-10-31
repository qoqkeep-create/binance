# Generated manually for User.is_admin (app-level admin flag)

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("users", "0004_systemsetting"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="is_admin",
            field=models.BooleanField(default=False),
        ),
    ]
