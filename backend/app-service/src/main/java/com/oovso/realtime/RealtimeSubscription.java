package com.oovso.realtime;

import com.oovso.market.MarketKlineService;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import org.springframework.util.StringUtils;

public record RealtimeSubscription(
        String channel,
        Set<String> symbols,
        Set<String> intervals
) {

    private static final Set<String> SUPPORTED_CHANNELS = Set.of(
            RealtimeProtocol.CHANNEL_MARKET_KLINE,
            RealtimeProtocol.CHANNEL_MARKET_TICKER,
            RealtimeProtocol.CHANNEL_STRATEGY_SIGNAL,
            RealtimeProtocol.CHANNEL_TRADING_ACCOUNT,
            RealtimeProtocol.CHANNEL_TRADING_POSITION,
            RealtimeProtocol.CHANNEL_TRADING_ORDER,
            RealtimeProtocol.CHANNEL_TRADING_FILL
    );

    static RealtimeSubscription from(
            RealtimeProtocol.SubscriptionRequest request,
            RealtimeProperties properties
    ) {
        if (request == null || !StringUtils.hasText(request.channel())) {
            throw new RealtimeProtocolException("INVALID_SUBSCRIPTION", "订阅频道不能为空");
        }

        String channel = request.channel().trim().toLowerCase(Locale.ROOT);
        if (!SUPPORTED_CHANNELS.contains(channel)) {
            throw new RealtimeProtocolException("UNSUPPORTED_CHANNEL", "不支持的订阅频道: " + channel);
        }

        Map<String, List<String>> filters = request.filters() == null ? Map.of() : request.filters();
        Set<String> symbols = normalizedUppercase(filters.get("symbols"));
        if (symbols.size() > Math.max(1, properties.getMaxSymbolsPerSubscription())) {
            throw new RealtimeProtocolException(
                    "TOO_MANY_SYMBOLS",
                    "单个频道订阅的交易对数量超过限制"
            );
        }

        Set<String> intervals = normalizedLowercase(filters.get("intervals"));
        if (RealtimeProtocol.CHANNEL_MARKET_KLINE.equals(channel)) {
            if (symbols.isEmpty()) {
                throw new RealtimeProtocolException(
                        "SYMBOLS_REQUIRED",
                        "market.kline 必须指定交易对"
                );
            }
            if (intervals.isEmpty()) {
                intervals = Set.of(MarketKlineService.INTERVAL_1M);
            }
            if (!MarketKlineService.SUPPORTED_INTERVALS.containsAll(intervals)) {
                throw new RealtimeProtocolException(
                        "UNSUPPORTED_INTERVAL",
                        "K线周期只支持 " + MarketKlineService.SUPPORTED_INTERVALS
                );
            }
        } else if (RealtimeProtocol.CHANNEL_MARKET_TICKER.equals(channel)) {
            if (symbols.isEmpty()) {
                throw new RealtimeProtocolException(
                        "SYMBOLS_REQUIRED",
                        "market.ticker 必须指定交易对"
                );
            }
            if (!intervals.isEmpty()) {
                throw new RealtimeProtocolException(
                        "INVALID_FILTER",
                        "market.ticker 不支持 intervals 过滤条件"
                );
            }
        } else if (!intervals.isEmpty()) {
            throw new RealtimeProtocolException(
                    "INVALID_FILTER",
                    channel + " 不支持 intervals 过滤条件"
            );
        }

        if (channel.startsWith("trading.") && !symbols.isEmpty()) {
            throw new RealtimeProtocolException(
                    "INVALID_FILTER",
                    channel + " 不支持 symbols 过滤条件"
            );
        }

        return new RealtimeSubscription(
                channel,
                Set.copyOf(symbols),
                Set.copyOf(intervals)
        );
    }

    boolean matches(String eventSymbol, String eventInterval) {
        if (!symbols.isEmpty() && !symbols.contains(normalizeUppercase(eventSymbol))) {
            return false;
        }
        return intervals.isEmpty() || intervals.contains(normalizeLowercase(eventInterval));
    }

    private static Set<String> normalizedUppercase(List<String> values) {
        return normalized(values, true);
    }

    private static Set<String> normalizedLowercase(List<String> values) {
        return normalized(values, false);
    }

    private static Set<String> normalized(List<String> values, boolean uppercase) {
        if (values == null || values.isEmpty()) {
            return Set.of();
        }
        Set<String> normalized = new LinkedHashSet<>();
        for (String value : values) {
            if (!StringUtils.hasText(value)) {
                continue;
            }
            normalized.add(uppercase ? normalizeUppercase(value) : normalizeLowercase(value));
        }
        return normalized;
    }

    private static String normalizeUppercase(String value) {
        return StringUtils.hasText(value) ? value.trim().toUpperCase(Locale.ROOT) : "";
    }

    private static String normalizeLowercase(String value) {
        return StringUtils.hasText(value) ? value.trim().toLowerCase(Locale.ROOT) : "";
    }
}
