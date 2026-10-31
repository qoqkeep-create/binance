package com.oovso;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.strategy.SuperEmaPullbackStrategyProperties;
import java.io.IOException;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.core.env.PropertySource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.test.context.ActiveProfiles;

@ActiveProfiles("test")
@SpringBootTest(properties = {
        "notification.webhook.enabled=true",
        "notification.webhook.url=https://example.com/webhook",
        "notification.webhook.key=test"
})
class AppServiceApplicationTests {

    @Autowired
    private BinanceContinuousKlineProperties binanceProperties;

    @Autowired
    private SuperEmaPullbackStrategyProperties strategyProperties;

    @Test
    void contextLoads() {
    }

    @Test
    void usesBinanceUsdmMainnetForRestAndWebSocket() {
        assertEquals("https://fapi.binance.com", binanceProperties.getRestBaseUrl());
        assertEquals("wss://fstream.binance.com/market/stream", binanceProperties.getStreamBaseUrl());
        assertEquals("1m", binanceProperties.getInterval());
        assertEquals(3_000, strategyProperties.getFifteenMinute().getHistorySize());
    }

    @Test
    void devProfilePinsEveryBinanceClientToFuturesTestnet() throws IOException {
        List<PropertySource<?>> sources = new YamlPropertySourceLoader().load(
                "application-dev",
                new ClassPathResource("application-dev.yml")
        );
        PropertySource<?> dev = sources.getFirst();

        assertEquals(
                "https://testnet.binancefuture.com",
                dev.getProperty("binance.usdm.continuous-kline.rest-base-url")
        );
        assertEquals(
                "wss://fstream.binancefuture.com/market/stream",
                dev.getProperty("binance.usdm.continuous-kline.stream-base-url")
        );
        assertEquals(
                "https://testnet.binancefuture.com",
                dev.getProperty("trading.binance.rest-base-url")
        );
        assertEquals(
                "wss://fstream.binancefuture.com/private",
                dev.getProperty("trading.sync.user-stream-base-url")
        );
    }

}
