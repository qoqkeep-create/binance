package com.oovso.trading;

import com.oovso.trading.TradingAccountService.AccountView;
import com.oovso.trading.TradingAccountService.PositionRealizedFillView;
import com.oovso.trading.TradingAccountService.PositionView;
import com.oovso.trading.TradingPositionHistoryProjector.HistoryPosition;
import com.oovso.trading.TradingPositionHistoryProjector.OpenPosition;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

@Service
public class TradingAccountQueryService {

    private static final int POSITION_HISTORY_SCAN_LIMIT = 10_000;

    private final TradingProperties properties;
    private final TradingAccountMapper accountMapper;
    private final TradingAccountBalanceMapper balanceMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final ExchangeFillMapper fillMapper;
    private final TradingAccountSessionManager sessionManager;

    public TradingAccountQueryService(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingAccountBalanceMapper balanceMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            ExchangeFillMapper fillMapper,
            TradingAccountSessionManager sessionManager
    ) {
        this.properties = properties;
        this.accountMapper = accountMapper;
        this.balanceMapper = balanceMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.fillMapper = fillMapper;
        this.sessionManager = sessionManager;
    }

    public AccountSnapshotView snapshot(String userId, String accountId) {
        TradingAccount account = requireOwned(userId, accountId);
        return new AccountSnapshotView(
                AccountView.from(account, canExecute(account)),
                balanceMapper.selectByAccount(accountId).stream()
                        .map(BalanceView::from)
                        .toList(),
                positionMapper.selectOpenByAccount(accountId).stream()
                        .map(PositionView::from)
                        .toList(),
                orderMapper.selectActiveByAccount(accountId).stream()
                        .map(OrderView::from)
                        .toList()
        );
    }

    public List<OrderView> orders(
            String userId,
            String accountId,
            int limit
    ) {
        requireOwned(userId, accountId);
        return orderMapper.selectRecentByAccount(accountId, boundedLimit(limit))
                .stream()
                .map(OrderView::from)
                .toList();
    }

    public PositionCenterView positionCenter(
            String userId,
            String accountId,
            int historyLimit
    ) {
        TradingAccount account = requireOwned(userId, accountId);
        List<ExchangeFill> historyFills = fillMapper
                .selectRecentForPositionHistory(
                        accountId,
                        POSITION_HISTORY_SCAN_LIMIT
                );
        List<ExchangeOrder> activeMakerCloses = orderMapper
                .selectActiveManualClosesByAccount(accountId);
        if (activeMakerCloses == null) {
            activeMakerCloses = List.of();
        }
        Map<String, ExchangeOrder> makerCloses = activeMakerCloses
                .stream()
                .collect(Collectors.toMap(
                        TradingAccountQueryService::positionGenerationKey,
                        Function.identity(),
                        (first, ignored) -> first
                ));
        Map<String, OpenPosition> openCycles = TradingPositionHistoryProjector
                .projectOpen(historyFills)
                .stream()
                .collect(Collectors.toMap(
                        TradingAccountQueryService::positionCycleKey,
                        Function.identity(),
                        (first, ignored) -> first
                ));
        return new PositionCenterView(
                account.getId(),
                account.getQuoteAsset(),
                account.getTotalMarginBalance() == null
                        ? BigDecimal.ZERO
                        : account.getTotalMarginBalance(),
                account.getSyncStatus(),
                System.currentTimeMillis(),
                positionMapper.selectOpenByAccount(accountId).stream()
                        .map(position -> positionView(
                                accountId,
                                position,
                                makerCloses.get(positionGenerationKey(position)),
                                openCycles.get(positionCycleKey(position))
                        ))
                        .toList(),
                orderMapper.selectActiveLimitByAccount(accountId).stream()
                        .map(OrderView::from)
                        .toList(),
                TradingPositionHistoryProjector.project(
                        historyFills,
                        Math.max(1, Math.min(200, historyLimit))
                ),
                historyFills.size() >= POSITION_HISTORY_SCAN_LIMIT
        );
    }

    private PositionView positionView(
            String accountId,
            TradingPosition position,
            ExchangeOrder makerClose,
            OpenPosition openCycle
    ) {
        List<ExchangeOrder> protectionOrders = orderMapper
                .selectActivePositionProtection(
                        accountId,
                        position.getSymbol(),
                        position.getPositionSide()
                );
        if (protectionOrders == null) {
            protectionOrders = List.of();
        }
        return PositionView.from(
                position,
                makerClose,
                protectionPrices(protectionOrders, true),
                protectionPrices(protectionOrders, false),
                openCycle == null
                        ? BigDecimal.ZERO
                        : openCycle.realizedPnl(),
                openCycle == null
                        ? List.of()
                        : openCycle.fills().stream()
                                .map(PositionRealizedFillView::from)
                                .toList()
        );
    }

    private List<BigDecimal> protectionPrices(
            List<ExchangeOrder> orders,
            boolean takeProfit
    ) {
        List<BigDecimal> prices = new ArrayList<>();
        for (ExchangeOrder order : orders) {
            if (isTakeProfit(order) != takeProfit) {
                continue;
            }
            BigDecimal price = positive(order.getTriggerPrice())
                    ? order.getTriggerPrice()
                    : order.getPrice();
            if (!positive(price) || prices.stream().anyMatch(
                    existing -> existing.compareTo(price) == 0
            )) {
                continue;
            }
            prices.add(price);
        }
        return List.copyOf(prices);
    }

    private boolean isTakeProfit(ExchangeOrder order) {
        String purpose = text(order.getPurpose()).toUpperCase(Locale.ROOT);
        String type = text(order.getOrderType()).toUpperCase(Locale.ROOT);
        return "TAKE_PROFIT".equals(purpose)
                || type.startsWith("TAKE_PROFIT");
    }

    private boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    private String text(String value) {
        return value == null ? "" : value;
    }

    public List<FillView> fills(
            String userId,
            String accountId,
            int limit
    ) {
        requireOwned(userId, accountId);
        return fillMapper.selectRecentByAccount(accountId, boundedLimit(limit))
                .stream()
                .map(FillView::from)
                .toList();
    }

    public ReconcileAccepted requestReconcile(
            String userId,
            String accountId
    ) {
        TradingAccount account = requireOwned(userId, accountId);
        if (!properties.getSync().isEnabled()) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "服务器账户监听尚未启用"
            );
        }
        if (!"ACTIVE".equals(account.getStatus())
                && !"PAUSED".equals(account.getStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "交易凭证不可用，请重新绑定后再对账"
            );
        }
        if (!sessionManager.requestReconcile(accountId)) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "账户同步会话暂时不可用"
            );
        }
        return new ReconcileAccepted(
                accountId,
                "REQUESTED",
                System.currentTimeMillis()
        );
    }

    private TradingAccount requireOwned(String userId, String accountId) {
        if (!properties.isEnabled()) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "服务器交易账户功能未启用"
            );
        }
        TradingAccount account = accountMapper.selectOwned(accountId, userId);
        if (account == null) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "交易账户不存在或尚未绑定"
            );
        }
        return account;
    }

    private int boundedLimit(int limit) {
        return Math.max(1, Math.min(500, limit));
    }

    private boolean canExecute(TradingAccount account) {
        return properties.getSync().isEnabled()
                && "ACTIVE".equals(account.getStatus())
                && TradingSyncStatus.SYNCED.name().equals(
                        account.getSyncStatus()
                );
    }

    private static String positionGenerationKey(TradingPosition position) {
        return position.getId() + ":" + position.getGeneration();
    }

    private static String positionGenerationKey(ExchangeOrder order) {
        return order.getTradingPositionId()
                + ":"
                + order.getPositionGeneration();
    }

    private static String positionCycleKey(TradingPosition position) {
        return position.getSymbol().toUpperCase(Locale.ROOT)
                + ":"
                + normalizedPositionSide(position.getPositionSide());
    }

    private static String positionCycleKey(OpenPosition position) {
        return position.symbol().toUpperCase(Locale.ROOT)
                + ":"
                + normalizedPositionSide(position.positionSide());
    }

    private static String normalizedPositionSide(String value) {
        String normalized = value == null
                ? ""
                : value.toUpperCase(Locale.ROOT);
        return switch (normalized) {
            case "LONG", "SHORT" -> normalized;
            default -> "BOTH";
        };
    }

    public record AccountSnapshotView(
            AccountView account,
            List<BalanceView> balances,
            List<PositionView> positions,
            List<OrderView> activeOrders
    ) {
    }

    public record PositionCenterView(
            String accountId,
            String quoteAsset,
            BigDecimal totalMarginBalance,
            String syncStatus,
            long updatedAtMillis,
            List<PositionView> positions,
            List<OrderView> limitOrders,
            List<HistoryPosition> historyPositions,
            boolean historyTruncated
    ) {
    }

    public record BalanceView(
            String asset,
            BigDecimal walletBalance,
            BigDecimal crossWalletBalance,
            BigDecimal balanceChange,
            long lastEventMillis,
            long snapshotRevision
    ) {
        static BalanceView from(TradingAccountBalance balance) {
            return new BalanceView(
                    balance.getAsset(),
                    balance.getWalletBalance(),
                    balance.getCrossWalletBalance(),
                    balance.getBalanceChange(),
                    value(balance.getLastEventMs()),
                    value(balance.getLastReconcileRevision())
            );
        }
    }

    public record OrderView(
            String id,
            String orderClass,
            String origin,
            String purpose,
            String symbol,
            String side,
            String positionSide,
            String orderType,
            String clientOrderId,
            String exchangeOrderId,
            String clientAlgoId,
            String exchangeAlgoId,
            String actualOrderId,
            BigDecimal quantity,
            BigDecimal price,
            BigDecimal triggerPrice,
            BigDecimal executedQuantity,
            BigDecimal averagePrice,
            boolean reduceOnly,
            boolean closePosition,
            String status,
            String exchangeStatus,
            String executionType,
            String rejectReason,
            long exchangeUpdateMillis,
            long snapshotRevision,
            boolean entryCancelable
    ) {
        static OrderView from(ExchangeOrder order) {
            return new OrderView(
                    order.getId(),
                    order.getOrderClass(),
                    order.getOrigin(),
                    order.getPurpose(),
                    order.getSymbol(),
                    order.getSide(),
                    order.getPositionSide(),
                    order.getOrderType(),
                    order.getClientOrderId(),
                    order.getExchangeOrderId(),
                    order.getClientAlgoId(),
                    order.getExchangeAlgoId(),
                    order.getActualOrderId(),
                    order.getQuantity(),
                    order.getPrice(),
                    order.getTriggerPrice(),
                    order.getExecutedQuantity(),
                    order.getAveragePrice(),
                    Integer.valueOf(1).equals(order.getReduceOnly()),
                    Integer.valueOf(1).equals(order.getClosePosition()),
                    order.getStatus(),
                    order.getExchangeStatus(),
                    order.getExecutionType(),
                    order.getRejectReason(),
                    value(order.getExchangeUpdateMs()),
                    value(order.getLastReconcileRevision()),
                    isEntryCancelable(order)
            );
        }

        private static boolean isEntryCancelable(ExchangeOrder order) {
            return "REGULAR".equals(order.getOrderClass())
                    && "SYSTEM".equals(order.getOrigin())
                    && "ENTRY".equals(order.getPurpose())
                    && "LIMIT".equals(order.getOrderType())
                    && order.getClientOrderId() != null
                    && !order.getClientOrderId().isBlank()
                    && TradingOrderStateMachine.isRegularActive(
                            order.getStatus()
                    );
        }
    }

    public record FillView(
            String id,
            String symbol,
            String tradeId,
            String orderId,
            String side,
            String positionSide,
            BigDecimal price,
            BigDecimal quantity,
            BigDecimal quoteQuantity,
            BigDecimal commission,
            String commissionAsset,
            BigDecimal realizedPnl,
            boolean maker,
            long tradeTimeMillis
    ) {
        static FillView from(ExchangeFill fill) {
            return new FillView(
                    fill.getId(),
                    fill.getSymbol(),
                    fill.getTradeId(),
                    fill.getOrderId(),
                    fill.getSide(),
                    fill.getPositionSide(),
                    fill.getPrice(),
                    fill.getQuantity(),
                    fill.getQuoteQuantity(),
                    fill.getCommission(),
                    fill.getCommissionAsset(),
                    fill.getRealizedPnl(),
                    Integer.valueOf(1).equals(fill.getMaker()),
                    value(fill.getTradeTimeMs())
            );
        }
    }

    public record ReconcileAccepted(
            String accountId,
            String status,
            long requestedAtMillis
    ) {
    }

    private static long value(Long value) {
        return value == null ? 0L : value;
    }
}
