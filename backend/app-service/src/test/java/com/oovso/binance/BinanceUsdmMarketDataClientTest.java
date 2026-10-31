package com.oovso.binance;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.gson.JsonArray;
import com.google.gson.JsonParser;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingData;
import com.oovso.binance.BinanceUsdmMarketDataClient.ChartTradingDataSeries;
import com.oovso.market.KlineStorageProperties;
import java.math.BigDecimal;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class BinanceUsdmMarketDataClientTest {

    @Test
    void mergesTradingSeriesIntoTheirKlineOpenTime() {
        JsonArray openInterest = array("""
                [{
                  "symbol":"BTCUSDC",
                  "sumOpenInterest":"123.4",
                  "sumOpenInterestValue":"567.8",
                  "timestamp":7200001
                }]
                """);
        JsonArray topAccount = array("""
                [{
                  "longAccount":"0.57",
                  "shortAccount":"0.43",
                  "longShortRatio":"1.32",
                  "timestamp":7200001
                }]
                """);
        JsonArray topPosition = array("""
                [{
                  "longAccount":"0.61",
                  "shortAccount":"0.39",
                  "longShortRatio":"1.56",
                  "timestamp":7200001
                }]
                """);
        JsonArray globalAccount = array("""
                [{
                  "longAccount":"0.48",
                  "shortAccount":"0.52",
                  "longShortRatio":"0.92",
                  "timestamp":7200001
                }]
                """);
        JsonArray takerVolume = array("""
                [{
                  "buyVol":"12",
                  "sellVol":"9",
                  "buySellRatio":"1.33",
                  "timestamp":7200001
                }]
                """);
        JsonArray basis = array("""
                [{
                  "basis":"10",
                  "basisRate":"0.001",
                  "annualizedBasisRate":"0.008",
                  "futuresPrice":"65010",
                  "indexPrice":"65000",
                  "timestamp":7200001
                }]
                """);

        Map<Long, ChartTradingData> result =
                BinanceUsdmMarketDataClient.parseChartTradingData(
                        "1h",
                        openInterest,
                        topAccount,
                        topPosition,
                        globalAccount,
                        takerVolume,
                        basis
                );

        assertEquals(1, result.size());
        ChartTradingData value = result.get(7_200_000L);
        assertEquals(new BigDecimal("123.4"), value.openInterest());
        assertEquals(new BigDecimal("567.8"),
                value.openInterestNotional());
        assertEquals(new BigDecimal("1.32"),
                value.topLongShortAccountRatio());
        assertEquals(new BigDecimal("1.56"),
                value.topLongShortPositionRatio());
        assertEquals(new BigDecimal("0.92"),
                value.globalLongShortAccountRatio());
        assertEquals(new BigDecimal("12"), value.takerBuyVolume());
        assertEquals(new BigDecimal("9"), value.takerSellVolume());
        assertEquals(new BigDecimal("10"), value.basis());
        assertEquals(new BigDecimal("65000"), value.indexPrice());
    }

    @Test
    void ignoresUnsupportedTradingDataIntervals() {
        Map<Long, ChartTradingData> result =
                BinanceUsdmMarketDataClient.parseChartTradingData(
                        "1m",
                        array("[]"),
                        array("[]"),
                        array("[]"),
                        array("[]"),
                        array("[]"),
                        array("[]")
                );

        assertTrue(result.isEmpty());
    }

    @Test
    @SuppressWarnings("unchecked")
    void onlyRequestsSelectedTradingDataSeries() {
        BinanceContinuousKlineProperties properties =
                new BinanceContinuousKlineProperties();
        properties.setRestBaseUrl("https://example.com");
        HttpClient httpClient = mock(HttpClient.class);
        HttpResponse<String> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(200);
        when(response.body()).thenReturn("[]");
        when(httpClient.sendAsync(
                any(HttpRequest.class),
                any(HttpResponse.BodyHandler.class)
        )).thenReturn(CompletableFuture.completedFuture(response));
        BinanceUsdmMarketDataClient client =
                new BinanceUsdmMarketDataClient(
                        properties,
                        new KlineStorageProperties(),
                        mock(BinanceRestRequestBudget.class),
                        httpClient
                );

        client.loadChartTradingData(
                "BTCUSDC",
                "1h",
                Set.of(ChartTradingDataSeries.OPEN_INTEREST)
        );

        ArgumentCaptor<HttpRequest> request =
                ArgumentCaptor.forClass(HttpRequest.class);
        verify(httpClient, times(1)).sendAsync(
                request.capture(),
                any(HttpResponse.BodyHandler.class)
        );
        assertEquals(
                "/futures/data/openInterestHist",
                request.getValue().uri().getPath()
        );
    }

    @Test
    void omitsUnrequestedAndUnusedFieldsFromJson()
            throws JsonProcessingException {
        ChartTradingData value =
                BinanceUsdmMarketDataClient.parseChartTradingData(
                        "1h",
                        array("""
                                [{
                                  "sumOpenInterest":"123.4",
                                  "sumOpenInterestValue":"567.8",
                                  "timestamp":7200001
                                }]
                                """),
                        array("[]"),
                        array("[]"),
                        array("[]"),
                        array("[]"),
                        array("[]")
                ).get(7_200_000L);

        assertEquals(
                "{\"openInterest\":123.4,"
                        + "\"openInterestNotional\":567.8}",
                new ObjectMapper().writeValueAsString(value)
        );
    }

    private JsonArray array(String json) {
        return JsonParser.parseString(json).getAsJsonArray();
    }
}
