from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("accounts", "0002_lead_settings")]

    operations = [
        migrations.AddField(
            model_name="transferhistorysyncstate",
            name="source_version",
            field=models.PositiveSmallIntegerField(db_default=0, default=0),
        ),
    ]
