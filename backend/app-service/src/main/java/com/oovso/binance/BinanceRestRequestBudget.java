package com.oovso.binance;

import com.oovso.trading.TradingProperties;
import java.net.http.HttpHeaders;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.stereotype.Component;

@Component
public class BinanceRestRequestBudget {

    private static final long WINDOW_MILLIS = 60_000;
    private static final long FALLBACK_COOLDOWN_MILLIS = 60_000;
    private static final Pattern BANNED_UNTIL_PATTERN = Pattern.compile(
            "banned\\s+until\\s+(\\d{12,})",
            Pattern.CASE_INSENSITIVE
    );

    private final TradingProperties properties;
    private long windowStartedAt = minuteStartedAt(
            System.currentTimeMillis()
    );
    private int reservedWeight;
    private long cooldownUntilMillis;

    public BinanceRestRequestBudget(TradingProperties properties) {
        this.properties = properties;
    }

    public synchronized void acquire(int weight) {
        int required = Math.max(1, weight);
        long deadline = System.currentTimeMillis()
                + Math.max(
                        1_000,
                        properties.getBinance().getRequestTimeoutMillis()
                );
        while (true) {
            long now = System.currentTimeMillis();
            resetWindowIfNeeded(now);
            if (cooldownUntilMillis > now) {
                throw cooldownException(cooldownUntilMillis);
            }
            int limit = Math.max(
                    100,
                    properties.getBinance()
                            .getPrivateRestWeightBudgetPerMinute()
            );
            if (reservedWeight + required <= limit) {
                reservedWeight += required;
                return;
            }
            long retryAtMillis = windowStartedAt + WINDOW_MILLIS;
            long waitMillis = Math.min(
                    deadline - now,
                    retryAtMillis - now
            );
            if (waitMillis <= 0) {
                throw new BinanceRestRateLimitException(
                        "Binance REST shared request weight budget exhausted",
                        retryAtMillis
                );
            }
            try {
                wait(waitMillis);
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                throw new BinanceRestRateLimitException(
                        "Interrupted while waiting for Binance REST request budget",
                        retryAtMillis
                );
            }
        }
    }

    public synchronized long observeResponse(
            int statusCode,
            HttpHeaders headers,
            String responseBody
    ) {
        resetWindowIfNeeded(System.currentTimeMillis());
        observeExchangeWeight(headers);
        if (statusCode != 418 && statusCode != 429) {
            return cooldownUntilMillis;
        }

        long now = System.currentTimeMillis();
        long retryAtMillis = Math.max(
                retryAtFromHeader(headers, now),
                retryAtFromBody(responseBody)
        );
        if (retryAtMillis <= now) {
            retryAtMillis = now + FALLBACK_COOLDOWN_MILLIS;
        }
        cooldownUntilMillis = Math.max(
                cooldownUntilMillis,
                retryAtMillis
        );
        notifyAll();
        return cooldownUntilMillis;
    }

    public synchronized long cooldownUntilMillis() {
        return cooldownUntilMillis;
    }

    synchronized int reservedWeight() {
        resetWindowIfNeeded(System.currentTimeMillis());
        return reservedWeight;
    }

    private void observeExchangeWeight(HttpHeaders headers) {
        Optional<String> value = headers.firstValue(
                "X-MBX-USED-WEIGHT-1M"
        );
        if (value.isEmpty()) {
            return;
        }
        try {
            reservedWeight = Math.max(
                    reservedWeight,
                    Math.max(0, Integer.parseInt(value.get()))
            );
        } catch (NumberFormatException ignored) {
            // A malformed diagnostic header must not fail the API response.
        }
    }

    private long retryAtFromHeader(HttpHeaders headers, long now) {
        Optional<String> value = headers.firstValue("Retry-After");
        if (value.isEmpty()) {
            return 0;
        }
        String retryAfter = value.get().trim();
        try {
            long seconds = Long.parseLong(retryAfter);
            if (seconds <= 0) {
                return 0;
            }
            return now + Math.min(
                    seconds,
                    (Long.MAX_VALUE - now) / 1_000
            ) * 1_000;
        } catch (NumberFormatException ignored) {
            try {
                return ZonedDateTime.parse(
                        retryAfter,
                        DateTimeFormatter.RFC_1123_DATE_TIME
                ).toInstant().toEpochMilli();
            } catch (DateTimeParseException malformedDate) {
                return 0;
            }
        }
    }

    private long retryAtFromBody(String responseBody) {
        if (responseBody == null || responseBody.isBlank()) {
            return 0;
        }
        Matcher matcher = BANNED_UNTIL_PATTERN.matcher(responseBody);
        if (!matcher.find()) {
            return 0;
        }
        try {
            return Long.parseLong(matcher.group(1));
        } catch (NumberFormatException ignored) {
            return 0;
        }
    }

    private BinanceRestRateLimitException cooldownException(
            long retryAtMillis
    ) {
        return new BinanceRestRateLimitException(
                "Binance REST requests are cooling down until "
                        + retryAtMillis,
                retryAtMillis
        );
    }

    private void resetWindowIfNeeded(long now) {
        long currentWindowStartedAt = minuteStartedAt(now);
        if (currentWindowStartedAt == windowStartedAt) {
            return;
        }
        windowStartedAt = currentWindowStartedAt;
        reservedWeight = 0;
        notifyAll();
    }

    private static long minuteStartedAt(long timestampMillis) {
        return timestampMillis
                - Math.floorMod(timestampMillis, WINDOW_MILLIS);
    }
}
