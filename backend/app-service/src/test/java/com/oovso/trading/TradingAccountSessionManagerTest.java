package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.trading.TradingAccountLeaseService.Lease;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class TradingAccountSessionManagerTest {

    @Test
    void reconnectWaitHonorsBinanceCooldownDeadline() {
        assertEquals(
                30_000,
                TradingAccountSessionManager.reconnectDelayMillis(
                        1_000,
                        130_000,
                        100_000
                )
        );
        assertEquals(
                1_000,
                TradingAccountSessionManager.reconnectDelayMillis(
                        1_000,
                        99_000,
                        100_000
                )
        );
    }

    @Test
    void applicationStartupDoesNotReconfigureAccountLeverage()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setEnabled(true);
        properties.getBinance().setRestBaseUrl(
                "https://testnet.binancefuture.com"
        );
        properties.getSync().setUserStreamBaseUrl(
                "wss://fstream.binancefuture.com/private"
        );
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
        TradingCredentialCipher cipher = mock(TradingCredentialCipher.class);
        BinanceUsdmPrivateGateway gateway = mock(BinanceUsdmPrivateGateway.class);
        BinanceUserDataStreamClient streamClient = mock(
                BinanceUserDataStreamClient.class
        );
        TradingUserStreamEventParser parser = mock(
                TradingUserStreamEventParser.class
        );
        TradingExchangeEventReducer reducer = mock(
                TradingExchangeEventReducer.class
        );
        TradingReconciliationService reconciliationService = mock(
                TradingReconciliationService.class
        );
        TradingAccountLeaseService leaseService = mock(
                TradingAccountLeaseService.class
        );
        TradingAccountSyncStateService syncStateService = mock(
                TradingAccountSyncStateService.class
        );
        TradingExecutionCoordinator executionCoordinator = mock(
                TradingExecutionCoordinator.class
        );
        TradingAccount account = account();
        when(accountMapper.selectListenableAccounts()).thenReturn(List.of(account));
        when(leaseService.tryAcquire(account.getId()))
                .thenReturn(new Lease("lease-key", "lease-value"));
        when(accountMapper.claimFence(account.getId())).thenReturn(1);
        when(accountMapper.selectFenceToken(account.getId())).thenReturn(7L);
        when(accountMapper.selectListenableById(account.getId()))
                .thenReturn(account);
        BinanceCredentials credentials = new BinanceCredentials("key", "secret");
        when(cipher.decrypt(account.getAppUserId(), account))
                .thenReturn(credentials);
        when(gateway.enforceHedgeMode(credentials)).thenReturn("HEDGE");
        CountDownLatch streamRequested = new CountDownLatch(1);
        when(gateway.createListenKey(credentials))
                .thenAnswer(invocation -> {
                    streamRequested.countDown();
                    throw new BinancePrivateApiException(
                            -1001,
                            "disconnected"
                    );
                });

        TradingAccountSessionManager manager = new TradingAccountSessionManager(
                properties,
                accountMapper,
                positionMapper,
                orderMapper,
                cipher,
                gateway,
                streamClient,
                parser,
                reducer,
                reconciliationService,
                leaseService,
                syncStateService,
                executionCoordinator
        );
        try {
            manager.restoreSessions();
            assertTrue(streamRequested.await(2, TimeUnit.SECONDS));
            verify(gateway).enforceHedgeMode(credentials);
            verify(gateway).createListenKey(credentials);
            verify(gateway, never()).enforceHedgeModeAndMaximumLeverage(
                    org.mockito.ArgumentMatchers.any(),
                    org.mockito.ArgumentMatchers.any()
            );
        } finally {
            manager.shutdown();
        }
    }

    private TradingAccount account() {
        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        account.setAppUserId("user-1");
        account.setQuoteAsset("USDC");
        account.setStatus("ACTIVE");
        account.setSyncStatus(TradingSyncStatus.STOPPED.name());
        return account;
    }
}
