package com.oovso.strategy;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ReversalAlertStateService {

    private final StrategySignalMapper signalMapper;

    public ReversalAlertStateService(StrategySignalMapper signalMapper) {
        this.signalMapper = signalMapper;
    }

    @Transactional
    public boolean claim(ReversalAlert alert) {
        return signalMapper.claimReversalTrigger(
                alert.userId(),
                alert.sourceSignalId(),
                alert.triggeredTimeMs(),
                alert.triggerOpenTimeMs(),
                alert.patternCode()
        ) == 1;
    }
}
