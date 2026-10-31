package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.trading.BinanceUsdmPrivateGateway.VerifiedAccount;
import com.oovso.trading.TradingCredentialCipher.EncryptedCredential;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;

class TradingAccountServiceTest {

    @Test
    void bindingVerifiesBeforePersistingAndStartsAccountSync() {
        TradingProperties properties = new TradingProperties();
        BinanceContinuousKlineProperties marketProperties =
                new BinanceContinuousKlineProperties();
        marketProperties.setQuoteAsset("USDC");
        TradingCredentialCipher cipher = mock(TradingCredentialCipher.class);
        BinanceUsdmPrivateGateway gateway = mock(
                BinanceUsdmPrivateGateway.class
        );
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingRiskPolicyMapper riskMapper = mock(
                TradingRiskPolicyMapper.class
        );
        TradingPositionMapper positionMapper = mock(
                TradingPositionMapper.class
        );
        PlatformTransactionManager transactionManager = transactionManager();
        VerifiedAccount beforeSetup = new VerifiedAccount(
                new BigDecimal("152.32"),
                new BigDecimal("-1.25"),
                "USDC",
                "ONE_WAY",
                1000L,
                List.of()
        );
        VerifiedAccount verified = new VerifiedAccount(
                beforeSetup.totalMarginBalance(),
                beforeSetup.unrealizedProfit(),
                beforeSetup.asset(),
                "HEDGE",
                1001L,
                List.of()
        );
        when(gateway.verify(any(), any()))
                .thenReturn(beforeSetup, verified);
        when(gateway.enforceHedgeModeAndMaximumLeverage(any(), any()))
                .thenReturn(new BinanceUsdmPrivateGateway.AccountSetupResult(
                        "HEDGE",
                        12
                ));
        when(cipher.encrypt(any(), any(), any())).thenReturn(
                new EncryptedCredential(
                        "ciphertext",
                        "nonce",
                        "fingerprint",
                        "abcde****vwxyz",
                        "v1"
                )
        );
        when(positionMapper.selectByAccount(any())).thenReturn(List.of());

        TradingAccountService service = new TradingAccountService(
                properties,
                marketProperties,
                cipher,
                gateway,
                accountMapper,
                riskMapper,
                positionMapper,
                transactionManager
        );
        TradingAccountSessionManager sessionManager = mock(
                TradingAccountSessionManager.class
        );
        service.setSessionManager(sessionManager);

        TradingAccountService.AccountView response = service.bind(
                "user-a",
                "abcde12345vwxyz",
                "server-only-secret"
        );

        assertEquals(new BigDecimal("152.32"), response.totalMarginBalance());
        assertEquals("abcde****vwxyz", response.apiKeyMasked());
        assertFalse(response.canExecute());
        verify(gateway, times(2)).verify(
                any(BinanceCredentials.class),
                any()
        );
        verify(gateway).enforceHedgeModeAndMaximumLeverage(
                any(BinanceCredentials.class),
                any()
        );
        verify(accountMapper).insertAccount(any(TradingAccount.class));
        verify(riskMapper).insertPolicy(any(TradingRiskPolicy.class));
        verify(sessionManager).restartAccount(response.id());
    }

    private PlatformTransactionManager transactionManager() {
        PlatformTransactionManager transactionManager = mock(
                PlatformTransactionManager.class
        );
        when(transactionManager.getTransaction(any(TransactionDefinition.class)))
                .thenReturn(mock(TransactionStatus.class));
        return transactionManager;
    }
}
