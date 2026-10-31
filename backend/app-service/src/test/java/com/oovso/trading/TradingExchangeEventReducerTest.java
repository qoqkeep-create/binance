package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.trading.TradingUserStreamEvent.BalanceDelta;
import com.oovso.trading.TradingUserStreamEvent.Kind;
import com.oovso.trading.TradingUserStreamEvent.PositionDelta;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;

class TradingExchangeEventReducerTest {

    @Test
    void accountUpdateAppliesOnlyListedDeltasAndNeverClosesMissingPosition() {
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingExchangeEventMapper eventMapper = mock(
                TradingExchangeEventMapper.class
        );
        TradingMirrorService mirrorService = mock(TradingMirrorService.class);
        TradingOutboxService outboxService = mock(TradingOutboxService.class);
        TradingAccount account = account();
        when(accountMapper.isFenceCurrent("account-1", 7)).thenReturn(1);
        when(accountMapper.selectListenableById("account-1"))
                .thenReturn(account);
        when(eventMapper.insertIgnore(any())).thenReturn(1);

        TradingExchangeEventReducer reducer = new TradingExchangeEventReducer(
                accountMapper,
                eventMapper,
                mirrorService,
                outboxService,
                transactionManager()
        );
        TradingUserStreamEvent event = new TradingUserStreamEvent(
                Kind.ACCOUNT_UPDATE,
                "ACCOUNT_UPDATE",
                100,
                90,
                110,
                "account:ORDER",
                "hash-1",
                "{}",
                "ORDER",
                List.of(new BalanceDelta(
                        "USDC",
                        new BigDecimal("100"),
                        new BigDecimal("90"),
                        BigDecimal.ONE
                )),
                List.of(new PositionDelta(
                        "BTCUSDC",
                        "BOTH",
                        new BigDecimal("0.1"),
                        new BigDecimal("63000"),
                        new BigDecimal("62900"),
                        BigDecimal.ZERO,
                        BigDecimal.ONE,
                        "cross",
                        90
                )),
                null,
                null,
                null
        );

        assertTrue(reducer.apply("account-1", 7, event));
        verify(mirrorService).upsertBalance(
                any(),
                any(),
                any(),
                any(),
                any(),
                anyLong(),
                anyLong()
        );
        verify(mirrorService).mergeEventPosition(
                any(),
                any(),
                anyLong()
        );
    }

    @Test
    void duplicateInboxEventDoesNotApplyDomainMutationTwice() {
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingExchangeEventMapper eventMapper = mock(
                TradingExchangeEventMapper.class
        );
        TradingMirrorService mirrorService = mock(TradingMirrorService.class);
        when(accountMapper.isFenceCurrent("account-1", 7)).thenReturn(1);
        when(accountMapper.selectListenableById("account-1"))
                .thenReturn(account());
        when(eventMapper.insertIgnore(any())).thenReturn(0);
        TradingExchangeEventReducer reducer = new TradingExchangeEventReducer(
                accountMapper,
                eventMapper,
                mirrorService,
                mock(TradingOutboxService.class),
                transactionManager()
        );
        TradingUserStreamEvent duplicate = new TradingUserStreamEvent(
                Kind.ACCOUNT_UPDATE,
                "ACCOUNT_UPDATE",
                100,
                90,
                110,
                "account:ORDER",
                "same-hash",
                "{}",
                "ORDER",
                List.of(),
                List.of(),
                null,
                null,
                null
        );

        assertFalse(reducer.apply("account-1", 7, duplicate));
        verify(mirrorService, never()).mergeEventPosition(
                any(),
                any(),
                anyLong()
        );
        verify(accountMapper, never()).markStreamEvent(
                any(),
                anyLong(),
                anyLong()
        );
    }

    private TradingAccount account() {
        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        account.setAppUserId("user-1");
        account.setQuoteAsset("USDC");
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
}
