import secrets
import string

from django.core.management.base import BaseCommand

from invites.models import InviteCode


class Command(BaseCommand):
    help = "Generate invite codes"

    def add_arguments(self, parser):
        parser.add_argument("--count", type=int, default=1000)

    def handle(self, *args, **options):
        count = options["count"]
        chars = string.ascii_uppercase + string.digits

        created = 0
        while created < count:
            code = "".join(secrets.choice(chars) for _ in range(6))
            _, is_created = InviteCode.objects.get_or_create(code=code)
            if is_created:
                created += 1

        self.stdout.write(self.style.SUCCESS(f"Generated {created} invite codes"))
