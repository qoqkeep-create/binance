from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('positions', '0005_limitorder_strategy_config_limitorder_strategy_id_and_more'),
    ]

    operations = [
        migrations.AddField(
            model_name='order',
            name='strategy_tp_algo_ids',
            field=models.JSONField(blank=True, default=list),
        ),
    ]
