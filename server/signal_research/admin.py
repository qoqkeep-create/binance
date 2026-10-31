from django.contrib import admin

from signal_research.models import SignalSample


@admin.register(SignalSample)
class SignalSampleAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "symbol", "timeframe", "signal_time", "trusted", "fetched_at")
    list_filter = ("timeframe", "trusted")
    search_fields = ("symbol", "user__username")
