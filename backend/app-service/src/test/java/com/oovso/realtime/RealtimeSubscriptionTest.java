package com.oovso.realtime;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;

class RealtimeSubscriptionTest {

    private final RealtimeProperties properties = new RealtimeProperties();

    @Test
    void normalizesAndMatchesMarketKlineFilters() {
        RealtimeSubscription subscription = RealtimeSubscription.from(
                new RealtimeProtocol.SubscriptionRequest(
                        " MARKET.KLINE ",
                        Map.of(
                                "symbols", List.of("btcusdc", " ETHUSDC "),
                                "intervals", List.of("1M", "1h")
                        )
                ),
                properties
        );

        assertEquals("market.kline", subscription.channel());
        assertEquals(Set.of("BTCUSDC", "ETHUSDC"), subscription.symbols());
        assertEquals(Set.of("1m", "1h"), subscription.intervals());
        assertTrue(subscription.matches("btcusdc", "1m"));
        assertFalse(subscription.matches("SOLUSDC", "1m"));
        assertFalse(subscription.matches("BTCUSDC", "4h"));
    }

    @Test
    void defaultsMarketKlineToOneMinute() {
        RealtimeSubscription subscription = RealtimeSubscription.from(
                new RealtimeProtocol.SubscriptionRequest(
                        "market.kline",
                        Map.of("symbols", List.of("BTCUSDC"))
                ),
                properties
        );

        assertEquals(Set.of("1m"), subscription.intervals());
    }

    @Test
    void marketTickerRequiresSymbolsAndRejectsIntervals() {
        RealtimeSubscription subscription = RealtimeSubscription.from(
                new RealtimeProtocol.SubscriptionRequest(
                        "market.ticker",
                        Map.of("symbols", List.of("btcusdc", "ETHUSDC"))
                ),
                properties
        );

        assertEquals(Set.of("BTCUSDC", "ETHUSDC"), subscription.symbols());
        assertTrue(subscription.matches("BTCUSDC", null));
        assertFalse(subscription.matches("SOLUSDC", null));

        RealtimeProtocolException missingSymbols = assertThrows(
                RealtimeProtocolException.class,
                () -> RealtimeSubscription.from(
                        new RealtimeProtocol.SubscriptionRequest(
                                "market.ticker",
                                Map.of()
                        ),
                        properties
                )
        );
        assertEquals("SYMBOLS_REQUIRED", missingSymbols.getCode());

        RealtimeProtocolException invalidInterval = assertThrows(
                RealtimeProtocolException.class,
                () -> RealtimeSubscription.from(
                        new RealtimeProtocol.SubscriptionRequest(
                                "market.ticker",
                                Map.of(
                                        "symbols", List.of("BTCUSDC"),
                                        "intervals", List.of("1m")
                                )
                        ),
                        properties
                )
        );
        assertEquals("INVALID_FILTER", invalidInterval.getCode());
    }

    @Test
    void rejectsUnboundedMarketSubscription() {
        RealtimeProtocolException exception = assertThrows(
                RealtimeProtocolException.class,
                () -> RealtimeSubscription.from(
                        new RealtimeProtocol.SubscriptionRequest(
                                "market.kline",
                                Map.of()
                        ),
                        properties
                )
        );

        assertEquals("SYMBOLS_REQUIRED", exception.getCode());
    }

    @Test
    void strategySignalCanSubscribeToAllSymbols() {
        RealtimeSubscription subscription = RealtimeSubscription.from(
                new RealtimeProtocol.SubscriptionRequest(
                        "strategy.signal",
                        Map.of()
                ),
                properties
        );

        assertTrue(subscription.matches("BTCUSDC", "1h"));
        assertTrue(subscription.matches("ETHUSDC", "1h"));
    }

    @Test
    void privateTradingChannelsAreSupportedWithoutMarketFilters() {
        RealtimeSubscription subscription = RealtimeSubscription.from(
                new RealtimeProtocol.SubscriptionRequest(
                        "trading.order",
                        Map.of()
                ),
                properties
        );

        assertTrue(subscription.matches("BTCUSDC", null));
        assertThrows(
                RealtimeProtocolException.class,
                () -> RealtimeSubscription.from(
                        new RealtimeProtocol.SubscriptionRequest(
                                "trading.fill",
                                Map.of("symbols", List.of("BTCUSDC"))
                        ),
                        properties
                )
        );
    }
}
