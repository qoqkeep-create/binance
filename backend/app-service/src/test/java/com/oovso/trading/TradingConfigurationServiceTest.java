package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.oovso.trading.TradingConfigurationService.ExitStrategyCommand;
import com.oovso.trading.TradingConfigurationService.ExitStrategyLevelCommand;
import com.oovso.trading.TradingConfigurationService.LossLimitView;
import com.oovso.trading.TradingConfigurationService.OrderSettingsCommand;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;

class TradingConfigurationServiceTest {

    @Test
    void lossAmountRoundingMatchesReferenceScreenSamples() {
        BigDecimal balance = new BigDecimal("152.32");

        assertEquals(
                new BigDecimal("2.00"),
                TradingConfigurationService.roundedLossAmount(balance, 1)
        );
        assertEquals(
                new BigDecimal("5.00"),
                TradingConfigurationService.roundedLossAmount(balance, 3)
        );
        assertEquals(
                new BigDecimal("6.00"),
                TradingConfigurationService.roundedLossAmount(balance, 4)
        );
        assertEquals(
                new BigDecimal("8.00"),
                TradingConfigurationService.roundedLossAmount(balance, 5)
        );
        assertEquals(
                new BigDecimal("14.00"),
                TradingConfigurationService.roundedLossAmount(balance, 9)
        );
        assertEquals(
                new BigDecimal("15.00"),
                TradingConfigurationService.roundedLossAmount(balance, 10)
        );
        assertEquals(
                new BigDecimal("17.00"),
                TradingConfigurationService.roundedLossAmount(balance, 11)
        );
        assertEquals(
                new BigDecimal("40.00"),
                TradingConfigurationService.roundedLossAmount(balance, 25)
        );
    }

    @Test
    void higherLossAmountIsQueuedForTwoHours() {
        Fixture fixture = new Fixture();

        LossLimitView view = fixture.service.updateLossLimit(
                "user-a",
                "account-a",
                5
        );

        assertEquals(3, view.currentPercentage());
        assertEquals(new BigDecimal("5.00"), view.currentAmount());
        assertEquals(5, view.pendingPercentage());
        assertEquals(new BigDecimal("8.00"), view.pendingAmount());
        assertEquals(
                7_201_000L,
                view.pendingEffectiveAtMillis()
        );
    }

    @Test
    void lowerLossAmountTakesEffectImmediately() {
        Fixture fixture = new Fixture();

        LossLimitView view = fixture.service.updateLossLimit(
                "user-a",
                "account-a",
                1
        );

        assertEquals(1, view.currentPercentage());
        assertEquals(new BigDecimal("2.00"), view.currentAmount());
        assertNull(view.pendingPercentage());
        assertNull(view.pendingEffectiveAtMillis());
    }

    @Test
    void dueHigherLossAmountIsPromotedAtomicallyOnRead() {
        Fixture fixture = new Fixture();
        fixture.limit.setPendingPercentage(5);
        fixture.limit.setPendingAmount(new BigDecimal("8.00"));
        fixture.limit.setPendingEffectiveAtMs(500L);

        LossLimitView view = fixture.service.lossLimit(
                "user-a",
                "account-a"
        );

        assertEquals(5, view.currentPercentage());
        assertEquals(new BigDecimal("8.00"), view.currentAmount());
        assertNull(view.pendingPercentage());
        assertEquals(1L, fixture.limit.getVersion());
    }

    @Test
    void strategyRequiresAtLeastOneActionPerLevel() {
        Fixture fixture = new Fixture();
        ExitStrategyCommand invalid = new ExitStrategyCommand(
                "测试策略",
                List.of(new ExitStrategyLevelCommand(
                        new BigDecimal("2"),
                        BigDecimal.ZERO,
                        "NONE",
                        null
                ))
        );

        TradingApiException error = assertThrows(
                TradingApiException.class,
                () -> fixture.service.createStrategy(
                        "user-a",
                        "account-a",
                        invalid
                )
        );

        assertEquals(
                "每一级至少选择减仓或移动止损中的一项",
                error.getMessage()
        );
    }

    @Test
    void createsOrderedStrategyLevels() {
        Fixture fixture = new Fixture();
        ExitStrategyCommand command = new ExitStrategyCommand(
                "固定1保本2移动",
                List.of(
                        new ExitStrategyLevelCommand(
                                new BigDecimal("2"),
                                new BigDecimal("50"),
                                "NONE",
                                null
                        ),
                        new ExitStrategyLevelCommand(
                                new BigDecimal("3"),
                                BigDecimal.ZERO,
                                "TRAILING_PROFIT_R",
                                BigDecimal.ONE
                        )
                )
        );

        var view = fixture.service.createStrategy(
                "user-a",
                "account-a",
                command
        );

        assertEquals("固定1保本2移动", view.name());
        assertEquals(2, view.levels().size());
        assertEquals(1, view.levels().getFirst().level());
        assertEquals(2, view.levels().getLast().level());
    }

    @Test
    void newOrderSettingsUseSafeDefaults() {
        Fixture fixture = new Fixture();
        when(fixture.orderSettingsMapper.selectByAccount("account-a"))
                .thenReturn(null);
        when(fixture.orderSettingsMapper.insertSettings(any()))
                .thenReturn(1);

        var view = fixture.service.orderSettings("user-a", "account-a");

        assertNull(view.defaultExitStrategyId());
        assertEquals("MAKER_ONLY", view.entryOrderType());
        assertEquals("MAKER_ONLY", view.takeProfitOrderType());
        assertEquals("MARKET", view.stopLossOrderType());
        assertNull(view.fallbackMarketStopR());
    }

    @Test
    void savesLimitStopWithOwnedDefaultStrategyAndFallback() {
        Fixture fixture = new Fixture();
        TradingExitStrategy strategy = new TradingExitStrategy();
        strategy.setId("strategy-a");
        strategy.setStrategyName("默认策略");
        when(fixture.strategyMapper.selectOwned("strategy-a", "account-a"))
                .thenReturn(strategy);

        var view = fixture.service.updateOrderSettings(
                "user-a",
                "account-a",
                new OrderSettingsCommand(
                        "strategy-a",
                        "LIMIT",
                        "MARKET",
                        "LIMIT",
                        new BigDecimal("1.5")
                )
        );

        assertEquals("strategy-a", view.defaultExitStrategyId());
        assertEquals("默认策略", view.defaultExitStrategyName());
        assertEquals("LIMIT", view.entryOrderType());
        assertEquals("MARKET", view.takeProfitOrderType());
        assertEquals("LIMIT", view.stopLossOrderType());
        assertEquals(new BigDecimal("1.5"), view.fallbackMarketStopR());
    }

    @Test
    void limitStopRequiresFallbackStrictlyGreaterThanOneR() {
        Fixture fixture = new Fixture();

        TradingApiException error = assertThrows(
                TradingApiException.class,
                () -> fixture.service.updateOrderSettings(
                        "user-a",
                        "account-a",
                        new OrderSettingsCommand(
                                null,
                                "MAKER_ONLY",
                                "MAKER_ONLY",
                                "LIMIT",
                                BigDecimal.ONE
                        )
                )
        );

        assertEquals(
                "保底市价止损必须大于1R",
                error.getMessage()
        );
    }

    @Test
    void marketStopRejectsUnusedFallbackValue() {
        Fixture fixture = new Fixture();

        TradingApiException error = assertThrows(
                TradingApiException.class,
                () -> fixture.service.updateOrderSettings(
                        "user-a",
                        "account-a",
                        new OrderSettingsCommand(
                                null,
                                "MARKET",
                                "LIMIT",
                                "MARKET",
                                new BigDecimal("2")
                        )
                )
        );

        assertEquals(
                "只有限价止损可以设置保底市价止损",
                error.getMessage()
        );
    }

    @Test
    void deletingDefaultStrategyClearsOrderSettingsReference() {
        Fixture fixture = new Fixture();
        TradingExitStrategy strategy = new TradingExitStrategy();
        strategy.setId("strategy-a");
        when(fixture.strategyMapper.selectOwned("strategy-a", "account-a"))
                .thenReturn(strategy);
        when(fixture.strategyMapper.deleteOwned("strategy-a", "account-a"))
                .thenReturn(1);

        fixture.service.deleteStrategy(
                "user-a",
                "account-a",
                "strategy-a"
        );

        verify(fixture.orderSettingsMapper).clearDefaultStrategy(
                org.mockito.ArgumentMatchers.eq("account-a"),
                org.mockito.ArgumentMatchers.eq("strategy-a"),
                any(LocalDateTime.class)
        );
    }

    private static final class Fixture {
        final TradingAccount account = account();
        final TradingLossLimit limit = limit();
        final TradingAccountMapper accountMapper = mock(
                TradingAccountMapper.class
        );
        final TradingExitStrategyMapper strategyMapper = mock(
                TradingExitStrategyMapper.class
        );
        final TradingExitStrategyLevelMapper levelMapper = mock(
                TradingExitStrategyLevelMapper.class
        );
        final TradingLossLimitMapper lossMapper = mock(
                TradingLossLimitMapper.class
        );
        final TradingOrderSettingsMapper orderSettingsMapper = mock(
                TradingOrderSettingsMapper.class
        );
        final TradingOrderSettings orderSettings = orderSettings();
        final TradingConfigurationService service;

        Fixture() {
            when(accountMapper.selectActiveOwned("account-a", "user-a"))
                    .thenReturn(account);
            when(lossMapper.selectByAccount("account-a")).thenReturn(limit);
            when(lossMapper.updateLimit(any())).thenReturn(1);
            when(strategyMapper.insertStrategy(any())).thenReturn(1);
            when(levelMapper.insertLevel(any())).thenReturn(1);
            when(orderSettingsMapper.selectByAccount("account-a"))
                    .thenReturn(orderSettings);
            when(orderSettingsMapper.updateSettings(any())).thenReturn(1);
            service = new TradingConfigurationService(
                    new TradingProperties(),
                    accountMapper,
                    strategyMapper,
                    levelMapper,
                    lossMapper,
                    orderSettingsMapper,
                    transactionManager(),
                    () -> 1_000L
            );
        }

        private static TradingAccount account() {
            TradingAccount account = new TradingAccount();
            account.setId("account-a");
            account.setAppUserId("user-a");
            account.setQuoteAsset("USDT");
            account.setTotalMarginBalance(new BigDecimal("152.32"));
            return account;
        }

        private static TradingLossLimit limit() {
            TradingLossLimit limit = new TradingLossLimit();
            limit.setId("limit-a");
            limit.setCreateTime(LocalDateTime.now());
            limit.setUpdateTime(LocalDateTime.now());
            limit.setTradingAccountId("account-a");
            limit.setRevision(1L);
            limit.setCurrentPercentage(3);
            limit.setCurrentAmount(new BigDecimal("5.00"));
            limit.setBalanceSnapshot(new BigDecimal("152.32"));
            limit.setSettlementAsset("USDT");
            limit.setVersion(0L);
            return limit;
        }

        private static TradingOrderSettings orderSettings() {
            TradingOrderSettings settings = new TradingOrderSettings();
            settings.setId("order-settings-a");
            settings.setCreateTime(LocalDateTime.now());
            settings.setUpdateTime(LocalDateTime.now());
            settings.setTradingAccountId("account-a");
            settings.setRevision(1L);
            settings.setEntryOrderType("MAKER_ONLY");
            settings.setTakeProfitOrderType("MAKER_ONLY");
            settings.setStopLossOrderType("MARKET");
            settings.setVersion(0L);
            return settings;
        }

        private static PlatformTransactionManager transactionManager() {
            PlatformTransactionManager manager = mock(
                    PlatformTransactionManager.class
            );
            when(manager.getTransaction(any(TransactionDefinition.class)))
                    .thenReturn(mock(TransactionStatus.class));
            return manager;
        }
    }
}
