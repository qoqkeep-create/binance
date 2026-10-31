package com.oovso.strategy;

import com.oovso.market.MarketKline;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.util.Objects;
import java.util.function.Consumer;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Serializes each symbol's live pullback episodes in the same transaction as
 * signal insertion. A service restart or duplicate WebSocket event cannot
 * rearm an already consumed touch.
 */
@Service
public class FourHourEmaPullbackStateService {

    private static final String WAITING = "WAITING";

    private static final String ARMED = "ARMED";

    private static final String TOUCHING = "TOUCHING";

    static final long ALERT_COOLDOWN_MS = Duration.ofHours(24).toMillis();

    private final FourHourEmaPullbackStateMapper mapper;

    private final Clock clock;

    @Autowired
    public FourHourEmaPullbackStateService(FourHourEmaPullbackStateMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    FourHourEmaPullbackStateService(FourHourEmaPullbackStateMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional
    public void evaluate(
            MarketKline kline,
            TrendDirection direction,
            BigDecimal target,
            BigDecimal tolerance,
            Consumer<Long> onTouch
    ) {
        evaluate(kline, direction, target, tolerance, null, onTouch);
    }

    @Transactional
    public void evaluate(
            MarketKline kline,
            TrendDirection direction,
            BigDecimal target,
            BigDecimal tolerance,
            MarketKline sourceOneMinute,
            Consumer<Long> onTouch
    ) {
        Objects.requireNonNull(kline.getOpenTimeMs(), "4h open time is required");
        Objects.requireNonNull(kline.getClosePrice(), "4h latest price is required");
        long eventTime = eventTime(kline);
        FourHourEmaPullbackState key = key(kline);
        mapper.insertIfMissing(key);
        FourHourEmaPullbackState state = mapper.selectForUpdate(key);
        long bucketOpen = kline.getOpenTimeMs();
        if (bucketOpen < state.getLastBucketOpenMs()
                || eventTime < state.getLastEventMs()
                || (eventTime == state.getLastEventMs()
                    && !hasNewSourceInformation(state, sourceOneMinute))
                || (sourceOneMinute != null
                && sourceOneMinute.getOpenTimeMs() != null
                && sourceOneMinute.getOpenTimeMs() < state.getLastSourceOpenMs())) {
            return;
        }

        boolean closed = Integer.valueOf(1).equals(kline.getClosedState());
        boolean firstObservation = state.getLastEventMs() < 0;
        boolean directionChanged = direction != null
                && !Objects.equals(state.getDirection(), direction.name());
        boolean canUseCandleRange = (firstObservation && sourceOneMinute == null)
                || (closed && bucketOpen != state.getLastIntrabarBucketOpenMs());
        BigDecimal previousPrice = directionChanged ? null : state.getLastPrice();
        if (directionChanged) {
            state.setPhase(WAITING);
        }
        if (direction != null) {
            state.setDirection(direction.name());
        }
        state.setLastEventMs(eventTime);
        state.setLastBucketOpenMs(bucketOpen);
        state.setLastPrice(kline.getClosePrice());
        if (!closed) {
            state.setLastIntrabarBucketOpenMs(bucketOpen);
        }

        if (direction == null) {
            // A short-lived invalid alignment must not forget an already
            // consumed touch and alert again while price stays inside the band.
            updateSource(state, sourceOneMinute);
            mapper.update(state);
            return;
        }
        Objects.requireNonNull(target, "EMA144 is required for an EMA direction");
        Objects.requireNonNull(tolerance, "EMA144 tolerance is required");
        BigDecimal lower = target.subtract(tolerance.max(BigDecimal.ZERO));
        BigDecimal upper = target.add(tolerance.max(BigDecimal.ZERO));
        BigDecimal price = kline.getClosePrice();
        boolean onTrendSide = isTrendSide(price, lower, upper, direction);
        boolean inside = price.compareTo(lower) >= 0 && price.compareTo(upper) <= 0;
        boolean crossed = ARMED.equals(state.getPhase())
                && previousPrice != null
                && isTrendSide(previousPrice, lower, upper, direction)
                && !onTrendSide;
        boolean candleTouch = canUseCandleRange
                && kline.getHighPrice() != null
                && kline.getLowPrice() != null
                && kline.getHighPrice().compareTo(lower) >= 0
                && kline.getLowPrice().compareTo(upper) <= 0;
        boolean freshWick = freshSourceTouch(state, sourceOneMinute, direction, lower, upper);

        boolean touched = !TOUCHING.equals(state.getPhase())
                && (inside || crossed || candleTouch || freshWick);
        if (touched) {
            state.setPhase(TOUCHING);
        } else if (onTrendSide) {
            state.setPhase(ARMED);
        }
        updateSource(state, sourceOneMinute);
        long now = clock.millis();
        long lastAlert = state.getLastAlertTimeMs();
        boolean alert = touched && (lastAlert < 0
                || (now >= lastAlert && now - lastAlert >= ALERT_COOLDOWN_MS));
        if (alert) {
            state.setLastAlertTimeMs(now);
        }
        mapper.update(state);
        if (alert) {
            onTouch.accept(eventTime);
        }
    }

    private boolean freshSourceTouch(
            FourHourEmaPullbackState state,
            MarketKline source,
            TrendDirection direction,
            BigDecimal lower,
            BigDecimal upper
    ) {
        if (!usableSource(source)) {
            return false;
        }
        if (source.getOpenTimeMs() > state.getLastSourceOpenMs()) {
            return source.getHighPrice().compareTo(lower) >= 0
                    && source.getLowPrice().compareTo(upper) <= 0;
        }
        return direction == TrendDirection.SHORT
                ? state.getLastSourceHigh() != null
                    && source.getHighPrice().compareTo(state.getLastSourceHigh()) > 0
                    && source.getHighPrice().compareTo(lower) >= 0
                    && source.getLowPrice().compareTo(upper) <= 0
                : state.getLastSourceLow() != null
                    && source.getLowPrice().compareTo(state.getLastSourceLow()) < 0
                    && source.getLowPrice().compareTo(upper) <= 0
                    && source.getHighPrice().compareTo(lower) >= 0;
    }

    private boolean hasNewSourceInformation(
            FourHourEmaPullbackState state,
            MarketKline source
    ) {
        if (!usableSource(source)) {
            return false;
        }
        return source.getOpenTimeMs() > state.getLastSourceOpenMs()
                || (source.getOpenTimeMs().equals(state.getLastSourceOpenMs())
                    && (state.getLastSourceHigh() == null
                        || source.getHighPrice().compareTo(state.getLastSourceHigh()) > 0
                        || state.getLastSourceLow() == null
                        || source.getLowPrice().compareTo(state.getLastSourceLow()) < 0));
    }

    private void updateSource(FourHourEmaPullbackState state, MarketKline source) {
        if (!usableSource(source)) {
            return;
        }
        if (source.getOpenTimeMs() > state.getLastSourceOpenMs()) {
            state.setLastSourceOpenMs(source.getOpenTimeMs());
            state.setLastSourceHigh(source.getHighPrice());
            state.setLastSourceLow(source.getLowPrice());
        } else {
            state.setLastSourceHigh(state.getLastSourceHigh() == null
                    ? source.getHighPrice() : state.getLastSourceHigh().max(source.getHighPrice()));
            state.setLastSourceLow(state.getLastSourceLow() == null
                    ? source.getLowPrice() : state.getLastSourceLow().min(source.getLowPrice()));
        }
    }

    private boolean usableSource(MarketKline source) {
        return source != null && source.getOpenTimeMs() != null
                && source.getHighPrice() != null && source.getLowPrice() != null;
    }

    private boolean isTrendSide(
            BigDecimal price,
            BigDecimal lower,
            BigDecimal upper,
            TrendDirection direction
    ) {
        return direction == TrendDirection.LONG
                ? price.compareTo(upper) > 0
                : price.compareTo(lower) < 0;
    }

    private long eventTime(MarketKline kline) {
        if (Integer.valueOf(1).equals(kline.getClosedState())) {
            return Math.max(
                    kline.getCloseTimeMs() == null ? kline.getOpenTimeMs() : kline.getCloseTimeMs(),
                    kline.getEventTimeMs() == null ? 0 : kline.getEventTimeMs()
            );
        }
        return Objects.requireNonNull(kline.getEventTimeMs(), "live event time is required");
    }

    private FourHourEmaPullbackState key(MarketKline kline) {
        FourHourEmaPullbackState state = new FourHourEmaPullbackState();
        state.setExchange(kline.getExchange());
        state.setMarketType(kline.getMarketType());
        state.setContractType(kline.getContractType());
        state.setPair(kline.getPair());
        return state;
    }
}
