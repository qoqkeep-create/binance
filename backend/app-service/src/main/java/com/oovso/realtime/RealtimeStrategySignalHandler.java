package com.oovso.realtime;

import com.oovso.strategy.ReversalAlert;
import com.oovso.strategy.ReversalAlertHandler;
import com.oovso.strategy.StrategySignal;
import com.oovso.strategy.StrategySignalHandler;
import java.math.BigDecimal;
import org.springframework.stereotype.Component;

@Component
public class RealtimeStrategySignalHandler
        implements StrategySignalHandler, ReversalAlertHandler {

    private final RealtimeEventPublisher eventPublisher;

    public RealtimeStrategySignalHandler(RealtimeEventPublisher eventPublisher) {
        this.eventPublisher = eventPublisher;
    }

    @Override
    public void onSignal(StrategySignal signal) {
        StrategySignalPayload payload = StrategySignalPayload.from(signal);
        eventPublisher.publishPublic(
                RealtimeProtocol.CHANNEL_STRATEGY_SIGNAL,
                "created",
                payload.symbol(),
                payload.symbol(),
                payload.interval(),
                payload
        );
    }

    @Override
    public void onReversalAlert(ReversalAlert alert) {
        eventPublisher.publishToUser(
                alert.userId(),
                RealtimeProtocol.CHANNEL_STRATEGY_SIGNAL,
                "reversalTriggered",
                alert.sourceSignalId(),
                alert.symbol(),
                alert.intervalCode(),
                ReversalAlertPayload.from(alert)
        );
    }

    public record ReversalAlertPayload(
            String sourceSignalId,
            String symbol,
            String interval,
            String direction,
            long signalTime,
            long triggerOpenTime,
            BigDecimal price,
            String patternCode,
            String patternName
    ) {

        static ReversalAlertPayload from(ReversalAlert alert) {
            return new ReversalAlertPayload(
                    alert.sourceSignalId(),
                    alert.symbol(),
                    alert.intervalCode(),
                    alert.direction(),
                    alert.triggeredTimeMs(),
                    alert.triggerOpenTimeMs(),
                    alert.triggerPrice(),
                    alert.patternCode(),
                    alert.patternName()
            );
        }
    }

    public record StrategySignalPayload(
            String id,
            String symbol,
            String contractType,
            String interval,
            String strategyCode,
            String direction,
            long signalTime,
            long triggerOpenTime,
            BigDecimal price,
            BigDecimal score,
            String patternCode,
            String reasonJson
    ) {

        static StrategySignalPayload from(StrategySignal signal) {
            return new StrategySignalPayload(
                    signal.getId(),
                    signal.getPair(),
                    signal.getContractType(),
                    signal.getIntervalCode(),
                    signal.getStrategyCode(),
                    signal.getDirection(),
                    value(signal.getSignalTimeMs()),
                    value(signal.getTriggerOpenTimeMs()),
                    signal.getPrice(),
                    signal.getScore(),
                    signal.getPatternCode(),
                    signal.getReasonJson()
            );
        }

        private static long value(Long value) {
            return value == null ? 0 : value;
        }
    }
}
