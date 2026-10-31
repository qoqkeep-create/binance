package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.oovso.trading.TradingAccountQueryService.PositionCenterView;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.Test;

class TradingAccountQueryServiceTest {

    @Test
    void positionCenterIncludesProtectionAndCurrentCycleRealizedPnl() {
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingAccountBalanceMapper balanceMapper = mock(
                TradingAccountBalanceMapper.class
        );
        TradingPositionMapper positionMapper = mock(
                TradingPositionMapper.class
        );
        ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
        ExchangeFillMapper fillMapper = mock(ExchangeFillMapper.class);

        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        account.setQuoteAsset("USDC");
        account.setSyncStatus("SYNCED");
        account.setTotalMarginBalance(new BigDecimal("200"));
        when(accountMapper.selectOwned("account-1", "user-1"))
                .thenReturn(account);

        TradingPosition position = position();
        when(positionMapper.selectOpenByAccount("account-1"))
                .thenReturn(List.of(position));
        when(orderMapper.selectActiveManualClosesByAccount("account-1"))
                .thenReturn(List.of());
        when(orderMapper.selectActiveLimitByAccount("account-1"))
                .thenReturn(List.of());
        when(orderMapper.selectActivePositionProtection(
                "account-1",
                "BTCUSDC",
                "BOTH"
        )).thenReturn(List.of(
                protection("TAKE_PROFIT", "LIMIT", "120"),
                protection("UNKNOWN", "STOP_MARKET", "90")
        ));
        when(fillMapper.selectRecentForPositionHistory("account-1", 10_000))
                .thenReturn(List.of(
                        fill("1", "BUY", "1", "100", "0"),
                        fill("2", "SELL", "0.4", "120", "8")
                ));

        TradingAccountQueryService service = new TradingAccountQueryService(
                new TradingProperties(),
                accountMapper,
                balanceMapper,
                positionMapper,
                orderMapper,
                fillMapper,
                mock(TradingAccountSessionManager.class)
        );

        PositionCenterView view = service.positionCenter(
                "user-1",
                "account-1",
                100
        );

        assertEquals(new BigDecimal("200"), view.totalMarginBalance());
        assertEquals(1, view.positions().size());
        var actual = view.positions().getFirst();
        assertEquals(new BigDecimal("120"), actual.takeProfitPrices().getFirst());
        assertEquals(new BigDecimal("90"), actual.stopLossPrices().getFirst());
        assertEquals(new BigDecimal("8"), actual.realizedPnl());
        assertEquals(2, actual.realizedPnlDetails().size());
    }

    private TradingPosition position() {
        TradingPosition position = new TradingPosition();
        position.setId("position-1");
        position.setTradingAccountId("account-1");
        position.setSymbol("BTCUSDC");
        position.setPositionSide("BOTH");
        position.setGeneration(1L);
        position.setQuantity(new BigDecimal("0.6"));
        position.setEntryPrice(new BigDecimal("100"));
        position.setBreakEvenPrice(new BigDecimal("100.1"));
        position.setMarkPrice(new BigDecimal("110"));
        position.setLiquidationPrice(new BigDecimal("50"));
        position.setLeverage(20);
        position.setMarginType("cross");
        position.setIsolatedMargin(BigDecimal.ZERO);
        position.setUnrealizedProfit(new BigDecimal("6"));
        position.setExchangeUpdateMs(1_000L);
        return position;
    }

    private ExchangeOrder protection(
            String purpose,
            String type,
            String triggerPrice
    ) {
        ExchangeOrder order = new ExchangeOrder();
        order.setPurpose(purpose);
        order.setOrderType(type);
        order.setTriggerPrice(new BigDecimal(triggerPrice));
        order.setPrice(BigDecimal.ZERO);
        return order;
    }

    private ExchangeFill fill(
            String id,
            String side,
            String quantity,
            String price,
            String realizedPnl
    ) {
        ExchangeFill fill = new ExchangeFill();
        fill.setId(id);
        fill.setCreateTime(LocalDateTime.now());
        fill.setSymbol("BTCUSDC");
        fill.setTradeId(id);
        fill.setSide(side);
        fill.setPositionSide("BOTH");
        fill.setQuantity(new BigDecimal(quantity));
        fill.setPrice(new BigDecimal(price));
        fill.setCommission(new BigDecimal("0.01"));
        fill.setCommissionAsset("USDC");
        fill.setRealizedPnl(new BigDecimal(realizedPnl));
        fill.setMaker(0);
        fill.setTradeTimeMs(Long.parseLong(id));
        return fill;
    }
}
