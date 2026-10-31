package com.oovso.trading;

import com.oovso.realtime.RealtimeProtocol;
import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class TradingExchangeEventReducer {

    private final TradingAccountMapper accountMapper;
    private final TradingExchangeEventMapper eventMapper;
    private final TradingMirrorService mirrorService;
    private final TradingOutboxService outboxService;
    private final TransactionTemplate transactionTemplate;

    public TradingExchangeEventReducer(
            TradingAccountMapper accountMapper,
            TradingExchangeEventMapper eventMapper,
            TradingMirrorService mirrorService,
            TradingOutboxService outboxService,
            PlatformTransactionManager transactionManager
    ) {
        this.accountMapper = accountMapper;
        this.eventMapper = eventMapper;
        this.mirrorService = mirrorService;
        this.outboxService = outboxService;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    public boolean apply(
            String accountId,
            long fenceToken,
            TradingUserStreamEvent event
    ) {
        Boolean applied = transactionTemplate.execute(status -> applyInTransaction(
                accountId,
                fenceToken,
                event
        ));
        return Boolean.TRUE.equals(applied);
    }

    private boolean applyInTransaction(
            String accountId,
            long fenceToken,
            TradingUserStreamEvent event
    ) {
        if (accountMapper.isFenceCurrent(accountId, fenceToken) != 1) {
            throw new StaleTradingAccountWorkerException(accountId);
        }
        TradingAccount account = accountMapper.selectListenableById(accountId);
        if (account == null) {
            throw new StaleTradingAccountWorkerException(accountId);
        }
        TradingExchangeEvent inbox = inbox(accountId, event);
        if (eventMapper.insertIgnore(inbox) != 1) {
            return false;
        }

        switch (event.kind()) {
            case ACCOUNT_UPDATE -> applyAccountUpdate(account, event);
            case REGULAR_ORDER_UPDATE, ALGO_ORDER_UPDATE -> applyOrderUpdate(
                    account,
                    event
            );
            case LISTEN_KEY_EXPIRED, RISK_OR_CONFIG, UNKNOWN -> enqueueControl(
                    account,
                    event
            );
        }
        accountMapper.markStreamEvent(
                accountId,
                fenceToken,
                event.eventTimeMillis() > 0
                        ? event.eventTimeMillis()
                        : event.receivedAtMillis()
        );
        eventMapper.updateAppliedState(inbox.getId(), "APPLIED");
        return true;
    }

    private void applyAccountUpdate(
            TradingAccount account,
            TradingUserStreamEvent event
    ) {
        event.balances().forEach(balance -> mirrorService.upsertBalance(
                account,
                balance.asset(),
                balance.walletBalance(),
                balance.crossWalletBalance(),
                balance.balanceChange(),
                event.eventTimeMillis(),
                0
        ));
        event.positions().forEach(position -> mirrorService.mergeEventPosition(
                account,
                position,
                Math.max(event.transactionTimeMillis(), event.eventTimeMillis())
        ));
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("accountId", account.getId());
        payload.put("reason", event.reason());
        payload.put("eventTimeMillis", event.eventTimeMillis());
        payload.put("balanceCount", event.balances().size());
        payload.put("positionCount", event.positions().size());
        outboxService.enqueue(
                account,
                RealtimeProtocol.CHANNEL_TRADING_ACCOUNT,
                "updated",
                account.getId(),
                null,
                payload
        );
    }

    private void applyOrderUpdate(
            TradingAccount account,
            TradingUserStreamEvent event
    ) {
        ExchangeOrder order = mirrorService.mergeOrder(
                account,
                event.order(),
                event.reason(),
                event.rejectReason(),
                Math.max(event.transactionTimeMillis(), event.eventTimeMillis()),
                0,
                true
        );
        mirrorService.mergeFill(account, event.fill(), order, true);
    }

    private void enqueueControl(
            TradingAccount account,
            TradingUserStreamEvent event
    ) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("accountId", account.getId());
        payload.put("eventType", event.eventType());
        payload.put("eventTimeMillis", event.eventTimeMillis());
        if (event.rejectReason() != null) {
            payload.put("reason", event.rejectReason());
        }
        outboxService.enqueue(
                account,
                RealtimeProtocol.CHANNEL_TRADING_ACCOUNT,
                "notice",
                account.getId(),
                null,
                payload
        );
    }

    private TradingExchangeEvent inbox(
            String accountId,
            TradingUserStreamEvent event
    ) {
        TradingExchangeEvent inbox = new TradingExchangeEvent();
        inbox.setId(UUID.randomUUID().toString());
        inbox.setCreateTime(LocalDateTime.now());
        inbox.setTradingAccountId(accountId);
        inbox.setEventType(event.eventType());
        inbox.setEventHash(event.eventHash());
        inbox.setExchangeEventMs(event.eventTimeMillis());
        inbox.setTransactionMs(event.transactionTimeMillis());
        inbox.setReceivedAtMs(event.receivedAtMillis());
        inbox.setEntityKey(event.entityKey());
        inbox.setNormalizedSummary(event.normalizedSummary());
        inbox.setAppliedState("RECEIVED");
        return inbox;
    }

    public static final class StaleTradingAccountWorkerException
            extends RuntimeException {

        StaleTradingAccountWorkerException(String accountId) {
            super("Trading account worker lost its fence: " + accountId);
        }
    }
}
