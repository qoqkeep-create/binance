package com.oovso.trading;

import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import java.math.BigDecimal;
import java.math.RoundingMode;

/** Pure calculations for linear USD-M contracts. */
public final class TradingRiskEngine {

    private static final BigDecimal ONE_HUNDRED = new BigDecimal("100");

    private TradingRiskEngine() {
    }

    public static EntrySizing sizeEntry(
            String direction,
            String entryOrderType,
            BigDecimal requestedEntryPrice,
            BigDecimal serverReferencePrice,
            BigDecimal requestedStopPrice,
            BigDecimal configuredRAmount,
            SymbolRules rules
    ) {
        boolean longDirection = isLong(direction);
        requirePositive(configuredRAmount, "R金额必须大于0");
        requirePositive(serverReferencePrice, "服务器参考价格无效");
        requirePositive(requestedStopPrice, "止损价格必须大于0");
        requireRules(rules);

        boolean market = "MARKET".equals(entryOrderType);
        BigDecimal entryPrice = market
                ? serverReferencePrice
                : normalizedEntry(
                        requestedEntryPrice,
                        rules.priceTick(),
                        longDirection
                );
        BigDecimal stopPrice = normalizedInitialStop(
                requestedStopPrice,
                rules.priceTick(),
                longDirection
        );
        validateStopSide(longDirection, entryPrice, stopPrice);

        BigDecimal distance = entryPrice.subtract(stopPrice).abs();
        BigDecimal step = market
                ? rules.marketQuantityStep()
                : rules.quantityStep();
        BigDecimal minimum = market
                ? rules.marketMinQuantity()
                : rules.minQuantity();
        BigDecimal maximum = market
                ? rules.marketMaxQuantity()
                : rules.maxQuantity();
        BigDecimal quantity = floorToStep(
                configuredRAmount.divide(distance, 38, RoundingMode.DOWN),
                step
        );
        if (quantity.signum() <= 0 || quantity.compareTo(minimum) < 0) {
            throw new IllegalArgumentException("R金额不足以达到该交易对最小下单数量");
        }
        if (maximum != null && maximum.signum() > 0
                && quantity.compareTo(maximum) > 0) {
            quantity = floorToStep(maximum, step);
        }
        BigDecimal notional = quantity.multiply(entryPrice);
        if (rules.minNotional() != null
                && rules.minNotional().signum() > 0
                && notional.compareTo(rules.minNotional()) < 0) {
            throw new IllegalArgumentException("R金额对应仓位低于交易对最小名义价值");
        }
        return new EntrySizing(
                entryPrice,
                market ? null : entryPrice,
                stopPrice,
                distance,
                quantity,
                quantity.multiply(distance),
                step
        );
    }

    public static BigDecimal profitR(
            String direction,
            BigDecimal entryPrice,
            BigDecimal currentPrice,
            BigDecimal riskPerUnit
    ) {
        requirePositive(entryPrice, "建仓价格无效");
        requirePositive(currentPrice, "当前价格无效");
        requirePositive(riskPerUnit, "每单位风险无效");
        BigDecimal profit = isLong(direction)
                ? currentPrice.subtract(entryPrice)
                : entryPrice.subtract(currentPrice);
        return profit.divide(riskPerUnit, 18, RoundingMode.HALF_UP);
    }

    public static BigDecimal fixedStop(
            String direction,
            BigDecimal entryPrice,
            BigDecimal riskPerUnit,
            BigDecimal moveStopR
    ) {
        BigDecimal offset = riskPerUnit.multiply(moveStopR);
        return isLong(direction)
                ? entryPrice.add(offset)
                : entryPrice.subtract(offset);
    }

    public static BigDecimal trailingStop(
            String direction,
            BigDecimal currentPrice,
            BigDecimal riskPerUnit,
            BigDecimal trailingDistanceR
    ) {
        BigDecimal offset = riskPerUnit.multiply(trailingDistanceR);
        return isLong(direction)
                ? currentPrice.subtract(offset)
                : currentPrice.add(offset);
    }

    public static BigDecimal ratchetStop(
            String direction,
            BigDecimal currentStop,
            BigDecimal candidate,
            BigDecimal currentPrice,
            BigDecimal tick
    ) {
        boolean longDirection = isLong(direction);
        requirePositive(candidate, "候选止损价格无效");
        requirePositive(currentPrice, "当前价格无效");
        requirePositive(tick, "价格步长无效");
        BigDecimal bounded = longDirection
                ? candidate.min(currentPrice.subtract(tick))
                : candidate.max(currentPrice.add(tick));
        BigDecimal aligned = longDirection
                ? floorToStep(bounded, tick)
                : ceilToStep(bounded, tick);
        if (currentStop == null || currentStop.signum() <= 0) {
            return aligned;
        }
        return longDirection
                ? currentStop.max(aligned)
                : currentStop.min(aligned);
    }

    public static BigDecimal fallbackStop(
            String direction,
            BigDecimal primaryStop,
            BigDecimal riskPerUnit,
            BigDecimal fallbackMarketStopR,
            BigDecimal tick
    ) {
        if (fallbackMarketStopR == null
                || fallbackMarketStopR.compareTo(BigDecimal.ONE) <= 0) {
            throw new IllegalArgumentException("保底市价止损必须大于1R");
        }
        BigDecimal gap = riskPerUnit.multiply(
                fallbackMarketStopR.subtract(BigDecimal.ONE)
        );
        BigDecimal candidate = isLong(direction)
                ? primaryStop.subtract(gap)
                : primaryStop.add(gap);
        return isLong(direction)
                ? floorToStep(candidate, tick)
                : ceilToStep(candidate, tick);
    }

    public static BigDecimal reductionQuantity(
            BigDecimal initialQuantity,
            BigDecimal reducePercent,
            BigDecimal remainingQuantity,
            BigDecimal quantityStep
    ) {
        BigDecimal planned = plannedReductionQuantity(
                initialQuantity,
                reducePercent,
                quantityStep
        );
        return planned.min(floorToStep(remainingQuantity, quantityStep));
    }

    public static BigDecimal plannedReductionQuantity(
            BigDecimal initialQuantity,
            BigDecimal reducePercent,
            BigDecimal quantityStep
    ) {
        if (reducePercent == null || reducePercent.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return floorToStep(initialQuantity
                .multiply(reducePercent)
                .divide(ONE_HUNDRED, 38, RoundingMode.DOWN), quantityStep);
    }

    public static BigDecimal floorToStep(BigDecimal value, BigDecimal step) {
        requirePositive(step, "步长必须大于0");
        if (value == null || value.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return value.divide(step, 0, RoundingMode.FLOOR).multiply(step)
                .stripTrailingZeros();
    }

    public static BigDecimal ceilToStep(BigDecimal value, BigDecimal step) {
        requirePositive(step, "步长必须大于0");
        return value.divide(step, 0, RoundingMode.CEILING).multiply(step)
                .stripTrailingZeros();
    }

    private static BigDecimal normalizedEntry(
            BigDecimal requested,
            BigDecimal tick,
            boolean longDirection
    ) {
        requirePositive(requested, "限价或Maker建仓必须提供建仓价格");
        return longDirection
                ? floorToStep(requested, tick)
                : ceilToStep(requested, tick);
    }

    private static BigDecimal normalizedInitialStop(
            BigDecimal requested,
            BigDecimal tick,
            boolean longDirection
    ) {
        return longDirection
                ? ceilToStep(requested, tick)
                : floorToStep(requested, tick);
    }

    private static void validateStopSide(
            boolean longDirection,
            BigDecimal entry,
            BigDecimal stop
    ) {
        if (longDirection && stop.compareTo(entry) >= 0) {
            throw new IllegalArgumentException("做多止损必须低于建仓价格");
        }
        if (!longDirection && stop.compareTo(entry) <= 0) {
            throw new IllegalArgumentException("做空止损必须高于建仓价格");
        }
    }

    private static void requireRules(SymbolRules rules) {
        if (rules == null || !"TRADING".equals(rules.status())) {
            throw new IllegalArgumentException("交易对当前不可交易");
        }
        requirePositive(rules.priceTick(), "交易对价格步长无效");
        requirePositive(rules.quantityStep(), "交易对数量步长无效");
        requirePositive(rules.marketQuantityStep(), "交易对市价数量步长无效");
    }

    private static boolean isLong(String direction) {
        if ("LONG".equals(direction)) {
            return true;
        }
        if ("SHORT".equals(direction)) {
            return false;
        }
        throw new IllegalArgumentException("方向必须是LONG或SHORT");
    }

    private static void requirePositive(BigDecimal value, String message) {
        if (value == null || value.signum() <= 0) {
            throw new IllegalArgumentException(message);
        }
    }

    public record EntrySizing(
            BigDecimal referenceEntryPrice,
            BigDecimal normalizedRequestedEntryPrice,
            BigDecimal initialStopPrice,
            BigDecimal riskPerUnit,
            BigDecimal quantity,
            BigDecimal plannedRiskAmount,
            BigDecimal quantityStep
    ) {
    }
}
