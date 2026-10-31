package com.oovso.trading;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.NullNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.oovso.binance.BinanceRestRateLimitException;
import com.oovso.binance.BinanceRestRequestBudget;
import java.io.IOException;
import java.math.BigDecimal;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BinanceUsdmPrivateRestClient
        implements BinanceUsdmPrivateGateway {

    private static final Logger log = LoggerFactory.getLogger(
            BinanceUsdmPrivateRestClient.class
    );

    private final TradingProperties properties;
    private final ObjectMapper objectMapper;
    private final HttpClient httpClient;
    private final BinanceRestRequestBudget requestBudget;
    private final URI baseUri;
    private volatile long serverTimeOffsetMillis;
    private final Map<String, CachedSymbolRules> symbolRulesCache =
            new ConcurrentHashMap<>();

    @Autowired
    public BinanceUsdmPrivateRestClient(
            TradingProperties properties,
            ObjectMapper objectMapper,
            BinanceRestRequestBudget requestBudget
    ) {
        this(
                properties,
                objectMapper,
                requestBudget,
                HttpClient.newBuilder()
                        .connectTimeout(Duration.ofMillis(
                                properties.getBinance()
                                        .getRequestTimeoutMillis()
                        ))
                        .followRedirects(HttpClient.Redirect.NEVER)
                        .build()
        );
    }

    BinanceUsdmPrivateRestClient(
            TradingProperties properties,
            ObjectMapper objectMapper,
            BinanceRestRequestBudget requestBudget,
            HttpClient httpClient
    ) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.httpClient = httpClient;
        this.requestBudget = requestBudget;
        this.baseUri = normalizeBaseUri(
                properties.getBinance().getRestBaseUrl()
        );
    }

    @Override
    public VerifiedAccount verify(
            BinanceCredentials credentials,
            String preferredAsset
    ) {
        try {
            JsonNode account = signedGet(
                    "/fapi/v3/account",
                    credentials,
                    Map.of()
            );
            JsonNode positions = signedGet(
                    "/fapi/v3/positionRisk",
                    credentials,
                    Map.of()
            );
            JsonNode accountConfiguration = signedGet(
                    "/fapi/v1/accountConfig",
                    credentials,
                    Map.of()
            );
            long syncedAt = System.currentTimeMillis();
            AccountBalance balance = selectBalance(account, preferredAsset);

            return new VerifiedAccount(
                    balance.marginBalance(),
                    balance.unrealizedProfit(),
                    balance.asset(),
                    decodePositionMode(accountConfiguration),
                    syncedAt,
                    decodePositions(positions)
            );
        } catch (BinancePrivateApiException exception) {
            throw mapVerificationError(exception);
        }
    }

    @Override
    public String enforceHedgeMode(BinanceCredentials credentials) {
        PositionModeObservation current = observePositionMode(credentials);
        if (current.consistentHedgeMode()) {
            return "HEDGE";
        }
        try {
            signedRequest(
                    "POST",
                    "/fapi/v1/positionSide/dual",
                    credentials,
                    Map.of("dualSidePosition", "true")
            );
        } catch (BinancePrivateApiException exception) {
            if (!Integer.valueOf(-4059).equals(exception.code())) {
                throw exception;
            }
        }
        PositionModeObservation verified = observePositionMode(credentials);
        if (!verified.consistentHedgeMode()) {
            throw new BinancePrivateApiException(
                    verified.consistent()
                            ? "币安账户未能切换为双向持仓模式"
                            : "币安持仓模式接口状态不一致，请稍后重试",
                    null
            );
        }
        return "HEDGE";
    }

    private PositionModeObservation observePositionMode(
            BinanceCredentials credentials
    ) {
        JsonNode positionMode = signedGet(
                "/fapi/v1/positionSide/dual",
                credentials,
                Map.of()
        );
        JsonNode accountConfiguration = signedGet(
                "/fapi/v1/accountConfig",
                credentials,
                Map.of()
        );
        return new PositionModeObservation(
                positionMode.path("dualSidePosition").asBoolean(false),
                accountConfiguration.path("dualSidePosition")
                        .asBoolean(false)
        );
    }

    @Override
    public AccountSetupResult enforceHedgeModeAndMaximumLeverage(
            BinanceCredentials credentials,
            String quoteAsset
    ) {
        String positionMode = enforceHedgeMode(credentials);
        String normalizedQuoteAsset = requireText(quoteAsset, "quoteAsset")
                .toUpperCase(Locale.ROOT);

        Set<String> activeSymbols = activePerpetualSymbols(
                publicGet("/fapi/v1/exchangeInfo", Map.of()),
                normalizedQuoteAsset
        );
        Map<String, Integer> maximumLeverageBySymbol =
                maximumLeverageBySymbol(signedGet(
                        "/fapi/v1/leverageBracket",
                        credentials,
                        Map.of()
                ));
        int configured = 0;
        for (String symbol : activeSymbols) {
            Integer maximumLeverage = maximumLeverageBySymbol.get(symbol);
            if (maximumLeverage == null || maximumLeverage < 1) {
                throw new BinancePrivateApiException(
                        "币安未返回" + symbol + "的最大杠杆档位",
                        null
                );
            }
            JsonNode response = signedRequest(
                    "POST",
                    "/fapi/v1/leverage",
                    credentials,
                    Map.of(
                            "symbol", symbol,
                            "leverage", Integer.toString(maximumLeverage)
                    )
            );
            int accepted = response.path("leverage").asInt(0);
            if (accepted != maximumLeverage) {
                throw new BinancePrivateApiException(
                        "币安未接受" + symbol + "的最大杠杆设置",
                        null
                );
            }
            configured++;
        }
        return new AccountSetupResult(positionMode, configured);
    }

    @Override
    public LeverageSnapshot leverage(
            BinanceCredentials credentials,
            String symbol
    ) {
        String normalized = requireText(symbol, "symbol")
                .toUpperCase(Locale.ROOT);
        JsonNode configuration = selectSymbolConfiguration(
                signedGet(
                        "/fapi/v1/symbolConfig",
                        credentials,
                        Map.of("symbol", normalized)
                ),
                normalized
        );
        List<LeverageBracket> brackets = leverageBrackets(
                signedGet(
                        "/fapi/v1/leverageBracket",
                        credentials,
                        Map.of("symbol", normalized)
                ),
                normalized
        );
        return new LeverageSnapshot(
                normalized,
                configuration.path("leverage").asInt(0),
                maximumLeverage(brackets),
                decimal(configuration, "maxNotionalValue"),
                brackets
        );
    }

    @Override
    public LeverageSnapshot changeLeverage(
            BinanceCredentials credentials,
            String symbol,
            int leverage
    ) {
        String normalized = requireText(symbol, "symbol")
                .toUpperCase(Locale.ROOT);
        List<LeverageBracket> brackets = leverageBrackets(
                signedGet(
                        "/fapi/v1/leverageBracket",
                        credentials,
                        Map.of("symbol", normalized)
                ),
                normalized
        );
        int maximum = maximumLeverage(brackets);
        if (leverage < 1 || leverage > maximum) {
            throw new IllegalArgumentException(
                    "杠杆倍数应在1到" + maximum + "倍之间"
            );
        }
        JsonNode response = signedRequest(
                "POST",
                "/fapi/v1/leverage",
                credentials,
                Map.of(
                        "symbol", normalized,
                        "leverage", Integer.toString(leverage)
                )
        );
        int accepted = response.path("leverage").asInt(0);
        if (accepted != leverage) {
            throw new BinancePrivateApiException(
                    "币安未接受" + normalized + "的杠杆设置",
                    null
            );
        }
        return new LeverageSnapshot(
                normalized,
                accepted,
                maximum,
                decimal(response, "maxNotionalValue"),
                brackets
        );
    }

    @Override
    public String createListenKey(BinanceCredentials credentials) {
        JsonNode response = apiKeyRequest(
                "POST",
                "/fapi/v1/listenKey",
                credentials,
                Map.of()
        );
        String listenKey = response.path("listenKey").asText();
        if (!StringUtils.hasText(listenKey)) {
            throw new BinancePrivateApiException(
                    "Binance listenKey响应无法解析",
                    null
            );
        }
        return listenKey;
    }

    @Override
    public void keepAliveListenKey(
            BinanceCredentials credentials,
            String listenKey
    ) {
        requireListenKey(listenKey);
        apiKeyRequest(
                "PUT",
                "/fapi/v1/listenKey",
                credentials,
                Map.of("listenKey", listenKey)
        );
    }

    @Override
    public void closeListenKey(
            BinanceCredentials credentials,
            String listenKey
    ) {
        requireListenKey(listenKey);
        apiKeyRequest(
                "DELETE",
                "/fapi/v1/listenKey",
                credentials,
                Map.of("listenKey", listenKey)
        );
    }

    @Override
    public ReconciliationSnapshot reconciliationSnapshot(
            BinanceCredentials credentials,
            String preferredAsset,
            boolean includeOpenOrders
    ) {
        JsonNode account = signedGet(
                "/fapi/v3/account",
                credentials,
                Map.of()
        );
        JsonNode positions = signedGet(
                "/fapi/v3/positionRisk",
                credentials,
                Map.of()
        );
        JsonNode regularOrders = includeOpenOrders
                ? signedGet(
                        "/fapi/v1/openOrders",
                        credentials,
                        Map.of()
                )
                : objectMapper.createArrayNode();
        JsonNode algoOrders = includeOpenOrders
                ? signedGet(
                        "/fapi/v1/openAlgoOrders",
                        credentials,
                        Map.of()
                )
                : objectMapper.createArrayNode();
        JsonNode positionMode = signedGet(
                "/fapi/v1/positionSide/dual",
                credentials,
                Map.of()
        );
        long syncedAt = System.currentTimeMillis();
        AccountBalance selected = selectBalance(account, preferredAsset);
        return new ReconciliationSnapshot(
                selected.marginBalance(),
                selected.unrealizedProfit(),
                selected.asset(),
                decodePositionMode(positionMode),
                syncedAt,
                decodeBalances(account),
                decodePositions(positions),
                decodeRegularOrders(regularOrders),
                decodeAlgoOrders(algoOrders)
        );
    }

    @Override
    public Optional<OrderSnapshot> queryRegularOrder(
            BinanceCredentials credentials,
            String symbol,
            String clientOrderId,
            String exchangeOrderId
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        parameters.put("symbol", requireText(symbol, "symbol"));
        if (StringUtils.hasText(exchangeOrderId)) {
            parameters.put("orderId", exchangeOrderId);
        } else {
            parameters.put(
                    "origClientOrderId",
                    requireText(clientOrderId, "clientOrderId")
            );
        }
        try {
            return Optional.of(decodeRegularOrder(signedGet(
                    "/fapi/v1/order",
                    credentials,
                    parameters
            )));
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                return Optional.empty();
            }
            throw exception;
        }
    }

    @Override
    public Optional<OrderSnapshot> queryAlgoOrder(
            BinanceCredentials credentials,
            String clientAlgoId,
            String exchangeAlgoId
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        if (StringUtils.hasText(exchangeAlgoId)) {
            parameters.put("algoId", exchangeAlgoId);
        } else {
            parameters.put(
                    "clientAlgoId",
                    requireText(clientAlgoId, "clientAlgoId")
            );
        }
        try {
            JsonNode response = signedGet(
                    "/fapi/v1/algoOrder",
                    credentials,
                    parameters
            );
            JsonNode order = response.has("order")
                    ? response.path("order")
                    : response;
            return Optional.of(decodeAlgoOrder(order));
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                return Optional.empty();
            }
            throw exception;
        }
    }

    @Override
    public List<FillSnapshot> userTrades(
            BinanceCredentials credentials,
            String symbol,
            long startTimeMillis
    ) {
        long sevenDays = Duration.ofDays(7).toMillis();
        long boundedStart = Math.max(
                System.currentTimeMillis() - sevenDays + 1,
                startTimeMillis
        );
        JsonNode response = signedGet(
                "/fapi/v1/userTrades",
                credentials,
                Map.of(
                        "symbol", requireText(symbol, "symbol"),
                        "startTime", Long.toString(boundedStart),
                        "limit", "1000"
                )
        );
        return decodeFills(response);
    }

    @Override
    public List<OrderSnapshot> recentRegularOrders(
            BinanceCredentials credentials,
            String symbol,
            long startTimeMillis
    ) {
        long sevenDays = Duration.ofDays(7).toMillis();
        long boundedStart = Math.max(
                System.currentTimeMillis() - sevenDays + 1,
                startTimeMillis
        );
        return decodeRegularOrders(signedGet(
                "/fapi/v1/allOrders",
                credentials,
                Map.of(
                        "symbol", requireText(symbol, "symbol"),
                        "startTime", Long.toString(boundedStart),
                        "limit", "1000"
                )
        ));
    }

    @Override
    public SymbolRules symbolRules(String symbol) {
        String normalized = requireText(symbol, "symbol")
                .toUpperCase(Locale.ROOT);
        long now = System.currentTimeMillis();
        CachedSymbolRules cached = symbolRulesCache.get(normalized);
        if (cached != null && cached.expiresAtMillis() > now) {
            return cached.rules();
        }
        JsonNode response = publicGet(
                "/fapi/v1/exchangeInfo",
                Map.of("symbol", normalized)
        );
        JsonNode selected = null;
        for (JsonNode candidate : response.path("symbols")) {
            if (normalized.equals(candidate.path("symbol").asText())) {
                selected = candidate;
                break;
            }
        }
        if (selected == null) {
            throw new BinancePrivateApiException(
                    "Binance交易规则中不存在该交易对",
                    null
            );
        }
        SymbolRules rules = decodeSymbolRules(selected);
        symbolRulesCache.put(
                normalized,
                new CachedSymbolRules(rules, now + Duration.ofMinutes(5).toMillis())
        );
        return rules;
    }

    @Override
    public PriceSnapshot priceSnapshot(String symbol) {
        String normalized = requireText(symbol, "symbol")
                .toUpperCase(Locale.ROOT);
        JsonNode premium = publicGet(
                "/fapi/v1/premiumIndex",
                Map.of("symbol", normalized)
        );
        JsonNode book = publicGet(
                "/fapi/v1/ticker/bookTicker",
                Map.of("symbol", normalized)
        );
        return new PriceSnapshot(
                normalized,
                decimal(premium, "markPrice"),
                decimal(book, "bidPrice"),
                decimal(book, "askPrice"),
                Math.max(
                        premium.path("time").asLong(0),
                        book.path("time").asLong(0)
                )
        );
    }

    @Override
    public OrderSnapshot placeRegularOrder(
            BinanceCredentials credentials,
            RegularOrderRequest request
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        parameters.put("symbol", requireText(request.symbol(), "symbol"));
        parameters.put("side", requireText(request.side(), "side"));
        putPositionSide(parameters, request.positionSide());
        parameters.put("type", requireText(request.type(), "type"));
        parameters.put("quantity", decimalText(request.quantity(), "quantity"));
        put(parameters, "timeInForce", request.timeInForce());
        putDecimal(parameters, "price", request.price());
        if (request.reduceOnly()) {
            parameters.put("reduceOnly", "true");
        }
        parameters.put(
                "newClientOrderId",
                requireText(request.clientOrderId(), "clientOrderId")
        );
        parameters.put("newOrderRespType", "RESULT");
        return decodeRegularOrder(signedRequest(
                "POST",
                "/fapi/v1/order",
                credentials,
                parameters
        ));
    }

    @Override
    public OrderSnapshot cancelRegularOrder(
            BinanceCredentials credentials,
            String symbol,
            String clientOrderId,
            String exchangeOrderId
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        parameters.put("symbol", requireText(symbol, "symbol"));
        if (StringUtils.hasText(exchangeOrderId)) {
            parameters.put("orderId", exchangeOrderId);
        } else {
            parameters.put(
                    "origClientOrderId",
                    requireText(clientOrderId, "clientOrderId")
            );
        }
        return decodeRegularOrder(signedRequest(
                "DELETE",
                "/fapi/v1/order",
                credentials,
                parameters
        ));
    }

    @Override
    public OrderSnapshot placeAlgoOrder(
            BinanceCredentials credentials,
            AlgoOrderRequest request
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        parameters.put("algoType", "CONDITIONAL");
        parameters.put("symbol", requireText(request.symbol(), "symbol"));
        parameters.put("side", requireText(request.side(), "side"));
        putPositionSide(parameters, request.positionSide());
        parameters.put("type", requireText(request.type(), "type"));
        put(parameters, "timeInForce", request.timeInForce());
        put(parameters, "workingType", request.workingType());
        putDecimal(parameters, "quantity", request.quantity());
        putDecimal(parameters, "price", request.price());
        putDecimal(parameters, "triggerPrice", request.triggerPrice());
        if (request.reduceOnly()) {
            parameters.put("reduceOnly", "true");
        }
        if (request.closePosition()) {
            parameters.put("closePosition", "true");
        }
        parameters.put(
                "clientAlgoId",
                requireText(request.clientAlgoId(), "clientAlgoId")
        );
        JsonNode response = signedRequest(
                "POST",
                "/fapi/v1/algoOrder",
                credentials,
                parameters
        );
        JsonNode order = response.has("order") ? response.path("order") : response;
        return fillAlgoRequestDefaults(decodeAlgoOrder(order), request);
    }

    @Override
    public OrderSnapshot cancelAlgoOrder(
            BinanceCredentials credentials,
            String clientAlgoId,
            String exchangeAlgoId
    ) {
        LinkedHashMap<String, String> parameters = new LinkedHashMap<>();
        if (StringUtils.hasText(exchangeAlgoId)) {
            parameters.put("algoId", exchangeAlgoId);
        } else {
            parameters.put(
                    "clientAlgoId",
                    requireText(clientAlgoId, "clientAlgoId")
            );
        }
        JsonNode response = signedRequest(
                "DELETE",
                "/fapi/v1/algoOrder",
                credentials,
                parameters
        );
        JsonNode order = response.has("order") ? response.path("order") : response;
        return decodeAlgoOrder(order);
    }

    private JsonNode signedGet(
            String path,
            BinanceCredentials credentials,
            Map<String, String> parameters
    ) {
        return signedRequest("GET", path, credentials, parameters);
    }

    private JsonNode signedRequest(
            String method,
            String path,
            BinanceCredentials credentials,
            Map<String, String> parameters
    ) {
        try {
            return signedRequestOnce(method, path, credentials, parameters);
        } catch (BinancePrivateApiException exception) {
            if (Integer.valueOf(-1021).equals(exception.code())) {
                synchronizeServerTime();
                return signedRequestOnce(method, path, credentials, parameters);
            }
            throw exception;
        }
    }

    private JsonNode signedRequestOnce(
            String method,
            String path,
            BinanceCredentials credentials,
            Map<String, String> parameters
    ) {
        acquireRequestBudget(requestWeight(method, path, parameters));
        LinkedHashMap<String, String> signedParameters = new LinkedHashMap<>();
        signedParameters.putAll(parameters);
        signedParameters.put(
                "recvWindow",
                Long.toString(properties.getBinance().getRecvWindowMillis())
        );
        signedParameters.put(
                "timestamp",
                Long.toString(
                        System.currentTimeMillis() + serverTimeOffsetMillis
                )
        );
        String payload = encodeQuery(signedParameters);
        String query = payload + "&signature="
                + signature(payload, credentials.secretKey());
        HttpRequest request = requestBuilder(path + "?" + query)
                .header("X-MBX-APIKEY", credentials.apiKey())
                .method(method, HttpRequest.BodyPublishers.noBody())
                .build();
        return sendJson(
                request,
                new RestDiagnostic(method, path, signedParameters)
        );
    }

    private JsonNode publicGet(String path, Map<String, String> parameters) {
        acquireRequestBudget(requestWeight("GET", path, parameters));
        String query = encodeQuery(parameters);
        HttpRequest request = requestBuilder(
                query.isEmpty() ? path : path + "?" + query
        ).GET().build();
        return sendJson(request);
    }

    private JsonNode apiKeyRequest(
            String method,
            String path,
            BinanceCredentials credentials,
            Map<String, String> parameters
    ) {
        acquireRequestBudget(1);
        String query = encodeQuery(parameters);
        String target = query.isEmpty() ? path : path + "?" + query;
        HttpRequest.Builder builder = requestBuilder(target)
                .header("X-MBX-APIKEY", credentials.apiKey());
        return sendJson(
                builder.method(
                        method,
                        HttpRequest.BodyPublishers.noBody()
                ).build(),
                new RestDiagnostic(method, path, parameters)
        );
    }

    private HttpRequest.Builder requestBuilder(String pathAndQuery) {
        return HttpRequest.newBuilder(resolve(pathAndQuery))
                .timeout(Duration.ofMillis(
                        properties.getBinance().getRequestTimeoutMillis()
                ))
                .header("Accept", "application/json");
    }

    private void synchronizeServerTime() {
        acquireRequestBudget(1);
        HttpRequest request = requestBuilder("/fapi/v1/time")
                .GET()
                .build();
        long before = System.currentTimeMillis();
        JsonNode response = sendJson(request);
        long after = System.currentTimeMillis();
        long serverTime = response.path("serverTime").asLong(0);
        if (serverTime <= 0) {
            throw new BinancePrivateApiException(
                    "Binance时间响应无法解析",
                    null
            );
        }
        serverTimeOffsetMillis = serverTime - ((before + after) / 2);
    }

    private JsonNode sendJson(HttpRequest request) {
        return sendJson(request, null);
    }

    private JsonNode sendJson(
            HttpRequest request,
            RestDiagnostic diagnostic
    ) {
        try {
            HttpResponse<String> response = httpClient.send(
                    request,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8)
            );
            String responseBody = response.body();
            long retryAtMillis = requestBudget.observeResponse(
                    response.statusCode(),
                    response.headers(),
                    responseBody
            );
            JsonNode body = responseBody == null || responseBody.isBlank()
                    ? NullNode.getInstance()
                    : objectMapper.readTree(responseBody);
            logDiagnosticResponse(diagnostic, response.statusCode(), body);
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                Integer code = body != null && body.has("code")
                        ? body.path("code").asInt()
                        : null;
                String message = body == null
                        ? ""
                        : body.path("msg").asText("");
                throw new BinancePrivateApiException(
                        response.statusCode(),
                        code,
                        message,
                        retryAtMillis
                );
            }
            return body == null ? NullNode.getInstance() : body;
        } catch (HttpTimeoutException exception) {
            logDiagnosticFailure(diagnostic, exception);
            throw new BinancePrivateApiException(
                    "Binance私有接口请求超时",
                    exception
            );
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            logDiagnosticFailure(diagnostic, exception);
            throw new BinancePrivateApiException(
                    "Binance私有接口请求被中断",
                    exception
            );
        } catch (IOException exception) {
            logDiagnosticFailure(diagnostic, exception);
            throw new BinancePrivateApiException(
                    "Binance私有接口网络异常",
                    exception
            );
        }
    }

    private void acquireRequestBudget(int weight) {
        try {
            requestBudget.acquire(weight);
        } catch (BinanceRestRateLimitException exception) {
            throw new BinancePrivateApiException(
                    429,
                    -1003,
                    exception.getMessage(),
                    exception.retryAtMillis()
            );
        }
    }

    private void logDiagnosticResponse(
            RestDiagnostic diagnostic,
            int status,
            JsonNode response
    ) {
        if (diagnostic == null
                || !properties.getBinance()
                .isDiagnosticRestLoggingEnabled()) {
            return;
        }
        log.info(
                "BINANCE_PRIVATE_REST method={} path={} params={} status={} response={}",
                diagnostic.method(),
                diagnostic.path(),
                sanitizeParameters(diagnostic.parameters()),
                status,
                sanitizeJson(response)
        );
    }

    private void logDiagnosticFailure(
            RestDiagnostic diagnostic,
            Exception exception
    ) {
        if (diagnostic == null
                || !properties.getBinance()
                .isDiagnosticRestLoggingEnabled()) {
            return;
        }
        log.warn(
                "BINANCE_PRIVATE_REST method={} path={} params={} transportError={}",
                diagnostic.method(),
                diagnostic.path(),
                sanitizeParameters(diagnostic.parameters()),
                exception.getClass().getSimpleName()
        );
    }

    private Map<String, String> sanitizeParameters(
            Map<String, String> parameters
    ) {
        LinkedHashMap<String, String> sanitized = new LinkedHashMap<>();
        parameters.forEach((name, value) -> sanitized.put(
                name,
                isSensitiveField(name) ? "<redacted>" : value
        ));
        return sanitized;
    }

    private JsonNode sanitizeJson(JsonNode source) {
        if (source == null || source.isNull()) {
            return NullNode.getInstance();
        }
        if (source.isObject()) {
            ObjectNode sanitized = objectMapper.createObjectNode();
            source.properties().forEach(entry -> {
                if (isSensitiveField(entry.getKey())) {
                    sanitized.put(entry.getKey(), "<redacted>");
                } else {
                    sanitized.set(
                            entry.getKey(),
                            sanitizeJson(entry.getValue())
                    );
                }
            });
            return sanitized;
        }
        if (source.isArray()) {
            ArrayNode sanitized = objectMapper.createArrayNode();
            source.forEach(value -> sanitized.add(sanitizeJson(value)));
            return sanitized;
        }
        return source.deepCopy();
    }

    private boolean isSensitiveField(String fieldName) {
        String normalized = fieldName.toLowerCase(Locale.ROOT)
                .replace("-", "")
                .replace("_", "");
        return normalized.equals("signature")
                || normalized.equals("secret")
                || normalized.equals("secretkey")
                || normalized.equals("apisecret")
                || normalized.equals("apikey")
                || normalized.equals("listenkey");
    }

    private List<BalanceSnapshot> decodeBalances(JsonNode account) {
        List<BalanceSnapshot> balances = new ArrayList<>();
        if (!account.path("assets").isArray()) {
            return List.of();
        }
        for (JsonNode asset : account.path("assets")) {
            balances.add(new BalanceSnapshot(
                    asset.path("asset").asText(),
                    decimal(asset, "walletBalance"),
                    decimal(asset, "crossWalletBalance"),
                    decimal(asset, "marginBalance"),
                    decimal(asset, "unrealizedProfit")
            ));
        }
        balances.sort(Comparator.comparing(BalanceSnapshot::asset));
        return List.copyOf(balances);
    }

    private SymbolRules decodeSymbolRules(JsonNode symbol) {
        JsonNode priceFilter = filter(symbol, "PRICE_FILTER");
        JsonNode lot = filter(symbol, "LOT_SIZE");
        JsonNode marketLot = filter(symbol, "MARKET_LOT_SIZE");
        JsonNode notional = filter(symbol, "MIN_NOTIONAL");
        if (notional == null) {
            notional = filter(symbol, "NOTIONAL");
        }
        BigDecimal lotStep = decimal(lot, "stepSize");
        BigDecimal marketStep = decimalOr(marketLot, "stepSize", lotStep);
        if (marketStep.signum() <= 0) {
            marketStep = lotStep;
        }
        return new SymbolRules(
                symbol.path("symbol").asText(),
                symbol.path("status").asText(),
                symbol.path("baseAsset").asText(),
                symbol.path("quoteAsset").asText(),
                decimal(priceFilter, "tickSize"),
                decimal(lot, "minQty"),
                decimal(lot, "maxQty"),
                lotStep,
                decimalOr(marketLot, "minQty", decimal(lot, "minQty")),
                decimalOr(marketLot, "maxQty", decimal(lot, "maxQty")),
                marketStep,
                notional == null
                        ? BigDecimal.ZERO
                        : firstDecimal(notional, "notional", "minNotional")
        );
    }

    private Set<String> activePerpetualSymbols(
            JsonNode exchangeInfo,
            String quoteAsset
    ) {
        if (!exchangeInfo.path("symbols").isArray()) {
            throw new BinancePrivateApiException(
                    "币安交易对列表无法解析",
                    null
            );
        }
        Set<String> symbols = new TreeSet<>();
        for (JsonNode symbol : exchangeInfo.path("symbols")) {
            if ("TRADING".equalsIgnoreCase(symbol.path("status").asText())
                    && "PERPETUAL".equalsIgnoreCase(
                            symbol.path("contractType").asText()
                    )
                    && quoteAsset.equalsIgnoreCase(
                            symbol.path("quoteAsset").asText()
                    )) {
                String name = symbol.path("symbol").asText()
                        .toUpperCase(Locale.ROOT);
                if (StringUtils.hasText(name)) {
                    symbols.add(name);
                }
            }
        }
        if (symbols.isEmpty()) {
            throw new BinancePrivateApiException(
                    "币安没有返回可配置的" + quoteAsset + "永续合约",
                    null
            );
        }
        return symbols;
    }

    private Map<String, Integer> maximumLeverageBySymbol(JsonNode response) {
        List<JsonNode> entries = new ArrayList<>();
        if (response.isArray()) {
            response.forEach(entries::add);
        } else if (response.isObject()) {
            entries.add(response);
        } else {
            throw new BinancePrivateApiException(
                    "币安杠杆档位响应无法解析",
                    null
            );
        }
        Map<String, Integer> result = new LinkedHashMap<>();
        for (JsonNode entry : entries) {
            String symbol = entry.path("symbol").asText()
                    .toUpperCase(Locale.ROOT);
            int maximum = 0;
            for (JsonNode bracket : entry.path("brackets")) {
                maximum = Math.max(
                        maximum,
                        bracket.path("initialLeverage").asInt(0)
                );
            }
            if (StringUtils.hasText(symbol) && maximum > 0) {
                result.put(symbol, Math.min(125, maximum));
            }
        }
        return result;
    }

    private JsonNode selectSymbolConfiguration(
            JsonNode response,
            String symbol
    ) {
        if (response.isObject()
                && symbol.equalsIgnoreCase(response.path("symbol").asText())) {
            return response;
        }
        if (response.isArray()) {
            for (JsonNode entry : response) {
                if (symbol.equalsIgnoreCase(entry.path("symbol").asText())) {
                    return entry;
                }
            }
        }
        throw new BinancePrivateApiException(
                "币安未返回" + symbol + "的杠杆配置",
                null
        );
    }

    private List<LeverageBracket> leverageBrackets(
            JsonNode response,
            String symbol
    ) {
        JsonNode selected = null;
        if (response.isObject()
                && symbol.equalsIgnoreCase(response.path("symbol").asText())) {
            selected = response;
        } else if (response.isArray()) {
            for (JsonNode entry : response) {
                if (symbol.equalsIgnoreCase(entry.path("symbol").asText())) {
                    selected = entry;
                    break;
                }
            }
        }
        if (selected == null || !selected.path("brackets").isArray()) {
            throw new BinancePrivateApiException(
                    "币安未返回" + symbol + "的杠杆档位",
                    null
            );
        }
        List<LeverageBracket> brackets = new ArrayList<>();
        for (JsonNode bracket : selected.path("brackets")) {
            int initialLeverage = Math.min(
                    125,
                    bracket.path("initialLeverage").asInt(0)
            );
            BigDecimal floor = decimal(bracket, "notionalFloor");
            BigDecimal cap = decimal(bracket, "notionalCap");
            if (initialLeverage > 0 && cap.signum() > 0) {
                brackets.add(new LeverageBracket(
                        initialLeverage,
                        floor.max(BigDecimal.ZERO),
                        cap
                ));
            }
        }
        brackets.sort(Comparator.comparing(LeverageBracket::notionalFloor));
        if (brackets.isEmpty()) {
            throw new BinancePrivateApiException(
                    "币安返回的" + symbol + "杠杆档位为空",
                    null
            );
        }
        return List.copyOf(brackets);
    }

    private int maximumLeverage(List<LeverageBracket> brackets) {
        return brackets.stream()
                .mapToInt(LeverageBracket::initialLeverage)
                .max()
                .orElseThrow();
    }

    private JsonNode filter(JsonNode symbol, String filterType) {
        for (JsonNode filter : symbol.path("filters")) {
            if (filterType.equals(filter.path("filterType").asText())) {
                return filter;
            }
        }
        return null;
    }

    private BigDecimal decimalOr(
            JsonNode node,
            String field,
            BigDecimal fallback
    ) {
        if (node == null || !node.hasNonNull(field)) {
            return fallback;
        }
        BigDecimal value = decimal(node, field);
        return value.signum() > 0 ? value : fallback;
    }

    private OrderSnapshot fillAlgoRequestDefaults(
            OrderSnapshot snapshot,
            AlgoOrderRequest request
    ) {
        long now = System.currentTimeMillis();
        return new OrderSnapshot(
                "ALGO",
                textOr(snapshot.symbol(), request.symbol()),
                textOr(snapshot.side(), request.side()),
                textOr(snapshot.positionSide(), request.positionSide()),
                textOr(snapshot.orderType(), request.type()),
                textOr(snapshot.timeInForce(), request.timeInForce()),
                textOr(snapshot.workingType(), request.workingType()),
                null,
                null,
                textOr(snapshot.clientAlgoId(), request.clientAlgoId()),
                snapshot.exchangeAlgoId(),
                snapshot.actualOrderId(),
                positiveOr(snapshot.quantity(), request.quantity()),
                positiveOr(snapshot.price(), request.price()),
                positiveOr(snapshot.triggerPrice(), request.triggerPrice()),
                snapshot.executedQuantity(),
                snapshot.cumulativeQuote(),
                snapshot.averagePrice(),
                request.reduceOnly(),
                request.closePosition(),
                "UNKNOWN".equals(snapshot.exchangeStatus())
                        ? "NEW"
                        : snapshot.exchangeStatus(),
                snapshot.createTimeMillis() > 0
                        ? snapshot.createTimeMillis()
                        : now,
                snapshot.updateTimeMillis() > 0
                        ? snapshot.updateTimeMillis()
                        : now
        );
    }

    private BigDecimal positiveOr(BigDecimal value, BigDecimal fallback) {
        return value != null && value.signum() > 0
                ? value
                : fallback == null ? BigDecimal.ZERO : fallback;
    }

    private String textOr(String value, String fallback) {
        return StringUtils.hasText(value) && !"UNKNOWN".equals(value)
                ? value
                : fallback;
    }

    private AccountBalance selectBalance(
            JsonNode account,
            String preferredAsset
    ) {
        for (BalanceSnapshot asset : decodeBalances(account)) {
            if (preferredAsset.equalsIgnoreCase(asset.asset())) {
                return new AccountBalance(
                        asset.asset(),
                        asset.marginBalance(),
                        asset.unrealizedProfit()
                );
            }
        }
        return new AccountBalance(
                preferredAsset,
                decimal(account, "totalMarginBalance"),
                decimal(account, "totalUnrealizedProfit")
        );
    }

    private List<PositionSnapshot> decodePositions(JsonNode response) {
        if (!response.isArray()) {
            throw new BinancePrivateApiException(
                    "Binance仓位响应无法解析",
                    null
            );
        }
        List<PositionSnapshot> positions = new ArrayList<>();
        for (JsonNode item : response) {
            BigDecimal quantity = decimal(item, "positionAmt");
            if (quantity.signum() == 0) {
                continue;
            }
            positions.add(new PositionSnapshot(
                    item.path("symbol").asText(),
                    normalizePositionSide(item.path("positionSide").asText()),
                    quantity,
                    decimal(item, "entryPrice"),
                    decimal(item, "breakEvenPrice"),
                    decimal(item, "markPrice"),
                    decimal(item, "liquidationPrice"),
                    item.path("leverage").asInt(1),
                    item.path("marginType").asText("cross")
                            .toLowerCase(Locale.ROOT),
                    decimal(item, "isolatedMargin"),
                    decimal(item, "unRealizedProfit"),
                    item.path("updateTime").asLong(0)
            ));
        }
        positions.sort(Comparator
                .comparing(PositionSnapshot::symbol)
                .thenComparing(PositionSnapshot::positionSide));
        return List.copyOf(positions);
    }

    private List<OrderSnapshot> decodeRegularOrders(JsonNode response) {
        if (!response.isArray()) {
            throw new BinancePrivateApiException(
                    "Binance普通挂单响应无法解析",
                    null
            );
        }
        List<OrderSnapshot> orders = new ArrayList<>();
        response.forEach(item -> orders.add(decodeRegularOrder(item)));
        return List.copyOf(orders);
    }

    private OrderSnapshot decodeRegularOrder(JsonNode item) {
        return new OrderSnapshot(
                "REGULAR",
                item.path("symbol").asText(),
                item.path("side").asText(),
                normalizePositionSide(item.path("positionSide").asText()),
                item.path("type").asText("UNKNOWN"),
                nullableText(item, "timeInForce"),
                nullableText(item, "workingType"),
                nullableText(item, "clientOrderId"),
                nullableIdentifier(item, "orderId"),
                null,
                null,
                null,
                decimal(item, "origQty"),
                decimal(item, "price"),
                decimal(item, "stopPrice"),
                decimal(item, "executedQty"),
                decimal(item, "cumQuote"),
                decimal(item, "avgPrice"),
                item.path("reduceOnly").asBoolean(false),
                item.path("closePosition").asBoolean(false),
                item.path("status").asText("UNKNOWN"),
                item.path("time").asLong(item.path("updateTime").asLong(0)),
                item.path("updateTime").asLong(item.path("time").asLong(0))
        );
    }

    private List<OrderSnapshot> decodeAlgoOrders(JsonNode response) {
        JsonNode ordersNode = response.isArray()
                ? response
                : response.path("orders");
        if (!ordersNode.isArray()) {
            throw new BinancePrivateApiException(
                    "Binance Algo挂单响应无法解析",
                    null
            );
        }
        List<OrderSnapshot> orders = new ArrayList<>();
        ordersNode.forEach(item -> orders.add(decodeAlgoOrder(item)));
        return List.copyOf(orders);
    }

    private OrderSnapshot decodeAlgoOrder(JsonNode item) {
        return new OrderSnapshot(
                "ALGO",
                item.path("symbol").asText(),
                item.path("side").asText(),
                normalizePositionSide(item.path("positionSide").asText()),
                firstText(item, "orderType", "type", "algoType"),
                nullableText(item, "timeInForce"),
                nullableText(item, "workingType"),
                null,
                null,
                firstNullableText(item, "clientAlgoId", "clientOrderId"),
                firstNullableIdentifier(item, "algoId", "orderId"),
                firstNullableIdentifier(item, "actualOrderId", "actualOrderIdList"),
                firstDecimal(item, "quantity", "origQty"),
                decimal(item, "price"),
                firstDecimal(item, "triggerPrice", "stopPrice"),
                firstDecimal(item, "executedQty", "executedQuantity"),
                firstDecimal(item, "cumQuote", "cumulativeQuote"),
                firstDecimal(item, "avgPrice", "averagePrice"),
                item.path("reduceOnly").asBoolean(false),
                item.path("closePosition").asBoolean(false),
                firstText(item, "algoStatus", "status"),
                firstLong(item, "createTime", "time", "updateTime"),
                firstLong(item, "updateTime", "time", "createTime")
        );
    }

    private List<FillSnapshot> decodeFills(JsonNode response) {
        if (!response.isArray()) {
            throw new BinancePrivateApiException(
                    "Binance成交响应无法解析",
                    null
            );
        }
        List<FillSnapshot> fills = new ArrayList<>();
        for (JsonNode item : response) {
            BigDecimal price = decimal(item, "price");
            BigDecimal quantity = decimal(item, "qty");
            BigDecimal quote = item.has("quoteQty")
                    ? decimal(item, "quoteQty")
                    : price.multiply(quantity);
            fills.add(new FillSnapshot(
                    item.path("symbol").asText(),
                    nullableIdentifier(item, "id"),
                    nullableIdentifier(item, "orderId"),
                    item.path("side").asText(),
                    normalizePositionSide(item.path("positionSide").asText()),
                    price,
                    quantity,
                    quote,
                    decimal(item, "commission"),
                    nullableText(item, "commissionAsset"),
                    decimal(item, "realizedPnl"),
                    item.path("maker").asBoolean(false),
                    item.path("time").asLong(0)
            ));
        }
        return List.copyOf(fills);
    }

    private String decodePositionMode(JsonNode response) {
        return response.path("dualSidePosition").asBoolean(false)
                ? "HEDGE"
                : "ONE_WAY";
    }

    private String normalizePositionSide(String positionSide) {
        String normalized = positionSide == null
                ? ""
                : positionSide.toUpperCase(Locale.ROOT);
        return switch (normalized) {
            case "LONG", "SHORT" -> normalized;
            default -> "BOTH";
        };
    }

    private BigDecimal decimal(JsonNode node, String field) {
        if (node == null) {
            return BigDecimal.ZERO;
        }
        String value = node.path(field).asText("0");
        try {
            return new BigDecimal(value);
        } catch (NumberFormatException exception) {
            throw new BinancePrivateApiException(
                    "Binance账户数值无法解析",
                    exception
            );
        }
    }

    private BigDecimal firstDecimal(JsonNode node, String... fields) {
        for (String field : fields) {
            if (node.hasNonNull(field) && !node.path(field).asText().isBlank()) {
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
        String value = firstNullableText(node, fields);
        return value == null ? "UNKNOWN" : value;
    }

    private String firstNullableText(JsonNode node, String... fields) {
        for (String field : fields) {
            String value = nullableText(node, field);
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    private String firstNullableIdentifier(JsonNode node, String... fields) {
        for (String field : fields) {
            String value = nullableIdentifier(node, field);
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    private String nullableText(JsonNode node, String field) {
        String value = node.path(field).asText();
        return StringUtils.hasText(value) ? value : null;
    }

    private String nullableIdentifier(JsonNode node, String field) {
        JsonNode value = node.path(field);
        if (value.isMissingNode() || value.isNull()) {
            return null;
        }
        String text = value.asText();
        return StringUtils.hasText(text) && !"0".equals(text) ? text : null;
    }

    private boolean isOrderNotFound(BinancePrivateApiException error) {
        return Integer.valueOf(-2011).equals(error.code())
                || Integer.valueOf(-2013).equals(error.code());
    }

    static boolean isAuthenticationError(BinancePrivateApiException error) {
        return Integer.valueOf(-2014).equals(error.code())
                || Integer.valueOf(-2015).equals(error.code());
    }

    private TradingApiException mapVerificationError(
            BinancePrivateApiException error
    ) {
        return BinanceErrorTranslator.tradingApiException(error);
    }

    private String encodeQuery(Map<String, String> parameters) {
        StringBuilder query = new StringBuilder();
        for (Map.Entry<String, String> entry : parameters.entrySet()) {
            if (entry.getValue() == null) {
                continue;
            }
            if (!query.isEmpty()) {
                query.append('&');
            }
            query.append(urlEncode(entry.getKey()))
                    .append('=')
                    .append(urlEncode(entry.getValue()));
        }
        return query.toString();
    }

    private void put(
            Map<String, String> parameters,
            String name,
            String value
    ) {
        if (StringUtils.hasText(value)) {
            parameters.put(name, value);
        }
    }

    private void putPositionSide(
            Map<String, String> parameters,
            String positionSide
    ) {
        String normalized = requireText(positionSide, "positionSide")
                .toUpperCase(Locale.ROOT);
        if (!"BOTH".equals(normalized)) {
            parameters.put("positionSide", normalized);
        }
    }

    private void putDecimal(
            Map<String, String> parameters,
            String name,
            BigDecimal value
    ) {
        if (value != null && value.signum() > 0) {
            parameters.put(name, value.stripTrailingZeros().toPlainString());
        }
    }

    private String decimalText(BigDecimal value, String name) {
        if (value == null || value.signum() <= 0) {
            throw new IllegalArgumentException(name + " must be positive");
        }
        return value.stripTrailingZeros().toPlainString();
    }

    private int requestWeight(
            String method,
            String path,
            Map<String, String> parameters
    ) {
        if ("/fapi/v1/openOrders".equals(path)
                || "/fapi/v1/openAlgoOrders".equals(path)) {
            return parameters.containsKey("symbol") ? 1 : 40;
        }
        if ("/fapi/v1/userTrades".equals(path)) {
            return 5;
        }
        if ("/fapi/v1/allOrders".equals(path)) {
            return 5;
        }
        if ("/fapi/v1/symbolConfig".equals(path)) {
            return 5;
        }
        if ("/fapi/v1/accountConfig".equals(path)) {
            return 5;
        }
        if ("GET".equals(method)
                && "/fapi/v1/positionSide/dual".equals(path)) {
            return 30;
        }
        if ("/fapi/v3/account".equals(path)
                || "/fapi/v3/positionRisk".equals(path)) {
            return 5;
        }
        return 1;
    }

    private String urlEncode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private String requireText(String value, String name) {
        if (!StringUtils.hasText(value)) {
            throw new IllegalArgumentException(name + " is required");
        }
        return value.trim();
    }

    private void requireListenKey(String listenKey) {
        requireText(listenKey, "listenKey");
    }

    private URI resolve(String pathAndQuery) {
        return URI.create(baseUri.toString() + pathAndQuery);
    }

    private URI normalizeBaseUri(String value) {
        URI uri = URI.create(value);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null) {
            throw new IllegalArgumentException(
                    "trading.binance.rest-base-url must be an HTTPS origin"
            );
        }
        String normalized = uri.toString();
        while (normalized.endsWith("/")) {
            normalized = normalized.substring(0, normalized.length() - 1);
        }
        return URI.create(normalized);
    }

    static String signature(String payload, String secretKey) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(
                    secretKey.getBytes(StandardCharsets.UTF_8),
                    "HmacSHA256"
            ));
            byte[] digest = mac.doFinal(payload.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder(digest.length * 2);
            for (byte value : digest) {
                result.append(String.format("%02x", value));
            }
            return result.toString();
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException(
                    "HMAC-SHA256 is unavailable",
                    exception
            );
        }
    }

    private record AccountBalance(
            String asset,
            BigDecimal marginBalance,
            BigDecimal unrealizedProfit
    ) {
    }

    private record CachedSymbolRules(
            SymbolRules rules,
            long expiresAtMillis
    ) {
    }

    private record RestDiagnostic(
            String method,
            String path,
            Map<String, String> parameters
    ) {
        private RestDiagnostic {
            parameters = new LinkedHashMap<>(parameters);
        }
    }

    private record PositionModeObservation(
            boolean positionModeEndpointHedge,
            boolean accountConfigurationHedge
    ) {
        private boolean consistent() {
            return positionModeEndpointHedge == accountConfigurationHedge;
        }

        private boolean consistentHedgeMode() {
            return positionModeEndpointHedge && accountConfigurationHedge;
        }
    }
}
