from django.contrib import admin

from experiences.models import TradingExperience


@admin.register(TradingExperience)
class TradingExperienceAdmin(admin.ModelAdmin):
    list_display = ("id", "title", "user", "created_at", "updated_at")
    search_fields = ("title", "body", "user__email")
    readonly_fields = ("created_at", "updated_at")
