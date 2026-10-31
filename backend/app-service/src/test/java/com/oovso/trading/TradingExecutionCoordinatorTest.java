package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.atLeast;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.trading.BinanceUsdmPrivateGateway.AlgoOrderRequest;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.PriceSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.RegularOrderRequest;
import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

class TradingExecutionCoordinatorTest {

    private final TradingProperties properties = new TradingProperties();
    private final TradingAccountMapper accountMapper = mock(TradingAccountMapper.class);
    private final TradingCommandMapper commandMapper = mock(TradingCommandMapper.class);
    private final TradingPositionPlanMapper planMapper = mock(TradingPositionPlanMapper.class);
    private final TradingPositionPlanLevelMapper levelMapper =
            mock(TradingPositionPlanLevelMapper.class);
    private final TradingPositionMapper positionMapper = mock(TradingPositionMapper.class);
    private final ExchangeOrderMapper orderMapper = mock(ExchangeOrderMapper.class);
    private final BinanceUsdmPrivateGateway gateway = mock(BinanceUsdmPrivateGateway.class);
    private final TradingMirrorService mirrorService = mock(TradingMirrorService.class);
    private final TradingExecutionCoordinator coordinator =
            new TradingExecutionCoordinator(
                    properties,
                    accountMapper,
                    commandMapper,
                    planMapper,
                    levelMapper,
                    positionMapper,
                    orderMapper,
                    gateway,
                    mirrorService,
                    new ObjectMapper()
            );
    private final BinanceCredentials credentials =
            new BinanceCredentials("api-key", "secret");

    @BeforeEach
    void setUp() {
        when(accountMapper.isFenceCurrent("account-1", 7L)).thenReturn(1);
        when(accountMapper.selectListenableById("account-1"))
                .thenReturn(account());
        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of());
        when(planMapper.updatePlan(any())).thenReturn(1);
        when(levelMapper.updateLevel(any())).thenReturn(1);
        when(orderMapper.selectActiveSystemStops(anyString(), anyString(), anyString()))
                .thenReturn(List.of());
        when(orderMapper.selectActiveManualCloseOrdersByAccount("account-1"))
                .thenReturn(List.of());
    }

    @Test
    void entrySubmitsOnceWithoutCheckingOrChangingPositionMode() {
        TradingCommand command = new TradingCommand();
        command.setId("command-entry-1");
        command.setCreateTime(LocalDateTime.now());
        command.setTradingAccountId("account-1");
        command.setStatus("PERSISTED");
        command.setVersion(0L);
        TradingPositionPlan plan = plan();
        plan.setPositionSide("LONG");
        ExchangeOrder intent = regularOrder(
                "intent-entry-1",
                plan.getEntryClientOrderId(),
                "INTENT",
                plan.getPlannedQuantity(),
                BigDecimal.ZERO
        );
        intent.setPositionSide("LONG");
        ExchangeOrder merged = regularOrder(
                "exchange-entry-1",
                plan.getEntryClientOrderId(),
                "LIVE",
                plan.getPlannedQuantity(),
                BigDecimal.ZERO
        );
        merged.setPositionSide("LONG");

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(planMapper.selectByCommand(command.getId())).thenReturn(plan);
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                plan.getEntryClientOrderId(),
                null
        )).thenReturn(null, intent);
        when(orderMapper.insertOrder(any())).thenReturn(1);
        when(orderMapper.updateOrder(any())).thenReturn(1);
        when(commandMapper.transition(
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                any(),
                any(),
                any(),
                any(),
                anyLong()
        )).thenReturn(1);
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenReturn(new OrderSnapshot(
                        "REGULAR", "BTCUSDC", "BUY", "LONG",
                        "LIMIT", "GTC", null,
                        plan.getEntryClientOrderId(), "exchange-entry-1",
                        null, null, null, plan.getPlannedQuantity(),
                        bd("100"), BigDecimal.ZERO, BigDecimal.ZERO,
                        BigDecimal.ZERO, BigDecimal.ZERO, false, false,
                        "NEW", System.currentTimeMillis(),
                        System.currentTimeMillis()
                ));
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(),
                eq(true)
        )).thenReturn(merged);

        coordinator.tick("account-1", 7L, credentials, false);

        verify(gateway, never()).enforceHedgeMode(credentials);
        verify(gateway, times(1)).placeRegularOrder(
                eq(credentials),
                any()
        );
        assertEquals("SUCCEEDED", command.getStatus());
    }

    @Test
    void cancelEntryCommandCancelsOnlyTheTargetLimitOrder() {
        TradingCommand command = new TradingCommand();
        command.setId("command-cancel-entry-1");
        command.setCreateTime(LocalDateTime.now());
        command.setTradingAccountId("account-1");
        command.setCommandType("CANCEL_ENTRY");
        command.setStatus("PERSISTED");
        command.setClientOrderId("tt-e-entry-1");
        command.setVersion(0L);
        ExchangeOrder entry = regularOrder(
                "entry-1",
                command.getClientOrderId(),
                "LIVE",
                bd("2"),
                BigDecimal.ZERO
        );
        entry.setOrigin("SYSTEM");
        entry.setPurpose("ENTRY");
        entry.setOrderType("LIMIT");
        ExchangeOrder canceled = regularOrder(
                "entry-1",
                command.getClientOrderId(),
                "CANCELED",
                bd("2"),
                BigDecimal.ZERO
        );
        canceled.setOrigin("SYSTEM");
        canceled.setPurpose("ENTRY");
        canceled.setOrderType("LIMIT");

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                command.getClientOrderId(),
                null
        )).thenReturn(entry);
        when(commandMapper.transition(
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                any(),
                any(),
                any(),
                any(),
                anyLong()
        )).thenReturn(1);
        when(gateway.cancelRegularOrder(
                credentials,
                "BTCUSDC",
                command.getClientOrderId(),
                entry.getExchangeOrderId()
        )).thenReturn(regularSnapshot(
                command.getClientOrderId(),
                "CANCELED",
                bd("2"),
                BigDecimal.ZERO
        ));
        when(mirrorService.mergeOrder(
                any(),
                any(),
                eq("REST_CANCEL"),
                isNull(),
                anyLong(),
                anyLong(),
                eq(true)
        )).thenReturn(canceled);

        coordinator.tick("account-1", 7L, credentials, false);

        verify(gateway).cancelRegularOrder(
                credentials,
                "BTCUSDC",
                command.getClientOrderId(),
                entry.getExchangeOrderId()
        );
        assertEquals("SUCCEEDED", command.getStatus());
    }

    @Test
    void makerCloseLongSellsOneTickAboveBestAsk() {
        assertMakerClose("LONG", bd("1.234"), "SELL", bd("100.2"));
    }

    @Test
    void makerCloseShortBuysOneTickBelowBestBid() {
        assertMakerClose("SHORT", bd("-1.234"), "BUY", bd("99.8"));
    }

    @Test
    void manualCloseCancelsPlanEntryAndTakeProfitBeforeSubmitting() {
        TradingCommand command = new TradingCommand();
        command.setId("command-managed-close");
        command.setCreateTime(LocalDateTime.now());
        command.setTradingAccountId("account-1");
        command.setCommandType("CLOSE_POSITION_MAKER");
        command.setStatus("PERSISTED");
        command.setClientOrderId("tt-c-managed");
        command.setRequestJson(
                "{\"positionId\":\"position-1\",\"orderType\":\"MAKER\"}"
        );
        command.setVersion(0L);

        TradingPositionPlan plan = plan();
        plan.setStatus("ACTIVE");
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(3L);
        TradingPosition position = position("position-1", 3L, bd("1.2"));
        position.setSymbol("BTCUSDC");
        position.setPositionSide("BOTH");
        ExchangeOrder entry = regularOrder(
                "entry-managed",
                plan.getEntryClientOrderId(),
                "PARTIALLY_FILLED",
                bd("2"),
                bd("1.2")
        );
        TradingPositionPlanLevel level = level(plan.getId());
        level.setReductionClientOrderId("tt-r-managed");
        level.setReductionStatus("LIVE");
        ExchangeOrder reduction = regularOrder(
                "reduction-managed",
                level.getReductionClientOrderId(),
                "LIVE",
                bd("0.5"),
                BigDecimal.ZERO
        );
        AtomicReference<ExchangeOrder> closeIntent = new AtomicReference<>();

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(positionMapper.selectOwnedById("account-1", "position-1"))
                .thenReturn(position);
        when(planMapper.selectActiveByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(plan);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            if (plan.getEntryClientOrderId().equals(clientId)) {
                return entry;
            }
            if (level.getReductionClientOrderId().equals(clientId)) {
                return reduction;
            }
            return closeIntent.get();
        });
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            closeIntent.set(invocation.getArgument(0));
            return 1;
        });
        when(orderMapper.updateOrder(any())).thenReturn(1);
        when(commandMapper.transition(
                anyString(), anyString(), anyString(), anyString(), any(),
                any(), any(), any(), anyLong()
        )).thenReturn(1);
        when(gateway.symbolRules("BTCUSDC")).thenReturn(new SymbolRules(
                "BTCUSDC", "TRADING", "BTC", "USDC", bd("0.1"),
                bd("0.1"), bd("100"), bd("0.1"), bd("0.1"),
                bd("100"), bd("0.1"), bd("5")
        ));
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(new PriceSnapshot(
                "BTCUSDC", bd("100"), bd("99.9"), bd("100.1"), 1_000
        ));
        when(gateway.cancelRegularOrder(
                eq(credentials), eq("BTCUSDC"), anyString(), anyString()
        )).thenAnswer(invocation -> regularSnapshot(
                invocation.getArgument(2),
                "CANCELED",
                plan.getEntryClientOrderId().equals(invocation.getArgument(2))
                        ? bd("2")
                        : bd("0.5"),
                plan.getEntryClientOrderId().equals(invocation.getArgument(2))
                        ? bd("1.2")
                        : BigDecimal.ZERO
        ));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return regularSnapshot(
                            request.clientOrderId(),
                            "NEW",
                            request.quantity(),
                            BigDecimal.ZERO
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder target;
            if (plan.getEntryClientOrderId().equals(snapshot.clientOrderId())) {
                target = entry;
            } else if (level.getReductionClientOrderId().equals(
                    snapshot.clientOrderId()
            )) {
                target = reduction;
            } else {
                target = closeIntent.get();
            }
            target.setStatus(TradingOrderStateMachine.normalizeRegular(
                    snapshot.exchangeStatus()
            ));
            target.setExecutedQuantity(snapshot.executedQuantity());
            return target;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        verify(levelMapper).selectByPlan(plan.getId());
        InOrder exchangeSequence = inOrder(gateway);
        exchangeSequence.verify(gateway).cancelRegularOrder(
                credentials,
                "BTCUSDC",
                plan.getEntryClientOrderId(),
                entry.getExchangeOrderId()
        );
        exchangeSequence.verify(gateway).cancelRegularOrder(
                credentials,
                "BTCUSDC",
                level.getReductionClientOrderId(),
                reduction.getExchangeOrderId()
        );
        exchangeSequence.verify(gateway).placeRegularOrder(
                eq(credentials),
                any()
        );
        assertEquals("MANUAL_CLOSING", plan.getStatus());
        assertEquals("SUCCEEDED", command.getStatus());
    }

    @Test
    void manualCloseWaitsWhenManagedOrderCleanupIsUnconfirmed() {
        TradingCommand command = new TradingCommand();
        command.setId("command-managed-close-pending");
        command.setCreateTime(LocalDateTime.now());
        command.setTradingAccountId("account-1");
        command.setCommandType("CLOSE_POSITION_MAKER");
        command.setStatus("PERSISTED");
        command.setClientOrderId("tt-c-managed-pending");
        command.setRequestJson(
                "{\"positionId\":\"position-1\",\"orderType\":\"MAKER\"}"
        );
        command.setVersion(0L);

        TradingPositionPlan plan = plan();
        plan.setStatus("ACTIVE");
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(3L);
        TradingPosition position = position("position-1", 3L, bd("1.2"));
        position.setSymbol("BTCUSDC");
        position.setPositionSide("BOTH");
        ExchangeOrder entry = regularOrder(
                "entry-managed-pending",
                plan.getEntryClientOrderId(),
                "PARTIALLY_FILLED",
                bd("2"),
                bd("1.2")
        );

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(positionMapper.selectOwnedById("account-1", "position-1"))
                .thenReturn(position);
        when(planMapper.selectActiveByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(plan);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of());
        when(orderMapper.selectActiveSystemTakeProfits(
                "account-1",
                "position-1",
                3L
        )).thenReturn(List.of());
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                plan.getEntryClientOrderId(),
                null
        )).thenReturn(entry);
        when(gateway.symbolRules("BTCUSDC")).thenReturn(new SymbolRules(
                "BTCUSDC", "TRADING", "BTC", "USDC", bd("0.1"),
                bd("0.1"), bd("100"), bd("0.1"), bd("0.1"),
                bd("100"), bd("0.1"), bd("5")
        ));
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(new PriceSnapshot(
                "BTCUSDC", bd("100"), bd("99.9"), bd("100.1"), 1_000
        ));
        when(gateway.cancelRegularOrder(
                credentials,
                "BTCUSDC",
                plan.getEntryClientOrderId(),
                entry.getExchangeOrderId()
        )).thenThrow(new BinancePrivateApiException(
                "timeout",
                new IllegalStateException("timeout")
        ));

        coordinator.tick("account-1", 7L, credentials, false);

        assertEquals("MANUAL_CLOSING", plan.getStatus());
        assertEquals("MANUAL_CLOSE_CLEANUP_PENDING", plan.getLastErrorCode());
        assertEquals("PERSISTED", command.getStatus());
        verify(gateway, never()).placeRegularOrder(any(), any());
        verify(orderMapper, never()).insertOrder(any());
    }

    @Test
    void orphanedMakerCloseIsCanceledWhenPositionGenerationEnds() {
        ExchangeOrder maker = regularOrder(
                "manual-close-orphan",
                "tt-c-orphan",
                "LIVE",
                bd("1"),
                BigDecimal.ZERO
        );
        maker.setOrigin("SYSTEM");
        maker.setPurpose("MANUAL_CLOSE");
        maker.setOrderType("LIMIT");
        maker.setTradingPositionId("position-1");
        maker.setPositionGeneration(4L);
        TradingPosition closed = position("position-1", 4L, BigDecimal.ZERO);
        closed.setStatus("CLOSED");
        closed.setSymbol("BTCUSDC");
        closed.setPositionSide("LONG");
        ExchangeOrder canceled = regularOrder(
                maker.getId(),
                maker.getClientOrderId(),
                "CANCELED",
                maker.getQuantity(),
                BigDecimal.ZERO
        );

        when(orderMapper.selectActiveManualCloseOrdersByAccount("account-1"))
                .thenReturn(List.of(maker));
        when(positionMapper.selectOwnedById("account-1", "position-1"))
                .thenReturn(closed);
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                maker.getClientOrderId(),
                null
        )).thenReturn(maker);
        when(gateway.cancelRegularOrder(
                credentials,
                "BTCUSDC",
                maker.getClientOrderId(),
                maker.getExchangeOrderId()
        )).thenReturn(regularSnapshot(
                maker.getClientOrderId(),
                "CANCELED",
                maker.getQuantity(),
                BigDecimal.ZERO
        ));
        when(mirrorService.mergeOrder(
                any(), any(), eq("REST_CANCEL"), isNull(), anyLong(),
                anyLong(), eq(true)
        )).thenReturn(canceled);

        coordinator.tick("account-1", 7L, credentials, false);

        verify(gateway).cancelRegularOrder(
                credentials,
                "BTCUSDC",
                maker.getClientOrderId(),
                maker.getExchangeOrderId()
        );
    }

    @Test
    void queuedDuplicateCloseIsRejectedAfterEarlierCloseWasDispatched() {
        TradingCommand command = new TradingCommand();
        command.setId("command-close-duplicate");
        command.setCreateTime(LocalDateTime.now().minusSeconds(2));
        command.setTradingAccountId("account-1");
        command.setCommandType("CLOSE_POSITION_MARKET");
        command.setStatus("PERSISTED");
        command.setClientOrderId("tt-c-duplicate");
        command.setRequestJson(
                "{\"positionId\":\"position-1\",\"orderType\":\"MARKET\"}"
        );
        command.setVersion(0L);
        TradingPosition position = position("position-1", 3L, bd("1"));
        position.setSymbol("BTCUSDC");
        position.setPositionSide("LONG");
        ExchangeOrder earlier = regularOrder(
                "close-earlier",
                "tt-c-earlier",
                "FILLED",
                bd("1"),
                bd("1")
        );
        earlier.setCreateTime(LocalDateTime.now().minusSeconds(1));
        earlier.setOrigin("SYSTEM");
        earlier.setPurpose("MANUAL_CLOSE");
        earlier.setTradingPositionId("position-1");
        earlier.setPositionGeneration(3L);

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(positionMapper.selectOwnedById("account-1", "position-1"))
                .thenReturn(position);
        when(orderMapper.selectLatestManualClose(
                "account-1",
                "position-1",
                3L
        )).thenReturn(earlier);
        when(commandMapper.transition(
                anyString(), anyString(), anyString(), anyString(), any(),
                any(), any(), any(), anyLong()
        )).thenReturn(1);

        coordinator.tick("account-1", 7L, credentials, false);

        assertEquals("FAILED_KNOWN", command.getStatus());
        verify(gateway, never()).placeRegularOrder(any(), any());
    }

    @Test
    void closingPartiallyFilledPlanCancelsRemainingEntryBeforeClosing() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "PARTIALLY_FILLED",
                bd("2"),
                bd("1")
        );
        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                plan.getEntryClientOrderId(),
                null
        )).thenReturn(entry);
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(null);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of());
        when(gateway.cancelRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq(plan.getEntryClientOrderId()),
                eq(entry.getExchangeOrderId())
        )).thenReturn(regularSnapshot(
                plan.getEntryClientOrderId(),
                "CANCELED",
                bd("2"),
                bd("1")
        ));

        coordinator.tick("account-1", 7L, credentials, false);

        verify(gateway).cancelRegularOrder(
                credentials,
                "BTCUSDC",
                plan.getEntryClientOrderId(),
                entry.getExchangeOrderId()
        );
        assertEquals("CLOSED", plan.getStatus());
    }

    @Test
    void failedStaleStopCleanupKeepsPlanActiveAndRetriesNextTick() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "FILLED",
                bd("1"),
                bd("1")
        );
        ExchangeOrder stale = algoOrder(
                "algo-old",
                stopClientId("tt-s-", plan, 1),
                "NEW"
        );
        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                plan.getEntryClientOrderId(),
                null
        )).thenReturn(entry);
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(null);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of());
        when(orderMapper.selectActiveSystemStops("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(List.of(stale));
        when(orderMapper.selectAlgoByIdentity(
                "account-1",
                stale.getClientAlgoId(),
                null
        )).thenReturn(stale);
        when(gateway.cancelAlgoOrder(
                credentials,
                stale.getClientAlgoId(),
                stale.getExchangeAlgoId()
        )).thenThrow(new BinancePrivateApiException(
                "timeout",
                new IllegalStateException("timeout")
        )).thenReturn(algoSnapshot(stale, "CANCELED"));

        coordinator.tick("account-1", 7L, credentials, false);
        assertEquals("DEGRADED", plan.getStatus());
        assertEquals("CLOSE_CLEANUP_PENDING", plan.getLastErrorCode());
        assertNotNull(plan.getNextProtectionRepairAtMs());

        coordinator.tick("account-1", 7L, credentials, false);
        verify(gateway, times(1)).cancelAlgoOrder(
                credentials,
                stale.getClientAlgoId(),
                stale.getExchangeAlgoId()
        );

        plan.setNextProtectionRepairAtMs(System.currentTimeMillis() - 1);
        coordinator.tick("account-1", 7L, credentials, false);
        verify(gateway, atLeast(2)).cancelAlgoOrder(
                credentials,
                stale.getClientAlgoId(),
                stale.getExchangeAlgoId()
        );
        assertEquals("CLOSED", plan.getStatus());
    }

    @Test
    void partialEntryFillPreinstallsConditionalMarketTakeProfit() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setTakeProfitOrderType("MARKET");
        plan.setLastOrderHealthCheckMs(System.currentTimeMillis());
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "PARTIALLY_FILLED",
                bd("2"),
                bd("1")
        );
        entry.setAveragePrice(bd("100"));
        TradingPosition position = position("position-1", 1L, bd("1"));
        TradingPositionPlanLevel level = level(plan.getId());
        AtomicReference<ExchangeOrder> reduction = new AtomicReference<>();

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"),
                anyString(),
                isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : null;
        });
        when(orderMapper.selectAlgoByIdentity(
                eq("account-1"),
                anyString(),
                isNull()
        )).thenAnswer(invocation -> reduction.get());
        when(orderMapper.selectRegularByExchangeId(
                eq("account-1"),
                anyString()
        )).thenReturn(null);
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reduction.set(inserted);
            return 1;
        });
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(new PriceSnapshot(
                "BTCUSDC",
                bd("105"),
                bd("104.9"),
                bd("105.1"),
                System.currentTimeMillis()
        ));
        when(gateway.placeAlgoOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    AlgoOrderRequest request = invocation.getArgument(1);
                    return algoTakeProfitSnapshot(request, "NEW", null);
                });
        when(mirrorService.mergeOrder(
                any(),
                any(),
                anyString(),
                isNull(),
                anyLong(),
                anyLong(),
                eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder live = algoTakeProfitOrder(
                    "reduction-live",
                    snapshot.clientAlgoId(),
                    "NEW",
                    snapshot.quantity(),
                    snapshot.triggerPrice()
            );
            reduction.set(live);
            return live;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        ArgumentCaptor<AlgoOrderRequest> request =
                ArgumentCaptor.forClass(AlgoOrderRequest.class);
        verify(gateway).placeAlgoOrder(eq(credentials), request.capture());
        assertEquals("TAKE_PROFIT_MARKET", request.getValue().type());
        assertEquals(bd("0.5"), request.getValue().quantity());
        assertEquals(0, bd("110.0").compareTo(request.getValue().triggerPrice()));
        assertEquals(false, request.getValue().closePosition());
        assertEquals(true, request.getValue().reduceOnly());
        assertEquals(bd("1"), plan.getInitialFilledQuantity());
        assertEquals("LIVE", level.getReductionStatus());
        assertEquals("PENDING", level.getStatus());
        verify(gateway, never()).placeRegularOrder(any(), any());
    }

    @Test
    void healthPollingRepairsMissingUntriggeredLimitTakeProfit() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "FILLED",
                bd("1"),
                bd("1")
        );
        entry.setAveragePrice(bd("100"));
        TradingPosition position = position("position-1", 1L, bd("1"));
        TradingPositionPlanLevel level = level(plan.getId());
        AtomicReference<ExchangeOrder> reduction = new AtomicReference<>();

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : reduction.get();
        });
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reduction.set(inserted);
            return 1;
        });
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(price(bd("105")));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return regularSnapshot(
                            request.clientOrderId(),
                            "NEW",
                            request.quantity(),
                            BigDecimal.ZERO
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder live = regularOrder(
                    "reduction-live",
                    snapshot.clientOrderId(),
                    "LIVE",
                    snapshot.quantity(),
                    BigDecimal.ZERO
            );
            reduction.set(live);
            return live;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        ArgumentCaptor<RegularOrderRequest> request =
                ArgumentCaptor.forClass(RegularOrderRequest.class);
        verify(gateway).placeRegularOrder(eq(credentials), request.capture());
        assertEquals("LIMIT", request.getValue().type());
        assertEquals("GTC", request.getValue().timeInForce());
        assertEquals(0, bd("110").compareTo(request.getValue().price()));
        assertEquals(bd("0.5"), request.getValue().quantity());
        assertEquals("PENDING", level.getStatus());
        assertEquals("LIVE", level.getReductionStatus());
    }

    @Test
    void healthPollingResolvesTriggeredMarketTakeProfitChildFill() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setTakeProfitOrderType("MARKET");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "FILLED",
                bd("1"),
                bd("1")
        );
        TradingPosition position = position("position-1", 1L, bd("0.5"));
        TradingPositionPlanLevel level = level(plan.getId());
        level.setReductionClientOrderId("tt-x-market-1");
        level.setReductionRevision(1L);
        level.setPlannedReductionQuantity(bd("0.5"));
        level.setReductionStatus("LIVE");
        ExchangeOrder algo = algoTakeProfitOrder(
                "algo-tp-1",
                level.getReductionClientOrderId(),
                "FINISHED",
                bd("0.5"),
                bd("110")
        );
        algo.setActualOrderId("actual-tp-1");
        ExchangeOrder child = regularOrder(
                "child-tp-1",
                null,
                "FILLED",
                bd("0.5"),
                bd("0.5")
        );
        child.setExchangeOrderId("actual-tp-1");

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                "account-1", plan.getEntryClientOrderId(), null
        )).thenReturn(entry);
        when(orderMapper.selectAlgoByIdentity(
                "account-1", level.getReductionClientOrderId(), null
        )).thenReturn(algo);
        when(orderMapper.selectRegularByExchangeId(
                "account-1", "actual-tp-1"
        )).thenReturn(child);
        when(gateway.queryAlgoOrder(
                credentials,
                level.getReductionClientOrderId(),
                algo.getExchangeAlgoId()
        )).thenReturn(Optional.of(algoTakeProfitSnapshot(
                new AlgoOrderRequest(
                        "BTCUSDC", "SELL", "BOTH", "TAKE_PROFIT_MARKET",
                        null, "MARK_PRICE", bd("0.5"), null, bd("110"),
                        true, false, level.getReductionClientOrderId()
                ),
                "FINISHED",
                "actual-tp-1"
        )));
        when(gateway.queryRegularOrder(
                credentials, "BTCUSDC", null, "actual-tp-1"
        )).thenReturn(Optional.of(regularSnapshot(
                null, "FILLED", bd("0.5"), bd("0.5")
        )));
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            return "ALGO".equals(snapshot.orderClass()) ? algo : child;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        assertEquals("COMPLETED", level.getReductionStatus());
        assertEquals("ACTIVE", level.getStatus());
        assertEquals(0, bd("0.5").compareTo(
                level.getExecutedReductionQuantity()
        ));
        assertNotNull(level.getTriggeredAtMs());
    }

    @Test
    void laterEntryFillsReplaceAnUnderCoveredLiveTakeProfit() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setInitialFilledQuantity(bd("2"));
        plan.setFilledQuantity(bd("2"));
        plan.setLastOrderHealthCheckMs(System.currentTimeMillis());
        ExchangeOrder entry = regularOrder(
                "entry-1",
                plan.getEntryClientOrderId(),
                "FILLED",
                bd("2"),
                bd("2")
        );
        TradingPosition position = position("position-1", 1L, bd("2"));
        TradingPositionPlanLevel level = level(plan.getId());
        level.setStatus("ACTIVE");
        level.setReductionStatus("LIVE");
        level.setPlannedReductionQuantity(bd("0.5"));
        level.setReductionClientOrderId("tt-r-old");
        level.setReductionRevision(1L);
        AtomicReference<ExchangeOrder> reduction = new AtomicReference<>(
                regularOrder("reduction-old", "tt-r-old", "LIVE", bd("0.5"),
                        BigDecimal.ZERO)
        );

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"),
                anyString(),
                isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : reduction.get();
        });
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reduction.set(inserted);
            return 1;
        });
        when(gateway.queryRegularOrder(
                credentials,
                "BTCUSDC",
                "tt-r-old",
                reduction.get().getExchangeOrderId()
        )).thenReturn(Optional.of(regularSnapshot(
                "tt-r-old", "NEW", bd("0.5"), BigDecimal.ZERO
        )));
        when(gateway.cancelRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq("tt-r-old"),
                anyString()
        )).thenReturn(regularSnapshot(
                "tt-r-old", "CANCELED", bd("0.5"), BigDecimal.ZERO
        ));
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(price(bd("105")));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return regularSnapshot(
                            request.clientOrderId(),
                            "NEW",
                            request.quantity(),
                            BigDecimal.ZERO
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder merged = regularOrder(
                    "mirror-" + snapshot.clientOrderId(),
                    snapshot.clientOrderId(),
                    "CANCELED".equals(snapshot.exchangeStatus())
                            ? "CANCELED"
                            : "LIVE",
                    snapshot.quantity(),
                    snapshot.executedQuantity()
            );
            reduction.set(merged);
            return merged;
        });

        coordinator.tick("account-1", 7L, credentials, true);

        verify(gateway).cancelRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq("tt-r-old"),
                anyString()
        );
        ArgumentCaptor<RegularOrderRequest> request =
                ArgumentCaptor.forClass(RegularOrderRequest.class);
        verify(gateway).placeRegularOrder(eq(credentials), request.capture());
        assertEquals(bd("1"), request.getValue().quantity());
        assertEquals(2L, level.getReductionRevision());
        assertEquals("LIVE", level.getReductionStatus());
    }

    @Test
    void outstandingTakeProfitsReserveCapacityAcrossMultipleLevels() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        plan.setLastOrderHealthCheckMs(System.currentTimeMillis());
        ExchangeOrder entry = regularOrder(
                "entry-1", plan.getEntryClientOrderId(), "FILLED", bd("1"), bd("1")
        );
        TradingPosition position = position("position-1", 1L, bd("0.6"));
        TradingPositionPlanLevel first = level(plan.getId(), "level-1", 1);
        TradingPositionPlanLevel second = level(plan.getId(), "level-2", 2);
        List<TradingPositionPlanLevel> levels = List.of(first, second);
        Map<String, ExchangeOrder> reductions = new HashMap<>();

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(levels);
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : reductions.get(clientId);
        });
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reductions.put(inserted.getClientOrderId(), inserted);
            return 1;
        });
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(price(bd("115")));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return regularSnapshot(
                            request.clientOrderId(),
                            "NEW",
                            request.quantity(),
                            BigDecimal.ZERO
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder merged = reductions.get(snapshot.clientOrderId());
            merged.setStatus("LIVE");
            merged.setExecutedQuantity(snapshot.executedQuantity());
            return merged;
        });

        coordinator.tick("account-1", 7L, credentials, true);

        ArgumentCaptor<RegularOrderRequest> requests =
                ArgumentCaptor.forClass(RegularOrderRequest.class);
        verify(gateway, times(2)).placeRegularOrder(
                eq(credentials), requests.capture()
        );
        assertEquals(bd("0.5"), requests.getAllValues().get(0).quantity());
        assertEquals(bd("0.1"), requests.getAllValues().get(1).quantity());
        BigDecimal total = requests.getAllValues().stream()
                .map(RegularOrderRequest::quantity)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        assertTrue(total.compareTo(position.getQuantity().abs()) <= 0);
        verify(gateway, never()).cancelRegularOrder(
                any(), anyString(), anyString(), any()
        );
    }

    @Test
    void conditionalMarketTakeProfitsReserveCapacityAcrossLevels() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setTakeProfitOrderType("MARKET");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        plan.setLastOrderHealthCheckMs(System.currentTimeMillis());
        ExchangeOrder entry = regularOrder(
                "entry-1", plan.getEntryClientOrderId(), "FILLED", bd("1"), bd("1")
        );
        TradingPosition position = position("position-1", 1L, bd("0.6"));
        List<TradingPositionPlanLevel> levels = List.of(
                level(plan.getId(), "level-1", 1),
                level(plan.getId(), "level-2", 2)
        );
        Map<String, ExchangeOrder> reductions = new HashMap<>();

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(levels);
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> plan.getEntryClientOrderId().equals(
                invocation.getArgument(1)
        ) ? entry : null);
        when(orderMapper.selectAlgoByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> reductions.get(invocation.getArgument(1)));
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reductions.put(inserted.getClientAlgoId(), inserted);
            return 1;
        });
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(price(bd("105")));
        when(gateway.placeAlgoOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    AlgoOrderRequest request = invocation.getArgument(1);
                    return algoTakeProfitSnapshot(request, "NEW", null);
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder merged = reductions.get(snapshot.clientAlgoId());
            merged.setStatus("NEW");
            merged.setQuantity(snapshot.quantity());
            return merged;
        });

        coordinator.tick("account-1", 7L, credentials, true);

        ArgumentCaptor<AlgoOrderRequest> requests =
                ArgumentCaptor.forClass(AlgoOrderRequest.class);
        verify(gateway, times(2)).placeAlgoOrder(
                eq(credentials), requests.capture()
        );
        assertEquals(bd("0.5"), requests.getAllValues().get(0).quantity());
        assertEquals(bd("0.1"), requests.getAllValues().get(1).quantity());
        assertEquals(0, plan.getRemainingQuantity().compareTo(bd("0.6")));
        verify(gateway, never()).cancelAlgoOrder(any(), anyString(), any());
    }

    @Test
    void crossedMarketTakeProfitRepairsWithImmediateRegularMarketOrder() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setTakeProfitOrderType("MARKET");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        plan.setLastOrderHealthCheckMs(System.currentTimeMillis());
        ExchangeOrder entry = regularOrder(
                "entry-1", plan.getEntryClientOrderId(), "FILLED", bd("1"), bd("1")
        );
        TradingPosition position = position("position-1", 1L, bd("1"));
        TradingPositionPlanLevel level = level(plan.getId());
        AtomicReference<ExchangeOrder> reduction = new AtomicReference<>();

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : reduction.get();
        });
        when(orderMapper.selectAlgoByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenReturn(null);
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            ExchangeOrder inserted = invocation.getArgument(0);
            reduction.set(inserted);
            return 1;
        });
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(price(bd("115")));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return regularSnapshot(
                            request.clientOrderId(),
                            "FILLED",
                            request.quantity(),
                            request.quantity()
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder filled = regularOrder(
                    "reduction-filled",
                    snapshot.clientOrderId(),
                    "FILLED",
                    snapshot.quantity(),
                    snapshot.executedQuantity()
            );
            reduction.set(filled);
            return filled;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        ArgumentCaptor<RegularOrderRequest> request =
                ArgumentCaptor.forClass(RegularOrderRequest.class);
        verify(gateway).placeRegularOrder(eq(credentials), request.capture());
        assertEquals("MARKET", request.getValue().type());
        assertEquals(bd("0.5"), request.getValue().quantity());
        assertEquals("COMPLETED", level.getReductionStatus());
        assertEquals("ACTIVE", level.getStatus());
        verify(gateway, never()).placeAlgoOrder(any(), any());
    }

    @Test
    void manualPositionReductionCancelsAnOversizedTakeProfit() {
        TradingPositionPlan plan = plan();
        plan.setTradingPositionId("position-1");
        plan.setPositionGeneration(1L);
        plan.setStopLossOrderType("NONE");
        plan.setInitialFilledQuantity(bd("1"));
        plan.setFilledQuantity(bd("1"));
        ExchangeOrder entry = regularOrder(
                "entry-1", plan.getEntryClientOrderId(), "FILLED", bd("1"), bd("1")
        );
        TradingPosition position = position("position-1", 1L, bd("0.5"));
        TradingPositionPlanLevel level = level(plan.getId());
        level.setStatus("ACTIVE");
        level.setReductionStatus("LIVE");
        level.setPlannedReductionQuantity(bd("0.8"));
        level.setReductionClientOrderId("tt-r-oversized");
        level.setReductionRevision(1L);
        AtomicReference<ExchangeOrder> reduction = new AtomicReference<>(
                regularOrder(
                        "reduction-large",
                        "tt-r-oversized",
                        "LIVE",
                        bd("0.8"),
                        BigDecimal.ZERO
                )
        );

        when(planMapper.selectActiveByAccount("account-1"))
                .thenReturn(List.of(plan));
        when(positionMapper.selectByKey("account-1", "BTCUSDC", "BOTH"))
                .thenReturn(position);
        when(levelMapper.selectByPlan(plan.getId())).thenReturn(List.of(level));
        when(orderMapper.selectRegularByIdentity(
                eq("account-1"), anyString(), isNull()
        )).thenAnswer(invocation -> {
            String clientId = invocation.getArgument(1);
            return plan.getEntryClientOrderId().equals(clientId)
                    ? entry
                    : reduction.get();
        });
        when(gateway.queryRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq("tt-r-oversized"),
                anyString()
        )).thenReturn(Optional.of(regularSnapshot(
                "tt-r-oversized", "NEW", bd("0.8"), BigDecimal.ZERO
        )));
        when(gateway.cancelRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq("tt-r-oversized"),
                anyString()
        )).thenReturn(regularSnapshot(
                "tt-r-oversized", "CANCELED", bd("0.8"), BigDecimal.ZERO
        ));
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(), eq(true)
        )).thenAnswer(invocation -> {
            OrderSnapshot snapshot = invocation.getArgument(1);
            ExchangeOrder merged = regularOrder(
                    "mirror-large",
                    snapshot.clientOrderId(),
                    "CANCELED".equals(snapshot.exchangeStatus())
                            ? "CANCELED"
                            : "LIVE",
                    snapshot.quantity(),
                    snapshot.executedQuantity()
            );
            reduction.set(merged);
            return merged;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        verify(gateway).cancelRegularOrder(
                eq(credentials),
                eq("BTCUSDC"),
                eq("tt-r-oversized"),
                anyString()
        );
        assertEquals("PENDING", level.getReductionStatus());
        assertEquals(BigDecimal.ZERO, level.getExecutedReductionQuantity());
    }

    private void assertMakerClose(
            String positionSide,
            BigDecimal positionQuantity,
            String expectedSide,
            BigDecimal expectedPrice
    ) {
        TradingCommand command = new TradingCommand();
        command.setId("command-close-" + positionSide.toLowerCase());
        command.setCreateTime(LocalDateTime.now());
        command.setTradingAccountId("account-1");
        command.setCommandType("CLOSE_POSITION_MAKER");
        command.setStatus("PERSISTED");
        command.setClientOrderId("tt-c-" + positionSide.toLowerCase());
        command.setRequestJson(
                "{\"positionId\":\"position-1\",\"orderType\":\"MAKER\"}"
        );
        command.setVersion(0L);
        TradingPosition position = position(
                "position-1",
                3L,
                positionQuantity
        );
        position.setSymbol("BTCUSDC");
        position.setPositionSide(positionSide);
        AtomicReference<ExchangeOrder> intent = new AtomicReference<>();

        when(commandMapper.selectDispatchable("account-1", 10))
                .thenReturn(List.of(command));
        when(positionMapper.selectOwnedById("account-1", "position-1"))
                .thenReturn(position);
        when(orderMapper.selectActiveManualClose(
                "account-1",
                "position-1",
                3L
        )).thenReturn(null);
        when(orderMapper.selectRegularByIdentity(
                "account-1",
                command.getClientOrderId(),
                null
        )).thenAnswer(invocation -> intent.get());
        when(orderMapper.insertOrder(any())).thenAnswer(invocation -> {
            intent.set(invocation.getArgument(0));
            return 1;
        });
        when(orderMapper.updateOrder(any())).thenReturn(1);
        when(commandMapper.transition(
                anyString(),
                anyString(),
                anyString(),
                anyString(),
                any(),
                any(),
                any(),
                any(),
                anyLong()
        )).thenReturn(1);
        when(gateway.symbolRules("BTCUSDC")).thenReturn(new SymbolRules(
                "BTCUSDC", "TRADING", "BTC", "USDC", bd("0.1"),
                bd("0.001"), bd("100"), bd("0.001"), bd("0.001"),
                bd("100"), bd("0.001"), bd("5")
        ));
        when(gateway.priceSnapshot("BTCUSDC")).thenReturn(new PriceSnapshot(
                "BTCUSDC", bd("100"), bd("99.9"), bd("100.1"), 1_000
        ));
        when(gateway.placeRegularOrder(eq(credentials), any()))
                .thenAnswer(invocation -> {
                    RegularOrderRequest request = invocation.getArgument(1);
                    return new OrderSnapshot(
                            "REGULAR", "BTCUSDC", request.side(),
                            positionSide, "LIMIT", "GTX", null,
                            request.clientOrderId(), "exchange-close", null,
                            null, null, request.quantity(), request.price(),
                            BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                            BigDecimal.ZERO, false, false, "NEW", 1_000, 1_000
                    );
                });
        when(mirrorService.mergeOrder(
                any(), any(), anyString(), isNull(), anyLong(), anyLong(),
                eq(true)
        )).thenAnswer(invocation -> {
            ExchangeOrder merged = intent.get();
            merged.setStatus("LIVE");
            merged.setExchangeOrderId("exchange-close");
            return merged;
        });

        coordinator.tick("account-1", 7L, credentials, false);

        ArgumentCaptor<RegularOrderRequest> request =
                ArgumentCaptor.forClass(RegularOrderRequest.class);
        verify(gateway).placeRegularOrder(eq(credentials), request.capture());
        assertEquals(expectedSide, request.getValue().side());
        assertEquals(positionSide, request.getValue().positionSide());
        assertEquals("LIMIT", request.getValue().type());
        assertEquals("GTX", request.getValue().timeInForce());
        assertEquals(0, expectedPrice.compareTo(request.getValue().price()));
        assertEquals(0, bd("1.234").compareTo(request.getValue().quantity()));
        assertEquals("MANUAL_CLOSE", intent.get().getPurpose());
        assertEquals("SUCCEEDED", command.getStatus());
    }

    private TradingAccount account() {
        TradingAccount account = new TradingAccount();
        account.setId("account-1");
        account.setStatus("ACTIVE");
        account.setSyncStatus("SYNCED");
        account.setReconcileRevision(1L);
        account.setExecutionFenceToken(7L);
        return account;
    }

    private TradingPositionPlan plan() {
        TradingPositionPlan plan = new TradingPositionPlan();
        plan.setId("12345678-1234-1234-1234-123456789abc");
        plan.setCreateTime(LocalDateTime.now());
        plan.setTradingAccountId("account-1");
        plan.setSymbol("BTCUSDC");
        plan.setDirection("LONG");
        plan.setPositionSide("BOTH");
        plan.setEntrySide("BUY");
        plan.setStatus("ENTRY_LIVE");
        plan.setEntryOrderType("LIMIT");
        plan.setTakeProfitOrderType("LIMIT");
        plan.setStopLossOrderType("MARKET");
        plan.setWorkingType("MARK_PRICE");
        plan.setReferenceEntryPrice(bd("100"));
        plan.setInitialStopPrice(bd("90"));
        plan.setRiskPerUnit(bd("10"));
        plan.setPlannedQuantity(bd("2"));
        plan.setFilledQuantity(BigDecimal.ZERO);
        plan.setProtectedQuantity(BigDecimal.ZERO);
        plan.setRemainingQuantity(BigDecimal.ZERO);
        plan.setPriceTick(bd("0.1"));
        plan.setQuantityStep(bd("0.1"));
        plan.setMarketQuantityStep(bd("0.1"));
        plan.setEntryClientOrderId("tt-e-entry-1");
        plan.setStopRevision(0L);
        plan.setProtectionRepairAttempts(0);
        plan.setVersion(0L);
        return plan;
    }

    private TradingPosition position(String id, long generation, BigDecimal quantity) {
        TradingPosition position = new TradingPosition();
        position.setId(id);
        position.setGeneration(generation);
        position.setStatus("OPEN");
        position.setQuantity(quantity);
        return position;
    }

    private TradingPositionPlanLevel level(String planId) {
        return level(planId, "level-1", 1);
    }

    private TradingPositionPlanLevel level(
            String planId,
            String id,
            int levelNo
    ) {
        TradingPositionPlanLevel level = new TradingPositionPlanLevel();
        level.setId(id);
        level.setTradingPositionPlanId(planId);
        level.setLevelNo(levelNo);
        level.setTriggerR(bd("1"));
        level.setReducePercent(bd("50"));
        level.setMoveStopMode("NONE");
        level.setStatus("PENDING");
        level.setReductionStatus("PENDING");
        level.setPlannedReductionQuantity(BigDecimal.ZERO);
        level.setExecutedReductionQuantity(BigDecimal.ZERO);
        level.setReductionOrderBaseExecutedQuantity(BigDecimal.ZERO);
        level.setReductionRevision(0L);
        level.setReductionRepairAttempts(0);
        level.setStopMoveActivated(0);
        level.setVersion(0L);
        return level;
    }

    private ExchangeOrder regularOrder(
            String id,
            String clientId,
            String status,
            BigDecimal quantity,
            BigDecimal executed
    ) {
        ExchangeOrder order = new ExchangeOrder();
        order.setId(id);
        order.setCreateTime(LocalDateTime.now());
        order.setTradingAccountId("account-1");
        order.setOrderClass("REGULAR");
        order.setSymbol("BTCUSDC");
        order.setClientOrderId(clientId);
        order.setExchangeOrderId("exchange-" + id);
        order.setQuantity(quantity);
        order.setExecutedQuantity(executed);
        order.setAveragePrice(bd("100"));
        order.setStatus(status);
        order.setVersion(0L);
        return order;
    }

    private ExchangeOrder algoOrder(String id, String clientId, String status) {
        ExchangeOrder order = new ExchangeOrder();
        order.setId(id);
        order.setCreateTime(LocalDateTime.now());
        order.setTradingAccountId("account-1");
        order.setOrderClass("ALGO");
        order.setOrigin("SYSTEM");
        order.setPurpose("STOP");
        order.setSymbol("BTCUSDC");
        order.setPositionSide("BOTH");
        order.setClientAlgoId(clientId);
        order.setExchangeAlgoId("exchange-" + id);
        order.setStatus(status);
        order.setVersion(0L);
        return order;
    }

    private ExchangeOrder algoTakeProfitOrder(
            String id,
            String clientId,
            String status,
            BigDecimal quantity,
            BigDecimal triggerPrice
    ) {
        ExchangeOrder order = algoOrder(id, clientId, status);
        order.setPurpose("TAKE_PROFIT");
        order.setOrderType("TAKE_PROFIT_MARKET");
        order.setQuantity(quantity);
        order.setTriggerPrice(triggerPrice);
        order.setExecutedQuantity(BigDecimal.ZERO);
        return order;
    }

    private OrderSnapshot regularSnapshot(
            String clientId,
            String status,
            BigDecimal quantity,
            BigDecimal executed
    ) {
        return new OrderSnapshot(
                "REGULAR", "BTCUSDC", "SELL", "BOTH", "LIMIT", "GTC",
                null, clientId, "exchange-regular", null, null, null,
                quantity, bd("100"), BigDecimal.ZERO, executed,
                BigDecimal.ZERO, bd("100"), true, false, status,
                System.currentTimeMillis(), System.currentTimeMillis()
        );
    }

    private OrderSnapshot algoSnapshot(ExchangeOrder order, String status) {
        return new OrderSnapshot(
                "ALGO", "BTCUSDC", "SELL", "BOTH", "STOP_MARKET", null,
                "MARK_PRICE", null, null, order.getClientAlgoId(),
                order.getExchangeAlgoId(), null, BigDecimal.ZERO,
                BigDecimal.ZERO, bd("90"), BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, false, true, status,
                System.currentTimeMillis(), System.currentTimeMillis()
        );
    }

    private OrderSnapshot algoTakeProfitSnapshot(
            AlgoOrderRequest request,
            String status,
            String actualOrderId
    ) {
        return new OrderSnapshot(
                "ALGO", request.symbol(), request.side(),
                request.positionSide(), request.type(), request.timeInForce(),
                request.workingType(), null, null, request.clientAlgoId(),
                "exchange-" + request.clientAlgoId(), actualOrderId,
                request.quantity(), BigDecimal.ZERO, request.triggerPrice(),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                request.reduceOnly(), request.closePosition(), status,
                System.currentTimeMillis(), System.currentTimeMillis()
        );
    }

    private PriceSnapshot price(BigDecimal markPrice) {
        return new PriceSnapshot(
                "BTCUSDC",
                markPrice,
                markPrice.subtract(bd("0.1")),
                markPrice.add(bd("0.1")),
                System.currentTimeMillis()
        );
    }

    private String stopClientId(
            String prefix,
            TradingPositionPlan plan,
            long revision
    ) {
        String compact = plan.getId().replace("-", "");
        String suffix = "-" + Long.toString(revision, 36);
        int available = 36 - prefix.length() - suffix.length();
        return prefix + compact.substring(0, available) + suffix;
    }

    private BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
