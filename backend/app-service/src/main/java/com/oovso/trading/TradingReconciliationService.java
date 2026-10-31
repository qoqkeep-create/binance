package com.oovso.trading;

import com.oovso.realtime.RealtimeProtocol;
import com.oovso.trading.BinanceUsdmPrivateGateway.FillSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.PositionSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.ReconciliationSnapshot;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class TradingReconciliationService {

    private final BinanceUsdmPrivateGateway gateway;
    private final TradingAccountMapper accountMapper;
    private final TradingAccountBalanceMapper balanceMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final TradingMirrorService mirrorService;
    private final TradingOutboxService outboxService;
    private final TransactionTemplate transactionTemplate;

    public TradingReconciliationService(
            BinanceUsdmPrivateGateway gateway,
            TradingAccountMapper accountMapper,
            TradingAccountBalanceMapper balanceMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            TradingMirrorService mirrorService,
            TradingOutboxService outboxService,
            PlatformTransactionManager transactionManager
    ) {
        this.gateway = gateway;
        this.accountMapper = accountMapper;
        this.balanceMapper = balanceMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.mirrorService = mirrorService;
        this.outboxService = outboxService;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    public ReconciliationReport reconcile(
            String accountId,
            long fenceToken,
            BinanceCredentials credentials,
            boolean fullDiscovery,
            boolean gapRecovery
    ) {
        TradingAccount before = requireCurrentAccount(accountId, fenceToken);
        List<ExchangeOrder> activeBefore = fullDiscovery
                ? orderMapper.selectActiveByAccount(accountId)
                : List.of();
        ReconciliationSnapshot snapshot = gateway.reconciliationSnapshot(
                credentials,
                before.getQuoteAsset(),
                fullDiscovery
        );
        Resolution resolution = fullDiscovery
                ? resolveMissingOrdersAndFills(
                        credentials,
                        before,
                        snapshot,
                        activeBefore
                )
                : Resolution.empty(snapshot);

        ReconciliationReport report = transactionTemplate.execute(status ->
                applySnapshot(
                        accountId,
                        fenceToken,
                        snapshot,
                        resolution,
                        fullDiscovery,
                        gapRecovery
                )
        );
        if (report == null) {
            throw new IllegalStateException("Trading reconciliation rolled back");
        }
        return report;
    }

    private Resolution resolveMissingOrdersAndFills(
            BinanceCredentials credentials,
            TradingAccount account,
            ReconciliationSnapshot snapshot,
            List<ExchangeOrder> activeBefore
    ) {
        List<OrderSnapshot> regular = new ArrayList<>(
                snapshot.regularOpenOrders()
        );
        List<OrderSnapshot> algo = new ArrayList<>(snapshot.algoOpenOrders());
        Set<String> regularKeys = identityKeys(regular);
        Set<String> algoKeys = identityKeys(algo);
        List<String> unresolved = new ArrayList<>();
        Set<String> knownSymbols = new HashSet<>();
        snapshot.positions().forEach(position ->
                knownSymbols.add(position.symbol())
        );
        regular.forEach(order -> knownSymbols.add(order.symbol()));
        algo.forEach(order -> knownSymbols.add(order.symbol()));
        activeBefore.forEach(order -> knownSymbols.add(order.getSymbol()));

        long now = System.currentTimeMillis();
        long start = account.getLastReconciledAtMs() == null
                ? now - java.time.Duration.ofDays(7).toMillis() + 1
                : Math.max(
                        now - java.time.Duration.ofDays(7).toMillis() + 1,
                        account.getLastReconciledAtMs() - 60_000
                );
        knownSymbols.stream()
                .filter(symbol -> symbol != null && !symbol.isBlank())
                .sorted()
                .forEach(symbol -> regular.addAll(
                        gateway.recentRegularOrders(
                                credentials,
                                symbol,
                                start
                        )
                ));
        regularKeys.addAll(identityKeys(regular));

        for (ExchangeOrder local : activeBefore) {
            knownSymbols.add(local.getSymbol());
            if (containsIdentity(
                    "ALGO".equals(local.getOrderClass())
                            ? algoKeys
                            : regularKeys,
                    local
            )) {
                continue;
            }
            Optional<OrderSnapshot> resolved = "ALGO".equals(
                    local.getOrderClass()
            )
                    ? gateway.queryAlgoOrder(
                            credentials,
                            local.getClientAlgoId(),
                            local.getExchangeAlgoId()
                    )
                    : gateway.queryRegularOrder(
                            credentials,
                            local.getSymbol(),
                            local.getClientOrderId(),
                            local.getExchangeOrderId()
                    );
            if (resolved.isPresent()) {
                if ("ALGO".equals(local.getOrderClass())) {
                    algo.add(resolved.get());
                    algoKeys.addAll(identityKeys(List.of(resolved.get())));
                } else {
                    regular.add(resolved.get());
                    regularKeys.addAll(identityKeys(List.of(resolved.get())));
                }
            } else {
                unresolved.add(local.getId());
            }
        }

        for (OrderSnapshot algoOrder : List.copyOf(algo)) {
            if (!"FINISHED".equalsIgnoreCase(algoOrder.exchangeStatus())
                    || algoOrder.actualOrderId() == null
                    || algoOrder.symbol() == null) {
                continue;
            }
            gateway.queryRegularOrder(
                    credentials,
                    algoOrder.symbol(),
                    null,
                    algoOrder.actualOrderId()
            ).ifPresent(regular::add);
        }

        List<FillSnapshot> fills = new ArrayList<>();
        knownSymbols.stream()
                .filter(symbol -> symbol != null && !symbol.isBlank())
                .sorted()
                .forEach(symbol -> fills.addAll(gateway.userTrades(
                        credentials,
                        symbol,
                        start
                )));
        return new Resolution(
                List.copyOf(regular),
                List.copyOf(algo),
                List.copyOf(fills),
                List.copyOf(unresolved)
        );
    }

    private ReconciliationReport applySnapshot(
            String accountId,
            long fenceToken,
            ReconciliationSnapshot snapshot,
            Resolution resolution,
            boolean fullDiscovery,
            boolean gapRecovery
    ) {
        TradingAccount account = requireCurrentAccount(accountId, fenceToken);
        long revision = (account.getReconcileRevision() == null
                ? 0
                : account.getReconcileRevision()) + 1;
        if (accountMapper.updateReconciledSnapshot(
                accountId,
                fenceToken,
                snapshot.asset(),
                snapshot.positionMode(),
                snapshot.totalMarginBalance(),
                snapshot.unrealizedProfit(),
                snapshot.syncedAtMillis(),
                revision,
                fullDiscovery ? 1 : 0
        ) != 1) {
            throw new TradingExchangeEventReducer
                    .StaleTradingAccountWorkerException(accountId);
        }
        account.setQuoteAsset(snapshot.asset());
        account.setPositionMode(snapshot.positionMode());
        account.setTotalMarginBalance(snapshot.totalMarginBalance());
        account.setUnrealizedProfit(snapshot.unrealizedProfit());
        account.setReconcileRevision(revision);
        account.setLastReconciledAtMs(snapshot.syncedAtMillis());

        snapshot.balances().forEach(balance -> mirrorService.upsertBalance(
                account,
                balance.asset(),
                balance.walletBalance(),
                balance.crossWalletBalance(),
                BigDecimal.ZERO,
                0,
                revision
        ));

        List<TradingPosition> stored = positionMapper.selectByAccount(accountId);
        Map<PositionKey, TradingPosition> storedByKey = new HashMap<>();
        stored.forEach(position -> storedByKey.put(
                PositionKey.from(position),
                position
        ));
        Set<PositionKey> seen = new HashSet<>();
        for (PositionSnapshot positionSnapshot : snapshot.positions()) {
            PositionKey key = new PositionKey(
                    positionSnapshot.symbol(),
                    positionSnapshot.positionSide()
            );
            seen.add(key);
            TradingPosition merged = mirrorService.mergeRestPosition(
                    account,
                    positionSnapshot,
                    revision
            );
            TradingPosition previous = storedByKey.get(key);
            if (gapRecovery && previous != null
                    && "OPEN".equals(previous.getStatus())
                    && previous.getQuantity() != null
                    && previous.getQuantity().signum() != 0
                    && positionSnapshot.quantity().signum() != 0
                    && previous.getQuantity().signum()
                    == positionSnapshot.quantity().signum()) {
                positionMapper.markContinuityUncertain(
                        merged.getId(),
                        accountId
                );
            }
        }
        for (TradingPosition position : stored) {
            if ("OPEN".equals(position.getStatus())
                    && !seen.contains(PositionKey.from(position))) {
                positionMapper.closeByIdAtRevision(
                        position.getId(),
                        accountId,
                        revision
                );
            }
        }

        if (fullDiscovery) {
            resolution.regularOrders().forEach(order ->
                    mirrorService.mergeOrder(
                            account,
                            order,
                            "REST_RECONCILE",
                            null,
                            order.updateTimeMillis(),
                            revision,
                            true
                    )
            );
            resolution.algoOrders().forEach(order ->
                    mirrorService.mergeOrder(
                            account,
                            order,
                            "REST_RECONCILE",
                            null,
                            order.updateTimeMillis(),
                            revision,
                            true
                    )
            );
            resolution.unresolvedOrderIds().forEach(orderId ->
                    orderMapper.markUnresolved(orderId, revision)
            );
            resolution.fills().forEach(fill -> {
                ExchangeOrder order = fill.orderId() == null
                        ? null
                        : orderMapper.selectRegularByExchangeId(
                                accountId,
                                fill.orderId()
                        );
                mirrorService.mergeFill(account, fill, order, true);
            });
        }

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("accountId", accountId);
        payload.put("syncStatus", TradingSyncStatus.RECONCILING.name());
        payload.put("snapshotRevision", revision);
        payload.put("reconciledAtMillis", snapshot.syncedAtMillis());
        payload.put("fullDiscovery", fullDiscovery);
        outboxService.enqueue(
                account,
                RealtimeProtocol.CHANNEL_TRADING_ACCOUNT,
                "reconciled",
                accountId,
                null,
                payload
        );
        return new ReconciliationReport(
                revision,
                snapshot.syncedAtMillis(),
                snapshot.positions().size(),
                resolution.regularOrders().size(),
                resolution.algoOrders().size(),
                resolution.fills().size(),
                resolution.unresolvedOrderIds().size()
        );
    }

    private TradingAccount requireCurrentAccount(
            String accountId,
            long fenceToken
    ) {
        if (accountMapper.isFenceCurrent(accountId, fenceToken) != 1) {
            throw new TradingExchangeEventReducer
                    .StaleTradingAccountWorkerException(accountId);
        }
        TradingAccount account = accountMapper.selectListenableById(accountId);
        if (account == null) {
            throw new TradingExchangeEventReducer
                    .StaleTradingAccountWorkerException(accountId);
        }
        return account;
    }

    private Set<String> identityKeys(List<OrderSnapshot> orders) {
        Set<String> keys = new HashSet<>();
        orders.forEach(order -> {
            addKey(keys, order.clientOrderId());
            addKey(keys, order.exchangeOrderId());
            addKey(keys, order.clientAlgoId());
            addKey(keys, order.exchangeAlgoId());
        });
        return keys;
    }

    private boolean containsIdentity(Set<String> keys, ExchangeOrder order) {
        return contains(keys, order.getClientOrderId())
                || contains(keys, order.getExchangeOrderId())
                || contains(keys, order.getClientAlgoId())
                || contains(keys, order.getExchangeAlgoId());
    }

    private void addKey(Set<String> keys, String value) {
        if (value != null && !value.isBlank()) {
            keys.add(value);
        }
    }

    private boolean contains(Set<String> keys, String value) {
        return value != null && keys.contains(value);
    }

    private record PositionKey(String symbol, String positionSide) {
        static PositionKey from(TradingPosition position) {
            return new PositionKey(
                    position.getSymbol(),
                    position.getPositionSide()
            );
        }
    }

    private record Resolution(
            List<OrderSnapshot> regularOrders,
            List<OrderSnapshot> algoOrders,
            List<FillSnapshot> fills,
            List<String> unresolvedOrderIds
    ) {
        static Resolution empty(ReconciliationSnapshot snapshot) {
            return new Resolution(List.of(), List.of(), List.of(), List.of());
        }
    }

    public record ReconciliationReport(
            long revision,
            long reconciledAtMillis,
            int positionCount,
            int regularOrderCount,
            int algoOrderCount,
            int fillCount,
            int unresolvedOrderCount
    ) {
    }
}
