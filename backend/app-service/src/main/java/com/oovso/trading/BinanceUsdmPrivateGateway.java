package com.oovso.trading;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

public interface BinanceUsdmPrivateGateway {

    VerifiedAccount verify(
            BinanceCredentials credentials,
            String preferredAsset
    );

    String enforceHedgeMode(BinanceCredentials credentials);

    AccountSetupResult enforceHedgeModeAndMaximumLeverage(
            BinanceCredentials credentials,
            String quoteAsset
    );

    LeverageSnapshot leverage(
            BinanceCredentials credentials,
            String symbol
    );

    LeverageSnapshot changeLeverage(
            BinanceCredentials credentials,
            String symbol,
            int leverage
    );

    String createListenKey(BinanceCredentials credentials);

    void keepAliveListenKey(
            BinanceCredentials credentials,
            String listenKey
    );

    void closeListenKey(
            BinanceCredentials credentials,
            String listenKey
    );

    ReconciliationSnapshot reconciliationSnapshot(
            BinanceCredentials credentials,
            String preferredAsset,
            boolean includeOpenOrders
    );

    Optional<OrderSnapshot> queryRegularOrder(
            BinanceCredentials credentials,
            String symbol,
            String clientOrderId,
            String exchangeOrderId
    );

    Optional<OrderSnapshot> queryAlgoOrder(
            BinanceCredentials credentials,
            String clientAlgoId,
            String exchangeAlgoId
    );

    List<FillSnapshot> userTrades(
            BinanceCredentials credentials,
            String symbol,
            long startTimeMillis
    );

    List<OrderSnapshot> recentRegularOrders(
            BinanceCredentials credentials,
            String symbol,
            long startTimeMillis
    );

    SymbolRules symbolRules(String symbol);

    PriceSnapshot priceSnapshot(String symbol);

    OrderSnapshot placeRegularOrder(
            BinanceCredentials credentials,
            RegularOrderRequest request
    );

    OrderSnapshot cancelRegularOrder(
            BinanceCredentials credentials,
            String symbol,
            String clientOrderId,
            String exchangeOrderId
    );

    OrderSnapshot placeAlgoOrder(
            BinanceCredentials credentials,
            AlgoOrderRequest request
    );

    OrderSnapshot cancelAlgoOrder(
            BinanceCredentials credentials,
            String clientAlgoId,
            String exchangeAlgoId
    );

    record VerifiedAccount(
            BigDecimal totalMarginBalance,
            BigDecimal unrealizedProfit,
            String asset,
            String positionMode,
            long syncedAtMillis,
            List<PositionSnapshot> positions
    ) {
    }

    record AccountSetupResult(
            String positionMode,
            int configuredSymbolCount
    ) {
    }

    record LeverageSnapshot(
            String symbol,
            int leverage,
            int maxLeverage,
            BigDecimal maxNotionalValue,
            List<LeverageBracket> brackets
    ) {
    }

    record LeverageBracket(
            int initialLeverage,
            BigDecimal notionalFloor,
            BigDecimal notionalCap
    ) {
    }

    record PositionSnapshot(
            String symbol,
            String positionSide,
            BigDecimal quantity,
            BigDecimal entryPrice,
            BigDecimal breakEvenPrice,
            BigDecimal markPrice,
            BigDecimal liquidationPrice,
            int leverage,
            String marginType,
            BigDecimal isolatedMargin,
            BigDecimal unrealizedProfit,
            long exchangeUpdateMillis
    ) {
    }

    record BalanceSnapshot(
            String asset,
            BigDecimal walletBalance,
            BigDecimal crossWalletBalance,
            BigDecimal marginBalance,
            BigDecimal unrealizedProfit
    ) {
    }

    record OrderSnapshot(
            String orderClass,
            String symbol,
            String side,
            String positionSide,
            String orderType,
            String timeInForce,
            String workingType,
            String clientOrderId,
            String exchangeOrderId,
            String clientAlgoId,
            String exchangeAlgoId,
            String actualOrderId,
            BigDecimal quantity,
            BigDecimal price,
            BigDecimal triggerPrice,
            BigDecimal executedQuantity,
            BigDecimal cumulativeQuote,
            BigDecimal averagePrice,
            boolean reduceOnly,
            boolean closePosition,
            String exchangeStatus,
            long createTimeMillis,
            long updateTimeMillis
    ) {
    }

    record FillSnapshot(
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
    }

    record ReconciliationSnapshot(
            BigDecimal totalMarginBalance,
            BigDecimal unrealizedProfit,
            String asset,
            String positionMode,
            long syncedAtMillis,
            List<BalanceSnapshot> balances,
            List<PositionSnapshot> positions,
            List<OrderSnapshot> regularOpenOrders,
            List<OrderSnapshot> algoOpenOrders
    ) {
    }

    record SymbolRules(
            String symbol,
            String status,
            String baseAsset,
            String quoteAsset,
            BigDecimal priceTick,
            BigDecimal minQuantity,
            BigDecimal maxQuantity,
            BigDecimal quantityStep,
            BigDecimal marketMinQuantity,
            BigDecimal marketMaxQuantity,
            BigDecimal marketQuantityStep,
            BigDecimal minNotional
    ) {
    }

    record PriceSnapshot(
            String symbol,
            BigDecimal markPrice,
            BigDecimal bidPrice,
            BigDecimal askPrice,
            long exchangeTimeMillis
    ) {
    }

    record RegularOrderRequest(
            String symbol,
            String side,
            String positionSide,
            String type,
            String timeInForce,
            BigDecimal quantity,
            BigDecimal price,
            boolean reduceOnly,
            String clientOrderId
    ) {
    }

    record AlgoOrderRequest(
            String symbol,
            String side,
            String positionSide,
            String type,
            String timeInForce,
            String workingType,
            BigDecimal quantity,
            BigDecimal price,
            BigDecimal triggerPrice,
            boolean reduceOnly,
            boolean closePosition,
            String clientAlgoId
    ) {
    }
}
