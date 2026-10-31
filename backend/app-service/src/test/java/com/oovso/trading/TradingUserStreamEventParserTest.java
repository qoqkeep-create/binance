package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class TradingUserStreamEventParserTest {

    private final TradingUserStreamEventParser parser =
            new TradingUserStreamEventParser(new ObjectMapper());

    @Test
    void parsesAccountUpdateAsDeltaWithoutInventingMissingPositions() {
        TradingUserStreamEvent event = parser.parse("""
                {
                  "e":"ACCOUNT_UPDATE","E":1000,"T":990,
                  "a":{
                    "m":"ORDER",
                    "B":[{"a":"USDC","wb":"152.32","cw":"150","bc":"2.32"}],
                    "P":[{
                      "s":"BTCUSDC","pa":"0.01","ep":"63900.8",
                      "bep":"63890","iw":"0","up":"1.2",
                      "mt":"cross","ps":"BOTH"
                    }]
                  }
                }
                """, 1100);

        assertEquals(TradingUserStreamEvent.Kind.ACCOUNT_UPDATE, event.kind());
        assertEquals(1, event.balances().size());
        assertEquals(new BigDecimal("152.32"),
                event.balances().getFirst().walletBalance());
        assertEquals(1, event.positions().size());
        assertEquals("BTCUSDC", event.positions().getFirst().symbol());
    }

    @Test
    void parsesTradeUpdateAndCreatesFillOnlyForTradeExecution() {
        TradingUserStreamEvent trade = parser.parse("""
                {
                  "e":"ORDER_TRADE_UPDATE","E":2000,"T":1990,
                  "o":{
                    "s":"BTCUSDC","c":"client-1","S":"BUY","o":"LIMIT",
                    "f":"GTC","q":"1","p":"63000","ap":"63000",
                    "sp":"0","x":"TRADE","X":"PARTIALLY_FILLED",
                    "i":123,"l":"0.25","z":"0.25","L":"63000",
                    "N":"USDC","n":"0.1","T":1990,"t":456,
                    "b":"15750","m":true,"R":false,"ps":"BOTH","rp":"0"
                  }
                }
                """, 2100);

        assertEquals(
                TradingUserStreamEvent.Kind.REGULAR_ORDER_UPDATE,
                trade.kind()
        );
        assertEquals("PARTIALLY_FILLED", trade.order().exchangeStatus());
        assertNotNull(trade.fill());
        assertEquals("456", trade.fill().tradeId());

        TradingUserStreamEvent created = parser.parse("""
                {
                  "e":"ORDER_TRADE_UPDATE","E":2001,"T":2001,
                  "o":{
                    "s":"BTCUSDC","c":"client-1","S":"BUY","o":"LIMIT",
                    "f":"GTC","q":"1","p":"63000","ap":"0",
                    "sp":"0","x":"NEW","X":"NEW","i":123,
                    "l":"0","z":"0","L":"0","T":2001,"t":0,
                    "b":"0","m":false,"R":false,"ps":"BOTH"
                  }
                }
                """, 2101);
        assertNull(created.fill());
    }

    @Test
    void parsesCurrentBinanceAlgoUpdateFieldNames() {
        TradingUserStreamEvent event = parser.parse("""
                {
                  "e":"ALGO_UPDATE","E":1765431097037,"T":1765431097031,
                  "o":{
                    "caid":"tt-s-plan-1","aid":1000000033225453,
                    "at":"CONDITIONAL","o":"STOP_MARKET",
                    "s":"DOGEUSDT","S":"BUY","ps":"BOTH","f":"GTC",
                    "q":"38","X":"FINISHED","ai":88937381063,
                    "ap":"0.13856","aq":"38","act":"MARKET",
                    "tp":"0.13855","p":"0","wt":"CONTRACT_PRICE",
                    "cp":false,"R":false,"tt":1765431097019,"rm":""
                  }
                }
                """, 1765431097040L);

        assertEquals(TradingUserStreamEvent.Kind.ALGO_ORDER_UPDATE, event.kind());
        assertEquals("tt-s-plan-1", event.order().clientAlgoId());
        assertEquals("1000000033225453", event.order().exchangeAlgoId());
        assertEquals("88937381063", event.order().actualOrderId());
        assertEquals(new BigDecimal("0.13855"), event.order().triggerPrice());
        assertEquals(new BigDecimal("38"), event.order().executedQuantity());
        assertEquals("FINISHED", event.order().exchangeStatus());
        assertEquals(1765431097031L, event.order().updateTimeMillis());
    }

    @Test
    void semanticHashIsStableAcrossObjectAndArrayOrdering() {
        TradingUserStreamEvent first = parser.parse("""
                {"e":"ACCOUNT_UPDATE","E":10,"T":9,"a":{"m":"ORDER","B":[
                  {"a":"USDC","wb":"1","cw":"1","bc":"0"},
                  {"a":"USDT","wb":"2","cw":"2","bc":"0"}
                ],"P":[]}}
                """, 20);
        TradingUserStreamEvent second = parser.parse("""
                {"T":9,"a":{"P":[],"B":[
                  {"bc":"0","cw":"2","wb":"2","a":"USDT"},
                  {"bc":"0","cw":"1","wb":"1","a":"USDC"}
                ],"m":"ORDER"},"E":10,"e":"ACCOUNT_UPDATE"}
                """, 21);

        assertEquals(first.eventHash(), second.eventHash());
    }
}
