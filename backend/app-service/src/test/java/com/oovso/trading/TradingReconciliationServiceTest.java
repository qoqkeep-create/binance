package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.trading.BinanceUsdmPrivateGateway.ReconciliationSnapshot;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;

class TradingReconciliationServiceTest {

    @Test
    void failedSnapshotDoesNotPerformPartialDeletion() {
        Fixture fixture = fixture();
        when(fixture.gateway.reconciliationSnapshot(
                any(),
                any(),
                any(Boolean.class)
        )).thenThrow(new BinancePrivateApiException("network", null));

        assertThrows(
                BinancePrivateApiException.class,
                () -> fixture.service.reconcile(
                        "account-1",
                        7,
                        new BinanceCredentials("key", "secret"),
                        false,
                        false
                )
        );

        verify(fixture.positionMapper, never()).closeByIdAtRevision(
                any(),
                any(),
                anyLong()
        );
        verify(fixture.accountMapper, never()).updateReconciledSnapshot(
                any(),
                anyLong(),
                any(),
                any(),
                any(),
                any(),
                anyLong(),
                anyLong(),
                anyInt()
        );
    }

    @Test
    void completePositionSnapshotClosesPositionThatIsReallyMissing() {
        Fixture fixture = fixture();
        TradingPosition open = new TradingPosition();
        open.setId("position-1");
        open.setTradingAccountId("account-1");
        open.setSymbol("BTCUSDC");
        open.setPositionSide("BOTH");
        open.setStatus("OPEN");
        when(fixture.positionMapper.selectByAccount("account-1"))
                .thenReturn(List.of(open));
        when(fixture.accountMapper.updateReconciledSnapshot(
                any(),
                anyLong(),
                any(),
                any(),
                any(),
                any(),
                anyLong(),
                anyLong(),
                anyInt()
        )).thenReturn(1);
        when(fixture.gateway.reconciliationSnapshot(
                any(),
                any(),
                any(Boolean.class)
        )).thenReturn(new ReconciliationSnapshot(
                new BigDecimal("100"),
                BigDecimal.ZERO,
                "USDC",
                "ONE_WAY",
                1000,
                List.of(),
                List.of(),
                List.of(),
                List.of()
        ));

        fixture.service.reconcile(
                "account-1",
                7,
                new BinanceCredentials("key", "secret"),
                false,
                false
        );

        verify(fixture.positionMapper).closeByIdAtRevision(
                "position-1",
                "account-1",
                1
        );
    }

    private Fixture fixture() {
        BinanceUsdmPrivateGateway gateway = mock(
                BinanceUsdmPrivateGateway.class
        );
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        when(accountMapper.isFenceCurrent("account-1", 7)).thenReturn(1);
        when(accountMapper.selectListenableById("account-1"))
                .thenReturn(account());
        TradingReconciliationService service = new TradingReconciliationService(
                gateway,
                accountMapper,
                mock(TradingAccountBalanceMapper.class),
                positionMapper,
                mock(ExchangeOrderMapper.class),
                mock(TradingMirrorService.class),
                mock(TradingOutboxService.class),
                transactionManager()
        );
        return new Fixture(service, gateway, accountMapper, positionMapper);
    }

    private TradingAccount account() {
        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        account.setAppUserId("user-1");
        account.setQuoteAsset("USDC");
        account.setPositionMode("ONE_WAY");
        account.setReconcileRevision(0L);
        return account;
    }

    private PlatformTransactionManager transactionManager() {
        PlatformTransactionManager transactionManager = mock(
                PlatformTransactionManager.class
        );
        when(transactionManager.getTransaction(any(TransactionDefinition.class)))
                .thenReturn(mock(TransactionStatus.class));
        return transactionManager;
    }

    private record Fixture(
            TradingReconciliationService service,
            BinanceUsdmPrivateGateway gateway,
            TradingAccountMapper accountMapper,
            TradingPositionMapper positionMapper
    ) {
    }
}
