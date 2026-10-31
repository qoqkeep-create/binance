import os
from django.core.management.base import BaseCommand, CommandError
from users.models import User


class Command(BaseCommand):
    help = "Create an initial mobile administrator only on an empty installation"

    def handle(self, *args, **options):
        email = os.environ.get("INTEGRATED_BOOTSTRAP_EMAIL", "").strip().lower()
        password = os.environ.get("INTEGRATED_BOOTSTRAP_PASSWORD", "")
        if not email or len(password) < 16:
            raise CommandError("Set bootstrap email and a password of at least 16 characters")
        if User.objects.exists():
            self.stdout.write("Users already exist; no account or password was changed")
            return
        User.objects.create_user(email, password, is_admin=True)
        self.stdout.write("Initial mobile administrator created")
