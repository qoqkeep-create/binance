package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.trading.BinanceUsdmPrivateGateway.PriceSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import com.oovso.trading.TradingConfigurationService.TradingExecutionConfiguration;
import java.math.BigDecimal;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;

class TradingExecutionServiceTest {

    @Test
    void entryDoesNotPrevalidatePositionModeAndFreezesExecutionSnapshot()
            throws Exception {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setEnabled(true);
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
        TradingCommandMapper commandMapper = mock(TradingCommandMapper.class);
        TradingPositionPlanMapper planMapper = mock(
                TradingPositionPlanMapper.class
        );
        TradingPositionPlanLevelMapper levelMapper = mock(
                TradingPositionPlanLevelMapper.class
        );
        TradingConfigurationService configurationService = mock(
                TradingConfigurationService.class
        );
        BinanceUsdmPrivateGateway gateway = mock(
                BinanceUsdmPrivateGateway.class
        );
        TradingAccountSessionManager sessionManager = mock(
                TradingAccountSessionManager.class
        );
        ObjectMapper objectMapper = new ObjectMapper();

        TradingAccount account = account();
        account.setPositionMode("ONE_WAY");
        TradingLossLimit lossLimit = lossLimit();
        TradingOrderSettings settings = orderSettings();
        TradingExitStrategy strategy = strategy();
        List<TradingExitStrategyLevel> sourceLevels = List.of(
                level("level-1", 1, "2", "50", "FIXED_R", "0"),
                level("level-2", 2, "3", "0", "TRAILING_PROFIT_R", "1")
        );
        TradingExecutionConfiguration configuration =
                new TradingExecutionConfiguration(
                        lossLimit,
                        settings,
                        strategy,
                        sourceLevels
                );

        when(accountMapper.selectOwned("account-a", "user-a"))
                .thenReturn(account);
        when(accountMapper.selectOwnedForUpdate("account-a", "user-a"))
                .thenReturn(account);
        when(configurationService.executionConfiguration(account))
                .thenReturn(configuration);
        when(commandMapper.insertCommand(any())).thenReturn(1);
        when(planMapper.insertPlan(any())).thenReturn(1);
        when(levelMapper.insertLevel(any())).thenReturn(1);
        when(gateway.symbolRules("BTCUSDC")).thenReturn(symbolRules());
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(new PriceSnapshot(
                "BTCUSDC",
                bd("101"),
                bd("100.9"),
                bd("101.1"),
                1_000
        ));

        TradingExecutionService service = new TradingExecutionService(
                properties,
                accountMapper,
                positionMapper,
                orderMapper,
                commandMapper,
                planMapper,
                levelMapper,
                configurationService,
                gateway,
                sessionManager,
                objectMapper,
                transactionManager()
        );

        service.createEntry(
                "user-a",
                "account-a",
                "entry-20260807-1",
                new TradingExecutionService.EntryCommand(
                        "BTCUSDC",
                        "LONG",
                        bd("100"),
                        bd("90")
                )
        );

        ArgumentCaptor<TradingPositionPlan> planCaptor =
                ArgumentCaptor.forClass(TradingPositionPlan.class);
        verify(planMapper).insertPlan(planCaptor.capture());
        TradingPositionPlan frozenPlan = planCaptor.getValue();
        assertEquals("LONG", frozenPlan.getPositionSide());
        assertEquals(9L, frozenPlan.getOrderSettingsRevision());
        assertEquals("MARKET", frozenPlan.getTakeProfitOrderType());
        assertEquals("LIMIT", frozenPlan.getStopLossOrderType());
        assertDecimal("1.5", frozenPlan.getFallbackMarketStopR());
        assertEquals(12L, frozenPlan.getExitStrategyRevision());
        assertDecimal("100", frozenPlan.getConfiguredRAmount());
        assertDecimal("10", frozenPlan.getPlannedQuantity());

        String snapshot = frozenPlan.getExecutionSnapshotJson();
        assertNotNull(snapshot);
        assertEquals(64, frozenPlan.getExecutionSnapshotHash().length());
        assertEquals(sha256(snapshot), frozenPlan.getExecutionSnapshotHash());
        JsonNode json = objectMapper.readTree(snapshot);
        assertEquals(9, json.path("orderSettingsRevision").asLong());
        assertEquals("MARKET", json.path("takeProfitOrderType").asText());
        assertEquals("LIMIT", json.path("stopLossOrderType").asText());
        assertEquals(12, json.path("exitStrategyRevision").asLong());
        assertEquals(2, json.path("levels").size());
        assertEquals("50", json.path("levels").get(0)
                .path("reducePercent").asText());

        ArgumentCaptor<TradingPositionPlanLevel> levelCaptor =
                ArgumentCaptor.forClass(TradingPositionPlanLevel.class);
        verify(levelMapper, org.mockito.Mockito.times(2))
                .insertLevel(levelCaptor.capture());
        List<TradingPositionPlanLevel> frozenLevels = levelCaptor.getAllValues();
        assertDecimal("2", frozenLevels.getFirst().getTriggerR());
        assertDecimal("50", frozenLevels.getFirst().getReducePercent());
        assertEquals("TRAILING_PROFIT_R", frozenLevels.getLast()
                .getMoveStopMode());

        settings.setTakeProfitOrderType("MAKER_ONLY");
        settings.setStopLossOrderType("MARKET");
        settings.setFallbackMarketStopR(null);
        sourceLevels.getFirst().setReducePercent(bd("25"));

        assertEquals("MARKET", frozenPlan.getTakeProfitOrderType());
        assertEquals("LIMIT", frozenPlan.getStopLossOrderType());
        assertDecimal("1.5", frozenPlan.getFallbackMarketStopR());
        assertDecimal("50", frozenLevels.getFirst().getReducePercent());
        assertTrue(snapshot.contains("\"fallbackMarketStopR\":1.5"));
        InOrder entryReservation = inOrder(planMapper, accountMapper);
        entryReservation.verify(planMapper).countActiveByKey(
                "account-a",
                "BTCUSDC",
                "LONG"
        );
        entryReservation.verify(accountMapper).selectOwnedForUpdate(
                "account-a",
                "user-a"
        );
        entryReservation.verify(planMapper).countActiveByKey(
                "account-a",
                "BTCUSDC",
                "LONG"
        );
        verify(planMapper, times(2)).countActiveByKey(
                "account-a",
                "BTCUSDC",
                "LONG"
        );
        verify(sessionManager).requestExecution("account-a");
    }

    @Test
    void cancellationPersistsOnlyForSystemEntryLimitOrder() {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setEnabled(true);
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
        TradingCommandMapper commandMapper = mock(TradingCommandMapper.class);
        TradingPositionPlanMapper planMapper = mock(
                TradingPositionPlanMapper.class
        );
        TradingPositionPlanLevelMapper levelMapper = mock(
                TradingPositionPlanLevelMapper.class
        );
        TradingConfigurationService configurationService = mock(
                TradingConfigurationService.class
        );
        BinanceUsdmPrivateGateway gateway = mock(
                BinanceUsdmPrivateGateway.class
        );
        TradingAccountSessionManager sessionManager = mock(
                TradingAccountSessionManager.class
        );
        TradingAccount account = account();
        ExchangeOrder entry = entryLimitOrder();
        when(accountMapper.selectOwned("account-a", "user-a"))
                .thenReturn(account);
        when(orderMapper.selectOwnedRegularById("account-a", "order-entry"))
                .thenReturn(entry);
        when(commandMapper.insertCommand(any())).thenReturn(1);

        TradingExecutionService service = new TradingExecutionService(
                properties,
                accountMapper,
                positionMapper,
                orderMapper,
                commandMapper,
                planMapper,
                levelMapper,
                configurationService,
                gateway,
                sessionManager,
                new ObjectMapper(),
                transactionManager()
        );

        service.cancelEntryLimitOrder(
                "user-a",
                "account-a",
                "cancel-entry:order-entry",
                "order-entry"
        );

        ArgumentCaptor<TradingCommand> commandCaptor =
                ArgumentCaptor.forClass(TradingCommand.class);
        verify(commandMapper).insertCommand(commandCaptor.capture());
        TradingCommand command = commandCaptor.getValue();
        assertEquals("CANCEL_ENTRY", command.getCommandType());
        assertEquals("PERSISTED", command.getStatus());
        assertEquals("tt-e-entry", command.getClientOrderId());
        verify(sessionManager).requestExecution("account-a");

        assertTrue(TradingAccountQueryService.OrderView.from(entry)
                .entryCancelable());
        entry.setPurpose("TAKE_PROFIT");
        assertFalse(TradingAccountQueryService.OrderView.from(entry)
                .entryCancelable());
    }

    @Test
    void makerClosePersistsAPositionScopedCommand() {
        TradingProperties properties = new TradingProperties();
        properties.getSync().setEnabled(true);
        TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
        TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
        ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
        TradingCommandMapper commandMapper = mock(TradingCommandMapper.class);
        TradingPositionPlanMapper planMapper = mock(
                TradingPositionPlanMapper.class
        );
        TradingPositionPlanLevelMapper levelMapper = mock(
                TradingPositionPlanLevelMapper.class
        );
        TradingAccountSessionManager sessionManager = mock(
                TradingAccountSessionManager.class
        );
        TradingAccount account = account();
        TradingPosition position = new TradingPosition();
        position.setId("position-1");
        position.setStatus("OPEN");
        position.setGeneration(4L);
        position.setQuantity(bd("1.25"));
        when(accountMapper.selectOwned("account-a", "user-a"))
                .thenReturn(account);
        when(positionMapper.selectOwnedById("account-a", "position-1"))
                .thenReturn(position);
        when(commandMapper.insertCommand(any())).thenReturn(1);

        TradingExecutionService service = new TradingExecutionService(
                properties,
                accountMapper,
                positionMapper,
                orderMapper,
                commandMapper,
                planMapper,
                levelMapper,
                mock(TradingConfigurationService.class),
                mock(BinanceUsdmPrivateGateway.class),
                sessionManager,
                new ObjectMapper(),
                transactionManager()
        );

        service.closePosition(
                "user-a",
                "account-a",
                "close:position-1:request-1",
                "position-1",
                "maker"
        );

        ArgumentCaptor<TradingCommand> commandCaptor =
                ArgumentCaptor.forClass(TradingCommand.class);
        verify(commandMapper).insertCommand(commandCaptor.capture());
        TradingCommand command = commandCaptor.getValue();
        assertEquals("CLOSE_POSITION_MAKER", command.getCommandType());
        assertTrue(command.getClientOrderId().startsWith("tt-c-"));
        assertTrue(command.getRequestJson().contains("\"positionId\":\"position-1\""));
        verify(sessionManager).requestExecution("account-a");
    }

    private ExchangeOrder entryLimitOrder() {
        ExchangeOrder order = new ExchangeOrder();
        order.setId("order-entry");
        order.setOrderClass("REGULAR");
        order.setOrigin("SYSTEM");
        order.setPurpose("ENTRY");
        order.setSymbol("BTCUSDC");
        order.setSide("BUY");
        order.setPositionSide("LONG");
        order.setOrderType("LIMIT");
        order.setClientOrderId("tt-e-entry");
        order.setQuantity(bd("1"));
        order.setPrice(bd("100"));
        order.setTriggerPrice(BigDecimal.ZERO);
        order.setExecutedQuantity(BigDecimal.ZERO);
        order.setAveragePrice(BigDecimal.ZERO);
        order.setStatus("LIVE");
        return order;
    }

    private TradingAccount account() {
        TradingAccount account = new TradingAccount();
        account.setId("account-a");
        account.setAppUserId("user-a");
        account.setQuoteAsset("USDC");
        account.setPositionMode("HEDGE");
        account.setStatus("ACTIVE");
        account.setSyncStatus(TradingSyncStatus.SYNCED.name());
        return account;
    }

    private TradingLossLimit lossLimit() {
        TradingLossLimit lossLimit = new TradingLossLimit();
        lossLimit.setRevision(7L);
        lossLimit.setCurrentAmount(bd("100"));
        lossLimit.setSettlementAsset("USDC");
        return lossLimit;
    }

    private TradingOrderSettings orderSettings() {
        TradingOrderSettings settings = new TradingOrderSettings();
        settings.setRevision(9L);
        settings.setEntryOrderType("LIMIT");
        settings.setTakeProfitOrderType("MARKET");
        settings.setStopLossOrderType("LIMIT");
        settings.setFallbackMarketStopR(bd("1.5"));
        return settings;
    }

    private TradingExitStrategy strategy() {
        TradingExitStrategy strategy = new TradingExitStrategy();
        strategy.setId("strategy-a");
        strategy.setStrategyRevision(12L);
        return strategy;
    }

    private TradingExitStrategyLevel level(
            String id,
            int number,
            String triggerR,
            String reducePercent,
            String moveMode,
            String moveR
    ) {
        TradingExitStrategyLevel level = new TradingExitStrategyLevel();
        level.setId(id);
        level.setLevelNo(number);
        level.setTriggerR(bd(triggerR));
        level.setReducePercent(bd(reducePercent));
        level.setMoveStopMode(moveMode);
        level.setMoveStopR(bd(moveR));
        return level;
    }

    private SymbolRules symbolRules() {
        return new SymbolRules(
                "BTCUSDC",
                "TRADING",
                "BTC",
                "USDC",
                bd("0.1"),
                bd("0.001"),
                bd("1000"),
                bd("0.001"),
                bd("0.001"),
                bd("1000"),
                bd("0.001"),
                bd("5")
        );
    }

    private PlatformTransactionManager transactionManager() {
        PlatformTransactionManager manager = mock(
                PlatformTransactionManager.class
        );
        when(manager.getTransaction(any(TransactionDefinition.class)))
                .thenReturn(mock(TransactionStatus.class));
        return manager;
    }

    private String sha256(String value) throws Exception {
        return HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(value.getBytes(
                        java.nio.charset.StandardCharsets.UTF_8
                ))
        );
    }

    private BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    private void assertDecimal(String expected, BigDecimal actual) {
        assertEquals(0, bd(expected).compareTo(actual));
    }
}
