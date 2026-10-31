from django.db import migrations, models
from django.db.models import Count


ACTIVE_STATUSES = [
    "funding_refill_pending",
    "spot_refill_pending",
    "futures_pending",
    "funding_pending",
    "spot_pending",
]


def normalize_active_slots(apps, schema_editor):
    CapitalSweep = apps.get_model("trading", "CapitalSweep")
    duplicate_users = list(
        CapitalSweep.objects.filter(status__in=ACTIVE_STATUSES)
        .values("user_id")
        .annotate(total=Count("id"))
        .filter(total__gt=1)
        .values_list("user_id", flat=True)
    )
    if duplicate_users:
        raise RuntimeError(
            "Cannot add the capital sweep uniqueness constraint: "
            f"users with multiple active sweeps: {duplicate_users}"
        )
    CapitalSweep.objects.filter(status__in=ACTIVE_STATUSES).update(active_slot=1)
    CapitalSweep.objects.exclude(status__in=ACTIVE_STATUSES).update(active_slot=None)
    CapitalSweep.objects.filter(
        status="futures_pending",
        futures_attempted_at__isnull=True,
    ).update(futures_attempted_at=models.F("created_at"))


class Migration(migrations.Migration):
    dependencies = [("trading", "0010_separate_external_and_tradingview_sources")]

    operations = [
        migrations.AddField(
            model_name="capitalsweep",
            name="active_slot",
            field=models.PositiveSmallIntegerField(blank=True, default=1, editable=False, null=True),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_refill_amount",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=24),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_refill_attempted_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="funding_refill_tran_id",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="futures_attempted_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="spot_refill_amount",
            field=models.DecimalField(decimal_places=8, default=0, max_digits=24),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="spot_refill_attempted_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="capitalsweep",
            name="spot_refill_tran_id",
            field=models.CharField(blank=True, default="", max_length=128),
        ),
        migrations.AlterField(
            model_name="capitalsweep",
            name="status",
            field=models.CharField(
                choices=[
                    ("funding_refill_pending", "资金转合约待确认"),
                    ("spot_refill_pending", "现货转合约待确认"),
                    ("futures_pending", "合约转现货待确认"),
                    ("funding_pending", "资金转现货待确认"),
                    ("spot_pending", "现货转主账户待确认"),
                    ("completed", "归集完成"),
                    ("failed", "归集失败"),
                ],
                default="futures_pending",
                max_length=24,
            ),
        ),
        migrations.RunPython(normalize_active_slots, migrations.RunPython.noop),
        migrations.AddConstraint(
            model_name="capitalsweep",
            constraint=models.UniqueConstraint(
                fields=("user", "active_slot"),
                name="capital_sweep_one_active_per_user",
            ),
        ),
    ]
