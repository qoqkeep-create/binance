package com.oovso.trading;

import com.oovso.realtime.RealtimeProtocol;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class TradingAccountSyncStateService {

    private final TradingAccountMapper accountMapper;
    private final TradingOutboxService outboxService;
    private final TradingProperties properties;
    private final TransactionTemplate transactionTemplate;

    public TradingAccountSyncStateService(
            TradingAccountMapper accountMapper,
            TradingOutboxService outboxService,
            TradingProperties properties,
            PlatformTransactionManager transactionManager
    ) {
        this.accountMapper = accountMapper;
        this.outboxService = outboxService;
        this.properties = properties;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    public void transition(
            String accountId,
            long fenceToken,
            TradingSyncStatus syncStatus,
            String errorCode,
            boolean failure
    ) {
        transactionTemplate.executeWithoutResult(status -> {
            if (accountMapper.updateSyncStatus(
                    accountId,
                    fenceToken,
                    syncStatus.name(),
                    sanitizeError(errorCode),
                    failure ? 1 : 0
            ) != 1) {
                throw new TradingExchangeEventReducer
                        .StaleTradingAccountWorkerException(accountId);
            }
            TradingAccount account = accountMapper.selectListenableById(accountId);
            if (account != null) {
                enqueue(account, syncStatus, errorCode);
            }
        });
    }

    public void streamConnected(
            String accountId,
            long fenceToken,
            long connectedAtMillis
    ) {
        transactionTemplate.executeWithoutResult(status -> {
            if (accountMapper.markStreamConnected(
                    accountId,
                    fenceToken,
                    connectedAtMillis
            ) != 1) {
                throw new TradingExchangeEventReducer
                        .StaleTradingAccountWorkerException(accountId);
            }
            TradingAccount account = accountMapper.selectListenableById(accountId);
            if (account != null) {
                enqueue(account, TradingSyncStatus.BUFFERING, null);
            }
        });
    }

    public void authenticationFailed(
            String accountId,
            long fenceToken,
            String errorCode
    ) {
        transactionTemplate.executeWithoutResult(status -> {
            if (accountMapper.isFenceCurrent(accountId, fenceToken) != 1) {
                throw new TradingExchangeEventReducer
                        .StaleTradingAccountWorkerException(accountId);
            }
            TradingAccount account = accountMapper.selectListenableById(accountId);
            if (account == null) {
                throw new TradingExchangeEventReducer
                        .StaleTradingAccountWorkerException(accountId);
            }
            enqueue(account, TradingSyncStatus.AUTH_FAILED, errorCode);
            if (accountMapper.markCredentialError(
                    accountId,
                    fenceToken,
                    sanitizeError(errorCode)
            ) != 1) {
                throw new TradingExchangeEventReducer
                        .StaleTradingAccountWorkerException(accountId);
            }
        });
    }

    private void enqueue(
            TradingAccount account,
            TradingSyncStatus status,
            String errorCode
    ) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("accountId", account.getId());
        payload.put("syncStatus", status.name());
        payload.put("lastStreamEventAtMillis", account.getLastStreamEventMs());
        payload.put("lastReconciledAtMillis", account.getLastReconciledAtMs());
        payload.put("degradedReason", sanitizeError(errorCode));
        payload.put("canExecute", canExecute(account, status));
        payload.put(
                "snapshotRevision",
                account.getReconcileRevision() == null
                        ? 0L
                        : account.getReconcileRevision()
        );
        outboxService.enqueue(
                account,
                RealtimeProtocol.CHANNEL_TRADING_ACCOUNT,
                "sync_status",
                account.getId(),
                null,
                payload
        );
    }

    private String sanitizeError(String errorCode) {
        if (errorCode == null || errorCode.isBlank()) {
            return null;
        }
        String normalized = errorCode.replaceAll("[^A-Za-z0-9_.-]", "_");
        return normalized.length() <= 64
                ? normalized
                : normalized.substring(0, 64);
    }

    private boolean canExecute(
            TradingAccount account,
            TradingSyncStatus status
    ) {
        return properties.isEnabled()
                && properties.getSync().isEnabled()
                && "ACTIVE".equals(account.getStatus())
                && TradingSyncStatus.SYNCED == status;
    }
}
