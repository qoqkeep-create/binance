package com.oovso.trading;

import com.oovso.realtime.RealtimeProtocol;
import com.oovso.trading.BinanceUsdmPrivateGateway.FillSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.PositionSnapshot;
import com.oovso.trading.TradingOrderStateMachine.MergeDecision;
import com.oovso.trading.TradingUserStreamEvent.PositionDelta;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.UUID;
import org.springframework.stereotype.Service;

@Service
public class TradingMirrorService {

    private final TradingAccountBalanceMapper balanceMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final ExchangeFillMapper fillMapper;
    private final TradingOutboxService outboxService;

    public TradingMirrorService(
            TradingAccountBalanceMapper balanceMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            ExchangeFillMapper fillMapper,
            TradingOutboxService outboxService
    ) {
        this.balanceMapper = balanceMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.fillMapper = fillMapper;
        this.outboxService = outboxService;
    }

    public TradingAccountBalance upsertBalance(
            TradingAccount account,
            String asset,
            BigDecimal walletBalance,
            BigDecimal crossWalletBalance,
            BigDecimal balanceChange,
            long eventMillis,
            long reconcileRevision
    ) {
        LocalDateTime now = LocalDateTime.now();
        TradingAccountBalance balance = new TradingAccountBalance();
        balance.setId(UUID.randomUUID().toString());
        balance.setCreateTime(now);
        balance.setUpdateTime(now);
        balance.setTradingAccountId(account.getId());
        balance.setAsset(asset);
        balance.setWalletBalance(nonNull(walletBalance));
        balance.setCrossWalletBalance(nonNull(crossWalletBalance));
        balance.setBalanceChange(nonNull(balanceChange));
        balance.setLastEventMs(Math.max(0, eventMillis));
        balance.setLastReconcileRevision(Math.max(0, reconcileRevision));
        balance.setVersion(0L);
        balanceMapper.upsert(balance);
        return balance;
    }

    public TradingPosition mergeRestPosition(
            TradingAccount account,
            PositionSnapshot snapshot,
            long reconcileRevision
    ) {
        TradingPosition current = positionMapper.selectByKey(
                account.getId(),
                snapshot.symbol(),
                snapshot.positionSide()
        );
        if (current != null
                && nonNull(current.getLastEventMs())
                > snapshot.exchangeUpdateMillis()) {
            if (snapshot.leverage() > 0
                    && (current.getLeverage() == null
                    || current.getLeverage() != snapshot.leverage())) {
                positionMapper.updateLeverageBySymbol(
                        account.getId(),
                        snapshot.symbol(),
                        snapshot.leverage()
                );
                current.setLeverage(snapshot.leverage());
            }
            return current;
        }
        TradingPosition position = basePosition(
                account,
                current,
                snapshot.symbol(),
                snapshot.positionSide(),
                snapshot.quantity()
        );
        position.setEntryPrice(snapshot.entryPrice());
        position.setBreakEvenPrice(snapshot.breakEvenPrice());
        position.setMarkPrice(snapshot.markPrice());
        position.setLiquidationPrice(snapshot.liquidationPrice());
        position.setLeverage(snapshot.leverage());
        position.setMarginType(snapshot.marginType());
        position.setIsolatedMargin(snapshot.isolatedMargin());
        position.setUnrealizedProfit(snapshot.unrealizedProfit());
        position.setExchangeUpdateMs(snapshot.exchangeUpdateMillis());
        position.setLastEventMs(current == null ? 0L : nonNull(current.getLastEventMs()));
        position.setLastReconcileRevision(reconcileRevision);
        position.setContinuityStatus(current == null
                || "CLOSED".equals(current.getStatus())
                ? "UNCERTAIN"
                : current.getContinuityStatus() == null
                        ? "CONTINUOUS"
                        : current.getContinuityStatus());
        position.setSource("REST");
        positionMapper.upsert(position);
        return position;
    }

    public TradingPosition mergeEventPosition(
            TradingAccount account,
            PositionDelta delta,
            long eventMillis
    ) {
        TradingPosition current = positionMapper.selectByKey(
                account.getId(),
                delta.symbol(),
                delta.positionSide()
        );
        if (current == null && delta.quantity().signum() == 0) {
            return null;
        }
        if (current != null && nonNull(current.getLastEventMs()) > eventMillis) {
            return current;
        }
        TradingPosition position = basePosition(
                account,
                current,
                delta.symbol(),
                delta.positionSide(),
                delta.quantity()
        );
        position.setEntryPrice(delta.entryPrice());
        position.setBreakEvenPrice(delta.breakEvenPrice());
        position.setMarkPrice(current == null ? BigDecimal.ZERO : current.getMarkPrice());
        position.setLiquidationPrice(current == null
                ? BigDecimal.ZERO
                : current.getLiquidationPrice());
        position.setLeverage(current == null ? 1 : current.getLeverage());
        position.setMarginType(delta.marginType());
        position.setIsolatedMargin(delta.isolatedMargin());
        position.setUnrealizedProfit(delta.unrealizedProfit());
        position.setExchangeUpdateMs(Math.max(
                delta.exchangeUpdateMillis(),
                current == null ? 0 : nonNull(current.getExchangeUpdateMs())
        ));
        position.setLastEventMs(eventMillis);
        position.setLastReconcileRevision(current == null
                ? 0L
                : nonNull(current.getLastReconcileRevision()));
        position.setContinuityStatus(current == null
                || "CLOSED".equals(current.getStatus())
                || current.getContinuityStatus() == null
                ? "CONTINUOUS"
                : current.getContinuityStatus());
        position.setSource("USER_STREAM");
        positionMapper.upsert(position);
        outboxService.enqueue(
                account,
                RealtimeProtocol.CHANNEL_TRADING_POSITION,
                "updated",
                position.getId(),
                position.getSymbol(),
                position
        );
        return position;
    }

    public ExchangeOrder mergeOrder(
            TradingAccount account,
            OrderSnapshot snapshot,
            String executionType,
            String rejectReason,
            long eventMillis,
            long reconcileRevision,
            boolean publish
    ) {
        ExchangeOrder current = "ALGO".equals(snapshot.orderClass())
                ? orderMapper.selectAlgoByIdentity(
                        account.getId(),
                        snapshot.clientAlgoId(),
                        snapshot.exchangeAlgoId()
                )
                : orderMapper.selectRegularByIdentity(
                        account.getId(),
                        snapshot.clientOrderId(),
                        snapshot.exchangeOrderId()
                );
        if (current != null && isNoOpSnapshot(current, snapshot, eventMillis)) {
            return current;
        }
        MergeDecision decision = "ALGO".equals(snapshot.orderClass())
                ? TradingOrderStateMachine.mergeAlgo(
                        current == null ? null : current.getStatus(),
                        current == null ? 0 : nonNull(current.getLastEventMs()),
                        snapshot.exchangeStatus(),
                        eventMillis
                )
                : TradingOrderStateMachine.mergeRegular(
                        current == null ? null : current.getStatus(),
                        current == null
                                ? BigDecimal.ZERO
                                : current.getExecutedQuantity(),
                        current == null ? 0 : nonNull(current.getLastEventMs()),
                        snapshot.exchangeStatus(),
                        snapshot.executedQuantity(),
                        eventMillis
                );
        if (!decision.acceptPayload() && current != null) {
            return current;
        }

        LocalDateTime now = LocalDateTime.now();
        ExchangeOrder order = current == null ? new ExchangeOrder() : current;
        if (current == null) {
            order.setId(UUID.randomUUID().toString());
            order.setCreateTime(now);
            order.setTradingAccountId(account.getId());
            order.setOrigin("EXTERNAL");
            order.setPurpose("UNKNOWN");
            order.setVersion(0L);
        }
        order.setUpdateTime(now);
        order.setOrderClass(snapshot.orderClass());
        order.setSymbol(prefer(snapshot.symbol(), value(current, ExchangeOrder::getSymbol)));
        order.setSide(prefer(snapshot.side(), value(current, ExchangeOrder::getSide)));
        order.setPositionSide(prefer(
                snapshot.positionSide(),
                value(current, ExchangeOrder::getPositionSide)
        ));
        order.setOrderType(prefer(
                snapshot.orderType(),
                value(current, ExchangeOrder::getOrderType)
        ));
        order.setTimeInForce(prefer(
                snapshot.timeInForce(),
                value(current, ExchangeOrder::getTimeInForce)
        ));
        order.setWorkingType(prefer(
                snapshot.workingType(),
                value(current, ExchangeOrder::getWorkingType)
        ));
        order.setClientOrderId(prefer(
                snapshot.clientOrderId(),
                value(current, ExchangeOrder::getClientOrderId)
        ));
        order.setExchangeOrderId(prefer(
                snapshot.exchangeOrderId(),
                value(current, ExchangeOrder::getExchangeOrderId)
        ));
        order.setClientAlgoId(prefer(
                snapshot.clientAlgoId(),
                value(current, ExchangeOrder::getClientAlgoId)
        ));
        order.setExchangeAlgoId(prefer(
                snapshot.exchangeAlgoId(),
                value(current, ExchangeOrder::getExchangeAlgoId)
        ));
        order.setActualOrderId(prefer(
                snapshot.actualOrderId(),
                value(current, ExchangeOrder::getActualOrderId)
        ));
        order.setQuantity(nonNull(snapshot.quantity()));
        order.setPrice(nonNull(snapshot.price()));
        order.setTriggerPrice(nonNull(snapshot.triggerPrice()));
        order.setExecutedQuantity(max(
                current == null ? null : current.getExecutedQuantity(),
                snapshot.executedQuantity()
        ));
        order.setCumulativeQuote(max(
                current == null ? null : current.getCumulativeQuote(),
                snapshot.cumulativeQuote()
        ));
        order.setAveragePrice(positiveOrExisting(
                snapshot.averagePrice(),
                current == null ? null : current.getAveragePrice()
        ));
        order.setReduceOnly(snapshot.reduceOnly() ? 1 : 0);
        order.setClosePosition(snapshot.closePosition() ? 1 : 0);
        order.setStatus(decision.state());
        order.setExchangeStatus(snapshot.exchangeStatus());
        order.setExecutionType(executionType);
        order.setRejectReason(prefer(
                sanitizeReason(rejectReason),
                current == null ? null : current.getRejectReason()
        ));
        order.setExchangeCreateMs(snapshot.createTimeMillis());
        order.setExchangeUpdateMs(Math.max(
                snapshot.updateTimeMillis(),
                current == null ? 0 : nonNull(current.getExchangeUpdateMs())
        ));
        order.setLastEventMs(Math.max(
                eventMillis,
                current == null ? 0 : nonNull(current.getLastEventMs())
        ));
        order.setLastReconcileRevision(Math.max(
                reconcileRevision,
                current == null ? 0 : nonNull(current.getLastReconcileRevision())
        ));
        if (current == null) {
            orderMapper.insertOrder(order);
        } else if (orderMapper.updateOrder(order) != 1) {
            throw new IllegalStateException("Concurrent exchange order update");
        }
        if (publish) {
            outboxService.enqueue(
                    account,
                    RealtimeProtocol.CHANNEL_TRADING_ORDER,
                    "updated",
                    order.getId(),
                    order.getSymbol(),
                    order
            );
        }
        return order;
    }

    public ExchangeFill mergeFill(
            TradingAccount account,
            FillSnapshot snapshot,
            ExchangeOrder order,
            boolean publish
    ) {
        if (snapshot == null || snapshot.tradeId() == null) {
            return null;
        }
        ExchangeFill fill = new ExchangeFill();
        fill.setId(UUID.randomUUID().toString());
        fill.setCreateTime(LocalDateTime.now());
        fill.setTradingAccountId(account.getId());
        fill.setExchangeOrderRowId(order == null ? null : order.getId());
        fill.setSymbol(snapshot.symbol());
        fill.setTradeId(snapshot.tradeId());
        fill.setOrderId(snapshot.orderId());
        fill.setSide(snapshot.side());
        fill.setPositionSide(snapshot.positionSide());
        fill.setPrice(nonNull(snapshot.price()));
        fill.setQuantity(nonNull(snapshot.quantity()));
        fill.setQuoteQuantity(nonNull(snapshot.quoteQuantity()));
        fill.setCommission(nonNull(snapshot.commission()));
        fill.setCommissionAsset(snapshot.commissionAsset());
        fill.setRealizedPnl(nonNull(snapshot.realizedPnl()));
        fill.setMaker(snapshot.maker() ? 1 : 0);
        fill.setTradeTimeMs(snapshot.tradeTimeMillis());
        int inserted = fillMapper.insertIgnore(fill);
        if (inserted == 1 && publish) {
            outboxService.enqueue(
                    account,
                    RealtimeProtocol.CHANNEL_TRADING_FILL,
                    "created",
                    fill.getId(),
                    fill.getSymbol(),
                    fill
            );
        }
        return inserted == 1 ? fill : null;
    }

    private TradingPosition basePosition(
            TradingAccount account,
            TradingPosition current,
            String symbol,
            String positionSide,
            BigDecimal quantity
    ) {
        LocalDateTime now = LocalDateTime.now();
        TradingPosition position = new TradingPosition();
        position.setId(current == null
                ? UUID.randomUUID().toString()
                : current.getId());
        position.setCreateTime(current == null ? now : current.getCreateTime());
        position.setUpdateTime(now);
        position.setTradingAccountId(account.getId());
        position.setSymbol(symbol);
        position.setPositionSide(positionSide);
        long generation = current == null ? 1 : nonNull(current.getGeneration());
        if (current != null && quantity.signum() != 0
                && ("CLOSED".equals(current.getStatus())
                || signsDiffer(current.getQuantity(), quantity))) {
            generation++;
        }
        position.setGeneration(generation);
        position.setQuantity(quantity);
        position.setStatus(quantity.signum() == 0 ? "CLOSED" : "OPEN");
        position.setVersion(current == null ? 0L : nonNull(current.getVersion()));
        return position;
    }

    private boolean signsDiffer(BigDecimal first, BigDecimal second) {
        return first != null && first.signum() != 0 && second.signum() != 0
                && first.signum() != second.signum();
    }

    private String sanitizeReason(String reason) {
        if (reason == null || reason.isBlank()) {
            return null;
        }
        return reason.length() <= 128 ? reason : reason.substring(0, 128);
    }

    private boolean isNoOpSnapshot(
            ExchangeOrder current,
            OrderSnapshot snapshot,
            long eventMillis
    ) {
        String incomingState = "ALGO".equals(snapshot.orderClass())
                ? TradingOrderStateMachine.normalizeAlgo(
                        snapshot.exchangeStatus()
                )
                : TradingOrderStateMachine.normalizeRegular(
                        snapshot.exchangeStatus()
                );
        return incomingState.equals(current.getStatus())
                && nonNull(snapshot.executedQuantity()).compareTo(
                        nonNull(current.getExecutedQuantity())
                ) <= 0
                && snapshot.updateTimeMillis()
                <= nonNull(current.getExchangeUpdateMs())
                && eventMillis <= nonNull(current.getLastEventMs())
                && (snapshot.actualOrderId() == null
                || java.util.Objects.equals(
                        snapshot.actualOrderId(),
                        current.getActualOrderId()
                ));
    }

    private String prefer(String candidate, String existing) {
        return candidate == null || candidate.isBlank() ? existing : candidate;
    }

    private String value(
            ExchangeOrder order,
            java.util.function.Function<ExchangeOrder, String> getter
    ) {
        return order == null ? null : getter.apply(order);
    }

    private BigDecimal positiveOrExisting(
            BigDecimal candidate,
            BigDecimal existing
    ) {
        return candidate != null && candidate.signum() > 0
                ? candidate
                : nonNull(existing);
    }

    private BigDecimal max(BigDecimal first, BigDecimal second) {
        first = nonNull(first);
        second = nonNull(second);
        return first.max(second);
    }

    private BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private long nonNull(Long value) {
        return value == null ? 0L : value;
    }

    private int nonNull(Integer value) {
        return value == null ? 0 : value;
    }
}
