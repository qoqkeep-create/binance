from django.contrib import admin

from plans.models import TradingPlan


@admin.register(TradingPlan)
class TradingPlanAdmin(admin.ModelAdmin):
    list_display = ("id", "symbol", "direction", "status", "user", "created_at")
    list_filter = ("direction", "status", "timeframe")
    search_fields = ("symbol", "thesis", "user__email")
    readonly_fields = ("created_at", "updated_at")