package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.net.URI;
import java.net.http.HttpClient;
import org.junit.jupiter.api.Test;

class BinanceUserDataStreamClientTest {

    @Test
    void buildsPrivateWssRouteWithoutLoggingOrPersistingListenKey() {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setUserStreamBaseUrl(
                "wss://fstream.binance.com/private/"
        );
        BinanceUserDataStreamClient client = new BinanceUserDataStreamClient(
                properties,
                HttpClient.newHttpClient()
        );

        assertEquals(
                URI.create("wss://fstream.binance.com/private/ws/test-key"),
                client.streamUri("test-key")
        );
    }

    @Test
    void rejectsNonTlsUserStreamEndpoint() {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setUserStreamBaseUrl(
                "ws://fstream.binance.com/private"
        );

        assertThrows(
                IllegalArgumentException.class,
                () -> new BinanceUserDataStreamClient(
                        properties,
                        HttpClient.newHttpClient()
                )
        );
    }
}
