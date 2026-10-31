package com.oovso.trading;

import com.oovso.trading.BinanceUsdmPrivateGateway.FillSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import java.math.BigDecimal;
import java.util.List;

public record TradingUserStreamEvent(
        Kind kind,
        String eventType,
        long eventTimeMillis,
        long transactionTimeMillis,
        long receivedAtMillis,
        String entityKey,
        String eventHash,
        String normalizedSummary,
        String reason,
        List<BalanceDelta> balances,
        List<PositionDelta> positions,
        OrderSnapshot order,
        FillSnapshot fill,
        String rejectReason
) {

    public enum Kind {
        ACCOUNT_UPDATE,
        REGULAR_ORDER_UPDATE,
        ALGO_ORDER_UPDATE,
        LISTEN_KEY_EXPIRED,
        RISK_OR_CONFIG,
        UNKNOWN
    }

    public record BalanceDelta(
            String asset,
            BigDecimal walletBalance,
            BigDecimal crossWalletBalance,
            BigDecimal balanceChange
    ) {
    }

    public record PositionDelta(
            String symbol,
            String positionSide,
            BigDecimal quantity,
            BigDecimal entryPrice,
            BigDecimal breakEvenPrice,
            BigDecimal isolatedMargin,
            BigDecimal unrealizedProfit,
            String marginType,
            long exchangeUpdateMillis
    ) {
    }
}
