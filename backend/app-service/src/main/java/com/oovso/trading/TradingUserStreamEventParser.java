package com.oovso.trading;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.oovso.trading.BinanceUsdmPrivateGateway.FillSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import com.oovso.trading.TradingUserStreamEvent.BalanceDelta;
import com.oovso.trading.TradingUserStreamEvent.Kind;
import com.oovso.trading.TradingUserStreamEvent.PositionDelta;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class TradingUserStreamEventParser {

    private final ObjectMapper objectMapper;

    public TradingUserStreamEventParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public TradingUserStreamEvent parse(
            String message,
            long receivedAtMillis
    ) {
        try {
            JsonNode root = objectMapper.readTree(message);
            if (root == null || !root.isObject()) {
                throw new IllegalArgumentException(
                        "Binance user stream event must be a JSON object"
                );
            }
            String eventType = root.path("e").asText("UNKNOWN");
            long eventTime = root.path("E").asLong(0);
            long transactionTime = root.path("T").asLong(eventTime);
            String eventHash = semanticHash(root);
            return switch (eventType) {
                case "ACCOUNT_UPDATE" -> accountUpdate(
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
                case "ORDER_TRADE_UPDATE" -> regularOrderUpdate(
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
                case "ALGO_UPDATE" -> algoOrderUpdate(
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
                case "listenKeyExpired" -> control(
                        Kind.LISTEN_KEY_EXPIRED,
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
                case "CONDITIONAL_ORDER_TRIGGER_REJECT",
                     "ACCOUNT_CONFIG_UPDATE", "MARGIN_CALL" -> control(
                        Kind.RISK_OR_CONFIG,
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
                default -> control(
                        !"TRADE_LITE".equals(eventType)
                                && (root.has("o") || root.has("a"))
                                ? Kind.RISK_OR_CONFIG
                                : Kind.UNKNOWN,
                        root,
                        eventType,
                        eventTime,
                        transactionTime,
                        receivedAtMillis,
                        eventHash
                );
            };
        } catch (JsonProcessingException exception) {
            throw new IllegalArgumentException(
                    "Unable to parse Binance user stream event",
                    exception
            );
        }
    }

    private TradingUserStreamEvent accountUpdate(
            JsonNode root,
            String eventType,
            long eventTime,
            long transactionTime,
            long receivedAt,
            String hash
    ) throws JsonProcessingException {
        JsonNode account = root.path("a");
        String reason = account.path("m").asText("UNKNOWN");
        List<BalanceDelta> balances = new ArrayList<>();
        if (account.path("B").isArray()) {
            for (JsonNode item : account.path("B")) {
                balances.add(new BalanceDelta(
                        item.path("a").asText(),
                        decimal(item, "wb"),
                        decimal(item, "cw"),
                        decimal(item, "bc")
                ));
            }
        }
        List<PositionDelta> positions = new ArrayList<>();
        if (account.path("P").isArray()) {
            for (JsonNode item : account.path("P")) {
                positions.add(new PositionDelta(
                        item.path("s").asText(),
                        normalizePositionSide(item.path("ps").asText()),
                        decimal(item, "pa"),
                        decimal(item, "ep"),
                        decimal(item, "bep"),
                        decimal(item, "iw"),
                        decimal(item, "up"),
                        item.path("mt").asText("cross")
                                .toLowerCase(Locale.ROOT),
                        transactionTime
                ));
            }
        }
        String entityKey = "account:" + reason;
        return new TradingUserStreamEvent(
                Kind.ACCOUNT_UPDATE,
                eventType,
                eventTime,
                transactionTime,
                receivedAt,
                entityKey,
                hash,
                summary(Map.of(
                        "reason", reason,
                        "balanceCount", balances.size(),
                        "positionCount", positions.size()
                )),
                reason,
                List.copyOf(balances),
                List.copyOf(positions),
                null,
                null,
                null
        );
    }

    private TradingUserStreamEvent regularOrderUpdate(
            JsonNode root,
            String eventType,
            long eventTime,
            long transactionTime,
            long receivedAt,
            String hash
    ) throws JsonProcessingException {
        JsonNode orderNode = root.path("o");
        String exchangeOrderId = identifier(orderNode, "i");
        String clientOrderId = text(orderNode, "c");
        String executionType = orderNode.path("x").asText("UNKNOWN");
        String exchangeStatus = orderNode.path("X").asText("UNKNOWN");
        OrderSnapshot order = new OrderSnapshot(
                "REGULAR",
                orderNode.path("s").asText(),
                orderNode.path("S").asText(),
                normalizePositionSide(orderNode.path("ps").asText()),
                orderNode.path("o").asText("UNKNOWN"),
                text(orderNode, "f"),
                text(orderNode, "wt"),
                clientOrderId,
                exchangeOrderId,
                null,
                null,
                null,
                decimal(orderNode, "q"),
                decimal(orderNode, "p"),
                decimal(orderNode, "sp"),
                decimal(orderNode, "z"),
                decimal(orderNode, "b"),
                decimal(orderNode, "ap"),
                orderNode.path("R").asBoolean(false),
                orderNode.path("cp").asBoolean(false),
                exchangeStatus,
                orderNode.path("T").asLong(transactionTime),
                transactionTime
        );
        FillSnapshot fill = decodeTradeFill(orderNode, transactionTime);
        String key = "regular:" + firstNonBlank(
                exchangeOrderId,
                clientOrderId,
                "unknown"
        );
        return new TradingUserStreamEvent(
                Kind.REGULAR_ORDER_UPDATE,
                eventType,
                eventTime,
                transactionTime,
                receivedAt,
                key,
                hash,
                summary(Map.of(
                        "symbol", order.symbol(),
                        "executionType", executionType,
                        "status", exchangeStatus,
                        "entity", key
                )),
                executionType,
                List.of(),
                List.of(),
                order,
                fill,
                text(orderNode, "r")
        );
    }

    private TradingUserStreamEvent algoOrderUpdate(
            JsonNode root,
            String eventType,
            long eventTime,
            long transactionTime,
            long receivedAt,
            String hash
    ) throws JsonProcessingException {
        JsonNode item = root.has("o") ? root.path("o") : root.path("a");
        String clientAlgoId = firstText(
                item,
                "caid",
                "clientAlgoId",
                "ca",
                "c"
        );
        String exchangeAlgoId = firstIdentifier(item, "aid", "algoId", "i");
        String status = firstText(item, "as", "algoStatus", "X", "status");
        long createTime = firstLong(item, "ct", "createTime");
        long updateTime = firstLong(item, "ut", "updateTime", "T");
        OrderSnapshot order = new OrderSnapshot(
                "ALGO",
                firstText(item, "s", "symbol"),
                firstText(item, "S", "side"),
                normalizePositionSide(firstText(item, "ps", "positionSide")),
                firstText(item, "o", "orderType", "type"),
                firstText(item, "f", "timeInForce"),
                firstText(item, "wt", "workingType"),
                null,
                null,
                clientAlgoId,
                exchangeAlgoId,
                firstIdentifier(item, "ai", "actualOrderId", "ao"),
                firstDecimal(item, "q", "quantity", "origQty"),
                firstDecimal(item, "p", "price"),
                firstDecimal(item, "tp", "triggerPrice", "sp", "stopPrice"),
                firstDecimal(item, "aq", "executedQty", "z"),
                firstDecimal(item, "b", "cumQuote"),
                firstDecimal(item, "ap", "avgPrice"),
                item.path("R").asBoolean(item.path("reduceOnly").asBoolean(false)),
                item.path("cp").asBoolean(item.path("closePosition").asBoolean(false)),
                status,
                createTime > 0 ? createTime : transactionTime,
                updateTime > 0 ? updateTime : transactionTime
        );
        String key = "algo:" + firstNonBlank(
                exchangeAlgoId,
                clientAlgoId,
                "unknown"
        );
        return new TradingUserStreamEvent(
                Kind.ALGO_ORDER_UPDATE,
                eventType,
                eventTime,
                transactionTime,
                receivedAt,
                key,
                hash,
                summary(Map.of(
                        "symbol", order.symbol(),
                        "status", status,
                        "entity", key
                )),
                null,
                List.of(),
                List.of(),
                order,
                null,
                firstText(item, "rm", "rejectReason", "r")
        );
    }

    private TradingUserStreamEvent control(
            Kind kind,
            JsonNode root,
            String eventType,
            long eventTime,
            long transactionTime,
            long receivedAt,
            String hash
    ) throws JsonProcessingException {
        String entityKey = "event:" + eventType;
        return new TradingUserStreamEvent(
                kind,
                eventType,
                eventTime,
                transactionTime,
                receivedAt,
                entityKey,
                hash,
                summary(Map.of(
                        "eventType", eventType,
                        "eventTime", eventTime
                )),
                null,
                List.of(),
                List.of(),
                null,
                null,
                firstText(root, "r", "or", "reason", "msg")
        );
    }

    private FillSnapshot decodeTradeFill(JsonNode order, long transactionTime) {
        if (!"TRADE".equals(order.path("x").asText())) {
            return null;
        }
        String tradeId = identifier(order, "t");
        BigDecimal quantity = decimal(order, "l");
        if (tradeId == null || quantity.signum() <= 0) {
            return null;
        }
        BigDecimal price = decimal(order, "L");
        return new FillSnapshot(
                order.path("s").asText(),
                tradeId,
                identifier(order, "i"),
                order.path("S").asText(),
                normalizePositionSide(order.path("ps").asText()),
                price,
                quantity,
                price.multiply(quantity),
                decimal(order, "n"),
                text(order, "N"),
                decimal(order, "rp"),
                order.path("m").asBoolean(false),
                order.path("T").asLong(transactionTime)
        );
    }

    private String semanticHash(JsonNode root) throws JsonProcessingException {
        JsonNode canonical = canonicalize(root);
        byte[] bytes = objectMapper.writeValueAsString(canonical)
                .getBytes(StandardCharsets.UTF_8);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            return java.util.HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private JsonNode canonicalize(JsonNode node) {
        if (node.isObject()) {
            ObjectNode result = objectMapper.createObjectNode();
            List<Map.Entry<String, JsonNode>> fields = new ArrayList<>();
            fields.addAll(node.properties());
            fields.sort(Map.Entry.comparingByKey());
            fields.forEach(entry -> result.set(
                    entry.getKey(),
                    canonicalize(entry.getValue())
            ));
            return result;
        }
        if (node.isArray()) {
            ArrayNode result = objectMapper.createArrayNode();
            List<JsonNode> values = new ArrayList<>();
            node.forEach(value -> values.add(canonicalize(value)));
            values.sort(Comparator.comparing(JsonNode::toString));
            values.forEach(result::add);
            return result;
        }
        return node;
    }

    private String summary(Map<String, Object> values)
            throws JsonProcessingException {
        return objectMapper.writeValueAsString(new LinkedHashMap<>(values));
    }

    private BigDecimal decimal(JsonNode node, String field) {
        String value = node.path(field).asText("0");
        if (!StringUtils.hasText(value)) {
            return BigDecimal.ZERO;
        }
        try {
            return new BigDecimal(value);
        } catch (NumberFormatException exception) {
            throw new IllegalArgumentException(
                    "Invalid Binance numeric field " + field,
                    exception
            );
        }
    }

    private BigDecimal firstDecimal(JsonNode node, String... fields) {
        for (String field : fields) {
            if (node.hasNonNull(field)) {
                return decimal(node, field);
            }
        }
        return BigDecimal.ZERO;
    }

    private long firstLong(JsonNode node, String... fields) {
        for (String field : fields) {
            if (node.hasNonNull(field)) {
                return node.path(field).asLong(0);
            }
        }
        return 0;
    }

    private String firstText(JsonNode node, String... fields) {
        for (String field : fields) {
            String value = text(node, field);
            if (value != null) {
                return value;
            }
        }
        return "UNKNOWN";
    }

    private String firstIdentifier(JsonNode node, String... fields) {
        for (String field : fields) {
            String value = identifier(node, field);
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    private String text(JsonNode node, String field) {
        String value = node.path(field).asText();
        return StringUtils.hasText(value) ? value : null;
    }

    private String identifier(JsonNode node, String field) {
        JsonNode value = node.path(field);
        if (value.isMissingNode() || value.isNull()) {
            return null;
        }
        String text = value.asText();
        return StringUtils.hasText(text) && !"0".equals(text) ? text : null;
    }

    private String normalizePositionSide(String value) {
        if (!StringUtils.hasText(value)) {
            return "BOTH";
        }
        String normalized = value.toUpperCase(Locale.ROOT);
        return switch (normalized) {
            case "LONG", "SHORT" -> normalized;
            default -> "BOTH";
        };
    }

    private String firstNonBlank(String... values) {
        for (String value : values) {
            if (StringUtils.hasText(value)) {
                return value;
            }
        }
        return "unknown";
    }
}
