from django.db import models


class MarketCandle(models.Model):
    symbol = models.CharField(max_length=32)
    interval = models.CharField(max_length=4)
    open_time = models.BigIntegerField()
    close_time = models.BigIntegerField()
    open_price = models.DecimalField(max_digits=38, decimal_places=18)
    high_price = models.DecimalField(max_digits=38, decimal_places=18)
    low_price = models.DecimalField(max_digits=38, decimal_places=18)
    close_price = models.DecimalField(max_digits=38, decimal_places=18)
    volume = models.DecimalField(max_digits=38, decimal_places=18)
    quote_volume = models.DecimalField(max_digits=38, decimal_places=18)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["symbol", "interval", "open_time"], name="market_candle_identity")]
        indexes = [models.Index(fields=["symbol", "interval", "-open_time"], name="market_candle_recent")]
