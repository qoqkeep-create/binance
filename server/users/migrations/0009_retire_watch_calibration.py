from django.db import migrations


class Migration(migrations.Migration):
    dependencies = [
        ("users", "0008_user_capital_collect_network"),
    ]

    operations = [
        # Retire the ORM state without destroying historical calibration data.
        # The nullable column remains compatible with the previous release.
        migrations.SeparateDatabaseAndState(
            database_operations=[],
            state_operations=[
                migrations.RemoveField(
                    model_name="user",
                    name="preflight_completed_at",
                ),
            ],
        ),
    ]
