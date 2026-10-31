# Seed initial admins: flag designated accounts as app admins

from django.db import migrations

# 初始管理员邮箱列表（后续可通过 ORM/Django admin 调整）
ADMIN_EMAILS = [
    "zqkeep@gmail.com",
    "2818057379@qq.com",
]


def seed_admins(apps, schema_editor):
    User = apps.get_model("users", "User")
    User.objects.filter(email__in=ADMIN_EMAILS).update(is_admin=True)


def unseed_admins(apps, schema_editor):
    User = apps.get_model("users", "User")
    User.objects.filter(email__in=ADMIN_EMAILS).update(is_admin=False)


class Migration(migrations.Migration):

    dependencies = [
        ("users", "0005_user_is_admin"),
    ]

    operations = [
        migrations.RunPython(seed_admins, unseed_admins),
    ]
