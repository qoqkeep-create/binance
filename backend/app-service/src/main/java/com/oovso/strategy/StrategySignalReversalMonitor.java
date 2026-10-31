package com.oovso.strategy;

import com.oovso.market.MarketClosedKlineEvent;
import com.oovso.market.MarketKline;
import com.oovso.market.MarketKlineMapper;
import com.oovso.market.MarketKlineService;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

@Component
public class StrategySignalReversalMonitor {

    private static final Logger log = LoggerFactory.getLogger(
            StrategySignalReversalMonitor.class
    );

    private static final int SECONDARY_ALERT_HISTORY_SIZE = 1_500;

    private final StrategySignalMapper signalMapper;

    private final MarketKlineMapper klineMapper;

    private final CandlestickPatternDetector patternDetector;

    private final MacdMomentumDecayDetector macdMomentumDecayDetector;

    private final ReversalAlertStateService stateService;

    private final List<ReversalAlertHandler> handlers;

    public StrategySignalReversalMonitor(
            StrategySignalMapper signalMapper,
            MarketKlineMapper klineMapper,
            CandlestickPatternDetector patternDetector,
            MacdMomentumDecayDetector macdMomentumDecayDetector,
            ReversalAlertStateService stateService,
            List<ReversalAlertHandler> handlers
    ) {
        this.signalMapper = signalMapper;
        this.klineMapper = klineMapper;
        this.patternDetector = patternDetector;
        this.macdMomentumDecayDetector = macdMomentumDecayDetector;
        this.stateService = stateService;
        this.handlers = handlers;
    }

    @Async("marketKlineEventExecutor")
    @EventListener
    public void onMarketClosedKline(MarketClosedKlineEvent event) {
        MarketKline kline = event.kline();
        if (!MarketKlineService.INTERVAL_15M.equals(kline.getIntervalCode())
                && !MarketKlineService.INTERVAL_1H.equals(
                        kline.getIntervalCode()
                )) {
            return;
        }

        List<StrategySignalReversalWatch> watches =
                signalMapper.selectActiveReversalWatches(
                        kline.getExchange(),
                        kline.getMarketType(),
                        kline.getContractType(),
                        kline.getPair(),
                        kline.getIntervalCode()
                );
        if (watches.isEmpty()) {
            return;
        }

        List<MarketKline> history = klineMapper.selectLatestClosed(
                        kline.getExchange(),
                        kline.getMarketType(),
                        kline.getContractType(),
                        kline.getPair(),
                        kline.getIntervalCode(),
                        SECONDARY_ALERT_HISTORY_SIZE
                ).stream()
                .sorted(Comparator.comparing(MarketKline::getOpenTimeMs))
                .toList();
        if (history.isEmpty()
                || !history.getLast().getOpenTimeMs().equals(
                        kline.getOpenTimeMs()
                )) {
            return;
        }

        int lastIndex = history.size() - 1;
        Map<TrendDirection, CandlestickPatternDetector.PatternMatch> matches =
                new EnumMap<>(TrendDirection.class);
        MacdMomentumDecayDetector.DecayMatch macdDecay =
                macdMomentumDecayDetector.detectDecay(history, lastIndex);
        for (StrategySignalReversalWatch watch : watches) {
            TrendDirection direction;
            try {
                direction = TrendDirection.valueOf(watch.getDirection());
            } catch (IllegalArgumentException exception) {
                log.warn(
                        "Skip invalid reversal alert direction signalId={} direction={}",
                        watch.getSignalId(),
                        watch.getDirection()
                );
                continue;
            }
            if (watch.getRequestedTimeMs() == null
                    || kline.getCloseTimeMs() == null
                    || kline.getCloseTimeMs() <= watch.getRequestedTimeMs()) {
                continue;
            }
            if (!matches.containsKey(direction)) {
                matches.put(
                        direction,
                        patternDetector.detectConfirmedReversal(
                                history,
                                lastIndex,
                                direction
                        )
                );
            }
            CandlestickPatternDetector.PatternMatch pattern =
                    matches.get(direction);
            ReversalAlert alert;
            if (pattern != null) {
                alert = ReversalAlert.from(watch, kline, pattern);
            } else {
                if (macdDecay == null) {
                    continue;
                }
                alert = ReversalAlert.from(watch, kline, macdDecay);
            }
            if (!stateService.claim(alert)) {
                continue;
            }
            log.info(
                    "STRATEGY_SECONDARY_ALERT_TRIGGERED userId={} signalId={} pair={} sourceInterval={} monitorInterval={} direction={} trigger={} triggerOpenTime={}",
                    alert.userId(),
                    alert.sourceSignalId(),
                    alert.symbol(),
                    alert.intervalCode(),
                    kline.getIntervalCode(),
                    alert.direction(),
                    alert.patternCode(),
                    alert.triggerOpenTimeMs()
            );
            notifyHandlers(alert);
        }
    }

    private void notifyHandlers(ReversalAlert alert) {
        for (ReversalAlertHandler handler : handlers) {
            try {
                handler.onReversalAlert(alert);
            } catch (Exception exception) {
                log.warn(
                        "Reversal alert handler {} failed userId={} signalId={}",
                        handler.getClass().getName(),
                        alert.userId(),
                        alert.sourceSignalId(),
                        exception
                );
            }
        }
    }
}
