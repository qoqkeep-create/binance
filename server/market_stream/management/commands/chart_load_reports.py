"""Read-only lookup of public chart diagnostics, without account identifiers."""
import json
from django.core.management.base import BaseCommand
from market_stream.models import ChartLoadReport


class Command(BaseCommand):
    help = 'Read stored chart-load diagnostics by trace ID or app build'

    def add_arguments(self, parser):
        parser.add_argument('--trace-id')
        parser.add_argument('--build')
        parser.add_argument('--limit', type=int, default=10)

    def handle(self, *args, **options):
        rows = ChartLoadReport.objects.order_by('-received_at')
        if options['trace_id']: rows = rows.filter(trace_id=options['trace_id'])
        if options['build']: rows = rows.filter(app_build=options['build'])
        for row in rows[:min(50, max(1, options['limit']))]:
            self.stdout.write(json.dumps({'receivedAt': row.received_at.isoformat(), 'report': row.payload}, ensure_ascii=False))
