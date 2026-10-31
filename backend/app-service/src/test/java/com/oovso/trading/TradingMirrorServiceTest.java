package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.trading.BinanceUsdmPrivateGateway.PositionSnapshot;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class TradingMirrorServiceTest {

    @Test
    void staleRestSnapshotStillCorrectsLeverageWithoutReplacingPosition() {
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        TradingPosition current = new TradingPosition();
        current.setId("position-1");
        current.setTradingAccountId("account-1");
        current.setSymbol("BTCUSDC");
        current.setPositionSide("LONG");
        current.setQuantity(new BigDecimal("1.25"));
        current.setLeverage(1);
        current.setLastEventMs(2_000L);
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "LONG"))
                .thenReturn(current);
        TradingMirrorService service = new TradingMirrorService(
                mock(TradingAccountBalanceMapper.class),
                positionMapper,
                mock(ExchangeOrderMapper.class),
                mock(ExchangeFillMapper.class),
                mock(TradingOutboxService.class)
        );
        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        PositionSnapshot snapshot = new PositionSnapshot(
                "BTCUSDC", "LONG", new BigDecimal("0.5"),
                new BigDecimal("100"), new BigDecimal("100"),
                new BigDecimal("101"), new BigDecimal("50"), 20,
                "cross", BigDecimal.ZERO, BigDecimal.ONE, 1_000L
        );

        TradingPosition merged = service.mergeRestPosition(
                account,
                snapshot,
                8L
        );

        assertEquals(new BigDecimal("1.25"), merged.getQuantity());
        assertEquals(20, merged.getLeverage());
        verify(positionMapper).updateLeverageBySymbol(
                "account-1",
                "BTCUSDC",
                20
        );
    }
}
