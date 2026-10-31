package com.oovso.realtime;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;
import java.util.Map;

public final class RealtimeProtocol {

    public static final int VERSION = 1;

    public static final String CHANNEL_MARKET_KLINE = "market.kline";

    public static final String CHANNEL_MARKET_TICKER = "market.ticker";

    public static final String CHANNEL_STRATEGY_SIGNAL = "strategy.signal";

    public static final String CHANNEL_TRADING_ACCOUNT = "trading.account";

    public static final String CHANNEL_TRADING_POSITION = "trading.position";

    public static final String CHANNEL_TRADING_ORDER = "trading.order";

    public static final String CHANNEL_TRADING_FILL = "trading.fill";

    private RealtimeProtocol() {
    }

    public record ClientMessage(
            Integer version,
            String type,
            String requestId,
            List<SubscriptionRequest> subscriptions,
            Long timestamp
    ) {
    }

    public record SubscriptionRequest(
            String channel,
            Map<String, List<String>> filters
    ) {
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    public record ServerMessage(
            int version,
            String type,
            String requestId,
            String channel,
            String event,
            String key,
            Long sequence,
            long timestamp,
            Object data,
            ErrorData error
    ) {

        public static ServerMessage ready(String connectionId, RealtimeProperties properties) {
            return new ServerMessage(
                    VERSION,
                    "ready",
                    null,
                    null,
                    null,
                    null,
                    null,
                    System.currentTimeMillis(),
                    Map.of(
                            "connectionId", connectionId,
                            "heartbeatIntervalMillis", Math.max(1_000, properties.getHeartbeatIntervalMillis()),
                            "clientTimeoutMillis", Math.max(2_000, properties.getClientTimeoutMillis())
                    ),
                    null
            );
        }

        public static ServerMessage ack(String requestId, Object data) {
            return new ServerMessage(
                    VERSION,
                    "ack",
                    requestId,
                    null,
                    null,
                    null,
                    null,
                    System.currentTimeMillis(),
                    data,
                    null
            );
        }

        public static ServerMessage pong(String requestId, Long clientTimestamp) {
            return new ServerMessage(
                    VERSION,
                    "pong",
                    requestId,
                    null,
                    null,
                    null,
                    null,
                    System.currentTimeMillis(),
                    Map.of("clientTimestamp", clientTimestamp == null ? 0 : clientTimestamp),
                    null
            );
        }

        public static ServerMessage event(
                String channel,
                String event,
                String key,
                long sequence,
                Object data
        ) {
            return new ServerMessage(
                    VERSION,
                    "event",
                    null,
                    channel,
                    event,
                    key,
                    sequence,
                    System.currentTimeMillis(),
                    data,
                    null
            );
        }

        public static ServerMessage error(String requestId, String code, String message) {
            return new ServerMessage(
                    VERSION,
                    "error",
                    requestId,
                    null,
                    null,
                    null,
                    null,
                    System.currentTimeMillis(),
                    null,
                    new ErrorData(code, message)
            );
        }
    }

    public record ErrorData(String code, String message) {
    }
}
