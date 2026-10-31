package com.oovso.binance;

import com.binance.connector.client.common.configuration.ClientConfiguration;
import com.binance.connector.client.derivatives_trading_usds_futures.rest.DerivativesTradingUsdsFuturesRestApiUtil;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.oovso.market.KlineStorageProperties;
import com.oovso.market.MarketKline;
import java.io.IOException;
import java.math.BigDecimal;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
public class BinanceUsdmMarketDataClient {

    private static final Logger log =
            LoggerFactory.getLogger(BinanceUsdmMarketDataClient.class);

    private static final Set<String> TRADING_DATA_PERIODS = Set.of(
            "5m", "15m", "30m", "1h", "2h", "4h", "6h", "12h", "1d"
    );

    private static final long TRADING_DATA_CACHE_MILLIS = 30_000L;

    private final BinanceContinuousKlineProperties binanceProperties;

    private final KlineStorageProperties klineProperties;

    private final BinanceRestRequestBudget requestBudget;

    private final HttpClient httpClient;

    private final Map<TradingDataCacheKey, CachedTradingData>
            tradingDataCache = new ConcurrentHashMap<>();

    @Autowired
    public BinanceUsdmMarketDataClient(
            BinanceContinuousKlineProperties binanceProperties,
            KlineStorageProperties klineProperties,
            BinanceRestRequestBudget requestBudget
    ) {
        this(
                binanceProperties,
                klineProperties,
                requestBudget,
                HttpClient.newHttpClient()
        );
    }

    BinanceUsdmMarketDataClient(
            BinanceContinuousKlineProperties binanceProperties,
            KlineStorageProperties klineProperties,
            BinanceRestRequestBudget requestBudget,
            HttpClient httpClient
    ) {
        this.binanceProperties = binanceProperties;
        this.klineProperties = klineProperties;
        this.requestBudget = requestBudget;
        this.httpClient = httpClient;
    }

    public List<BinanceUsdmSymbol> loadTargetSymbols() throws IOException, InterruptedException {
        HttpResponse<String> response = getJsonResponse(
                exchangeInfoUri(),
                "exchangeInfo",
                1
        );

        JsonObject root = JsonParser.parseString(response.body()).getAsJsonObject();
        JsonArray symbols = root.getAsJsonArray("symbols");
        if (symbols == null) {
            return List.of();
        }

        return symbols.asList().stream()
                .map(JsonElement::getAsJsonObject)
                .filter(this::isTargetSymbol)
                .map(this::toSymbol)
                .filter(symbol -> StringUtils.hasText(symbol.pair()))
                .distinct()
                .sorted((left, right) -> left.pair().compareTo(right.pair()))
                .toList();
    }

    public List<MarketKline> loadContinuousKlines(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            long startOpenTimeMs,
            long endOpenTimeExclusive,
            int limit
    ) throws IOException, InterruptedException {
        if (endOpenTimeExclusive <= startOpenTimeMs) {
            return List.of();
        }

        HttpResponse<String> response = getJsonResponse(
                continuousKlinesUri(
                        symbol,
                        intervalCode,
                        startOpenTimeMs,
                        endOpenTimeExclusive - 1,
                        limit
                ),
                "continuousKlines",
                continuousKlineWeight(limit)
        );

        JsonArray root = JsonParser.parseString(response.body()).getAsJsonArray();
        return root.asList().stream()
                .map(JsonElement::getAsJsonArray)
                .map(values -> toKline(symbol, intervalCode, values))
                .filter(kline -> kline.getOpenTimeMs() >= startOpenTimeMs)
                .filter(kline -> kline.getOpenTimeMs() < endOpenTimeExclusive)
                .toList();
    }

    public List<MarketKline> loadRecentContinuousKlines(
            String pair,
            String intervalCode,
            int limit
    ) throws IOException, InterruptedException {
        BinanceUsdmSymbol symbol = new BinanceUsdmSymbol(
                pair.toUpperCase(Locale.ROOT),
                binanceProperties.getContractType(),
                0
        );
        HttpResponse<String> response = getJsonResponse(
                recentContinuousKlinesUri(symbol, intervalCode, limit),
                "recentContinuousKlines",
                continuousKlineWeight(limit)
        );

        JsonArray root = JsonParser.parseString(response.body())
                .getAsJsonArray();
        return root.asList().stream()
                .map(JsonElement::getAsJsonArray)
                .map(values -> toKline(symbol, intervalCode, values))
                .toList();
    }

    public List<MarketKline> loadContinuousKlinesBefore(
            String pair,
            String intervalCode,
            long beforeOpenTimeExclusive,
            int limit
    ) throws IOException, InterruptedException {
        if (beforeOpenTimeExclusive <= 0) {
            return List.of();
        }
        BinanceUsdmSymbol symbol = new BinanceUsdmSymbol(
                pair.toUpperCase(Locale.ROOT),
                binanceProperties.getContractType(),
                0
        );
        HttpResponse<String> response = getJsonResponse(
                continuousKlinesBeforeUri(
                        symbol,
                        intervalCode,
                        beforeOpenTimeExclusive,
                        limit
                ),
                "continuousKlinesBefore",
                continuousKlineWeight(limit)
        );

        JsonArray root = JsonParser.parseString(response.body())
                .getAsJsonArray();
        return root.asList().stream()
                .map(JsonElement::getAsJsonArray)
                .map(values -> toKline(symbol, intervalCode, values))
                .filter(kline ->
                        kline.getOpenTimeMs() < beforeOpenTimeExclusive)
                .toList();
    }

    public Map<String, Ticker24h> load24hTickers() throws IOException, InterruptedException {
        JsonArray root = getJsonArray(ticker24hUri(), "24hTicker", 40);
        return root.asList().stream()
                .map(JsonElement::getAsJsonObject)
                .map(value -> new Ticker24h(
                        normalizedPair(value),
                        decimal(value, "lastPrice"),
                        decimal(value, "quoteVolume"),
                        decimal(value, "priceChangePercent").movePointLeft(2),
                        longValue(value, "closeTime")
                ))
                .filter(value -> StringUtils.hasText(value.pair()))
                .collect(Collectors.toUnmodifiableMap(Ticker24h::pair, Function.identity(), (left, right) -> right));
    }

    public Map<String, BookTicker> loadBookTickers() throws IOException, InterruptedException {
        JsonArray root = getJsonArray(bookTickerUri(), "bookTicker", 5);
        return root.asList().stream()
                .map(JsonElement::getAsJsonObject)
                .map(value -> new BookTicker(
                        normalizedPair(value),
                        decimal(value, "bidPrice"),
                        decimal(value, "askPrice")
                ))
                .filter(value -> StringUtils.hasText(value.pair()))
                .collect(Collectors.toUnmodifiableMap(BookTicker::pair, Function.identity(), (left, right) -> right));
    }

    public Map<String, PremiumIndex> loadPremiumIndexes() throws IOException, InterruptedException {
        JsonArray root = getJsonArray(premiumIndexUri(), "premiumIndex", 10);
        return root.asList().stream()
                .map(JsonElement::getAsJsonObject)
                .map(value -> new PremiumIndex(
                        normalizedPair(value),
                        decimal(value, "markPrice"),
                        decimal(value, "lastFundingRate")
                ))
                .filter(value -> StringUtils.hasText(value.pair()))
                .collect(Collectors.toUnmodifiableMap(PremiumIndex::pair, Function.identity(), (left, right) -> right));
    }

    public OpenInterestStats loadOpenInterestStats(String pair) throws IOException, InterruptedException {
        JsonArray root = getJsonArray(
                openInterestHistoryUri(pair),
                "openInterestHistory",
                1
        );
        if (root.isEmpty()) {
            return null;
        }

        JsonObject first = root.get(0).getAsJsonObject();
        JsonObject latest = root.get(root.size() - 1).getAsJsonObject();
        BigDecimal firstValue = decimal(first, "sumOpenInterestValue");
        BigDecimal latestValue = decimal(latest, "sumOpenInterestValue");
        BigDecimal changeRate = BigDecimal.ZERO;
        if (firstValue.signum() > 0) {
            changeRate = latestValue.subtract(firstValue)
                    .divide(firstValue, 8, java.math.RoundingMode.HALF_UP);
        }
        return new OpenInterestStats(
                normalizedPair(latest),
                latestValue,
                changeRate
        );
    }

    public Map<Long, ChartTradingData> loadChartTradingData(
            String pair,
            String intervalCode,
            Set<ChartTradingDataSeries> requestedSeries
    ) {
        String normalizedPair = pair.toUpperCase(Locale.ROOT);
        String period = intervalCode.toLowerCase(Locale.ROOT);
        Set<ChartTradingDataSeries> normalizedSeries = requestedSeries == null
                ? Set.of()
                : Set.copyOf(requestedSeries);
        if (!TRADING_DATA_PERIODS.contains(period)
                || normalizedSeries.isEmpty()) {
            return Map.of();
        }

        TradingDataCacheKey cacheKey =
                new TradingDataCacheKey(
                        normalizedPair,
                        period,
                        normalizedSeries
                );
        long now = System.currentTimeMillis();
        CachedTradingData cached = tradingDataCache.get(cacheKey);
        if (cached != null
                && now - cached.loadedAtMillis()
                < TRADING_DATA_CACHE_MILLIS) {
            return cached.values();
        }

        CompletableFuture<JsonArray> openInterest = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.OPEN_INTEREST),
                tradingDataUri(
                        "openInterestHist",
                        "symbol",
                        normalizedPair,
                        period
                ),
                "openInterestHist"
        );
        CompletableFuture<JsonArray> topAccount = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.TOP_ACCOUNT_RATIO),
                tradingDataUri(
                        "topLongShortAccountRatio",
                        "symbol",
                        normalizedPair,
                        period
                ),
                "topLongShortAccountRatio"
        );
        CompletableFuture<JsonArray> topPosition = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.TOP_POSITION_RATIO),
                tradingDataUri(
                        "topLongShortPositionRatio",
                        "symbol",
                        normalizedPair,
                        period
                ),
                "topLongShortPositionRatio"
        );
        CompletableFuture<JsonArray> globalAccount = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.GLOBAL_ACCOUNT_RATIO),
                tradingDataUri(
                        "globalLongShortAccountRatio",
                        "symbol",
                        normalizedPair,
                        period
                ),
                "globalLongShortAccountRatio"
        );
        CompletableFuture<JsonArray> takerVolume = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.BUY_SELL_VOLUME),
                tradingDataUri(
                        "takerlongshortRatio",
                        "symbol",
                        normalizedPair,
                        period
                ),
                "takerlongshortRatio"
        );
        CompletableFuture<JsonArray> basis = getJsonArrayIfRequested(
                normalizedSeries.contains(ChartTradingDataSeries.BASIS),
                basisHistoryUri(normalizedPair, period),
                "basis"
        );

        CompletableFuture.allOf(
                openInterest,
                topAccount,
                topPosition,
                globalAccount,
                takerVolume,
                basis
        ).join();

        Map<Long, ChartTradingData> values = parseChartTradingData(
                period,
                openInterest.join(),
                topAccount.join(),
                topPosition.join(),
                globalAccount.join(),
                takerVolume.join(),
                basis.join()
        );
        tradingDataCache.put(
                cacheKey,
                new CachedTradingData(now, values)
        );
        return values;
    }

    static Map<Long, ChartTradingData> parseChartTradingData(
            String intervalCode,
            JsonArray openInterest,
            JsonArray topAccount,
            JsonArray topPosition,
            JsonArray globalAccount,
            JsonArray takerVolume,
            JsonArray basis
    ) {
        long intervalMillis = intervalMilliseconds(intervalCode);
        if (intervalMillis <= 0) {
            return Map.of();
        }

        Map<Long, ChartTradingDataBuilder> values = new HashMap<>();
        mergeOpenInterest(values, openInterest, intervalMillis);
        mergeAccountRatio(values, topAccount, intervalMillis, RatioType.TOP_ACCOUNT);
        mergeAccountRatio(values, topPosition, intervalMillis, RatioType.TOP_POSITION);
        mergeAccountRatio(values, globalAccount, intervalMillis, RatioType.GLOBAL_ACCOUNT);
        mergeTakerVolume(values, takerVolume, intervalMillis);
        mergeBasis(values, basis, intervalMillis);
        return values.entrySet().stream().collect(Collectors.toUnmodifiableMap(
                Map.Entry::getKey,
                entry -> entry.getValue().build()
        ));
    }

    private static void mergeOpenInterest(
            Map<Long, ChartTradingDataBuilder> values,
            JsonArray series,
            long intervalMillis
    ) {
        forEachPoint(values, series, intervalMillis, (builder, point) -> {
            builder.openInterest = nullableDecimal(point, "sumOpenInterest");
            builder.openInterestNotional = nullableDecimal(
                    point,
                    "sumOpenInterestValue"
            );
        });
    }

    private static void mergeAccountRatio(
            Map<Long, ChartTradingDataBuilder> values,
            JsonArray series,
            long intervalMillis,
            RatioType type
    ) {
        forEachPoint(values, series, intervalMillis, (builder, point) -> {
            BigDecimal longAccount = nullableDecimal(point, "longAccount");
            BigDecimal shortAccount = nullableDecimal(point, "shortAccount");
            BigDecimal ratio = nullableDecimal(point, "longShortRatio");
            switch (type) {
                case TOP_ACCOUNT -> {
                    builder.topLongAccount = longAccount;
                    builder.topShortAccount = shortAccount;
                    builder.topLongShortAccountRatio = ratio;
                }
                case TOP_POSITION -> {
                    builder.topLongPosition = longAccount;
                    builder.topShortPosition = shortAccount;
                    builder.topLongShortPositionRatio = ratio;
                }
                case GLOBAL_ACCOUNT -> {
                    builder.globalLongAccount = longAccount;
                    builder.globalShortAccount = shortAccount;
                    builder.globalLongShortAccountRatio = ratio;
                }
            }
        });
    }

    private static void mergeTakerVolume(
            Map<Long, ChartTradingDataBuilder> values,
            JsonArray series,
            long intervalMillis
    ) {
        forEachPoint(values, series, intervalMillis, (builder, point) -> {
            builder.takerBuyVolume = nullableDecimal(point, "buyVol");
            builder.takerSellVolume = nullableDecimal(point, "sellVol");
        });
    }

    private static void mergeBasis(
            Map<Long, ChartTradingDataBuilder> values,
            JsonArray series,
            long intervalMillis
    ) {
        forEachPoint(values, series, intervalMillis, (builder, point) -> {
            builder.basis = nullableDecimal(point, "basis");
            builder.basisRate = nullableDecimal(point, "basisRate");
            builder.futuresPrice = nullableDecimal(point, "futuresPrice");
            builder.indexPrice = nullableDecimal(point, "indexPrice");
        });
    }

    private static void forEachPoint(
            Map<Long, ChartTradingDataBuilder> values,
            JsonArray series,
            long intervalMillis,
            TradingDataPointMerger merger
    ) {
        if (series == null) {
            return;
        }
        series.asList().stream()
                .filter(JsonElement::isJsonObject)
                .map(JsonElement::getAsJsonObject)
                .forEach(point -> {
                    long timestamp = staticLongValue(point, "timestamp");
                    if (timestamp <= 0) {
                        return;
                    }
                    long openTime = timestamp
                            - Math.floorMod(timestamp, intervalMillis);
                    merger.merge(
                            values.computeIfAbsent(
                                    openTime,
                                    ignored -> new ChartTradingDataBuilder()
                            ),
                            point
                    );
                });
    }

    private static long intervalMilliseconds(String intervalCode) {
        return switch (intervalCode.toLowerCase(Locale.ROOT)) {
            case "5m" -> Duration.ofMinutes(5).toMillis();
            case "15m" -> Duration.ofMinutes(15).toMillis();
            case "30m" -> Duration.ofMinutes(30).toMillis();
            case "1h" -> Duration.ofHours(1).toMillis();
            case "2h" -> Duration.ofHours(2).toMillis();
            case "4h" -> Duration.ofHours(4).toMillis();
            case "6h" -> Duration.ofHours(6).toMillis();
            case "12h" -> Duration.ofHours(12).toMillis();
            case "1d" -> Duration.ofDays(1).toMillis();
            default -> 0;
        };
    }

    private URI exchangeInfoUri() {
        return URI.create(restBaseUrl() + "/fapi/v1/exchangeInfo");
    }

    private URI ticker24hUri() {
        return URI.create(restBaseUrl() + "/fapi/v1/ticker/24hr");
    }

    private URI bookTickerUri() {
        return URI.create(restBaseUrl() + "/fapi/v1/ticker/bookTicker");
    }

    private URI premiumIndexUri() {
        return URI.create(restBaseUrl() + "/fapi/v1/premiumIndex");
    }

    private URI openInterestHistoryUri(String pair) {
        return URI.create(restBaseUrl()
                + "/futures/data/openInterestHist"
                + "?symbol=" + encode(pair)
                + "&period=1h"
                + "&limit=25");
    }

    private URI tradingDataUri(
            String endpoint,
            String symbolParameter,
            String pair,
            String period
    ) {
        return URI.create(restBaseUrl()
                + "/futures/data/" + endpoint
                + "?" + symbolParameter + "=" + encode(pair)
                + "&period=" + encode(period)
                + "&limit=500");
    }

    private URI basisHistoryUri(String pair, String period) {
        return URI.create(restBaseUrl()
                + "/futures/data/basis"
                + "?pair=" + encode(pair)
                + "&contractType=" + encode(binanceProperties.getContractType())
                + "&period=" + encode(period)
                + "&limit=500");
    }

    private URI continuousKlinesUri(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            long startTime,
            long endTime,
            int limit
    ) {
        return URI.create(restBaseUrl()
                + "/fapi/v1/continuousKlines"
                + "?pair=" + encode(symbol.pair())
                + "&contractType=" + encode(symbol.contractType())
                + "&interval=" + encode(intervalCode)
                + "&startTime=" + startTime
                + "&endTime=" + endTime
                + "&limit=" + limit);
    }

    private URI recentContinuousKlinesUri(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            int limit
    ) {
        return URI.create(restBaseUrl()
                + "/fapi/v1/continuousKlines"
                + "?pair=" + encode(symbol.pair())
                + "&contractType=" + encode(symbol.contractType())
                + "&interval=" + encode(intervalCode)
                + "&limit=" + limit);
    }

    private URI continuousKlinesBeforeUri(
            BinanceUsdmSymbol symbol,
            String intervalCode,
            long beforeOpenTimeExclusive,
            int limit
    ) {
        return URI.create(restBaseUrl()
                + "/fapi/v1/continuousKlines"
                + "?pair=" + encode(symbol.pair())
                + "&contractType=" + encode(symbol.contractType())
                + "&interval=" + encode(intervalCode)
                + "&endTime=" + (beforeOpenTimeExclusive - 1)
                + "&limit=" + limit);
    }

    private String restBaseUrl() {
        String configured = binanceProperties.getRestBaseUrl();
        if (!StringUtils.hasText(configured)) {
            ClientConfiguration restConfiguration = DerivativesTradingUsdsFuturesRestApiUtil.getClientConfiguration();
            configured = restConfiguration.getUrl();
        }
        String baseUrl = stripTrailingSlash(configured);
        return baseUrl.endsWith("/fapi/v1")
                ? baseUrl.substring(0, baseUrl.length() - "/fapi/v1".length())
                : baseUrl;
    }

    private boolean isTargetSymbol(JsonObject symbol) {
        return equalsIgnoreCase(binanceProperties.getQuoteAsset(), stringValue(symbol, "quoteAsset"))
                && equalsIgnoreCase(binanceProperties.getContractType(), stringValue(symbol, "contractType"))
                && equalsIgnoreCase(binanceProperties.getStatus(), stringValue(symbol, "status"));
    }

    private BinanceUsdmSymbol toSymbol(JsonObject symbol) {
        String pair = stringValue(symbol, "pair");
        if (!StringUtils.hasText(pair)) {
            pair = stringValue(symbol, "symbol");
        }
        return new BinanceUsdmSymbol(
                pair.toUpperCase(Locale.ROOT),
                stringValue(symbol, "contractType").toUpperCase(Locale.ROOT),
                longValue(symbol, "onboardDate")
        );
    }

    private MarketKline toKline(BinanceUsdmSymbol symbol, String intervalCode, JsonArray values) {
        MarketKline kline = new MarketKline();
        kline.setExchange(klineProperties.getExchange());
        kline.setMarketType(klineProperties.getMarketType());
        kline.setContractType(symbol.contractType());
        kline.setPair(symbol.pair());
        kline.setIntervalCode(intervalCode);
        kline.setOpenTimeMs(values.get(0).getAsLong());
        kline.setOpenPrice(decimal(values.get(1)));
        kline.setHighPrice(decimal(values.get(2)));
        kline.setLowPrice(decimal(values.get(3)));
        kline.setClosePrice(decimal(values.get(4)));
        kline.setVolume(decimal(values.get(5)));
        kline.setCloseTimeMs(values.get(6).getAsLong());
        kline.setQuoteVolume(decimal(values.get(7)));
        kline.setTradeCount(values.get(8).getAsLong());
        kline.setTakerBuyVolume(decimal(values.get(9)));
        kline.setTakerBuyQuoteVolume(decimal(values.get(10)));
        kline.setEventTimeMs(System.currentTimeMillis());
        kline.setClosedState(1);
        kline.setSourceInterval(intervalCode);
        return kline;
    }

    private void assertSuccess(HttpResponse<String> response, String apiName) {
        long retryAtMillis = requestBudget.observeResponse(
                response.statusCode(),
                response.headers(),
                response.body()
        );
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            if (response.statusCode() == 418 || response.statusCode() == 429) {
                throw new BinanceRestRateLimitException(
                        "Binance " + apiName + " rate limited, status="
                                + response.statusCode(),
                        retryAtMillis
                );
            }
            throw new IllegalStateException(
                    "Failed to call Binance " + apiName + ", status=" + response.statusCode()
                            + ", body=" + response.body()
            );
        }
    }

    private HttpResponse<String> getJsonResponse(
            URI uri,
            String apiName,
            int weight
    ) throws IOException, InterruptedException {
        requestBudget.acquire(weight);
        HttpResponse<String> response = httpClient.send(
                HttpRequest.newBuilder(uri)
                        .timeout(Duration.ofSeconds(20))
                        .GET()
                        .build(),
                HttpResponse.BodyHandlers.ofString()
        );
        assertSuccess(response, apiName);
        return response;
    }

    private JsonArray getJsonArray(
            URI uri,
            String apiName,
            int weight
    ) throws IOException, InterruptedException {
        HttpResponse<String> response = getJsonResponse(uri, apiName, weight);
        return JsonParser.parseString(response.body()).getAsJsonArray();
    }

    private CompletableFuture<JsonArray> getJsonArrayAsync(
            URI uri,
            String apiName
    ) {
        try {
            requestBudget.acquire(1);
        } catch (BinanceRestRateLimitException exception) {
            log.warn(
                    "Skipped Binance {} while REST requests are cooling down until {}",
                    apiName,
                    exception.retryAtMillis()
            );
            return CompletableFuture.completedFuture(new JsonArray());
        }
        return httpClient.sendAsync(
                HttpRequest.newBuilder(uri)
                        .timeout(Duration.ofSeconds(20))
                        .GET()
                        .build(),
                HttpResponse.BodyHandlers.ofString()
        ).handle((response, failure) -> {
            if (failure != null) {
                log.warn(
                        "Failed to call Binance {}: {}",
                        apiName,
                        rootMessage(failure)
                );
                return new JsonArray();
            }
            try {
                assertSuccess(response, apiName);
                return JsonParser.parseString(response.body())
                        .getAsJsonArray();
            } catch (BinanceRestRateLimitException ex) {
                log.warn(
                        "Binance {} entered REST cooldown until {}",
                        apiName,
                        ex.retryAtMillis()
                );
                return new JsonArray();
            } catch (RuntimeException ex) {
                log.warn(
                        "Failed to parse Binance {} response: {}",
                        apiName,
                        ex.getMessage()
                );
                return new JsonArray();
            }
        });
    }

    private CompletableFuture<JsonArray> getJsonArrayIfRequested(
            boolean requested,
            URI uri,
            String apiName
    ) {
        return requested
                ? getJsonArrayAsync(uri, apiName)
                : CompletableFuture.completedFuture(new JsonArray());
    }

    private int continuousKlineWeight(int limit) {
        if (limit < 100) {
            return 1;
        }
        if (limit < 500) {
            return 2;
        }
        if (limit <= 1_000) {
            return 5;
        }
        return 10;
    }

    private String normalizedPair(JsonObject object) {
        return stringValue(object, "symbol").toUpperCase(Locale.ROOT);
    }

    private String stringValue(JsonObject object, String key) {
        JsonElement value = object.get(key);
        return value == null || value.isJsonNull() ? "" : value.getAsString();
    }

    private long longValue(JsonObject object, String key) {
        JsonElement value = object.get(key);
        return value == null || value.isJsonNull() ? 0L : value.getAsLong();
    }

    private BigDecimal decimal(JsonElement value) {
        return value == null || value.isJsonNull() ? null : new BigDecimal(value.getAsString());
    }

    private BigDecimal decimal(JsonObject object, String key) {
        BigDecimal value = decimal(object.get(key));
        return value == null ? BigDecimal.ZERO : value;
    }

    private static BigDecimal nullableDecimal(JsonObject object, String key) {
        JsonElement value = object.get(key);
        return value == null || value.isJsonNull()
                ? null
                : new BigDecimal(value.getAsString());
    }

    private static long staticLongValue(JsonObject object, String key) {
        JsonElement value = object.get(key);
        return value == null || value.isJsonNull() ? 0L : value.getAsLong();
    }

    private String rootMessage(Throwable failure) {
        Throwable current = failure;
        while (current.getCause() != null) {
            current = current.getCause();
        }
        return current.getMessage() == null
                ? current.getClass().getSimpleName()
                : current.getMessage();
    }

    private boolean equalsIgnoreCase(String expected, String actual) {
        return expected != null && actual != null && expected.equalsIgnoreCase(actual);
    }

    private String stripTrailingSlash(String value) {
        if (!StringUtils.hasText(value)) {
            return "https://fapi.binance.com";
        }
        String stripped = value;
        while (stripped.endsWith("/")) {
            stripped = stripped.substring(0, stripped.length() - 1);
        }
        return stripped;
    }

    private String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    public record Ticker24h(
            String pair,
            BigDecimal lastPrice,
            BigDecimal quoteVolume,
            BigDecimal priceChangeRate,
            long eventTime
    ) {
    }

    public record BookTicker(
            String pair,
            BigDecimal bidPrice,
            BigDecimal askPrice
    ) {
    }

    public record PremiumIndex(
            String pair,
            BigDecimal markPrice,
            BigDecimal fundingRate
    ) {
    }

    public record OpenInterestStats(
            String pair,
            BigDecimal openInterestValue,
            BigDecimal changeRate24h
    ) {
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    public record ChartTradingData(
            BigDecimal openInterest,
            BigDecimal openInterestNotional,
            BigDecimal topLongAccount,
            BigDecimal topShortAccount,
            BigDecimal topLongShortAccountRatio,
            BigDecimal topLongPosition,
            BigDecimal topShortPosition,
            BigDecimal topLongShortPositionRatio,
            BigDecimal globalLongAccount,
            BigDecimal globalShortAccount,
            BigDecimal globalLongShortAccountRatio,
            BigDecimal takerBuyVolume,
            BigDecimal takerSellVolume,
            BigDecimal basis,
            BigDecimal basisRate,
            BigDecimal futuresPrice,
            BigDecimal indexPrice
    ) {
    }

    public enum ChartTradingDataSeries {
        OPEN_INTEREST("openInterest"),
        TOP_ACCOUNT_RATIO("topAccountRatio"),
        TOP_POSITION_RATIO("topPositionRatio"),
        GLOBAL_ACCOUNT_RATIO("globalAccountRatio"),
        BUY_SELL_VOLUME("buySellVolume"),
        BASIS("basis");

        private final String queryValue;

        ChartTradingDataSeries(String queryValue) {
            this.queryValue = queryValue;
        }

        public static ChartTradingDataSeries fromQueryValue(String value) {
            for (ChartTradingDataSeries series : values()) {
                if (series.queryValue.equals(value)) {
                    return series;
                }
            }
            throw new IllegalArgumentException(
                    "Unsupported chart trading data series: " + value
            );
        }
    }

    private enum RatioType {
        TOP_ACCOUNT,
        TOP_POSITION,
        GLOBAL_ACCOUNT
    }

    @FunctionalInterface
    private interface TradingDataPointMerger {

        void merge(ChartTradingDataBuilder builder, JsonObject point);
    }

    private static final class ChartTradingDataBuilder {

        private BigDecimal openInterest;
        private BigDecimal openInterestNotional;
        private BigDecimal topLongAccount;
        private BigDecimal topShortAccount;
        private BigDecimal topLongShortAccountRatio;
        private BigDecimal topLongPosition;
        private BigDecimal topShortPosition;
        private BigDecimal topLongShortPositionRatio;
        private BigDecimal globalLongAccount;
        private BigDecimal globalShortAccount;
        private BigDecimal globalLongShortAccountRatio;
        private BigDecimal takerBuyVolume;
        private BigDecimal takerSellVolume;
        private BigDecimal basis;
        private BigDecimal basisRate;
        private BigDecimal futuresPrice;
        private BigDecimal indexPrice;

        private ChartTradingData build() {
            return new ChartTradingData(
                    openInterest,
                    openInterestNotional,
                    topLongAccount,
                    topShortAccount,
                    topLongShortAccountRatio,
                    topLongPosition,
                    topShortPosition,
                    topLongShortPositionRatio,
                    globalLongAccount,
                    globalShortAccount,
                    globalLongShortAccountRatio,
                    takerBuyVolume,
                    takerSellVolume,
                    basis,
                    basisRate,
                    futuresPrice,
                    indexPrice
            );
        }
    }

    private record TradingDataCacheKey(
            String pair,
            String period,
            Set<ChartTradingDataSeries> requestedSeries
    ) {
    }

    private record CachedTradingData(
            long loadedAtMillis,
            Map<Long, ChartTradingData> values
    ) {
    }
}
