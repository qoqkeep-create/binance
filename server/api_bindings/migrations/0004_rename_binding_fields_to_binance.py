from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("api_bindings", "0003_apibinding_okx_uid_and_label"),
    ]

    operations = [
        migrations.RenameField(
            model_name="apibinding",
            old_name="okx_uid",
            new_name="binance_uid",
        ),
        migrations.RenameField(
            model_name="apibinding",
            old_name="okx_label",
            new_name="binance_label",
        ),
    ]
