package com.oovso.strategy;

import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponse;
import com.binance.connector.client.derivatives_trading_usds_futures.websocket.stream.model.ContinuousContractKlineCandlestickStreamsResponseK;
import com.oovso.binance.ContinuousKlineHandler;
import com.oovso.market.KlineStorageProperties;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineService;
import java.math.BigDecimal;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

/**
 * Coalesces high-frequency provisional 1m updates by symbol and evaluates the
 * currently forming 4h candle without waiting for the 4h close event.
 */
@Component
public class FourHourIntrabarStrategyHandler implements ContinuousKlineHandler {

    private static final Logger log = LoggerFactory.getLogger(FourHourIntrabarStrategyHandler.class);

    private final SuperEmaPullbackStrategyProperties properties;

    private final KlineStorageProperties klineProperties;

    private final FourHourIntrabarKlineAggregator aggregator;

    private final SuperEmaPullbackStrategy strategy;

    private final StrategySymbolWhitelist symbolWhitelist;

    private final StrategySymbolEligibilityService symbolEligibilityService;

    private final ExecutorService executor;

    private final ConcurrentHashMap<String, Slot> slots = new ConcurrentHashMap<>();

    public FourHourIntrabarStrategyHandler(
            SuperEmaPullbackStrategyProperties properties,
            KlineStorageProperties klineProperties,
            FourHourIntrabarKlineAggregator aggregator,
            SuperEmaPullbackStrategy strategy,
            StrategySymbolWhitelist symbolWhitelist,
            StrategySymbolEligibilityService symbolEligibilityService,
            @Qualifier("marketKlineEventExecutor") ExecutorService executor
    ) {
        this.properties = properties;
        this.klineProperties = klineProperties;
        this.aggregator = aggregator;
        this.strategy = strategy;
        this.symbolWhitelist = symbolWhitelist;
        this.symbolEligibilityService = symbolEligibilityService;
        this.executor = executor;
    }

    @Override
    public void onKline(ContinuousContractKlineCandlestickStreamsResponse event) {
        ContinuousContractKlineCandlestickStreamsResponseK kline = event.getkLowerCase();
        if (!enabled()
                || kline == null
                || !MarketKlineService.INTERVAL_1M.equals(normalize(kline.getiLowerCase()))
                || !StringUtils.hasText(event.getPs())
                || !isStrategySymbol(event.getPs())) {
            return;
        }

        MarketKline liveOneMinute;
        try {
            liveOneMinute = toMarketKline(event, kline);
        } catch (RuntimeException ex) {
            log.warn("Skip malformed intrabar kline for {}: {}", event.getPs(), ex.getMessage());
            return;
        }

        String key = liveOneMinute.getContractType() + ':' + liveOneMinute.getPair();
        Slot slot = slots.computeIfAbsent(key, ignored -> new Slot());
        slot.latest().set(liveOneMinute);
        schedule(key, slot);
    }

    private void schedule(String key, Slot slot) {
        if (!slot.running().compareAndSet(false, true)) {
            return;
        }
        executor.submit(() -> drain(key, slot));
    }

    private void drain(String key, Slot slot) {
        try {
            while (true) {
                MarketKline live = slot.latest().getAndSet(null);
                if (live == null) {
                    return;
                }

                long minimumInterval = Math.max(
                        0,
                        properties.getFourHour().getIntrabarAnalysisIntervalMillis()
                );
                long waitMillis = minimumInterval - (System.currentTimeMillis() - slot.lastAnalyzedAt());
                if (waitMillis > 0) {
                    Thread.sleep(waitMillis);
                    MarketKline newer = slot.latest().getAndSet(null);
                    if (newer != null) {
                        live = newer;
                    }
                }

                analyze(live);
                slot.lastAnalyzedAt(System.currentTimeMillis());
            }
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        } catch (Exception ex) {
            log.error("Failed to analyze provisional 4h kline for {}", key, ex);
        } finally {
            slot.running().set(false);
            if (slot.latest().get() != null) {
                schedule(key, slot);
            }
        }
    }

    private void analyze(MarketKline liveOneMinute) {
        int historySize = Math.max(500, properties.getFourHour().getHistorySize());
        aggregator.aggregate(liveOneMinute, historySize).ifPresent(strategy::onFourHourIntrabar);
    }

    private boolean enabled() {
        return properties.isEnabled()
                && properties.getFourHour().isEnabled()
                && properties.getFourHour().isIntrabarAlertEnabled()
                && klineProperties.isEnabled();
    }

    private boolean isStrategySymbol(String pair) {
        return symbolWhitelist.contains(pair)
                || symbolEligibilityService.isEligible(pair);
    }

    private MarketKline toMarketKline(
            ContinuousContractKlineCandlestickStreamsResponse event,
            ContinuousContractKlineCandlestickStreamsResponseK kline
    ) {
        MarketKline entity = new MarketKline();
        entity.setExchange(klineProperties.getExchange());
        entity.setMarketType(klineProperties.getMarketType());
        entity.setContractType(upper(valueOrDefault(event.getCt(), "PERPETUAL")));
        entity.setPair(upper(event.getPs()));
        entity.setIntervalCode(normalize(kline.getiLowerCase()));
        entity.setOpenTimeMs(kline.gettLowerCase());
        entity.setCloseTimeMs(kline.getT());
        entity.setEventTimeMs(event.getE());
        entity.setOpenPrice(decimal(kline.getoLowerCase()));
        entity.setHighPrice(decimal(kline.gethLowerCase()));
        entity.setLowPrice(decimal(kline.getlLowerCase()));
        entity.setClosePrice(decimal(kline.getcLowerCase()));
        entity.setVolume(decimal(kline.getvLowerCase()));
        entity.setQuoteVolume(decimal(kline.getqLowerCase()));
        entity.setTradeCount(kline.getnLowerCase());
        entity.setTakerBuyVolume(decimal(kline.getV()));
        entity.setTakerBuyQuoteVolume(decimal(kline.getQ()));
        entity.setClosedState(Boolean.TRUE.equals(kline.getxLowerCase()) ? 1 : 0);
        entity.setSourceInterval(MarketKlineService.INTERVAL_1M);
        return entity;
    }

    private BigDecimal decimal(String value) {
        return StringUtils.hasText(value) ? new BigDecimal(value) : BigDecimal.ZERO;
    }

    private String normalize(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    private String upper(String value) {
        return value == null ? "" : value.trim().toUpperCase(Locale.ROOT);
    }

    private String valueOrDefault(String value, String defaultValue) {
        return StringUtils.hasText(value) ? value : defaultValue;
    }

    private static final class Slot {

        private final AtomicReference<MarketKline> latest = new AtomicReference<>();

        private final AtomicBoolean running = new AtomicBoolean();

        private volatile long lastAnalyzedAt;

        private AtomicReference<MarketKline> latest() {
            return latest;
        }

        private AtomicBoolean running() {
            return running;
        }

        private long lastAnalyzedAt() {
            return lastAnalyzedAt;
        }

        private void lastAnalyzedAt(long value) {
            lastAnalyzedAt = value;
        }
    }
}
