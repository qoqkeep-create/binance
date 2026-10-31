package com.oovso.trading;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.trading.BinanceUsdmPrivateGateway.AlgoOrderRequest;
import com.oovso.trading.BinanceUsdmPrivateGateway.OrderSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.PriceSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.RegularOrderRequest;
import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Runs only from the fenced, per-account serial worker. It never retries an
 * ambiguous write without first querying its deterministic client id.
 */
@Service
public class TradingExecutionCoordinator {

    private static final Logger log = LoggerFactory.getLogger(
            TradingExecutionCoordinator.class
    );
    private final TradingProperties properties;
    private final TradingAccountMapper accountMapper;
    private final TradingCommandMapper commandMapper;
    private final TradingPositionPlanMapper planMapper;
    private final TradingPositionPlanLevelMapper levelMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final BinanceUsdmPrivateGateway gateway;
    private final TradingMirrorService mirrorService;
    private final ObjectMapper objectMapper;

    public TradingExecutionCoordinator(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingCommandMapper commandMapper,
            TradingPositionPlanMapper planMapper,
            TradingPositionPlanLevelMapper levelMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            BinanceUsdmPrivateGateway gateway,
            TradingMirrorService mirrorService,
            ObjectMapper objectMapper
    ) {
        this.properties = properties;
        this.accountMapper = accountMapper;
        this.commandMapper = commandMapper;
        this.planMapper = planMapper;
        this.levelMapper = levelMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.gateway = gateway;
        this.mirrorService = mirrorService;
        this.objectMapper = objectMapper;
    }

    public void tick(
            String accountId,
            long fenceToken,
            BinanceCredentials credentials,
            boolean evaluateStrategy
    ) {
        if (!properties.isEnabled()) {
            return;
        }
        TradingAccount account = currentAccount(accountId, fenceToken);
        cleanupUnsafeManualCloseOrders(account, credentials);
        dispatchCommands(account, fenceToken, credentials);
        for (TradingPositionPlan plan : planMapper.selectActiveByAccount(
                accountId
        )) {
            try {
                long now = System.currentTimeMillis();
                boolean orderHealthDue = TradingOrderRepairPolicy.checkDue(
                        plan.getLastOrderHealthCheckMs(),
                        properties.getExecution()
                                .getOrderHealthCheckIntervalMillis(),
                        now
                );
                synchronizePlan(
                        account,
                        plan,
                        fenceToken,
                        credentials,
                        evaluateStrategy,
                        orderHealthDue,
                        now
                );
            } catch (ExecutionDeferredException ignored) {
                markPlanDegraded(
                        plan,
                        fenceToken,
                        "ORDER_OUTCOME_PENDING"
                );
            } catch (BinancePrivateApiException exception) {
                markPlanDegraded(plan, fenceToken, errorCode(exception));
            } catch (RuntimeException exception) {
                markPlanDegraded(plan, fenceToken, errorCode(exception));
                log.warn(
                        "Trading plan tick failed accountId={} planId={} code={}",
                        accountId,
                        plan.getId(),
                        errorCode(exception)
                );
            }
        }
    }

    private void dispatchCommands(
            TradingAccount account,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        int limit = Math.max(
                1,
                properties.getExecution().getCommandBatchSize()
        );
        for (TradingCommand command : commandMapper.selectDispatchable(
                account.getId(),
                limit
        )) {
            boolean manualCloseCancellation = "CANCEL_MANUAL_CLOSE".equals(
                    command.getCommandType()
            );
            if ("CANCEL_ENTRY".equals(command.getCommandType())
                    || manualCloseCancellation) {
                switch (command.getStatus()) {
                    case "PERSISTED" -> dispatchRegularCancellation(
                            account,
                            command,
                            credentials,
                            manualCloseCancellation
                    );
                    case "DISPATCHING", "CONFIRMING", "UNKNOWN",
                         "RECONCILING" -> resolveRegularCancellation(
                            account,
                            command,
                            credentials,
                            manualCloseCancellation
                    );
                    default -> {
                        // selectDispatchable restricts this set.
                    }
                }
                continue;
            }
            if (command.getCommandType() != null
                    && command.getCommandType().startsWith("CLOSE_POSITION_")) {
                switch (command.getStatus()) {
                    case "PERSISTED" -> dispatchManualClose(
                            account,
                            command,
                            fenceToken,
                            credentials
                    );
                    case "DISPATCHING", "CONFIRMING", "UNKNOWN",
                         "RECONCILING" -> resolveManualClose(
                            account,
                            command,
                            fenceToken,
                            credentials
                    );
                    default -> {
                        // selectDispatchable restricts this set.
                    }
                }
                continue;
            }
            TradingPositionPlan plan = planMapper.selectByCommand(
                    command.getId()
            );
            if (plan == null) {
                failCommand(command, "PLAN_NOT_FOUND");
                continue;
            }
            switch (command.getStatus()) {
                case "PERSISTED" -> dispatchEntry(
                        account,
                        command,
                        plan,
                        fenceToken,
                        credentials
                );
                case "DISPATCHING", "CONFIRMING", "UNKNOWN", "RECONCILING" ->
                        resolveEntry(
                                account,
                                command,
                                plan,
                                fenceToken,
                                credentials
                        );
                default -> {
                    // selectDispatchable restricts this set.
                }
            }
        }
    }

    private void dispatchRegularCancellation(
            TradingAccount account,
            TradingCommand command,
            BinanceCredentials credentials,
            boolean manualClose
    ) {
        ExchangeOrder order = orderMapper.selectRegularByIdentity(
                account.getId(),
                command.getClientOrderId(),
                null
        );
        if (!isCancelableOrder(order, manualClose)) {
            failCommand(command, cancellationCode(
                    manualClose,
                    "ORDER_NOT_CANCELABLE"
            ));
            return;
        }
        if (!transitionCommand(
                command,
                "DISPATCHING",
                null,
                null,
                false
        )) {
            return;
        }
        if (!TradingOrderStateMachine.isRegularActive(order.getStatus())) {
            finishTerminalCancellation(command, order, manualClose);
            return;
        }
        try {
            OrderSnapshot response = gateway.cancelRegularOrder(
                    credentials,
                    order.getSymbol(),
                    order.getClientOrderId(),
                    order.getExchangeOrderId()
            );
            ExchangeOrder merged = mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_CANCEL",
                    null,
                    Math.max(
                            response.updateTimeMillis(),
                            System.currentTimeMillis()
                    ),
                    value(account.getReconcileRevision()),
                    true
            );
            if (TradingOrderStateMachine.isRegularActive(merged.getStatus())) {
                if ("CANCEL_PENDING".equals(merged.getStatus())) {
                    markOrderLocalState(
                            merged,
                            "LIVE",
                            cancellationCode(
                                    manualClose,
                                    "CANCEL_NOT_CONFIRMED"
                            )
                    );
                }
                failCommand(command, cancellationCode(
                        manualClose,
                        "CANCEL_NOT_CONFIRMED"
                ));
                return;
            }
            finishTerminalCancellation(command, merged, manualClose);
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                markOrderLocalState(
                        order,
                        "CANCELED",
                        "ORDER_NOT_FOUND_ON_CANCEL"
                );
                finishSuccessfulCancellation(command, order);
                return;
            }
            if (exception.outcomeUnknown()) {
                markOrderLocalState(
                        order,
                        "CANCEL_PENDING",
                        errorCode(exception)
                );
                transitionCommand(
                        command,
                        "UNKNOWN",
                        null,
                        errorCode(exception),
                        false
                );
                return;
            }
            failCommand(command, errorCode(exception));
        }
    }

    private void resolveRegularCancellation(
            TradingAccount account,
            TradingCommand command,
            BinanceCredentials credentials,
            boolean manualClose
    ) {
        if ("DISPATCHING".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "CONFIRMING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        } else if ("UNKNOWN".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "RECONCILING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        }
        ExchangeOrder current = orderMapper.selectRegularByIdentity(
                account.getId(),
                command.getClientOrderId(),
                null
        );
        if (!isCancelableOrder(current, manualClose)) {
            failCommand(command, cancellationCode(
                    manualClose,
                    "ORDER_NOT_CANCELABLE"
            ));
            return;
        }
        try {
            var remote = gateway.queryRegularOrder(
                    credentials,
                    current.getSymbol(),
                    current.getClientOrderId(),
                    current.getExchangeOrderId()
            );
            if (remote.isEmpty()) {
                markOrderLocalState(
                        current,
                        "CANCELED",
                        "ORDER_NOT_FOUND_AFTER_CANCEL"
                );
                finishSuccessfulCancellation(command, current);
                return;
            }
            ExchangeOrder merged = mirrorService.mergeOrder(
                    account,
                    remote.get(),
                    "REST_CANCEL_CONFIRM",
                    null,
                    remote.get().updateTimeMillis(),
                    value(account.getReconcileRevision()),
                    true
            );
            if (TradingOrderStateMachine.isRegularActive(merged.getStatus())) {
                if ("CANCEL_PENDING".equals(merged.getStatus())) {
                    markOrderLocalState(
                            merged,
                            "LIVE",
                            cancellationCode(
                                    manualClose,
                                    "CANCEL_NOT_CONFIRMED"
                            )
                    );
                }
                failCommand(command, cancellationCode(
                        manualClose,
                        "CANCEL_NOT_CONFIRMED"
                ));
                return;
            }
            finishTerminalCancellation(command, merged, manualClose);
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                markOrderLocalState(
                        current,
                        "CANCELED",
                        "ORDER_NOT_FOUND_AFTER_CANCEL"
                );
                finishSuccessfulCancellation(command, current);
                return;
            }
            if (!exception.outcomeUnknown()) {
                failCommand(command, errorCode(exception));
            }
        }
    }

    private void finishTerminalCancellation(
            TradingCommand command,
            ExchangeOrder order,
            boolean manualClose
    ) {
        if ("FILLED".equals(order.getStatus())) {
            failCommand(command, cancellationCode(
                    manualClose,
                    "ORDER_ALREADY_FILLED"
            ));
            return;
        }
        finishSuccessfulCancellation(command, order);
    }

    private void finishSuccessfulCancellation(
            TradingCommand command,
            ExchangeOrder order
    ) {
        if ("DISPATCHING".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "CONFIRMING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        }
        transitionCommand(
                command,
                "SUCCEEDED",
                json(Map.of(
                        "clientOrderId",
                        text(order.getClientOrderId()),
                        "status",
                        text(order.getStatus()),
                        "executedQuantity",
                        nonNull(order.getExecutedQuantity())
                )),
                null,
                true
        );
    }

    private boolean isEntryLimitOrder(ExchangeOrder order) {
        return order != null
                && "REGULAR".equals(order.getOrderClass())
                && "SYSTEM".equals(order.getOrigin())
                && "ENTRY".equals(order.getPurpose())
                && "LIMIT".equals(order.getOrderType())
                && order.getClientOrderId() != null
                && !order.getClientOrderId().isBlank();
    }

    private boolean isManualMakerCloseOrder(ExchangeOrder order) {
        return order != null
                && "REGULAR".equals(order.getOrderClass())
                && "SYSTEM".equals(order.getOrigin())
                && "MANUAL_CLOSE".equals(order.getPurpose())
                && "LIMIT".equals(order.getOrderType())
                && order.getClientOrderId() != null
                && !order.getClientOrderId().isBlank();
    }

    private boolean isCancelableOrder(
            ExchangeOrder order,
            boolean manualClose
    ) {
        return manualClose
                ? isManualMakerCloseOrder(order)
                : isEntryLimitOrder(order);
    }

    private String cancellationCode(boolean manualClose, String suffix) {
        return (manualClose ? "MANUAL_CLOSE_" : "ENTRY_") + suffix;
    }

    private void dispatchManualClose(
            TradingAccount account,
            TradingCommand command,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        if (!"ACTIVE".equals(account.getStatus())
                || !TradingSyncStatus.SYNCED.name().equals(
                        account.getSyncStatus()
                )) {
            failCommand(command, "ACCOUNT_NOT_READY");
            return;
        }
        ManualCloseRequest request = manualCloseRequest(command);
        if (request == null) {
            failCommand(command, "MANUAL_CLOSE_REQUEST_INVALID");
            return;
        }
        TradingPosition position = positionMapper.selectOwnedById(
                account.getId(),
                request.positionId()
        );
        if (!isOpenPosition(position)) {
            failCommand(command, "POSITION_ALREADY_CLOSED");
            return;
        }
        ExchangeOrder activeClose = orderMapper.selectActiveManualClose(
                account.getId(),
                position.getId(),
                position.getGeneration()
        );
        if (activeClose != null
                && !command.getClientOrderId().equals(
                        activeClose.getClientOrderId()
                )) {
            failCommand(command, "MANUAL_CLOSE_ALREADY_ACTIVE");
            return;
        }
        ExchangeOrder latestClose = orderMapper.selectLatestManualClose(
                account.getId(),
                position.getId(),
                position.getGeneration()
        );
        if (latestClose != null
                && !command.getClientOrderId().equals(
                        latestClose.getClientOrderId()
                )
                && command.getCreateTime() != null
                && latestClose.getCreateTime() != null
                && !latestClose.getCreateTime().isBefore(
                        command.getCreateTime()
                )) {
            failCommand(command, "MANUAL_CLOSE_ALREADY_ACTIVE");
            return;
        }

        boolean maker = "MAKER".equals(request.orderType());
        SymbolRules rules = gateway.symbolRules(position.getSymbol());
        BigDecimal step = maker
                ? rules.quantityStep()
                : rules.marketQuantityStep();
        if (!"TRADING".equals(rules.status())
                || step == null
                || step.signum() <= 0
                || rules.priceTick() == null
                || rules.priceTick().signum() <= 0) {
            failCommand(command, "MANUAL_CLOSE_RULES_INVALID");
            return;
        }
        BigDecimal quantity = TradingRiskEngine.floorToStep(
                nonNull(position.getQuantity()).abs(),
                step
        );
        BigDecimal minimum = maker
                ? rules.minQuantity()
                : rules.marketMinQuantity();
        BigDecimal maximum = maker
                ? rules.maxQuantity()
                : rules.marketMaxQuantity();
        if (quantity.signum() <= 0
                || minimum == null
                || maximum == null
                || quantity.compareTo(minimum) < 0
                || quantity.compareTo(maximum) > 0) {
            failCommand(command, "MANUAL_CLOSE_QUANTITY_INVALID");
            return;
        }
        BigDecimal price = maker
                ? manualMakerPrice(position, rules)
                : BigDecimal.ZERO;
        if (maker && price.signum() <= 0) {
            failCommand(command, "MANUAL_CLOSE_PRICE_INVALID");
            return;
        }
        TradingPositionPlan managedPlan = managedPlanForPosition(
                account,
                position
        );
        if (!prepareManagedPlanForManualClose(
                account,
                managedPlan,
                position,
                fenceToken,
                credentials
        )) {
            return;
        }
        ExchangeOrder intent = ensureManualCloseIntent(
                account,
                position,
                command.getClientOrderId(),
                maker ? "LIMIT" : "MARKET",
                maker ? "GTX" : null,
                quantity,
                price
        );
        if (!transitionCommand(command, "DISPATCHING", null, null, false)) {
            restoreManagedPlanAfterManualCloseFailure(
                    managedPlan,
                    position,
                    fenceToken
            );
            return;
        }
        markOrderLocalState(intent, "SUBMITTING", null);
        try {
            OrderSnapshot response = gateway.placeRegularOrder(
                    credentials,
                    new RegularOrderRequest(
                            position.getSymbol(),
                            closeSide(position),
                            position.getPositionSide(),
                            maker ? "LIMIT" : "MARKET",
                            maker ? "GTX" : null,
                            quantity,
                            maker ? price : null,
                            "BOTH".equals(position.getPositionSide()),
                            command.getClientOrderId()
                    )
            );
            ExchangeOrder merged = mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_SUBMIT",
                    null,
                    Math.max(
                            response.updateTimeMillis(),
                            System.currentTimeMillis()
                    ),
                    value(account.getReconcileRevision()),
                    true
            );
            transitionCommand(command, "CONFIRMING", null, null, false);
            if (!finishManualCloseSubmission(command, merged)) {
                restoreManagedPlanAfterManualCloseFailure(
                        managedPlan,
                        position,
                        fenceToken
                );
            }
        } catch (BinancePrivateApiException exception) {
            if (exception.outcomeUnknown()) {
                markOrderLocalState(intent, "UNKNOWN", errorCode(exception));
                transitionCommand(
                        command,
                        "UNKNOWN",
                        null,
                        errorCode(exception),
                        false
                );
                return;
            }
            markOrderLocalState(intent, "REJECTED", errorCode(exception));
            failCommand(command, errorCode(exception));
            restoreManagedPlanAfterManualCloseFailure(
                    managedPlan,
                    position,
                    fenceToken
            );
        }
    }

    private void resolveManualClose(
            TradingAccount account,
            TradingCommand command,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        if ("DISPATCHING".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "CONFIRMING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        } else if ("UNKNOWN".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "RECONCILING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        }
        ExchangeOrder current = orderMapper.selectRegularByIdentity(
                account.getId(),
                command.getClientOrderId(),
                null
        );
        if (current == null || !"MANUAL_CLOSE".equals(current.getPurpose())) {
            failCommand(command, "MANUAL_CLOSE_ORDER_NOT_FOUND");
            return;
        }
        try {
            var remote = gateway.queryRegularOrder(
                    credentials,
                    current.getSymbol(),
                    current.getClientOrderId(),
                    current.getExchangeOrderId()
            );
            if (remote.isPresent()) {
                ExchangeOrder merged = mirrorService.mergeOrder(
                        account,
                        remote.get(),
                        "REST_CONFIRM",
                        null,
                        remote.get().updateTimeMillis(),
                        value(account.getReconcileRevision()),
                        true
                );
                if (!finishManualCloseSubmission(command, merged)) {
                    restoreManagedPlanAfterManualCloseFailure(
                            managedPlanForOrder(account, merged),
                            positionForOrder(account, merged),
                            fenceToken
                    );
                }
                return;
            }
            if (commandAgeMillis(command) >= unknownTimeoutMillis()) {
                if ("CONFIRMING".equals(command.getStatus())) {
                    transitionCommand(
                            command,
                            "UNKNOWN",
                            null,
                            "ORDER_OUTCOME_UNKNOWN",
                            false
                    );
                } else {
                    transitionCommand(
                            command,
                            "UNRESOLVED",
                            null,
                            "ORDER_OUTCOME_UNRESOLVED",
                            true
                    );
                }
            }
        } catch (BinancePrivateApiException exception) {
            if (!exception.outcomeUnknown()) {
                failCommand(command, errorCode(exception));
            }
        }
    }

    private boolean finishManualCloseSubmission(
            TradingCommand command,
            ExchangeOrder order
    ) {
        if (!TradingOrderStateMachine.isRegularActive(order.getStatus())
                && !"FILLED".equals(order.getStatus())) {
            failCommand(command, order.getRejectReason() == null
                    ? "MANUAL_CLOSE_REJECTED"
                    : order.getRejectReason());
            return false;
        }
        transitionCommand(
                command,
                "SUCCEEDED",
                json(Map.of(
                        "orderId", text(order.getId()),
                        "clientOrderId", text(order.getClientOrderId()),
                        "status", text(order.getStatus()),
                        "executedQuantity", nonNull(
                                order.getExecutedQuantity()
                        )
                )),
                null,
                true
        );
        return true;
    }

    private ManualCloseRequest manualCloseRequest(TradingCommand command) {
        try {
            JsonNode root = objectMapper.readTree(command.getRequestJson());
            String positionId = root.path("positionId").asText("");
            String orderType = root.path("orderType").asText("");
            if (positionId.isBlank()
                    || (!"MARKET".equals(orderType)
                    && !"MAKER".equals(orderType))) {
                return null;
            }
            return new ManualCloseRequest(positionId, orderType);
        } catch (JsonProcessingException exception) {
            return null;
        }
    }

    private boolean isOpenPosition(TradingPosition position) {
        return position != null
                && "OPEN".equals(position.getStatus())
                && nonNull(position.getQuantity()).signum() != 0;
    }

    private TradingPositionPlan managedPlanForPosition(
            TradingAccount account,
            TradingPosition position
    ) {
        if (position == null) {
            return null;
        }
        TradingPositionPlan plan = planMapper.selectActiveByKey(
                account.getId(),
                position.getSymbol(),
                position.getPositionSide()
        );
        if (plan == null) {
            return null;
        }
        if (plan.getTradingPositionId() != null
                && !plan.getTradingPositionId().equals(position.getId())) {
            return null;
        }
        if (plan.getPositionGeneration() != null
                && !plan.getPositionGeneration().equals(
                        position.getGeneration()
                )) {
            return null;
        }
        return plan;
    }

    private TradingPositionPlan managedPlanForOrder(
            TradingAccount account,
            ExchangeOrder order
    ) {
        if (order == null) {
            return null;
        }
        TradingPositionPlan plan = planMapper.selectActiveByKey(
                account.getId(),
                order.getSymbol(),
                order.getPositionSide()
        );
        if (plan == null) {
            return null;
        }
        if (order.getTradingPositionId() != null
                && plan.getTradingPositionId() != null
                && !order.getTradingPositionId().equals(
                        plan.getTradingPositionId()
                )) {
            return null;
        }
        if (order.getPositionGeneration() != null
                && plan.getPositionGeneration() != null
                && !order.getPositionGeneration().equals(
                        plan.getPositionGeneration()
                )) {
            return null;
        }
        return plan;
    }

    private TradingPosition positionForOrder(
            TradingAccount account,
            ExchangeOrder order
    ) {
        if (order == null || order.getTradingPositionId() == null) {
            return null;
        }
        return positionMapper.selectOwnedById(
                account.getId(),
                order.getTradingPositionId()
        );
    }

    private boolean prepareManagedPlanForManualClose(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPosition position,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        if (plan == null) {
            return true;
        }
        boolean stateChanged = !"MANUAL_CLOSING".equals(plan.getStatus())
                || !position.getId().equals(plan.getTradingPositionId())
                || !Long.valueOf(position.getGeneration()).equals(
                        plan.getPositionGeneration()
                );
        plan.setTradingPositionId(position.getId());
        plan.setPositionGeneration(position.getGeneration());
        plan.setRemainingQuantity(nonNull(position.getQuantity()).abs());
        plan.setStatus("MANUAL_CLOSING");
        if (stateChanged) {
            savePlan(plan, fenceToken, null);
        }

        boolean cleaned = cancelPlanExitOrders(
                account,
                plan,
                credentials
        );
        if (!cleaned) {
            savePlan(
                    plan,
                    fenceToken,
                    "MANUAL_CLOSE_CLEANUP_PENDING"
            );
        } else if (plan.getLastErrorCode() != null) {
            savePlan(plan, fenceToken, null);
        }
        return cleaned;
    }

    private void restoreManagedPlanAfterManualCloseFailure(
            TradingPositionPlan plan,
            TradingPosition position,
            long fenceToken
    ) {
        if (plan == null || !"MANUAL_CLOSING".equals(plan.getStatus())
                || !isOpenPosition(position)) {
            return;
        }
        plan.setRemainingQuantity(nonNull(position.getQuantity()).abs());
        plan.setStatus("ACTIVE");
        savePlan(plan, fenceToken, null);
    }

    private boolean cancelPlanExitOrders(
            TradingAccount account,
            TradingPositionPlan plan,
            BinanceCredentials credentials
    ) {
        boolean cleaned = cancelRegularIfActive(
                account,
                credentials,
                plan.getSymbol(),
                plan.getEntryClientOrderId()
        );
        if (plan.getTradingPositionId() != null
                && plan.getPositionGeneration() != null) {
            for (ExchangeOrder takeProfit : orderMapper
                    .selectActiveSystemTakeProfits(
                            account.getId(),
                            plan.getTradingPositionId(),
                            plan.getPositionGeneration()
                    )) {
                cleaned &= cancelExitIfActive(
                        account,
                        credentials,
                        takeProfit
                );
            }
        }
        for (TradingPositionPlanLevel level : levelMapper.selectByPlan(
                plan.getId()
        )) {
            cleaned &= cancelReductionIfActive(
                    account,
                    plan,
                    level,
                    credentials
            );
        }
        return cleaned;
    }

    private void cleanupUnsafeManualCloseOrders(
            TradingAccount account,
            BinanceCredentials credentials
    ) {
        List<ExchangeOrder> active = orderMapper
                .selectActiveManualCloseOrdersByAccount(account.getId());
        if (active == null) {
            return;
        }
        for (ExchangeOrder order : active) {
            TradingPosition position = positionForOrder(account, order);
            boolean sameGeneration = position != null
                    && order.getPositionGeneration() != null
                    && order.getPositionGeneration().equals(
                            position.getGeneration()
                    );
            BigDecimal outstanding = nonNull(order.getQuantity())
                    .subtract(nonNull(order.getExecutedQuantity()))
                    .max(BigDecimal.ZERO);
            boolean oversized = isOpenPosition(position)
                    && sameGeneration
                    && outstanding.compareTo(
                            nonNull(position.getQuantity()).abs()
                    ) > 0;
            if (!isOpenPosition(position) || !sameGeneration || oversized) {
                cancelRegularIfActive(
                        account,
                        credentials,
                        order.getSymbol(),
                        order.getClientOrderId()
                );
            }
        }
    }

    private String closeSide(TradingPosition position) {
        return switch (position.getPositionSide()) {
            case "LONG" -> "SELL";
            case "SHORT" -> "BUY";
            default -> nonNull(position.getQuantity()).signum() >= 0
                    ? "SELL"
                    : "BUY";
        };
    }

    private BigDecimal manualMakerPrice(
            TradingPosition position,
            SymbolRules rules
    ) {
        PriceSnapshot prices = gateway.priceSnapshot(position.getSymbol());
        BigDecimal tick = rules.priceTick();
        if ("SELL".equals(closeSide(position))) {
            return TradingRiskEngine.ceilToStep(
                    prices.askPrice(),
                    tick
            ).add(tick);
        }
        BigDecimal price = TradingRiskEngine.floorToStep(
                prices.bidPrice(),
                tick
        ).subtract(tick);
        return price;
    }

    private long commandAgeMillis(TradingCommand command) {
        if (command.getCreateTime() == null) {
            return Long.MAX_VALUE;
        }
        return System.currentTimeMillis()
                - command.getCreateTime()
                .atZone(java.time.ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli();
    }

    private record ManualCloseRequest(String positionId, String orderType) {
    }

    private void dispatchEntry(
            TradingAccount account,
            TradingCommand command,
            TradingPositionPlan plan,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        if (!"ACTIVE".equals(account.getStatus())
                || !TradingSyncStatus.SYNCED.name().equals(
                        account.getSyncStatus()
                )) {
            failCommand(command, "ACCOUNT_NOT_READY");
            updatePlanState(plan, "FAILED", fenceToken,
                    "ACCOUNT_NOT_READY");
            return;
        }
        ExchangeOrder intent = ensureRegularIntent(
                account,
                plan,
                plan.getEntryClientOrderId(),
                "ENTRY",
                entryExchangeType(plan),
                entryTimeInForce(plan),
                plan.getPlannedQuantity(),
                plan.getRequestedEntryPrice(),
                false
        );
        if (!transitionCommand(command, "DISPATCHING", null, null, false)) {
            return;
        }
        markOrderLocalState(intent, "SUBMITTING", null);
        try {
            OrderSnapshot response = gateway.placeRegularOrder(
                    credentials,
                    new RegularOrderRequest(
                            plan.getSymbol(),
                            plan.getEntrySide(),
                            plan.getPositionSide(),
                            entryExchangeType(plan),
                            entryTimeInForce(plan),
                            plan.getPlannedQuantity(),
                            plan.getRequestedEntryPrice(),
                            false,
                            plan.getEntryClientOrderId()
                    )
            );
            ExchangeOrder merged = mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_SUBMIT",
                    null,
                    Math.max(response.updateTimeMillis(), System.currentTimeMillis()),
                    value(account.getReconcileRevision()),
                    true
            );
            transitionCommand(command, "CONFIRMING", null, null, false);
            transitionCommand(
                    command,
                    "SUCCEEDED",
                    json(Map.of(
                            "exchangeOrderId",
                            text(merged.getExchangeOrderId()),
                            "status",
                            text(merged.getStatus())
                    )),
                    null,
                    true
            );
            plan.setStatus("ENTRY_LIVE");
            savePlan(plan, fenceToken, null);
        } catch (BinancePrivateApiException exception) {
            if (exception.outcomeUnknown()) {
                markOrderLocalState(intent, "UNKNOWN", errorCode(exception));
                transitionCommand(
                        command,
                        "UNKNOWN",
                        null,
                        errorCode(exception),
                        false
                );
                throw new ExecutionDeferredException();
            }
            markOrderLocalState(intent, "REJECTED", errorCode(exception));
            transitionCommand(
                    command,
                    "FAILED_KNOWN",
                    null,
                    errorCode(exception),
                    true
            );
            updatePlanState(plan, "FAILED", fenceToken, errorCode(exception));
        }
    }

    private void resolveEntry(
            TradingAccount account,
            TradingCommand command,
            TradingPositionPlan plan,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        if ("DISPATCHING".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "CONFIRMING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        }
        if ("UNKNOWN".equals(command.getStatus())) {
            if (!transitionCommand(
                    command,
                    "RECONCILING",
                    null,
                    command.getErrorCode(),
                    false
            )) {
                return;
            }
        }
        try {
            var resolved = gateway.queryRegularOrder(
                    credentials,
                    plan.getSymbol(),
                    plan.getEntryClientOrderId(),
                    null
            );
            if (resolved.isPresent()) {
                ExchangeOrder merged = mirrorService.mergeOrder(
                        account,
                        resolved.get(),
                        "REST_CONFIRM",
                        null,
                        resolved.get().updateTimeMillis(),
                        value(account.getReconcileRevision()),
                        true
                );
                transitionCommand(
                        command,
                        "SUCCEEDED",
                        json(Map.of(
                                "exchangeOrderId",
                                text(merged.getExchangeOrderId()),
                                "status",
                                text(merged.getStatus())
                        )),
                        null,
                        true
                );
                plan.setStatus("ENTRY_LIVE");
                savePlan(plan, fenceToken, null);
                return;
            }
            long timeout = Math.max(
                    1_000,
                    properties.getExecution()
                            .getUnknownResolutionTimeoutMillis()
            );
            long age = System.currentTimeMillis()
                    - command.getCreateTime()
                    .atZone(java.time.ZoneId.systemDefault())
                    .toInstant()
                    .toEpochMilli();
            if (age >= timeout) {
                if ("CONFIRMING".equals(command.getStatus())) {
                    transitionCommand(
                            command,
                            "UNKNOWN",
                            null,
                            "ORDER_OUTCOME_UNKNOWN",
                            false
                    );
                    return;
                }
                transitionCommand(
                        command,
                        "UNRESOLVED",
                        null,
                        "ORDER_OUTCOME_UNRESOLVED",
                        true
                );
                updatePlanState(
                        plan,
                        "DEGRADED",
                        fenceToken,
                        "ORDER_OUTCOME_UNRESOLVED"
                );
            }
        } catch (BinancePrivateApiException exception) {
            if (!exception.outcomeUnknown()) {
                transitionCommand(
                        command,
                        "FAILED_KNOWN",
                        null,
                        errorCode(exception),
                        true
                );
                updatePlanState(
                        plan,
                        "FAILED",
                        fenceToken,
                        errorCode(exception)
                );
            }
        }
    }

    private void synchronizePlan(
            TradingAccount account,
            TradingPositionPlan plan,
            long fenceToken,
            BinanceCredentials credentials,
            boolean evaluateStrategy,
            boolean orderHealthDue,
            long now
    ) {
        if ("MANUAL_CLOSING".equals(plan.getStatus())) {
            synchronizeManualClosingPlan(
                    account,
                    plan,
                    fenceToken,
                    credentials,
                    orderHealthDue,
                    now
            );
            return;
        }
        ExchangeOrder entry = orderMapper.selectRegularByIdentity(
                account.getId(),
                plan.getEntryClientOrderId(),
                null
        );
        if (entry == null) {
            return;
        }
        BigDecimal executed = nonNull(entry.getExecutedQuantity());
        if (executed.signum() == 0 && isTerminal(entry.getStatus())) {
            updatePlanState(
                    plan,
                    "REJECTED".equals(entry.getStatus()) ? "FAILED" : "CANCELED",
                    fenceToken,
                    entry.getRejectReason()
            );
            return;
        }
        if (executed.signum() > 0) {
            BigDecimal previousInitial = nonNull(
                    plan.getInitialFilledQuantity()
            );
            applyEntryFill(plan, entry, executed);
            TradingPosition position = positionMapper.selectByKey(
                    account.getId(),
                    plan.getSymbol(),
                    plan.getPositionSide()
            );
            if (plan.getTradingPositionId() != null
                    && !isOpenLinkedPosition(plan, position)) {
                closePlan(account, plan, fenceToken, credentials);
                return;
            }
            BigDecimal remaining = executed;
            if (position != null && "OPEN".equals(position.getStatus())
                    && nonNull(position.getQuantity()).signum() != 0) {
                remaining = position.getQuantity().abs();
                plan.setTradingPositionId(position.getId());
                plan.setPositionGeneration(position.getGeneration());
            }
            plan.setRemainingQuantity(remaining);
            if (executed.compareTo(previousInitial) > 0) {
                plan.setInitialFilledQuantity(executed);
            }
            plan.setStatus("ACTIVE");
            savePlan(plan, fenceToken, null);

            if (!"NONE".equals(plan.getStopLossOrderType())) {
                ensureProtection(
                        account,
                        plan,
                        remaining,
                        plan.getCurrentStopPrice() == null
                                ? plan.getInitialStopPrice()
                                : plan.getCurrentStopPrice(),
                        fenceToken,
                        credentials,
                        false
                );
            }
            if (!orderHealthDue || position == null) {
                ensureTakeProfitOrders(
                        account,
                        plan,
                        remaining,
                        credentials,
                        now
                );
            }
        }

        TradingPosition linked = positionMapper.selectByKey(
                account.getId(),
                plan.getSymbol(),
                plan.getPositionSide()
        );
        if (plan.getTradingPositionId() != null
                && !isOpenLinkedPosition(plan, linked)) {
            closePlan(account, plan, fenceToken, credentials);
            return;
        }
        if (orderHealthDue
                && linked != null
                && "OPEN".equals(linked.getStatus())
                && plan.getInitialFilledQuantity() != null
                && plan.getInitialFilledQuantity().signum() > 0) {
            inspectOrderHealth(
                    account,
                    plan,
                    linked,
                    fenceToken,
                    credentials,
                    now
            );
        }
        if (evaluateStrategy
                && linked != null
                && plan.getInitialFilledQuantity() != null
                && plan.getInitialFilledQuantity().signum() > 0) {
            evaluateLevels(
                    account,
                    plan,
                    linked,
                    fenceToken,
                    credentials,
                    orderHealthDue
            );
        }
    }

    private void synchronizeManualClosingPlan(
            TradingAccount account,
            TradingPositionPlan plan,
            long fenceToken,
            BinanceCredentials credentials,
            boolean orderHealthDue,
            long now
    ) {
        TradingPosition linked = positionMapper.selectByKey(
                account.getId(),
                plan.getSymbol(),
                plan.getPositionSide()
        );
        if (!isOpenLinkedPosition(plan, linked)) {
            closePlan(account, plan, fenceToken, credentials);
            return;
        }

        BigDecimal remaining = nonNull(linked.getQuantity()).abs();
        plan.setRemainingQuantity(remaining);
        boolean cleaned = cancelPlanExitOrders(
                account,
                plan,
                credentials
        );
        savePlan(
                plan,
                fenceToken,
                cleaned ? null : "MANUAL_CLOSE_CLEANUP_PENDING"
        );

        ExchangeOrder latest = orderMapper.selectLatestManualClose(
                account.getId(),
                plan.getTradingPositionId(),
                plan.getPositionGeneration()
        );
        if (cleaned && latest != null
                && isTerminal(latest.getStatus())
                && !"FILLED".equals(latest.getStatus())) {
            plan.setStatus("ACTIVE");
            savePlan(plan, fenceToken, null);
            return;
        }

        if (!"NONE".equals(plan.getStopLossOrderType())) {
            ensureProtection(
                    account,
                    plan,
                    remaining,
                    plan.getCurrentStopPrice() == null
                            ? plan.getInitialStopPrice()
                            : plan.getCurrentStopPrice(),
                    fenceToken,
                    credentials,
                    false
            );
        }
        if (orderHealthDue) {
            plan.setLastOrderHealthCheckMs(now);
            savePlan(plan, fenceToken, plan.getLastErrorCode());
            if (!cleanupReplacedPlanStops(account, plan, credentials)) {
                savePlan(
                        plan,
                        fenceToken,
                        "STALE_STOP_CLEANUP_PENDING"
                );
            }
            if (!"NONE".equals(plan.getStopLossOrderType())) {
                inspectProtectionHealth(
                        account,
                        plan,
                        remaining,
                        fenceToken,
                        credentials,
                        now
                );
            }
        }
    }

    private void applyEntryFill(
            TradingPositionPlan plan,
            ExchangeOrder entry,
            BigDecimal executed
    ) {
        BigDecimal average = nonNull(entry.getAveragePrice());
        if (average.signum() <= 0 && nonNull(entry.getCumulativeQuote()).signum() > 0) {
            average = entry.getCumulativeQuote().divide(
                    executed,
                    18,
                    RoundingMode.HALF_UP
            );
        }
        if (average.signum() <= 0) {
            average = plan.getReferenceEntryPrice();
        }
        BigDecimal riskPerUnit = average
                .subtract(plan.getInitialStopPrice())
                .abs();
        plan.setAverageEntryPrice(average);
        plan.setRiskPerUnit(riskPerUnit);
        plan.setFilledQuantity(executed);
        plan.setActualInitialRAmount(executed.multiply(riskPerUnit));
    }

    private void ensureProtection(
            TradingAccount account,
            TradingPositionPlan plan,
            BigDecimal remainingQuantity,
            BigDecimal desiredStop,
            long fenceToken,
            BinanceCredentials credentials,
            boolean forceReplacement
    ) {
        BigDecimal protectedQuantity = nonNull(plan.getProtectedQuantity());
        boolean closePositionMarket = "MARKET".equals(
                plan.getStopLossOrderType()
        );
        boolean sameQuantity = closePositionMarket
                || protectedQuantity.compareTo(remainingQuantity) == 0;
        boolean sameStop = plan.getCurrentStopPrice() != null
                && plan.getCurrentStopPrice().compareTo(desiredStop) == 0;
        boolean hasExpectedReferences = plan.getPrimaryStopClientAlgoId() != null
                && (!"LIMIT".equals(plan.getStopLossOrderType())
                || plan.getFallbackStopClientAlgoId() != null);
        if (!forceReplacement && sameQuantity && sameStop
                && hasExpectedReferences) {
            if (closePositionMarket
                    && protectedQuantity.compareTo(remainingQuantity) != 0) {
                plan.setProtectedQuantity(remainingQuantity);
                savePlan(plan, fenceToken, null);
            }
            return;
        }

        long revision = value(plan.getStopRevision()) + 1;
        String primaryId = algoClientId("tt-s-", plan.getId(), revision);
        String fallbackId = "LIMIT".equals(plan.getStopLossOrderType())
                ? algoClientId("tt-f-", plan.getId(), revision)
                : null;
        String oldPrimary = plan.getPrimaryStopClientAlgoId();
        String oldFallback = plan.getFallbackStopClientAlgoId();
        String exitSide = exitSide(plan);
        boolean oneWayReduceOnly = "BOTH".equals(plan.getPositionSide());
        BigDecimal fallbackPrice = "LIMIT".equals(plan.getStopLossOrderType())
                ? TradingRiskEngine.fallbackStop(
                        plan.getDirection(),
                        desiredStop,
                        plan.getRiskPerUnit(),
                        plan.getFallbackMarketStopR(),
                        plan.getPriceTick()
                )
                : null;

        AlgoOrderRequest primaryRequest = new AlgoOrderRequest(
                plan.getSymbol(),
                exitSide,
                plan.getPositionSide(),
                closePositionMarket ? "STOP_MARKET" : "STOP",
                closePositionMarket ? null : "GTC",
                plan.getWorkingType(),
                closePositionMarket ? null : remainingQuantity,
                closePositionMarket ? null : fallbackPrice,
                desiredStop,
                !closePositionMarket && oneWayReduceOnly,
                closePositionMarket,
                primaryId
        );
        try {
            submitAlgo(account, plan, primaryRequest, "STOP", credentials);
        } catch (ExecutionDeferredException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            plan.setStopRevision(revision);
            scheduleProtectionRepair(plan, System.currentTimeMillis());
            savePlan(plan, fenceToken, errorCode(exception));
            throw exception;
        }

        boolean fallbackAccepted = true;
        if (fallbackId != null) {
            try {
                submitAlgo(
                        account,
                        plan,
                        new AlgoOrderRequest(
                                plan.getSymbol(),
                                exitSide,
                                plan.getPositionSide(),
                                "STOP_MARKET",
                                null,
                                plan.getWorkingType(),
                                null,
                                null,
                                fallbackPrice,
                                false,
                                true,
                                fallbackId
                        ),
                        "STOP",
                        credentials
                );
            } catch (ExecutionDeferredException exception) {
                throw exception;
            } catch (RuntimeException exception) {
                fallbackAccepted = false;
                scheduleProtectionRepair(plan, System.currentTimeMillis());
                log.warn(
                        "Fallback stop submission failed accountId={} planId={} code={}",
                        account.getId(),
                        plan.getId(),
                        errorCode(exception)
                );
            }
        }

        plan.setPrimaryStopClientAlgoId(primaryId);
        plan.setFallbackStopClientAlgoId(
                fallbackAccepted ? fallbackId : oldFallback
        );
        plan.setCurrentStopPrice(desiredStop);
        plan.setProtectedQuantity(remainingQuantity);
        plan.setStopRevision(revision);
        if (fallbackAccepted) {
            plan.setNextProtectionRepairAtMs(null);
            plan.setProtectionRepairAttempts(0);
        }
        savePlan(
                plan,
                fenceToken,
                fallbackAccepted ? null : "FALLBACK_STOP_SUBMIT_FAILED"
        );
        cancelAlgoIfReplaced(account, credentials, oldPrimary, primaryId);
        if (fallbackAccepted) {
            cancelAlgoIfReplaced(account, credentials, oldFallback, fallbackId);
        }
    }

    private void inspectOrderHealth(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPosition position,
            long fenceToken,
            BinanceCredentials credentials,
            long now
    ) {
        plan.setLastOrderHealthCheckMs(now);
        savePlan(plan, fenceToken, plan.getLastErrorCode());
        if (!cleanupReplacedPlanStops(account, plan, credentials)) {
            savePlan(
                    plan,
                    fenceToken,
                    "STALE_STOP_CLEANUP_PENDING"
            );
        }

        BigDecimal remaining = nonNull(position.getQuantity()).abs();
        if (!"NONE".equals(plan.getStopLossOrderType())
                && remaining.signum() > 0) {
            inspectProtectionHealth(
                    account,
                    plan,
                    remaining,
                    fenceToken,
                    credentials,
                    now
            );
        }

        List<TradingPositionPlanLevel> levels = levelMapper.selectByPlan(
                plan.getId()
        );
        for (TradingPositionPlanLevel level : levels) {
            refreshPlannedReduction(plan, level);
        }
        reconcileReductionOrders(
                account,
                plan,
                levels,
                credentials,
                now
        );
        if (enforceReductionCapacity(
                account,
                plan,
                levels,
                remaining,
                credentials
        )) {
            return;
        }
        boolean hasPendingRepair = levels.stream().anyMatch(level ->
                nonNull(level.getReducePercent()).signum() > 0
                        && "PENDING".equals(level.getReductionStatus())
                        && retryDue(level.getReductionNextRetryAtMs(), now)
        );
        if (!hasPendingRepair) {
            return;
        }
        PriceSnapshot prices = gateway.priceSnapshot(plan.getSymbol());
        BigDecimal available = remaining;
        for (TradingPositionPlanLevel level : levels) {
            if (nonNull(level.getReducePercent()).signum() > 0
                    && "PENDING".equals(level.getReductionStatus())
                    && retryDue(level.getReductionNextRetryAtMs(), now)) {
                BigDecimal newlyExecuted = submitReduction(
                        account,
                        plan,
                        level,
                        available,
                        prices,
                        credentials
                );
                available = available.subtract(newlyExecuted)
                        .max(BigDecimal.ZERO);
            }
        }
    }

    private void ensureTakeProfitOrders(
            TradingAccount account,
            TradingPositionPlan plan,
            BigDecimal remaining,
            BinanceCredentials credentials,
            long now
    ) {
        List<TradingPositionPlanLevel> levels = levelMapper.selectByPlan(
                plan.getId()
        );
        for (TradingPositionPlanLevel level : levels) {
            refreshPlannedReduction(plan, level);
        }
        if (enforceReductionCapacity(
                account,
                plan,
                levels,
                remaining,
                credentials
        )) {
            return;
        }

        for (TradingPositionPlanLevel level : levels) {
            if ("LIVE".equals(level.getReductionStatus())) {
                resetUnderCoveredReduction(
                        account,
                        plan,
                        level,
                        remaining,
                        credentials
                );
            }
        }

        boolean hasPending = levels.stream().anyMatch(level ->
                nonNull(level.getReducePercent()).signum() > 0
                        && "PENDING".equals(level.getReductionStatus())
                        && retryDue(level.getReductionNextRetryAtMs(), now)
        );
        if (!hasPending) {
            return;
        }
        PriceSnapshot prices = gateway.priceSnapshot(plan.getSymbol());
        BigDecimal available = remaining;
        for (TradingPositionPlanLevel level : levels) {
            if (nonNull(level.getReducePercent()).signum() <= 0
                    || !"PENDING".equals(level.getReductionStatus())
                    || !retryDue(level.getReductionNextRetryAtMs(), now)) {
                continue;
            }
            BigDecimal newlyExecuted = submitReduction(
                    account,
                    plan,
                    level,
                    available,
                    prices,
                    credentials
            );
            available = available.subtract(newlyExecuted)
                    .max(BigDecimal.ZERO);
        }
    }

    private void inspectProtectionHealth(
            TradingAccount account,
            TradingPositionPlan plan,
            BigDecimal remaining,
            long fenceToken,
            BinanceCredentials credentials,
            long now
    ) {
        var primary = resolveAlgoHealth(
                account,
                plan.getPrimaryStopClientAlgoId(),
                credentials,
                now
        );
        var fallback = "LIMIT".equals(plan.getStopLossOrderType())
                ? resolveAlgoHealth(
                        account,
                        plan.getFallbackStopClientAlgoId(),
                        credentials,
                        now
                )
                : TradingOrderRepairPolicy.Health.HEALTHY;
        boolean healthy = primary == TradingOrderRepairPolicy.Health.HEALTHY
                && fallback == TradingOrderRepairPolicy.Health.HEALTHY
                && hasCurrentProtectionReferences(plan);
        if (healthy) {
            if (plan.getNextProtectionRepairAtMs() != null
                    || value(plan.getProtectionRepairAttempts()) != 0) {
                plan.setNextProtectionRepairAtMs(null);
                plan.setProtectionRepairAttempts(0);
                savePlan(plan, fenceToken, null);
            }
            return;
        }
        if (primary == TradingOrderRepairPolicy.Health.RECONCILE
                || fallback == TradingOrderRepairPolicy.Health.RECONCILE) {
            return;
        }
        if (plan.getNextProtectionRepairAtMs() == null) {
            scheduleProtectionRepair(plan, now);
            savePlan(plan, fenceToken, "PROTECTION_REPAIR_SCHEDULED");
            return;
        }
        if (!retryDue(plan.getNextProtectionRepairAtMs(), now)) {
            return;
        }
        ensureProtection(
                account,
                plan,
                remaining,
                plan.getCurrentStopPrice() == null
                        ? plan.getInitialStopPrice()
                        : plan.getCurrentStopPrice(),
                fenceToken,
                credentials,
                true
        );
    }

    private boolean hasCurrentProtectionReferences(
            TradingPositionPlan plan
    ) {
        long revision = value(plan.getStopRevision());
        if (revision <= 0) {
            return false;
        }
        String expectedPrimary = algoClientId(
                "tt-s-",
                plan.getId(),
                revision
        );
        if (!expectedPrimary.equals(plan.getPrimaryStopClientAlgoId())) {
            return false;
        }
        if (!"LIMIT".equals(plan.getStopLossOrderType())) {
            return true;
        }
        return algoClientId("tt-f-", plan.getId(), revision).equals(
                plan.getFallbackStopClientAlgoId()
        );
    }

    private TradingOrderRepairPolicy.Health resolveAlgoHealth(
            TradingAccount account,
            String clientAlgoId,
            BinanceCredentials credentials,
            long now
    ) {
        if (clientAlgoId == null) {
            return TradingOrderRepairPolicy.Health.REPAIR;
        }
        ExchangeOrder current = orderMapper.selectAlgoByIdentity(
                account.getId(),
                clientAlgoId,
                null
        );
        try {
            var remote = gateway.queryAlgoOrder(
                    credentials,
                    clientAlgoId,
                    current == null ? null : current.getExchangeAlgoId()
            );
            if (remote.isPresent()) {
                current = mirrorService.mergeOrder(
                        account,
                        remote.get(),
                        "REST_HEALTH_CHECK",
                        null,
                        remote.get().updateTimeMillis(),
                        value(account.getReconcileRevision()),
                        true
                );
                return resolvedAlgoHealth(
                        account,
                        current,
                        credentials,
                        now
                );
            }
            if (current != null
                    && orderAgeMillis(current, now) < unknownTimeoutMillis()) {
                return TradingOrderRepairPolicy.Health.RECONCILE;
            }
            if (current != null) {
                markOrderLocalState(
                        current,
                        "UNRESOLVED",
                        "ALGO_ORDER_MISSING_AFTER_RECONCILE"
                );
            }
            return TradingOrderRepairPolicy.Health.REPAIR;
        } catch (BinancePrivateApiException exception) {
            if (exception.outcomeUnknown()) {
                return TradingOrderRepairPolicy.Health.RECONCILE;
            }
            throw exception;
        }
    }

    private TradingOrderRepairPolicy.Health resolvedAlgoHealth(
            TradingAccount account,
            ExchangeOrder order,
            BinanceCredentials credentials,
            long now
    ) {
        TradingOrderRepairPolicy.Health health =
                TradingOrderRepairPolicy.algoHealth(order.getStatus());
        if (health != TradingOrderRepairPolicy.Health.COMPLETED) {
            return health;
        }
        if (order.getActualOrderId() != null
                && !order.getActualOrderId().isBlank()
                && order.getSymbol() != null) {
            var actual = gateway.queryRegularOrder(
                    credentials,
                    order.getSymbol(),
                    null,
                    order.getActualOrderId()
            );
            if (actual.isPresent()) {
                ExchangeOrder child = mirrorService.mergeOrder(
                        account,
                        actual.get(),
                        "REST_HEALTH_CHECK",
                        null,
                        actual.get().updateTimeMillis(),
                        value(account.getReconcileRevision()),
                        true
                );
                TradingOrderRepairPolicy.Health childHealth =
                        TradingOrderRepairPolicy.regularHealth(
                                child.getStatus()
                        );
                if (childHealth == TradingOrderRepairPolicy.Health.HEALTHY) {
                    return childHealth;
                }
                if (childHealth == TradingOrderRepairPolicy.Health.REPAIR) {
                    return childHealth;
                }
            }
        }
        return orderAgeMillis(order, now) >= repairBackoffMillis()
                ? TradingOrderRepairPolicy.Health.REPAIR
                : TradingOrderRepairPolicy.Health.RECONCILE;
    }

    private void scheduleProtectionRepair(
            TradingPositionPlan plan,
            long now
    ) {
        int attempts = value(plan.getProtectionRepairAttempts()) + 1;
        plan.setProtectionRepairAttempts(attempts);
        plan.setNextProtectionRepairAtMs(
                TradingOrderRepairPolicy.nextRetryMillis(
                        now,
                        repairBackoffMillis(),
                        attempts
                )
        );
    }

    private ExchangeOrder submitAlgo(
            TradingAccount account,
            TradingPositionPlan plan,
            AlgoOrderRequest request,
            String purpose,
            BinanceCredentials credentials
    ) {
        ExchangeOrder current = orderMapper.selectAlgoByIdentity(
                account.getId(),
                request.clientAlgoId(),
                null
        );
        if (current != null) {
            if ("UNKNOWN".equals(current.getStatus())
                    || "SUBMITTING".equals(current.getStatus())
                    || "UNRESOLVED".equals(current.getStatus())) {
                var resolved = gateway.queryAlgoOrder(
                        credentials,
                        request.clientAlgoId(),
                        current.getExchangeAlgoId()
                );
                if (resolved.isPresent()) {
                    return mirrorService.mergeOrder(
                            account,
                            resolved.get(),
                            "REST_CONFIRM",
                            null,
                            resolved.get().updateTimeMillis(),
                            value(account.getReconcileRevision()),
                            true
                    );
                }
                long age = System.currentTimeMillis()
                        - current.getCreateTime()
                        .atZone(java.time.ZoneId.systemDefault())
                        .toInstant()
                        .toEpochMilli();
                if (age >= Math.max(
                        1_000,
                        properties.getExecution()
                                .getUnknownResolutionTimeoutMillis()
                )) {
                    markOrderLocalState(
                            current,
                            "UNRESOLVED",
                            "ALGO_ORDER_OUTCOME_UNRESOLVED"
                    );
                    throw new IllegalStateException(
                            "ALGO_ORDER_OUTCOME_UNRESOLVED"
                    );
                }
                throw new ExecutionDeferredException();
            }
            if (!"INTENT".equals(current.getStatus())
                    && TradingOrderStateMachine.isAlgoActive(
                            current.getStatus()
                    )) {
                return current;
            }
            if (!"INTENT".equals(current.getStatus())) {
                throw new IllegalStateException(
                        "ALGO_CLIENT_ID_ALREADY_TERMINAL"
                );
            }
        }
        ExchangeOrder intent = ensureAlgoIntent(
                account,
                plan,
                request,
                purpose
        );
        markOrderLocalState(intent, "SUBMITTING", null);
        try {
            OrderSnapshot response = gateway.placeAlgoOrder(
                    credentials,
                    request
            );
            return mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_SUBMIT",
                    null,
                    Math.max(response.updateTimeMillis(), System.currentTimeMillis()),
                    value(account.getReconcileRevision()),
                    true
            );
        } catch (BinancePrivateApiException exception) {
            if (exception.outcomeUnknown()) {
                markOrderLocalState(intent, "UNKNOWN", errorCode(exception));
                throw new ExecutionDeferredException();
            }
            markOrderLocalState(intent, "REJECTED", errorCode(exception));
            throw exception;
        }
    }

    private void evaluateLevels(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPosition position,
            long fenceToken,
            BinanceCredentials credentials,
            boolean orderHealthAlreadyChecked
    ) {
        long now = System.currentTimeMillis();
        long interval = Math.max(
                1_000,
                properties.getExecution().getStrategyIntervalMillis()
        );
        if (plan.getLastStrategyEvaluatedMs() != null
                && now - plan.getLastStrategyEvaluatedMs() < interval) {
            return;
        }
        PriceSnapshot prices = gateway.priceSnapshot(plan.getSymbol());
        BigDecimal currentPrice = prices.markPrice();
        BigDecimal remaining = nonNull(position.getQuantity()).abs();
        plan.setRemainingQuantity(remaining);
        plan.setLastStrategyEvaluatedMs(now);
        savePlan(plan, fenceToken, null);
        if (remaining.signum() <= 0) {
            closePlan(account, plan, fenceToken, credentials);
            return;
        }

        List<TradingPositionPlanLevel> levels = levelMapper.selectByPlan(
                plan.getId()
        );
        if (!orderHealthAlreadyChecked) {
            reconcileReductionOrders(account, plan, levels, credentials, now);
        }
        boolean capacityAdjusted = enforceReductionCapacity(
                account,
                plan,
                levels,
                remaining,
                credentials
        );
        if (capacityAdjusted) {
            levels = levelMapper.selectByPlan(plan.getId());
        }
        BigDecimal profitR = TradingRiskEngine.profitR(
                plan.getDirection(),
                plan.getAverageEntryPrice(),
                currentPrice,
                plan.getRiskPerUnit()
        );
        BigDecimal candidateStop = plan.getCurrentStopPrice();
        BigDecimal available = remaining;
        for (TradingPositionPlanLevel level : levels) {
            refreshPlannedReduction(plan, level);
            if ("PENDING".equals(level.getStatus())
                    && profitR.compareTo(level.getTriggerR()) >= 0) {
                activateLevel(level, currentPrice, now);
            }
            if (!capacityAdjusted
                    && "LIVE".equals(level.getReductionStatus())) {
                BigDecimal newlyExecuted = resetUnderCoveredReduction(
                        account,
                        plan,
                        level,
                        remaining,
                        credentials
                );
                available = available.subtract(newlyExecuted)
                        .max(BigDecimal.ZERO);
            }
            if (!"ACTIVE".equals(level.getStatus())) {
                continue;
            }
            if (!capacityAdjusted
                    && "PENDING".equals(level.getReductionStatus())) {
                BigDecimal newlyExecuted = submitReduction(
                        account,
                        plan,
                        level,
                        available,
                        prices,
                        credentials
                );
                available = available.subtract(newlyExecuted)
                        .max(BigDecimal.ZERO);
            }
            if (level.getStopMoveActivated() != null
                    && level.getStopMoveActivated() == 1) {
                BigDecimal levelCandidate = switch (level.getMoveStopMode()) {
                    case "FIXED_R" -> TradingRiskEngine.fixedStop(
                            plan.getDirection(),
                            plan.getAverageEntryPrice(),
                            plan.getRiskPerUnit(),
                            level.getMoveStopR()
                    );
                    case "TRAILING_PROFIT_R" -> TradingRiskEngine.trailingStop(
                            plan.getDirection(),
                            currentPrice,
                            plan.getRiskPerUnit(),
                            level.getMoveStopR()
                    );
                    default -> null;
                };
                if (levelCandidate != null) {
                    BigDecimal ratcheted = TradingRiskEngine.ratchetStop(
                            plan.getDirection(),
                            candidateStop,
                            levelCandidate,
                            currentPrice,
                            plan.getPriceTick()
                    );
                    candidateStop = tighter(
                            plan.getDirection(),
                            candidateStop,
                            ratcheted
                    );
                }
            }
        }

        boolean stopMoved = candidateStop != null
                && (plan.getCurrentStopPrice() == null
                || candidateStop.compareTo(plan.getCurrentStopPrice()) != 0);
        if (available.compareTo(remaining) < 0) {
            plan.setRemainingQuantity(available);
            savePlan(plan, fenceToken, null);
        }
        if (stopMoved
                && !capacityAdjusted
                && available.signum() > 0
                && !"NONE".equals(plan.getStopLossOrderType())) {
            ensureProtection(
                    account,
                    plan,
                    available,
                    candidateStop,
                    fenceToken,
                    credentials,
                    false
            );
        }
        finishCompletedLevels(levels);
    }

    private void activateLevel(
            TradingPositionPlanLevel level,
            BigDecimal currentPrice,
            long now
    ) {
        level.setStatus("ACTIVE");
        level.setTriggeredPrice(currentPrice);
        level.setTriggeredAtMs(now);
        level.setStopMoveActivated(
                "NONE".equals(level.getMoveStopMode()) ? 0 : 1
        );
        saveLevel(level, null);
    }

    private void refreshPlannedReduction(
            TradingPositionPlan plan,
            TradingPositionPlanLevel level
    ) {
        if (nonNull(level.getReducePercent()).signum() <= 0) {
            return;
        }
        BigDecimal desired = TradingRiskEngine.plannedReductionQuantity(
                plan.getInitialFilledQuantity(),
                level.getReducePercent(),
                plan.getQuantityStep()
        );
        boolean changed = false;
        if (desired.compareTo(nonNull(
                level.getPlannedReductionQuantity()
        )) > 0) {
            level.setPlannedReductionQuantity(desired);
            changed = true;
        }
        boolean incomplete = nonNull(level.getExecutedReductionQuantity())
                .compareTo(nonNull(level.getPlannedReductionQuantity())) < 0;
        if (incomplete
                && ("NONE".equals(level.getReductionStatus())
                || "COMPLETED".equals(level.getReductionStatus()))) {
            level.setReductionStatus("PENDING");
            level.setReductionNextRetryAtMs(null);
            changed = true;
        }
        if (changed) {
            saveLevel(level, null);
        }
    }

    private BigDecimal resetUnderCoveredReduction(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level,
            BigDecimal remaining,
            BinanceCredentials credentials
    ) {
        if (level.getReductionClientOrderId() == null) {
            return BigDecimal.ZERO;
        }
        ExchangeOrder order = selectReductionOrder(account, plan, level);
        if (order == null || !isReductionActive(order)) {
            return BigDecimal.ZERO;
        }
        BigDecimal attemptExecuted = nonNull(order.getExecutedQuantity());
        BigDecimal cumulative = TradingOrderRepairPolicy.cumulativeExecuted(
                level.getReductionOrderBaseExecutedQuantity(),
                attemptExecuted
        );
        BigDecimal desiredOutstanding = nonNull(
                level.getPlannedReductionQuantity()
        ).subtract(cumulative).max(BigDecimal.ZERO);
        BigDecimal availableCapacity = nonNull(remaining)
                .subtract(reservedReductionQuantity(
                        account,
                        plan,
                        level.getId()
                ))
                .max(BigDecimal.ZERO);
        BigDecimal requiredOutstanding = desiredOutstanding.min(
                availableCapacity
        );
        BigDecimal liveOutstanding = nonNull(order.getQuantity())
                .subtract(attemptExecuted)
                .max(BigDecimal.ZERO);
        if (liveOutstanding.compareTo(requiredOutstanding) >= 0) {
            return BigDecimal.ZERO;
        }
        if (!cancelReductionIfActive(account, plan, level, credentials)) {
            return BigDecimal.ZERO;
        }
        ExchangeOrder canceled = selectReductionOrder(account, plan, level);
        BigDecimal finalAttemptExecuted = canceled == null
                ? attemptExecuted
                : nonNull(canceled.getExecutedQuantity());
        BigDecimal finalCumulative = TradingOrderRepairPolicy
                .cumulativeExecuted(
                        level.getReductionOrderBaseExecutedQuantity(),
                        finalAttemptExecuted
                );
        level.setExecutedReductionQuantity(finalCumulative);
        level.setReductionStatus(finalCumulative.compareTo(nonNull(
                level.getPlannedReductionQuantity()
        )) >= 0 ? "COMPLETED" : "PENDING");
        level.setReductionNextRetryAtMs(null);
        level.setReductionRepairAttempts(0);
        saveLevel(level, null);
        return finalAttemptExecuted.subtract(attemptExecuted)
                .max(BigDecimal.ZERO);
    }

    private boolean isAlgoTakeProfit(TradingPositionPlan plan) {
        return "MARKET".equals(plan.getTakeProfitOrderType());
    }

    private ExchangeOrder selectReductionOrder(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level
    ) {
        ExchangeOrder regular = orderMapper.selectRegularByIdentity(
                account.getId(),
                level.getReductionClientOrderId(),
                null
        );
        if (regular != null) {
            return regular;
        }
        ExchangeOrder algo = orderMapper.selectAlgoByIdentity(
                account.getId(),
                level.getReductionClientOrderId(),
                null
        );
        if (algo == null
                || TradingOrderStateMachine.isAlgoActive(algo.getStatus())
                || algo.getActualOrderId() == null
                || algo.getActualOrderId().isBlank()) {
            return algo;
        }
        ExchangeOrder child = orderMapper.selectRegularByExchangeId(
                account.getId(),
                algo.getActualOrderId()
        );
        return child == null ? algo : child;
    }

    private boolean isReductionActive(ExchangeOrder order) {
        return "ALGO".equals(order.getOrderClass())
                ? TradingOrderStateMachine.isAlgoActive(order.getStatus())
                : TradingOrderStateMachine.isRegularActive(order.getStatus());
    }

    private boolean cancelReductionIfActive(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level,
            BinanceCredentials credentials
    ) {
        if (level.getReductionClientOrderId() == null) {
            return true;
        }
        ExchangeOrder order = selectReductionOrder(account, plan, level);
        if (order == null) {
            if (isAlgoTakeProfit(plan)) {
                return cancelAlgoIfActive(
                        account,
                        credentials,
                        level.getReductionClientOrderId()
                );
            }
            return cancelRegularIfActive(
                    account,
                    credentials,
                    plan.getSymbol(),
                    level.getReductionClientOrderId()
            );
        }
        return cancelExitIfActive(account, credentials, order);
    }

    private boolean cancelExitIfActive(
            TradingAccount account,
            BinanceCredentials credentials,
            ExchangeOrder order
    ) {
        if ("ALGO".equals(order.getOrderClass())) {
            return cancelAlgoIfActive(
                    account,
                    credentials,
                    order.getClientAlgoId()
            );
        }
        return cancelRegularIfActive(
                account,
                credentials,
                order.getSymbol(),
                order.getClientOrderId()
        );
    }

    private boolean enforceReductionCapacity(
            TradingAccount account,
            TradingPositionPlan plan,
            List<TradingPositionPlanLevel> levels,
            BigDecimal remaining,
            BinanceCredentials credentials
    ) {
        BigDecimal available = nonNull(remaining);
        boolean adjusted = false;
        for (TradingPositionPlanLevel level : levels) {
            String clientOrderId = level.getReductionClientOrderId();
            if (clientOrderId == null) {
                continue;
            }
            ExchangeOrder order = selectReductionOrder(account, plan, level);
            if (order == null || !isReductionActive(order)) {
                continue;
            }
            BigDecimal outstanding = nonNull(order.getQuantity())
                    .subtract(nonNull(order.getExecutedQuantity()))
                    .max(BigDecimal.ZERO);
            if (outstanding.compareTo(available) <= 0) {
                available = available.subtract(outstanding);
                continue;
            }
            boolean canceled = cancelReductionIfActive(
                    account,
                    plan,
                    level,
                    credentials
            );
            if (!canceled) {
                available = BigDecimal.ZERO;
                continue;
            }
            ExchangeOrder canceledOrder = selectReductionOrder(
                    account,
                    plan,
                    level
            );
            BigDecimal attemptExecuted = canceledOrder == null
                    ? nonNull(order.getExecutedQuantity())
                    : nonNull(canceledOrder.getExecutedQuantity());
            BigDecimal newlyExecuted = attemptExecuted.subtract(nonNull(
                    order.getExecutedQuantity()
            )).max(BigDecimal.ZERO);
            available = available.subtract(newlyExecuted)
                    .max(BigDecimal.ZERO);
            BigDecimal cumulative = TradingOrderRepairPolicy
                    .cumulativeExecuted(
                            level.getReductionOrderBaseExecutedQuantity(),
                            attemptExecuted
                    );
            level.setExecutedReductionQuantity(cumulative);
            level.setReductionStatus(cumulative.compareTo(nonNull(
                    level.getPlannedReductionQuantity()
            )) >= 0 ? "COMPLETED" : "PENDING");
            level.setReductionNextRetryAtMs(null);
            saveLevel(level, null);
            adjusted = true;
        }
        return adjusted;
    }

    private BigDecimal reservedReductionQuantity(
            TradingAccount account,
            TradingPositionPlan plan,
            String excludedLevelId
    ) {
        BigDecimal reserved = BigDecimal.ZERO;
        for (TradingPositionPlanLevel level : levelMapper.selectByPlan(
                plan.getId()
        )) {
            if (level.getId().equals(excludedLevelId)
                    || level.getReductionClientOrderId() == null) {
                continue;
            }
            ExchangeOrder order = selectReductionOrder(account, plan, level);
            if (order != null && isReductionActive(order)) {
                reserved = reserved.add(nonNull(order.getQuantity())
                        .subtract(nonNull(order.getExecutedQuantity()))
                        .max(BigDecimal.ZERO));
            }
        }
        return reserved;
    }

    private BigDecimal submitReduction(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level,
            BigDecimal remaining,
            PriceSnapshot prices,
            BinanceCredentials credentials
    ) {
        BigDecimal desired = TradingRiskEngine.plannedReductionQuantity(
                plan.getInitialFilledQuantity(),
                level.getReducePercent(),
                plan.getQuantityStep()
        );
        BigDecimal planned = nonNull(level.getPlannedReductionQuantity());
        if (desired.compareTo(planned) > 0) {
            planned = desired;
            level.setPlannedReductionQuantity(planned);
        }
        BigDecimal alreadyExecuted = nonNull(
                level.getExecutedReductionQuantity()
        );
        BigDecimal outstanding = planned.subtract(alreadyExecuted);
        if (outstanding.signum() <= 0) {
            level.setReductionStatus("COMPLETED");
            level.setReductionNextRetryAtMs(null);
            saveLevel(level, null);
            return BigDecimal.ZERO;
        }
        BigDecimal available = remaining.subtract(reservedReductionQuantity(
                account,
                plan,
                level.getId()
        ));
        BigDecimal quantity = TradingOrderRepairPolicy.remainingReduction(
                planned,
                alreadyExecuted,
                available.max(BigDecimal.ZERO),
                plan.getQuantityStep()
        );
        if (quantity.signum() <= 0) {
            level.setReductionStatus("PENDING");
            saveLevel(level, null);
            return BigDecimal.ZERO;
        }
        long revision = value(level.getReductionRevision()) + 1;
        String clientOrderId = reductionClientId(
                plan.getId(),
                level.getLevelNo(),
                revision
        );
        BigDecimal target = targetPrice(plan, level);
        boolean configuredMarket = isAlgoTakeProfit(plan);
        boolean immediateMarket = configuredMarket
                && targetReached(plan, prices.markPrice(), target);
        boolean conditionalMarket = configuredMarket && !immediateMarket;
        String type = conditionalMarket
                ? "TAKE_PROFIT_MARKET"
                : immediateMarket ? "MARKET" : "LIMIT";
        String timeInForce = switch (plan.getTakeProfitOrderType()) {
            case "MAKER_ONLY" -> "GTX";
            case "LIMIT" -> "GTC";
            default -> null;
        };
        BigDecimal price = switch (plan.getTakeProfitOrderType()) {
            case "MAKER_ONLY" -> makerExitPrice(plan, target, prices);
            case "LIMIT" -> normalizedExitPrice(plan, target);
            default -> null;
        };
        level.setReductionClientOrderId(clientOrderId);
        level.setReductionRevision(revision);
        level.setReductionOrderBaseExecutedQuantity(alreadyExecuted);
        level.setReductionNextRetryAtMs(null);
        level.setReductionStatus("LIVE");
        saveLevel(level, null);
        try {
            ExchangeOrder merged;
            if (conditionalMarket) {
                merged = submitAlgo(
                        account,
                        plan,
                        new AlgoOrderRequest(
                                plan.getSymbol(),
                                exitSide(plan),
                                plan.getPositionSide(),
                                type,
                                null,
                                plan.getWorkingType(),
                                quantity,
                                null,
                                normalizedExitPrice(plan, target),
                                "BOTH".equals(plan.getPositionSide()),
                                false,
                                clientOrderId
                        ),
                        "TAKE_PROFIT",
                        credentials
                );
            } else {
                ExchangeOrder intent = ensureRegularIntent(
                        account,
                        plan,
                        clientOrderId,
                        "TAKE_PROFIT",
                        type,
                        timeInForce,
                        quantity,
                        price,
                        "BOTH".equals(plan.getPositionSide())
                );
                markOrderLocalState(intent, "SUBMITTING", null);
                OrderSnapshot response = gateway.placeRegularOrder(
                        credentials,
                        new RegularOrderRequest(
                            plan.getSymbol(),
                            exitSide(plan),
                            plan.getPositionSide(),
                            type,
                            timeInForce,
                            quantity,
                            price,
                            "BOTH".equals(plan.getPositionSide()),
                            clientOrderId
                        )
                );
                merged = mirrorService.mergeOrder(
                        account,
                        response,
                        "REST_SUBMIT",
                        null,
                        Math.max(
                                response.updateTimeMillis(),
                                System.currentTimeMillis()
                        ),
                        value(account.getReconcileRevision()),
                        true
                );
            }
            BigDecimal cumulative = TradingOrderRepairPolicy
                    .cumulativeExecuted(
                            level.getReductionOrderBaseExecutedQuantity(),
                            merged.getExecutedQuantity()
                    );
            level.setExecutedReductionQuantity(cumulative);
            level.setReductionRepairAttempts(0);
            if ("PENDING".equals(level.getStatus())
                    && nonNull(merged.getExecutedQuantity()).signum() > 0) {
                activateLevel(
                        level,
                        target,
                        System.currentTimeMillis()
                );
            }
            if ("FILLED".equals(merged.getStatus())) {
                level.setReductionStatus("COMPLETED");
            } else {
                level.setReductionStatus("LIVE");
            }
            saveLevel(level, null);
            return nonNull(merged.getExecutedQuantity());
        } catch (ExecutionDeferredException exception) {
            level.setReductionStatus("UNKNOWN");
            saveLevel(level, "ORDER_OUTCOME_PENDING");
            throw exception;
        } catch (BinancePrivateApiException exception) {
            ExchangeOrder intent = selectReductionOrder(account, plan, level);
            if (exception.outcomeUnknown()) {
                if (intent != null) {
                    markOrderLocalState(intent, "UNKNOWN", errorCode(exception));
                }
                level.setReductionStatus("UNKNOWN");
            } else {
                if (intent != null) {
                    markOrderLocalState(intent, "REJECTED", errorCode(exception));
                }
                level.setReductionStatus("FAILED");
                scheduleReductionRepair(level, System.currentTimeMillis());
            }
            saveLevel(level, errorCode(exception));
            return BigDecimal.ZERO;
        }
    }

    private void reconcileReductionOrders(
            TradingAccount account,
            TradingPositionPlan plan,
            List<TradingPositionPlanLevel> levels,
            BinanceCredentials credentials,
            long now
    ) {
        for (TradingPositionPlanLevel level : levels) {
            if ("COMPLETED".equals(level.getReductionStatus())) {
                continue;
            }
            if (level.getReductionClientOrderId() == null) {
                continue;
            }
            ReductionResolution resolution;
            try {
                ExchangeOrder algo = isAlgoTakeProfit(plan)
                        ? orderMapper.selectAlgoByIdentity(
                                account.getId(),
                                level.getReductionClientOrderId(),
                                null
                        )
                        : null;
                resolution = algo != null
                        ? resolveAlgoReduction(
                                account,
                                plan,
                                level,
                                credentials,
                                now
                        )
                        : resolveRegularReduction(
                                account,
                                plan,
                                level,
                                credentials,
                                now
                        );
            } catch (BinancePrivateApiException exception) {
                level.setReductionStatus("UNKNOWN");
                saveLevel(level, errorCode(exception));
                if (exception.outcomeUnknown()) {
                    continue;
                }
                throw exception;
            }
            if (resolution == null) {
                continue;
            }
            BigDecimal cumulative = TradingOrderRepairPolicy
                    .cumulativeExecuted(
                            level.getReductionOrderBaseExecutedQuantity(),
                            resolution.executedQuantity()
                    );
            level.setExecutedReductionQuantity(cumulative);
            TradingOrderRepairPolicy.Health health = resolution.health();
            if (nonNull(level.getPlannedReductionQuantity()).signum() > 0
                    && cumulative.compareTo(
                            level.getPlannedReductionQuantity()
                    ) >= 0) {
                health = TradingOrderRepairPolicy.Health.COMPLETED;
            }
            if ("PENDING".equals(level.getStatus())
                    && (resolution.triggered()
                    || resolution.executedQuantity().signum() > 0)) {
                activateLevel(level, targetPrice(plan, level), now);
            }
            switch (health) {
                case HEALTHY -> {
                    level.setReductionStatus("LIVE");
                    level.setReductionNextRetryAtMs(null);
                    level.setReductionRepairAttempts(0);
                }
                case COMPLETED -> {
                    level.setReductionStatus("COMPLETED");
                    level.setReductionNextRetryAtMs(null);
                    level.setReductionRepairAttempts(0);
                }
                case REPAIR -> {
                    scheduleReductionRepairIfNeeded(level, now);
                    level.setReductionStatus(
                            retryDue(level.getReductionNextRetryAtMs(), now)
                                    ? "PENDING"
                                    : "FAILED"
                    );
                }
                case RECONCILE -> level.setReductionStatus("UNKNOWN");
            }
            saveLevel(level, resolution.errorCode());
        }
    }

    private ReductionResolution resolveRegularReduction(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level,
            BinanceCredentials credentials,
            long now
    ) {
        ExchangeOrder order = orderMapper.selectRegularByIdentity(
                account.getId(),
                level.getReductionClientOrderId(),
                null
        );
        var remote = gateway.queryRegularOrder(
                credentials,
                plan.getSymbol(),
                level.getReductionClientOrderId(),
                order == null ? null : order.getExchangeOrderId()
        );
        if (remote.isPresent()) {
            order = mirrorService.mergeOrder(
                    account,
                    remote.get(),
                    "REST_HEALTH_CHECK",
                    null,
                    remote.get().updateTimeMillis(),
                    value(account.getReconcileRevision()),
                    true
            );
        } else if (order == null
                || orderAgeMillis(order, now) >= unknownTimeoutMillis()) {
            if (order != null) {
                markOrderLocalState(
                        order,
                        "UNRESOLVED",
                        "REDUCTION_ORDER_MISSING"
                );
            }
            return new ReductionResolution(
                    order == null
                            ? BigDecimal.ZERO
                            : nonNull(order.getExecutedQuantity()),
                    TradingOrderRepairPolicy.Health.REPAIR,
                    false,
                    "REDUCTION_ORDER_MISSING"
            );
        }
        if (order == null) {
            return null;
        }
        TradingOrderRepairPolicy.Health health =
                TradingOrderRepairPolicy.regularHealth(order.getStatus());
        if (health == TradingOrderRepairPolicy.Health.RECONCILE
                && orderAgeMillis(order, now) >= unknownTimeoutMillis()) {
            health = TradingOrderRepairPolicy.Health.REPAIR;
        }
        BigDecimal executed = nonNull(order.getExecutedQuantity());
        return new ReductionResolution(
                executed,
                health,
                executed.signum() > 0,
                order.getRejectReason()
        );
    }

    private ReductionResolution resolveAlgoReduction(
            TradingAccount account,
            TradingPositionPlan plan,
            TradingPositionPlanLevel level,
            BinanceCredentials credentials,
            long now
    ) {
        ExchangeOrder algo = orderMapper.selectAlgoByIdentity(
                account.getId(),
                level.getReductionClientOrderId(),
                null
        );
        var remote = gateway.queryAlgoOrder(
                credentials,
                level.getReductionClientOrderId(),
                algo == null ? null : algo.getExchangeAlgoId()
        );
        if (remote.isPresent()) {
            algo = mirrorService.mergeOrder(
                    account,
                    remote.get(),
                    "REST_HEALTH_CHECK",
                    null,
                    remote.get().updateTimeMillis(),
                    value(account.getReconcileRevision()),
                    true
            );
        } else if (algo == null
                || orderAgeMillis(algo, now) >= unknownTimeoutMillis()) {
            if (algo != null) {
                markOrderLocalState(
                        algo,
                        "UNRESOLVED",
                        "REDUCTION_ALGO_MISSING"
                );
            }
            return new ReductionResolution(
                    BigDecimal.ZERO,
                    TradingOrderRepairPolicy.Health.REPAIR,
                    false,
                    "REDUCTION_ALGO_MISSING"
            );
        }
        if (algo == null) {
            return null;
        }

        boolean triggered = "TRIGGERING".equals(algo.getStatus())
                || "TRIGGERED".equals(algo.getStatus())
                || "FINISHED".equals(algo.getStatus());
        TradingOrderRepairPolicy.Health health =
                TradingOrderRepairPolicy.algoHealth(algo.getStatus());
        BigDecimal executed = BigDecimal.ZERO;
        String error = algo.getRejectReason();
        if (health == TradingOrderRepairPolicy.Health.COMPLETED) {
            if (algo.getActualOrderId() == null
                    || algo.getActualOrderId().isBlank()) {
                health = orderAgeMillis(algo, now) >= repairBackoffMillis()
                        ? TradingOrderRepairPolicy.Health.REPAIR
                        : TradingOrderRepairPolicy.Health.RECONCILE;
            } else {
                var childRemote = gateway.queryRegularOrder(
                        credentials,
                        plan.getSymbol(),
                        null,
                        algo.getActualOrderId()
                );
                ExchangeOrder child = childRemote.isPresent()
                        ? mirrorService.mergeOrder(
                                account,
                                childRemote.get(),
                                "REST_HEALTH_CHECK",
                                null,
                                childRemote.get().updateTimeMillis(),
                                value(account.getReconcileRevision()),
                                true
                        )
                        : orderMapper.selectRegularByExchangeId(
                                account.getId(),
                                algo.getActualOrderId()
                        );
                if (child == null) {
                    health = orderAgeMillis(algo, now) >= repairBackoffMillis()
                            ? TradingOrderRepairPolicy.Health.REPAIR
                            : TradingOrderRepairPolicy.Health.RECONCILE;
                } else {
                    executed = nonNull(child.getExecutedQuantity());
                    health = TradingOrderRepairPolicy.regularHealth(
                            child.getStatus()
                    );
                    error = child.getRejectReason();
                }
            }
        }
        return new ReductionResolution(
                executed,
                health,
                triggered,
                error
        );
    }

    private record ReductionResolution(
            BigDecimal executedQuantity,
            TradingOrderRepairPolicy.Health health,
            boolean triggered,
            String errorCode
    ) {
    }

    private void scheduleReductionRepairIfNeeded(
            TradingPositionPlanLevel level,
            long now
    ) {
        if (level.getReductionNextRetryAtMs() == null) {
            scheduleReductionRepair(level, now);
        }
    }

    private void scheduleReductionRepair(
            TradingPositionPlanLevel level,
            long now
    ) {
        int attempts = value(level.getReductionRepairAttempts()) + 1;
        level.setReductionRepairAttempts(attempts);
        level.setReductionNextRetryAtMs(
                TradingOrderRepairPolicy.nextRetryMillis(
                        now,
                        repairBackoffMillis(),
                        attempts
                )
            );
    }

    private void finishCompletedLevels(
            List<TradingPositionPlanLevel> levels
    ) {
        for (TradingPositionPlanLevel level : levels) {
            if (!"ACTIVE".equals(level.getStatus())) {
                continue;
            }
            boolean reductionDone = "NONE".equals(level.getReductionStatus())
                    || "COMPLETED".equals(level.getReductionStatus());
            boolean stopDone = "NONE".equals(level.getMoveStopMode())
                    || "FIXED_R".equals(level.getMoveStopMode());
            if (reductionDone && stopDone
                    && !"TRAILING_PROFIT_R".equals(level.getMoveStopMode())) {
                level.setStatus("COMPLETED");
                saveLevel(level, null);
            }
        }
    }

    private void closePlan(
            TradingAccount account,
            TradingPositionPlan plan,
            long fenceToken,
            BinanceCredentials credentials
    ) {
        long now = System.currentTimeMillis();
        if ("CLOSE_CLEANUP_PENDING".equals(plan.getLastErrorCode())
                && !retryDue(plan.getNextProtectionRepairAtMs(), now)) {
            return;
        }
        boolean cleaned = cancelPlanExitOrders(
                account,
                plan,
                credentials
        );
        cleaned &= cancelManualCloseIfActive(
                account,
                plan,
                credentials
        );
        cleaned &= cancelAllPlanStops(account, plan, credentials);
        plan.setRemainingQuantity(BigDecimal.ZERO);
        plan.setProtectedQuantity(BigDecimal.ZERO);
        if (cleaned) {
            plan.setNextProtectionRepairAtMs(null);
            plan.setProtectionRepairAttempts(0);
        } else {
            scheduleProtectionRepair(plan, now);
        }
        plan.setStatus(cleaned ? "CLOSED" : "DEGRADED");
        savePlan(
                plan,
                fenceToken,
                cleaned ? null : "CLOSE_CLEANUP_PENDING"
        );
    }

    private boolean cancelManualCloseIfActive(
            TradingAccount account,
            TradingPositionPlan plan,
            BinanceCredentials credentials
    ) {
        if (plan.getTradingPositionId() == null
                || plan.getPositionGeneration() == null) {
            return true;
        }
        ExchangeOrder manualClose = orderMapper.selectActiveManualClose(
                account.getId(),
                plan.getTradingPositionId(),
                plan.getPositionGeneration()
        );
        return manualClose == null || cancelRegularIfActive(
                account,
                credentials,
                plan.getSymbol(),
                manualClose.getClientOrderId()
        );
    }

    private boolean cancelAllPlanStops(
            TradingAccount account,
            TradingPositionPlan plan,
            BinanceCredentials credentials
    ) {
        boolean cleaned = true;
        cleaned &= cancelAlgoIfActive(
                account,
                credentials,
                plan.getPrimaryStopClientAlgoId()
        );
        cleaned &= cancelAlgoIfActive(
                account,
                credentials,
                plan.getFallbackStopClientAlgoId()
        );
        for (ExchangeOrder stop : orderMapper.selectActiveSystemStops(
                account.getId(),
                plan.getSymbol(),
                plan.getPositionSide()
        )) {
            if (belongsToPlanStop(plan, stop.getClientAlgoId())) {
                cleaned &= cancelAlgoIfActive(
                        account,
                        credentials,
                        stop.getClientAlgoId()
                );
            }
        }
        return cleaned;
    }

    private boolean cleanupReplacedPlanStops(
            TradingAccount account,
            TradingPositionPlan plan,
            BinanceCredentials credentials
    ) {
        boolean cleaned = true;
        for (ExchangeOrder stop : orderMapper.selectActiveSystemStops(
                account.getId(),
                plan.getSymbol(),
                plan.getPositionSide()
        )) {
            String clientId = stop.getClientAlgoId();
            boolean current = clientId != null
                    && (clientId.equals(plan.getPrimaryStopClientAlgoId())
                    || clientId.equals(plan.getFallbackStopClientAlgoId()));
            if (!current && belongsToPlanStop(plan, clientId)) {
                cleaned &= cancelAlgoIfActive(
                        account,
                        credentials,
                        clientId
                );
            }
        }
        return cleaned;
    }

    private boolean belongsToPlanStop(
            TradingPositionPlan plan,
            String clientAlgoId
    ) {
        if (clientAlgoId == null
                || !(clientAlgoId.startsWith("tt-s-")
                || clientAlgoId.startsWith("tt-f-"))) {
            return false;
        }
        int revisionSeparator = clientAlgoId.lastIndexOf('-');
        if (revisionSeparator <= 5) {
            return false;
        }
        String embeddedPlan = clientAlgoId.substring(5, revisionSeparator);
        return plan.getId().replace("-", "").startsWith(embeddedPlan);
    }

    private void cancelAlgoIfReplaced(
            TradingAccount account,
            BinanceCredentials credentials,
            String oldClientId,
            String newClientId
    ) {
        if (oldClientId == null || oldClientId.equals(newClientId)) {
            return;
        }
        cancelAlgoIfActive(account, credentials, oldClientId);
    }

    private boolean cancelAlgoIfActive(
            TradingAccount account,
            BinanceCredentials credentials,
            String clientAlgoId
    ) {
        if (clientAlgoId == null) {
            return true;
        }
        ExchangeOrder old = orderMapper.selectAlgoByIdentity(
                account.getId(),
                clientAlgoId,
                null
        );
        if (old != null && !TradingOrderStateMachine.isAlgoActive(
                old.getStatus()
        )) {
            return true;
        }
        try {
            OrderSnapshot response = gateway.cancelAlgoOrder(
                    credentials,
                    clientAlgoId,
                    old == null ? null : old.getExchangeAlgoId()
            );
            mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_CANCEL",
                    null,
                    Math.max(response.updateTimeMillis(), System.currentTimeMillis()),
                    value(account.getReconcileRevision()),
                    true
            );
            return true;
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                if (old != null) {
                    markOrderLocalState(
                            old,
                            "CANCELED",
                            "ORDER_NOT_FOUND_ON_CANCEL"
                    );
                }
                return true;
            }
            log.warn(
                    "Cancel Algo order failed accountId={} clientId={} code={}",
                    account.getId(),
                    clientAlgoId,
                    errorCode(exception)
            );
            return false;
        }
    }

    private boolean cancelRegularIfActive(
            TradingAccount account,
            BinanceCredentials credentials,
            String symbol,
            String clientOrderId
    ) {
        if (clientOrderId == null) {
            return true;
        }
        ExchangeOrder current = orderMapper.selectRegularByIdentity(
                account.getId(),
                clientOrderId,
                null
        );
        if (current != null && !TradingOrderStateMachine.isRegularActive(
                current.getStatus()
        )) {
            return true;
        }
        try {
            OrderSnapshot response = gateway.cancelRegularOrder(
                    credentials,
                    current == null ? symbol : current.getSymbol(),
                    clientOrderId,
                    current == null ? null : current.getExchangeOrderId()
            );
            mirrorService.mergeOrder(
                    account,
                    response,
                    "REST_CANCEL",
                    null,
                    Math.max(response.updateTimeMillis(), System.currentTimeMillis()),
                    value(account.getReconcileRevision()),
                    true
            );
            return true;
        } catch (BinancePrivateApiException exception) {
            if (isOrderNotFound(exception)) {
                if (current != null) {
                    markOrderLocalState(
                            current,
                            "CANCELED",
                            "ORDER_NOT_FOUND_ON_CANCEL"
                    );
                }
                return true;
            }
            log.warn(
                    "Cancel regular order failed accountId={} clientId={} code={}",
                    account.getId(),
                    clientOrderId,
                    errorCode(exception)
            );
            return false;
        }
    }

    private boolean isOpenLinkedPosition(
            TradingPositionPlan plan,
            TradingPosition position
    ) {
        return position != null
                && "OPEN".equals(position.getStatus())
                && nonNull(position.getQuantity()).signum() != 0
                && plan.getTradingPositionId().equals(position.getId())
                && (plan.getPositionGeneration() == null
                || plan.getPositionGeneration().equals(position.getGeneration()));
    }

    private ExchangeOrder ensureRegularIntent(
            TradingAccount account,
            TradingPositionPlan plan,
            String clientOrderId,
            String purpose,
            String type,
            String timeInForce,
            BigDecimal quantity,
            BigDecimal price,
            boolean reduceOnly
    ) {
        ExchangeOrder existing = orderMapper.selectRegularByIdentity(
                account.getId(),
                clientOrderId,
                null
        );
        if (existing != null) {
            return existing;
        }
        ExchangeOrder intent = baseIntent(
                account,
                plan,
                "REGULAR",
                purpose,
                type,
                timeInForce,
                quantity,
                price,
                BigDecimal.ZERO,
                reduceOnly,
                false
        );
        intent.setClientOrderId(clientOrderId);
        orderMapper.insertOrder(intent);
        return orderMapper.selectRegularByIdentity(
                account.getId(),
                clientOrderId,
                null
        );
    }

    private ExchangeOrder ensureManualCloseIntent(
            TradingAccount account,
            TradingPosition position,
            String clientOrderId,
            String type,
            String timeInForce,
            BigDecimal quantity,
            BigDecimal price
    ) {
        ExchangeOrder existing = orderMapper.selectRegularByIdentity(
                account.getId(),
                clientOrderId,
                null
        );
        if (existing != null) {
            return existing;
        }
        LocalDateTime now = LocalDateTime.now();
        ExchangeOrder intent = new ExchangeOrder();
        intent.setId(UUID.randomUUID().toString());
        intent.setCreateTime(now);
        intent.setUpdateTime(now);
        intent.setTradingAccountId(account.getId());
        intent.setTradingPositionId(position.getId());
        intent.setPositionGeneration(position.getGeneration());
        intent.setOrderClass("REGULAR");
        intent.setOrigin("SYSTEM");
        intent.setPurpose("MANUAL_CLOSE");
        intent.setSymbol(position.getSymbol());
        intent.setSide(closeSide(position));
        intent.setPositionSide(position.getPositionSide());
        intent.setOrderType(type);
        intent.setTimeInForce(timeInForce);
        intent.setClientOrderId(clientOrderId);
        intent.setQuantity(nonNull(quantity));
        intent.setPrice(nonNull(price));
        intent.setTriggerPrice(BigDecimal.ZERO);
        intent.setExecutedQuantity(BigDecimal.ZERO);
        intent.setCumulativeQuote(BigDecimal.ZERO);
        intent.setAveragePrice(BigDecimal.ZERO);
        intent.setReduceOnly("BOTH".equals(position.getPositionSide()) ? 1 : 0);
        intent.setClosePosition(0);
        intent.setStatus("INTENT");
        intent.setExchangeCreateMs(0L);
        intent.setExchangeUpdateMs(0L);
        intent.setLastEventMs(0L);
        intent.setLastReconcileRevision(value(account.getReconcileRevision()));
        intent.setVersion(0L);
        orderMapper.insertOrder(intent);
        return orderMapper.selectRegularByIdentity(
                account.getId(),
                clientOrderId,
                null
        );
    }

    private ExchangeOrder ensureAlgoIntent(
            TradingAccount account,
            TradingPositionPlan plan,
            AlgoOrderRequest request,
            String purpose
    ) {
        ExchangeOrder existing = orderMapper.selectAlgoByIdentity(
                account.getId(),
                request.clientAlgoId(),
                null
        );
        if (existing != null) {
            return existing;
        }
        ExchangeOrder intent = baseIntent(
                account,
                plan,
                "ALGO",
                purpose,
                request.type(),
                request.timeInForce(),
                request.quantity(),
                request.price(),
                request.triggerPrice(),
                request.reduceOnly(),
                request.closePosition()
        );
        intent.setWorkingType(request.workingType());
        intent.setClientAlgoId(request.clientAlgoId());
        orderMapper.insertOrder(intent);
        return orderMapper.selectAlgoByIdentity(
                account.getId(),
                request.clientAlgoId(),
                null
        );
    }

    private ExchangeOrder baseIntent(
            TradingAccount account,
            TradingPositionPlan plan,
            String orderClass,
            String purpose,
            String type,
            String timeInForce,
            BigDecimal quantity,
            BigDecimal price,
            BigDecimal triggerPrice,
            boolean reduceOnly,
            boolean closePosition
    ) {
        LocalDateTime now = LocalDateTime.now();
        ExchangeOrder order = new ExchangeOrder();
        order.setId(UUID.randomUUID().toString());
        order.setCreateTime(now);
        order.setUpdateTime(now);
        order.setTradingAccountId(account.getId());
        order.setTradingPositionId(plan.getTradingPositionId());
        order.setPositionGeneration(plan.getPositionGeneration());
        order.setOrderClass(orderClass);
        order.setOrigin("SYSTEM");
        order.setPurpose(purpose);
        order.setSymbol(plan.getSymbol());
        order.setSide("ENTRY".equals(purpose)
                ? plan.getEntrySide()
                : exitSide(plan));
        order.setPositionSide(plan.getPositionSide());
        order.setOrderType(type);
        order.setTimeInForce(timeInForce);
        order.setQuantity(nonNull(quantity));
        order.setPrice(nonNull(price));
        order.setTriggerPrice(nonNull(triggerPrice));
        order.setExecutedQuantity(BigDecimal.ZERO);
        order.setCumulativeQuote(BigDecimal.ZERO);
        order.setAveragePrice(BigDecimal.ZERO);
        order.setReduceOnly(reduceOnly ? 1 : 0);
        order.setClosePosition(closePosition ? 1 : 0);
        order.setStatus("INTENT");
        order.setExchangeCreateMs(0L);
        order.setExchangeUpdateMs(0L);
        order.setLastEventMs(0L);
        order.setLastReconcileRevision(value(account.getReconcileRevision()));
        order.setVersion(0L);
        return order;
    }

    private void markOrderLocalState(
            ExchangeOrder order,
            String state,
            String error
    ) {
        order.setUpdateTime(LocalDateTime.now());
        order.setStatus(state);
        order.setRejectReason(sanitize(error));
        if (orderMapper.updateOrder(order) == 1) {
            order.setVersion(value(order.getVersion()) + 1);
        }
    }

    private void failCommand(TradingCommand command, String errorCode) {
        transitionCommand(
                command,
                "FAILED_KNOWN",
                null,
                errorCode,
                true
        );
    }

    private boolean transitionCommand(
            TradingCommand command,
            String next,
            String resultJson,
            String error,
            boolean terminal
    ) {
        TradingCommandStateMachine.requireTransition(command.getStatus(), next);
        long now = System.currentTimeMillis();
        int updated = commandMapper.transition(
                command.getId(),
                command.getTradingAccountId(),
                command.getStatus(),
                next,
                resultJson,
                sanitize(error),
                "DISPATCHING".equals(next) ? now : null,
                terminal ? now : null,
                value(command.getVersion())
        );
        if (updated != 1) {
            return false;
        }
        command.setStatus(next);
        command.setResultJson(resultJson);
        command.setErrorCode(sanitize(error));
        command.setVersion(value(command.getVersion()) + 1);
        return true;
    }

    private void updatePlanState(
            TradingPositionPlan plan,
            String state,
            long fenceToken,
            String error
    ) {
        plan.setStatus(state);
        savePlan(plan, fenceToken, error);
    }

    private void markPlanDegraded(
            TradingPositionPlan plan,
            long fenceToken,
            String error
    ) {
        if ("MANUAL_CLOSING".equals(plan.getStatus())) {
            savePlan(plan, fenceToken, error);
            return;
        }
        if (!"CLOSED".equals(plan.getStatus())
                && !"FAILED".equals(plan.getStatus())
                && !"CANCELED".equals(plan.getStatus())) {
            updatePlanState(plan, "DEGRADED", fenceToken, error);
        }
    }

    private void savePlan(
            TradingPositionPlan plan,
            long fenceToken,
            String error
    ) {
        plan.setUpdateTime(LocalDateTime.now());
        plan.setExecutionFenceToken(fenceToken);
        plan.setLastErrorCode(sanitize(error));
        if (planMapper.updatePlan(plan) != 1) {
            throw new IllegalStateException("Concurrent trading plan update");
        }
        plan.setVersion(value(plan.getVersion()) + 1);
    }

    private void saveLevel(TradingPositionPlanLevel level, String error) {
        level.setUpdateTime(LocalDateTime.now());
        level.setLastErrorCode(sanitize(error));
        if (levelMapper.updateLevel(level) != 1) {
            throw new IllegalStateException("Concurrent plan level update");
        }
        level.setVersion(value(level.getVersion()) + 1);
    }

    private TradingAccount currentAccount(String accountId, long fenceToken) {
        if (accountMapper.isFenceCurrent(accountId, fenceToken) != 1) {
            throw new TradingExchangeEventReducer
                    .StaleTradingAccountWorkerException(accountId);
        }
        TradingAccount account = accountMapper.selectListenableById(accountId);
        if (account == null) {
            throw new TradingExchangeEventReducer
                    .StaleTradingAccountWorkerException(accountId);
        }
        return account;
    }

    private String entryExchangeType(TradingPositionPlan plan) {
        return "MARKET".equals(plan.getEntryOrderType()) ? "MARKET" : "LIMIT";
    }

    private String entryTimeInForce(TradingPositionPlan plan) {
        return switch (plan.getEntryOrderType()) {
            case "MAKER_ONLY" -> "GTX";
            case "LIMIT" -> "GTC";
            default -> null;
        };
    }

    private String exitSide(TradingPositionPlan plan) {
        return "LONG".equals(plan.getDirection()) ? "SELL" : "BUY";
    }

    private BigDecimal targetPrice(
            TradingPositionPlan plan,
            TradingPositionPlanLevel level
    ) {
        BigDecimal move = plan.getRiskPerUnit().multiply(level.getTriggerR());
        return "LONG".equals(plan.getDirection())
                ? plan.getAverageEntryPrice().add(move)
                : plan.getAverageEntryPrice().subtract(move);
    }

    private boolean targetReached(
            TradingPositionPlan plan,
            BigDecimal currentPrice,
            BigDecimal target
    ) {
        if (currentPrice == null || currentPrice.signum() <= 0) {
            return false;
        }
        return "LONG".equals(plan.getDirection())
                ? currentPrice.compareTo(target) >= 0
                : currentPrice.compareTo(target) <= 0;
    }

    private BigDecimal makerExitPrice(
            TradingPositionPlan plan,
            BigDecimal target,
            PriceSnapshot prices
    ) {
        if ("LONG".equals(plan.getDirection())) {
            BigDecimal candidate = target.max(
                    prices.askPrice().add(plan.getPriceTick())
            );
            return TradingRiskEngine.ceilToStep(candidate, plan.getPriceTick());
        }
        BigDecimal candidate = target.min(
                prices.bidPrice().subtract(plan.getPriceTick())
        );
        return TradingRiskEngine.floorToStep(candidate, plan.getPriceTick());
    }

    private BigDecimal normalizedExitPrice(
            TradingPositionPlan plan,
            BigDecimal target
    ) {
        return "LONG".equals(plan.getDirection())
                ? TradingRiskEngine.floorToStep(target, plan.getPriceTick())
                : TradingRiskEngine.ceilToStep(target, plan.getPriceTick());
    }

    private BigDecimal tighter(
            String direction,
            BigDecimal current,
            BigDecimal candidate
    ) {
        if (current == null) {
            return candidate;
        }
        return "LONG".equals(direction)
                ? current.max(candidate)
                : current.min(candidate);
    }

    private String reductionClientId(
            String planId,
            int level,
            long revision
    ) {
        String compact = planId.replace("-", "");
        String prefix = "tt-x-";
        String suffix = String.format(
                Locale.ROOT,
                "%02d-%s",
                level,
                Long.toString(revision, 36)
        );
        int available = 36 - prefix.length() - suffix.length();
        if (available < 1) {
            throw new IllegalStateException("REDUCTION_REVISION_TOO_LONG");
        }
        return prefix
                + compact.substring(0, Math.min(available, compact.length()))
                + suffix;
    }

    private String algoClientId(String prefix, String planId, long revision) {
        String compact = planId.replace("-", "");
        String suffix = Long.toString(revision, 36);
        int available = 36 - prefix.length() - suffix.length() - 1;
        if (available < 1) {
            throw new IllegalStateException("STOP_REVISION_TOO_LONG");
        }
        return prefix + compact.substring(0, Math.min(available, compact.length()))
                + "-" + suffix;
    }

    private boolean isTerminal(String status) {
        return List.of(
                "FILLED", "CANCELED", "REJECTED", "EXPIRED"
        ).contains(status);
    }

    private boolean isOrderNotFound(BinancePrivateApiException exception) {
        return Integer.valueOf(-2011).equals(exception.code())
                || Integer.valueOf(-2013).equals(exception.code());
    }

    private String errorCode(Throwable failure) {
        if (failure instanceof BinancePrivateApiException exchange
                && exchange.code() != null) {
            return "BINANCE_" + exchange.code();
        }
        String value = failure == null
                ? "UNKNOWN"
                : failure.getClass().getSimpleName();
        return sanitize(value);
    }

    private String sanitize(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String sanitized = value.replaceAll("[^A-Za-z0-9_.-]", "_");
        return sanitized.length() <= 64
                ? sanitized
                : sanitized.substring(0, 64);
    }

    private String json(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException exception) {
            return "{}";
        }
    }

    private String text(String value) {
        return value == null ? "" : value;
    }

    private BigDecimal nonNull(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private boolean retryDue(Long retryAtMillis, long now) {
        return retryAtMillis == null || now >= retryAtMillis;
    }

    private long unknownTimeoutMillis() {
        return Math.max(
                1_000,
                properties.getExecution().getUnknownResolutionTimeoutMillis()
        );
    }

    private long repairBackoffMillis() {
        return Math.max(
                1_000,
                properties.getExecution().getOrderRepairBackoffMillis()
        );
    }

    private long orderAgeMillis(ExchangeOrder order, long now) {
        LocalDateTime timestamp = order.getUpdateTime() == null
                ? order.getCreateTime()
                : order.getUpdateTime();
        if (timestamp == null) {
            return Long.MAX_VALUE;
        }
        return Math.max(0, now - timestamp
                .atZone(java.time.ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli());
    }

    private long levelAgeMillis(
            TradingPositionPlanLevel level,
            long now
    ) {
        LocalDateTime timestamp = level.getUpdateTime() == null
                ? level.getCreateTime()
                : level.getUpdateTime();
        if (timestamp == null) {
            return Long.MAX_VALUE;
        }
        return Math.max(0, now - timestamp
                .atZone(java.time.ZoneId.systemDefault())
                .toInstant()
                .toEpochMilli());
    }

    private long value(Long value) {
        return value == null ? 0 : value;
    }

    private int value(Integer value) {
        return value == null ? 0 : value;
    }

    private static final class ExecutionDeferredException
            extends RuntimeException {
    }
}
