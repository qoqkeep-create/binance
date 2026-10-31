package com.oovso.trading;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class TradingPositionHistoryProjector {

    private static final int DIVISION_SCALE = 18;

    private TradingPositionHistoryProjector() {
    }

    static List<HistoryPosition> project(
            List<ExchangeFill> fills,
            int limit
    ) {
        if (fills == null || fills.isEmpty() || limit <= 0) {
            return List.of();
        }
        return projectCycles(fills).completed().stream()
                .sorted(Comparator
                        .comparingLong(HistoryPosition::closedAtMillis)
                        .reversed()
                        .thenComparing(HistoryPosition::id))
                .limit(limit)
                .toList();
    }

    static List<OpenPosition> projectOpen(List<ExchangeFill> fills) {
        if (fills == null || fills.isEmpty()) {
            return List.of();
        }
        return projectCycles(fills).active().values().stream()
                .map(Cycle::openPosition)
                .sorted(Comparator
                        .comparing(OpenPosition::symbol)
                        .thenComparing(OpenPosition::positionSide))
                .toList();
    }

    private static Projection projectCycles(List<ExchangeFill> fills) {
        List<ExchangeFill> ordered = fills.stream()
                .filter(fill -> fill != null
                        && fill.getQuantity() != null
                        && fill.getQuantity().signum() > 0)
                .sorted(Comparator
                        .comparingLong(TradingPositionHistoryProjector::time)
                        .thenComparing(
                                fill -> text(fill.getTradeId()),
                                TradingPositionHistoryProjector::compareTradeId
                        ))
                .toList();
        Map<PositionKey, Cycle> active = new LinkedHashMap<>();
        List<HistoryPosition> completed = new ArrayList<>();

        for (ExchangeFill fill : ordered) {
            PositionKey key = new PositionKey(
                    text(fill.getSymbol()).toUpperCase(Locale.ROOT),
                    normalizedPositionSide(fill.getPositionSide())
            );
            BigDecimal delta = signedQuantity(fill, key.positionSide());
            if (delta.signum() == 0 || key.symbol().isBlank()) {
                continue;
            }
            Cycle cycle = active.get(key);
            if (cycle == null || cycle.quantity.signum() == 0) {
                if (nonNull(fill.getRealizedPnl()).signum() != 0) {
                    continue;
                }
                active.put(key, Cycle.open(key, fill, delta));
                continue;
            }
            if (cycle.quantity.signum() == delta.signum()) {
                cycle.addOpeningFill(fill, delta.abs(), commission(fill));
                continue;
            }

            BigDecimal closingQuantity = cycle.quantity.abs().min(delta.abs());
            BigDecimal closingFee = proportional(
                    commission(fill),
                    closingQuantity,
                    delta.abs()
            );
            cycle.addClosingFill(fill, closingQuantity, closingFee);
            BigDecimal remaining = cycle.quantity.add(delta);

            if (remaining.signum() == 0) {
                completed.add(cycle.complete(fill));
                active.remove(key);
            } else if (remaining.signum() == cycle.quantity.signum()) {
                cycle.quantity = remaining;
            } else {
                completed.add(cycle.complete(fill));
                BigDecimal remainingFee = commission(fill).subtract(closingFee);
                Cycle reversed = Cycle.open(
                        key,
                        fill,
                        remaining,
                        remainingFee,
                        BigDecimal.ZERO
                );
                reversed.realizedPnl = BigDecimal.ZERO;
                active.put(key, reversed);
            }
        }
        return new Projection(completed, active);
    }

    private static BigDecimal signedQuantity(
            ExchangeFill fill,
            String positionSide
    ) {
        BigDecimal quantity = nonNull(fill.getQuantity()).abs();
        String side = text(fill.getSide()).toUpperCase(Locale.ROOT);
        if ("SHORT".equals(positionSide)) {
            return "SELL".equals(side) ? quantity.negate() : quantity;
        }
        return "BUY".equals(side) ? quantity : quantity.negate();
    }

    private static String normalizedPositionSide(String value) {
        String normalized = text(value).toUpperCase(Locale.ROOT);
        return switch (normalized) {
            case "LONG", "SHORT" -> normalized;
            default -> "BOTH";
        };
    }

    private static BigDecimal proportional(
            BigDecimal value,
            BigDecimal part,
            BigDecimal total
    ) {
        if (value.signum() == 0 || part.compareTo(total) == 0) {
            return value;
        }
        return value.multiply(part).divide(
                total,
                DIVISION_SCALE,
                RoundingMode.HALF_UP
        );
    }

    private static BigDecimal commission(ExchangeFill fill) {
        return nonNull(fill.getCommission()).abs();
    }

    private static BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static String text(String value) {
        return value == null ? "" : value;
    }

    private static long time(ExchangeFill fill) {
        return fill.getTradeTimeMs() == null ? 0L : fill.getTradeTimeMs();
    }

    private static int compareTradeId(String first, String second) {
        try {
            return new BigInteger(first).compareTo(new BigInteger(second));
        } catch (NumberFormatException ignored) {
            return first.compareTo(second);
        }
    }

    public record HistoryPosition(
            String id,
            String symbol,
            String positionSide,
            String direction,
            BigDecimal maximumQuantity,
            BigDecimal entryPrice,
            BigDecimal closePrice,
            BigDecimal realizedPnl,
            List<FeeAmount> fees,
            int fillCount,
            long openedAtMillis,
            long closedAtMillis
    ) {
    }

    public record FeeAmount(String asset, BigDecimal amount) {
    }

    public record OpenPosition(
            String symbol,
            String positionSide,
            String direction,
            BigDecimal currentQuantity,
            BigDecimal realizedPnl,
            List<FeeAmount> fees,
            List<CurrentFill> fills,
            long openedAtMillis
    ) {
    }

    public record CurrentFill(
            String id,
            String side,
            BigDecimal price,
            BigDecimal quantity,
            BigDecimal realizedPnl,
            BigDecimal commission,
            String commissionAsset,
            boolean maker,
            long tradeTimeMillis
    ) {
    }

    private record PositionKey(String symbol, String positionSide) {
    }

    private record Projection(
            List<HistoryPosition> completed,
            Map<PositionKey, Cycle> active
    ) {
    }

    private static final class Cycle {

        private final PositionKey key;
        private final String direction;
        private final String firstTradeId;
        private final long openedAtMillis;
        private final Map<String, BigDecimal> fees = new LinkedHashMap<>();
        private final List<CurrentFill> fills = new ArrayList<>();
        private BigDecimal quantity;
        private BigDecimal maximumQuantity;
        private BigDecimal openingQuantity = BigDecimal.ZERO;
        private BigDecimal openingNotional = BigDecimal.ZERO;
        private BigDecimal closingQuantity = BigDecimal.ZERO;
        private BigDecimal closingNotional = BigDecimal.ZERO;
        private BigDecimal realizedPnl = BigDecimal.ZERO;
        private int fillCount;

        private Cycle(
                PositionKey key,
                ExchangeFill fill,
                BigDecimal delta
        ) {
            this.key = key;
            this.direction = delta.signum() >= 0 ? "LONG" : "SHORT";
            this.firstTradeId = text(fill.getTradeId());
            this.openedAtMillis = time(fill);
            this.quantity = delta;
            this.maximumQuantity = delta.abs();
        }

        static Cycle open(
                PositionKey key,
                ExchangeFill fill,
                BigDecimal delta
        ) {
            return open(
                    key,
                    fill,
                    delta,
                    commission(fill),
                    nonNull(fill.getRealizedPnl())
            );
        }

        static Cycle open(
                PositionKey key,
                ExchangeFill fill,
                BigDecimal delta,
                BigDecimal fee,
                BigDecimal fillRealizedPnl
        ) {
            Cycle cycle = new Cycle(key, fill, delta);
            cycle.addOpeningFill(
                    fill,
                    delta.abs(),
                    fee,
                    fillRealizedPnl,
                    false
            );
            return cycle;
        }

        void addOpeningFill(
                ExchangeFill fill,
                BigDecimal quantity,
                BigDecimal fee
        ) {
            addOpeningFill(
                    fill,
                    quantity,
                    fee,
                    nonNull(fill.getRealizedPnl()),
                    true
            );
        }

        private void addOpeningFill(
                ExchangeFill fill,
                BigDecimal openedQuantity,
                BigDecimal fee,
                BigDecimal fillRealizedPnl,
                boolean updatePosition
        ) {
            openingQuantity = openingQuantity.add(openedQuantity);
            openingNotional = openingNotional.add(
                    nonNull(fill.getPrice()).multiply(openedQuantity)
            );
            if (updatePosition) {
                BigDecimal signed = "LONG".equals(direction)
                        ? openedQuantity
                        : openedQuantity.negate();
                quantity = quantity.add(signed);
                maximumQuantity = maximumQuantity.max(quantity.abs());
            }
            addFee(fill.getCommissionAsset(), fee);
            realizedPnl = realizedPnl.add(fillRealizedPnl);
            fills.add(currentFill(
                    fill,
                    openedQuantity,
                    fillRealizedPnl,
                    fee
            ));
            fillCount++;
        }

        void addClosingFill(
                ExchangeFill fill,
                BigDecimal closedQuantity,
                BigDecimal fee
        ) {
            closingQuantity = closingQuantity.add(closedQuantity);
            closingNotional = closingNotional.add(
                    nonNull(fill.getPrice()).multiply(closedQuantity)
            );
            addFee(fill.getCommissionAsset(), fee);
            realizedPnl = realizedPnl.add(nonNull(fill.getRealizedPnl()));
            fills.add(currentFill(
                    fill,
                    closedQuantity,
                    nonNull(fill.getRealizedPnl()),
                    fee
            ));
            fillCount++;
        }

        OpenPosition openPosition() {
            return new OpenPosition(
                    key.symbol(),
                    key.positionSide(),
                    direction,
                    quantity.abs(),
                    realizedPnl,
                    feeAmounts(),
                    List.copyOf(fills),
                    openedAtMillis
            );
        }

        HistoryPosition complete(ExchangeFill fill) {
            String lastTradeId = text(fill.getTradeId());
            String id = key.symbol() + ":" + key.positionSide() + ":"
                    + firstTradeId + ":" + lastTradeId;
            return new HistoryPosition(
                    id,
                    key.symbol(),
                    key.positionSide(),
                    direction,
                    maximumQuantity,
                    average(openingNotional, openingQuantity),
                    average(closingNotional, closingQuantity),
                    realizedPnl,
                    feeAmounts(),
                    fillCount,
                    openedAtMillis,
                    time(fill)
            );
        }

        private List<FeeAmount> feeAmounts() {
            return fees.entrySet().stream()
                    .sorted(Map.Entry.comparingByKey())
                    .map(entry -> new FeeAmount(
                            entry.getKey(),
                            entry.getValue()
                    ))
                    .toList();
        }

        private CurrentFill currentFill(
                ExchangeFill fill,
                BigDecimal allocatedQuantity,
                BigDecimal fillRealizedPnl,
                BigDecimal allocatedCommission
        ) {
            String identifier = text(fill.getId());
            if (identifier.isBlank()) {
                identifier = key.symbol() + ":" + text(fill.getTradeId());
            }
            return new CurrentFill(
                    identifier,
                    text(fill.getSide()).toUpperCase(Locale.ROOT),
                    nonNull(fill.getPrice()),
                    allocatedQuantity,
                    fillRealizedPnl,
                    allocatedCommission,
                    text(fill.getCommissionAsset()).toUpperCase(Locale.ROOT),
                    Integer.valueOf(1).equals(fill.getMaker()),
                    time(fill)
            );
        }

        private void addFee(String asset, BigDecimal amount) {
            String normalized = text(asset).toUpperCase(Locale.ROOT);
            if (normalized.isBlank()) {
                normalized = "UNKNOWN";
            }
            fees.merge(normalized, amount, BigDecimal::add);
        }

        private BigDecimal average(
                BigDecimal notional,
                BigDecimal quantity
        ) {
            if (quantity.signum() == 0) {
                return BigDecimal.ZERO;
            }
            return notional.divide(
                    quantity,
                    DIVISION_SCALE,
                    RoundingMode.HALF_UP
            );
        }
    }
}
