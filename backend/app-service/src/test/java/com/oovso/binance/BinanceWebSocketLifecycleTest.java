package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.binance.connector.client.common.websocket.adapter.stream.StreamConnectionWrapper;
import com.binance.connector.client.common.websocket.configuration.WebSocketClientConfiguration;
import java.lang.reflect.Field;
import java.util.Timer;
import java.util.TimerTask;
import org.eclipse.jetty.websocket.client.WebSocketClient;
import org.junit.jupiter.api.Test;

class BinanceWebSocketLifecycleTest {

    @Test
    void stopCancelsSdkReconnectTimerAndStopsJettyClient() throws Exception {
        WebSocketClient webSocketClient = new WebSocketClient();
        WebSocketClientConfiguration configuration = new WebSocketClientConfiguration();
        configuration.setReconnectIntervalTime(60_000);
        StreamConnectionWrapper connection = new StreamConnectionWrapper(configuration, webSocketClient);
        Timer timer = reconnectTimer(connection);

        try {
            connection.stop();

            assertTrue(webSocketClient.isStopped());
            assertThrows(IllegalStateException.class, () -> timer.schedule(new TimerTask() {
                @Override
                public void run() {
                }
            }, 0));
        } finally {
            timer.cancel();
            if (!webSocketClient.isStopped()) {
                webSocketClient.stop();
            }
        }
    }

    private Timer reconnectTimer(StreamConnectionWrapper connection) throws Exception {
        Field field = connection.getClass().getSuperclass().getDeclaredField("timer");
        field.setAccessible(true);
        return (Timer) field.get(connection);
    }
}
