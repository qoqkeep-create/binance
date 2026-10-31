package com.oovso.trading;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.oovso.trading.BinanceUsdmPrivateGateway.PriceSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import com.oovso.trading.TradingConfigurationService.TradingExecutionConfiguration;
import com.oovso.trading.TradingRiskEngine.EntrySizing;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.util.StringUtils;

@Service
public class TradingExecutionService {

    private final TradingProperties properties;
    private final TradingAccountMapper accountMapper;
    private final TradingPositionMapper positionMapper;
    private final ExchangeOrderMapper orderMapper;
    private final TradingCommandMapper commandMapper;
    private final TradingPositionPlanMapper planMapper;
    private final TradingPositionPlanLevelMapper planLevelMapper;
    private final TradingConfigurationService configurationService;
    private final BinanceUsdmPrivateGateway gateway;
    private final TradingAccountSessionManager sessionManager;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate transactionTemplate;

    public TradingExecutionService(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingPositionMapper positionMapper,
            ExchangeOrderMapper orderMapper,
            TradingCommandMapper commandMapper,
            TradingPositionPlanMapper planMapper,
            TradingPositionPlanLevelMapper planLevelMapper,
            TradingConfigurationService configurationService,
            BinanceUsdmPrivateGateway gateway,
            TradingAccountSessionManager sessionManager,
            ObjectMapper objectMapper,
            PlatformTransactionManager transactionManager
    ) {
        this.properties = properties;
        this.accountMapper = accountMapper;
        this.positionMapper = positionMapper;
        this.orderMapper = orderMapper;
        this.commandMapper = commandMapper;
        this.planMapper = planMapper;
        this.planLevelMapper = planLevelMapper;
        this.configurationService = configurationService;
        this.gateway = gateway;
        this.sessionManager = sessionManager;
        this.objectMapper = objectMapper;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    public EntryCommandView createEntry(
            String userId,
            String accountId,
            String idempotencyKey,
            EntryCommand command
    ) {
        requireExecutionFeature();
        String key = normalizedIdempotencyKey(idempotencyKey);
        NormalizedEntry normalized = normalize(command);
        String requestJson = json(normalized.requestPayload());
        String requestHash = sha256(requestJson);
        TradingCommand existing = commandMapper.selectByIdempotency(userId, key);
        if (existing != null) {
            return idempotentResult(existing, accountId, requestHash);
        }

        TradingAccount account = requireExecutableAccount(userId, accountId);
        String positionSide = normalized.direction();
        requireNoManagedOrExistingPosition(
                accountId,
                normalized.symbol(),
                positionSide
        );
        TradingExecutionConfiguration configuration =
                configurationService.executionConfiguration(account);
        BigDecimal rAmount = configuration.lossLimit().getCurrentAmount();
        if (rAmount == null || rAmount.signum() <= 0) {
            throw badRequest("当前止损金额R为0，请先完成止损额设置");
        }
        TradingOrderSettings settings = configuration.orderSettings();
        SymbolRules rules = gateway.symbolRules(normalized.symbol());
        if (!account.getQuoteAsset().equalsIgnoreCase(rules.quoteAsset())) {
            throw badRequest("交易对结算资产与当前账户设置不一致");
        }
        PriceSnapshot prices = gateway.priceSnapshot(normalized.symbol());
        EntrySizing sizing;
        try {
            sizing = TradingRiskEngine.sizeEntry(
                    normalized.direction(),
                    settings.getEntryOrderType(),
                    normalized.entryPrice(),
                    prices.markPrice(),
                    normalized.stopPrice(),
                    rAmount,
                    rules
            );
        } catch (IllegalArgumentException exception) {
            throw badRequest(exception.getMessage());
        }

        PersistedEntry persisted = transactionTemplate.execute(status -> {
            TradingAccount lockedAccount = requireExecutableAccount(
                    accountMapper.selectOwnedForUpdate(accountId, userId)
            );
            TradingCommand duplicate = commandMapper.selectByIdempotency(
                    userId,
                    key
            );
            if (duplicate != null) {
                return new PersistedEntry(
                        duplicate,
                        planMapper.selectByCommand(duplicate.getId()),
                        true
                );
            }
            requireNoManagedOrExistingPosition(
                    accountId,
                    normalized.symbol(),
                    positionSide
            );
            String commandId = UUID.randomUUID().toString();
            String clientOrderId = deterministicId("tt-e-", commandId, 26);
            LocalDateTime now = LocalDateTime.now();
            TradingCommand createdCommand = new TradingCommand();
            createdCommand.setId(commandId);
            createdCommand.setCreateTime(now);
            createdCommand.setUpdateTime(now);
            createdCommand.setTradingAccountId(accountId);
            createdCommand.setAppUserId(userId);
            createdCommand.setIdempotencyKey(key);
            createdCommand.setRequestHash(requestHash);
            createdCommand.setRequestJson(requestJson);
            createdCommand.setCommandType("PLACE_ENTRY");
            createdCommand.setStatus("PERSISTED");
            createdCommand.setClientOrderId(clientOrderId);
            createdCommand.setVersion(0L);
            if (commandMapper.insertCommand(createdCommand) != 1) {
                throw new IllegalStateException("Cannot persist trading command");
            }

            TradingPositionPlan plan = newPlan(
                    lockedAccount,
                    createdCommand,
                    positionSide,
                    normalized,
                    configuration,
                    sizing,
                    rules,
                    now
            );
            if (planMapper.insertPlan(plan) != 1) {
                throw new IllegalStateException("Cannot persist position plan");
            }
            snapshotLevels(plan, configuration.levels(), now);
            return new PersistedEntry(createdCommand, plan, false);
        });
        if (persisted == null) {
            throw new IllegalStateException("Trading entry transaction rolled back");
        }
        if (persisted.duplicate()
                && !requestHash.equals(persisted.command().getRequestHash())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "同一个幂等键不能提交不同的下单参数"
            );
        }
        sessionManager.requestExecution(accountId);
        return EntryCommandView.from(persisted.command(), persisted.plan());
    }

    public EntryCommandView cancelEntryLimitOrder(
            String userId,
            String accountId,
            String idempotencyKey,
            String orderId
    ) {
        requireExecutionFeature();
        TradingAccount account = requireOwnedAccount(userId, accountId);
        String normalizedOrderId = normalizedOrderId(orderId);
        String key = normalizedIdempotencyKey(idempotencyKey);
        String requestJson = json(Map.of("orderId", normalizedOrderId));
        String requestHash = sha256(requestJson);
        TradingCommand existing = commandMapper.selectByIdempotency(userId, key);
        if (existing != null) {
            return idempotentResult(existing, accountId, requestHash);
        }

        requireCancellableAccount(account);
        PersistedCancel persisted = transactionTemplate.execute(status -> {
            TradingCommand duplicate = commandMapper.selectByIdempotency(
                    userId,
                    key
            );
            if (duplicate != null) {
                return new PersistedCancel(duplicate, true);
            }
            ExchangeOrder order = requireCancellableEntryLimitOrder(
                    accountId,
                    normalizedOrderId
            );
            LocalDateTime now = LocalDateTime.now();
            TradingCommand created = new TradingCommand();
            created.setId(UUID.randomUUID().toString());
            created.setCreateTime(now);
            created.setUpdateTime(now);
            created.setTradingAccountId(accountId);
            created.setAppUserId(userId);
            created.setIdempotencyKey(key);
            created.setRequestHash(requestHash);
            created.setRequestJson(requestJson);
            created.setCommandType("CANCEL_ENTRY");
            created.setStatus("PERSISTED");
            created.setClientOrderId(order.getClientOrderId());
            created.setVersion(0L);
            if (commandMapper.insertCommand(created) != 1) {
                throw new IllegalStateException(
                        "Cannot persist entry cancellation command"
                );
            }
            return new PersistedCancel(created, false);
        });
        if (persisted == null) {
            throw new IllegalStateException(
                    "Entry cancellation transaction rolled back"
            );
        }
        if (persisted.duplicate()
                && !requestHash.equals(persisted.command().getRequestHash())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "同一个幂等键不能取消不同的建仓委托"
            );
        }
        sessionManager.requestExecution(accountId);
        return EntryCommandView.from(
                persisted.command(),
                planMapper.selectByEntryClientOrderId(
                        accountId,
                        persisted.command().getClientOrderId()
                )
        );
    }

    public EntryCommandView closePosition(
            String userId,
            String accountId,
            String idempotencyKey,
            String positionId,
            String orderType
    ) {
        requireExecutionFeature();
        String key = normalizedIdempotencyKey(idempotencyKey);
        String normalizedPositionId = normalizedPositionId(positionId);
        String normalizedType = normalizeCloseOrderType(orderType);
        String requestJson = json(Map.of(
                "positionId", normalizedPositionId,
                "orderType", normalizedType
        ));
        String requestHash = sha256(requestJson);
        TradingCommand existing = commandMapper.selectByIdempotency(userId, key);
        if (existing != null) {
            return idempotentResult(existing, accountId, requestHash);
        }

        requireExecutableAccount(userId, accountId);
        PersistedCancel persisted = transactionTemplate.execute(status -> {
            TradingCommand duplicate = commandMapper.selectByIdempotency(
                    userId,
                    key
            );
            if (duplicate != null) {
                return new PersistedCancel(duplicate, true);
            }
            TradingPosition position = requireOpenPosition(
                    accountId,
                    normalizedPositionId
            );
            if (orderMapper.selectActiveManualClose(
                    accountId,
                    position.getId(),
                    position.getGeneration()
            ) != null) {
                throw new TradingApiException(
                        HttpStatus.CONFLICT,
                        "该持仓已有平仓订单处理中，请刷新后重试"
                );
            }
            TradingCommand created = newCommand(
                    userId,
                    accountId,
                    key,
                    requestHash,
                    requestJson,
                    "CLOSE_POSITION_" + normalizedType,
                    "tt-c-"
            );
            if (commandMapper.insertCommand(created) != 1) {
                throw new IllegalStateException(
                        "Cannot persist close position command"
                );
            }
            return new PersistedCancel(created, false);
        });
        if (persisted == null) {
            throw new IllegalStateException("Close position transaction rolled back");
        }
        requireSameIdempotentRequest(
                persisted,
                requestHash,
                "同一个幂等键不能提交不同的平仓参数"
        );
        sessionManager.requestExecution(accountId);
        return EntryCommandView.from(persisted.command(), null);
    }

    public EntryCommandView cancelMakerClose(
            String userId,
            String accountId,
            String idempotencyKey,
            String positionId,
            String orderId
    ) {
        requireExecutionFeature();
        TradingAccount account = requireOwnedAccount(userId, accountId);
        requireCancellableAccount(account);
        String key = normalizedIdempotencyKey(idempotencyKey);
        String normalizedPositionId = normalizedPositionId(positionId);
        String normalizedOrderId = normalizedOrderId(orderId);
        String requestJson = json(Map.of(
                "positionId", normalizedPositionId,
                "orderId", normalizedOrderId
        ));
        String requestHash = sha256(requestJson);
        TradingCommand existing = commandMapper.selectByIdempotency(userId, key);
        if (existing != null) {
            return idempotentResult(existing, accountId, requestHash);
        }

        PersistedCancel persisted = transactionTemplate.execute(status -> {
            TradingCommand duplicate = commandMapper.selectByIdempotency(
                    userId,
                    key
            );
            if (duplicate != null) {
                return new PersistedCancel(duplicate, true);
            }
            TradingPosition position = requireOpenPosition(
                    accountId,
                    normalizedPositionId
            );
            ExchangeOrder order = orderMapper.selectOwnedRegularById(
                    accountId,
                    normalizedOrderId
            );
            requireCancellableMakerClose(position, order);
            TradingCommand created = newCommand(
                    userId,
                    accountId,
                    key,
                    requestHash,
                    requestJson,
                    "CANCEL_MANUAL_CLOSE",
                    null
            );
            created.setClientOrderId(order.getClientOrderId());
            if (commandMapper.insertCommand(created) != 1) {
                throw new IllegalStateException(
                        "Cannot persist maker close cancellation command"
                );
            }
            return new PersistedCancel(created, false);
        });
        if (persisted == null) {
            throw new IllegalStateException(
                    "Maker close cancellation transaction rolled back"
            );
        }
        requireSameIdempotentRequest(
                persisted,
                requestHash,
                "同一个幂等键不能撤销不同的 Maker 平仓委托"
        );
        sessionManager.requestExecution(accountId);
        return EntryCommandView.from(persisted.command(), null);
    }

    public EntryCommandView command(
            String userId,
            String accountId,
            String commandId
    ) {
        requireOwnedAccount(userId, accountId);
        TradingCommand command = commandMapper.selectOwned(commandId, accountId);
        if (command == null || !userId.equals(command.getAppUserId())) {
            throw new TradingApiException(HttpStatus.NOT_FOUND, "交易命令不存在");
        }
        TradingPositionPlan plan = planMapper.selectByCommand(commandId);
        if (plan == null && "CANCEL_ENTRY".equals(command.getCommandType())) {
            plan = planMapper.selectByEntryClientOrderId(
                    accountId,
                    command.getClientOrderId()
            );
        }
        return EntryCommandView.from(command, plan);
    }

    private TradingPositionPlan newPlan(
            TradingAccount account,
            TradingCommand command,
            String positionSide,
            NormalizedEntry normalized,
            TradingExecutionConfiguration configuration,
            EntrySizing sizing,
            SymbolRules rules,
            LocalDateTime now
    ) {
        TradingOrderSettings settings = configuration.orderSettings();
        TradingPositionPlan plan = new TradingPositionPlan();
        plan.setId(UUID.randomUUID().toString());
        plan.setCreateTime(now);
        plan.setUpdateTime(now);
        plan.setTradingAccountId(account.getId());
        plan.setTradingCommandId(command.getId());
        plan.setSymbol(normalized.symbol());
        plan.setDirection(normalized.direction());
        plan.setPositionSide(positionSide);
        plan.setEntrySide("LONG".equals(normalized.direction()) ? "BUY" : "SELL");
        plan.setStatus("ENTRY_PENDING");
        plan.setEntryOrderType(settings.getEntryOrderType());
        plan.setTakeProfitOrderType(settings.getTakeProfitOrderType());
        plan.setStopLossOrderType(settings.getStopLossOrderType());
        plan.setWorkingType("MARK_PRICE");
        plan.setOrderSettingsRevision(settings.getRevision());
        if (configuration.exitStrategy() != null) {
            plan.setExitStrategyId(configuration.exitStrategy().getId());
            plan.setExitStrategyRevision(
                    configuration.exitStrategy().getStrategyRevision()
            );
        }
        String executionSnapshot = json(executionSnapshot(
                normalized,
                configuration,
                sizing,
                rules
        ));
        plan.setExecutionSnapshotJson(executionSnapshot);
        plan.setExecutionSnapshotHash(sha256(executionSnapshot));
        plan.setSettlementAsset(configuration.lossLimit().getSettlementAsset());
        plan.setConfiguredRAmount(configuration.lossLimit().getCurrentAmount());
        plan.setReferenceEntryPrice(sizing.referenceEntryPrice());
        plan.setRequestedEntryPrice(sizing.normalizedRequestedEntryPrice());
        plan.setInitialStopPrice(sizing.initialStopPrice());
        plan.setRiskPerUnit(sizing.riskPerUnit());
        plan.setPlannedQuantity(sizing.quantity());
        plan.setFilledQuantity(BigDecimal.ZERO);
        plan.setProtectedQuantity(BigDecimal.ZERO);
        plan.setRemainingQuantity(BigDecimal.ZERO);
        plan.setPriceTick(rules.priceTick());
        plan.setQuantityStep(rules.quantityStep());
        plan.setMarketQuantityStep(rules.marketQuantityStep());
        plan.setMinQuantity("MARKET".equals(settings.getEntryOrderType())
                ? rules.marketMinQuantity()
                : rules.minQuantity());
        plan.setMinNotional(rules.minNotional());
        plan.setFallbackMarketStopR(settings.getFallbackMarketStopR());
        plan.setEntryClientOrderId(command.getClientOrderId());
        plan.setStopRevision(0L);
        plan.setProtectionRepairAttempts(0);
        plan.setVersion(0L);
        return plan;
    }

    private TradingCommand newCommand(
            String userId,
            String accountId,
            String idempotencyKey,
            String requestHash,
            String requestJson,
            String commandType,
            String clientOrderPrefix
    ) {
        LocalDateTime now = LocalDateTime.now();
        TradingCommand command = new TradingCommand();
        command.setId(UUID.randomUUID().toString());
        command.setCreateTime(now);
        command.setUpdateTime(now);
        command.setTradingAccountId(accountId);
        command.setAppUserId(userId);
        command.setIdempotencyKey(idempotencyKey);
        command.setRequestHash(requestHash);
        command.setRequestJson(requestJson);
        command.setCommandType(commandType);
        command.setStatus("PERSISTED");
        if (clientOrderPrefix != null) {
            command.setClientOrderId(deterministicId(
                    clientOrderPrefix,
                    command.getId(),
                    26
            ));
        }
        command.setVersion(0L);
        return command;
    }

    private void requireSameIdempotentRequest(
            PersistedCancel persisted,
            String requestHash,
            String message
    ) {
        if (persisted.duplicate()
                && !requestHash.equals(persisted.command().getRequestHash())) {
            throw new TradingApiException(HttpStatus.CONFLICT, message);
        }
    }

    private void snapshotLevels(
            TradingPositionPlan plan,
            List<TradingExitStrategyLevel> levels,
            LocalDateTime now
    ) {
        for (TradingExitStrategyLevel source : levels) {
            TradingPositionPlanLevel level = new TradingPositionPlanLevel();
            level.setId(UUID.randomUUID().toString());
            level.setCreateTime(now);
            level.setUpdateTime(now);
            level.setTradingPositionPlanId(plan.getId());
            level.setSourceLevelId(source.getId());
            level.setLevelNo(source.getLevelNo());
            level.setTriggerR(source.getTriggerR());
            level.setReducePercent(source.getReducePercent());
            level.setMoveStopMode(source.getMoveStopMode());
            level.setMoveStopR(source.getMoveStopR());
            level.setStatus("PENDING");
            level.setReductionStatus(
                    source.getReducePercent().signum() > 0
                            ? "PENDING"
                            : "NONE"
            );
            level.setPlannedReductionQuantity(BigDecimal.ZERO);
            level.setExecutedReductionQuantity(BigDecimal.ZERO);
            level.setReductionOrderBaseExecutedQuantity(BigDecimal.ZERO);
            level.setReductionRevision(0L);
            level.setReductionRepairAttempts(0);
            level.setStopMoveActivated(0);
            level.setVersion(0L);
            if (planLevelMapper.insertLevel(level) != 1) {
                throw new IllegalStateException("Cannot snapshot exit level");
            }
        }
    }

    private Map<String, Object> executionSnapshot(
            NormalizedEntry entry,
            TradingExecutionConfiguration configuration,
            EntrySizing sizing,
            SymbolRules rules
    ) {
        TradingOrderSettings settings = configuration.orderSettings();
        TradingLossLimit lossLimit = configuration.lossLimit();
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("version", 1);
        snapshot.put("symbol", entry.symbol());
        snapshot.put("direction", entry.direction());
        snapshot.put("requestedEntryPrice", entry.entryPrice());
        snapshot.put("requestedStopPrice", entry.stopPrice());
        snapshot.put("referenceEntryPrice", sizing.referenceEntryPrice());
        snapshot.put("normalizedEntryPrice", sizing.normalizedRequestedEntryPrice());
        snapshot.put("normalizedInitialStopPrice", sizing.initialStopPrice());
        snapshot.put("plannedQuantity", sizing.quantity());
        snapshot.put("plannedRiskAmount", sizing.plannedRiskAmount());
        snapshot.put("lossLimitRevision", lossLimit.getRevision());
        snapshot.put("configuredRAmount", lossLimit.getCurrentAmount());
        snapshot.put("settlementAsset", lossLimit.getSettlementAsset());
        snapshot.put("orderSettingsRevision", settings.getRevision());
        snapshot.put("entryOrderType", settings.getEntryOrderType());
        snapshot.put("takeProfitOrderType", settings.getTakeProfitOrderType());
        snapshot.put("stopLossOrderType", settings.getStopLossOrderType());
        snapshot.put("fallbackMarketStopR", settings.getFallbackMarketStopR());
        snapshot.put(
                "exitStrategyId",
                configuration.exitStrategy() == null
                        ? null
                        : configuration.exitStrategy().getId()
        );
        snapshot.put(
                "exitStrategyRevision",
                configuration.exitStrategy() == null
                        ? null
                        : configuration.exitStrategy().getStrategyRevision()
        );
        List<Map<String, Object>> levels = configuration.levels().stream()
                .map(source -> {
                    Map<String, Object> level = new LinkedHashMap<>();
                    level.put("level", source.getLevelNo());
                    level.put("triggerR", source.getTriggerR());
                    level.put("reducePercent", source.getReducePercent());
                    level.put("moveStopMode", source.getMoveStopMode());
                    level.put("moveStopR", source.getMoveStopR());
                    return level;
                })
                .toList();
        snapshot.put("levels", levels);
        Map<String, Object> symbolRules = new LinkedHashMap<>();
        symbolRules.put("priceTick", rules.priceTick());
        symbolRules.put("quantityStep", rules.quantityStep());
        symbolRules.put("marketQuantityStep", rules.marketQuantityStep());
        symbolRules.put("minQuantity", rules.minQuantity());
        symbolRules.put("marketMinQuantity", rules.marketMinQuantity());
        symbolRules.put("minNotional", rules.minNotional());
        snapshot.put("symbolRules", symbolRules);
        return snapshot;
    }

    private EntryCommandView idempotentResult(
            TradingCommand existing,
            String accountId,
            String requestHash
    ) {
        if (!accountId.equals(existing.getTradingAccountId())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "幂等键已被其他交易账户使用"
            );
        }
        if (!requestHash.equals(existing.getRequestHash())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "同一个幂等键不能提交不同的下单参数"
            );
        }
        TradingPositionPlan plan = planMapper.selectByCommand(existing.getId());
        if (plan == null && "CANCEL_ENTRY".equals(existing.getCommandType())) {
            plan = planMapper.selectByEntryClientOrderId(
                    accountId,
                    existing.getClientOrderId()
            );
        }
        return EntryCommandView.from(existing, plan);
    }

    private void requireNoManagedOrExistingPosition(
            String accountId,
            String symbol,
            String positionSide
    ) {
        if (planMapper.countActiveByKey(accountId, symbol, positionSide) > 0) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "该方向已有系统管理中的建仓或仓位"
            );
        }
        TradingPosition position = positionMapper.selectByKey(
                accountId,
                symbol,
                positionSide
        );
        if (position != null && "OPEN".equals(position.getStatus())
                && position.getQuantity() != null
                && position.getQuantity().signum() != 0) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "该方向已有仓位，当前版本不允许叠加建仓"
            );
        }
    }

    private TradingAccount requireExecutableAccount(
            String userId,
            String accountId
    ) {
        return requireExecutableAccount(requireOwnedAccount(userId, accountId));
    }

    private TradingAccount requireExecutableAccount(TradingAccount account) {
        if (account == null) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "交易账户不存在"
            );
        }
        if (!"ACTIVE".equals(account.getStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "交易凭证不可用，禁止下单"
            );
        }
        if (!TradingSyncStatus.SYNCED.name().equals(account.getSyncStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "账户尚未完成监听与REST对账，禁止下单"
            );
        }
        return account;
    }

    private void requireCancellableAccount(TradingAccount account) {
        if (!"ACTIVE".equals(account.getStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "交易凭证不可用，无法取消建仓委托"
            );
        }
        if (!TradingSyncStatus.SYNCED.name().equals(account.getSyncStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "账户尚未完成监听与REST对账，暂时无法取消建仓委托"
            );
        }
    }

    private ExchangeOrder requireCancellableEntryLimitOrder(
            String accountId,
            String orderId
    ) {
        ExchangeOrder order = orderMapper.selectOwnedRegularById(
                accountId,
                orderId
        );
        if (order == null) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "建仓限价委托不存在"
            );
        }
        if (!"SYSTEM".equals(order.getOrigin())
                || !"ENTRY".equals(order.getPurpose())
                || !"LIMIT".equals(order.getOrderType())
                || !StringUtils.hasText(order.getClientOrderId())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "只能取消本系统创建的建仓限价委托"
            );
        }
        if (!TradingOrderStateMachine.isRegularActive(order.getStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "建仓限价委托已经结束，不能重复取消"
            );
        }
        return order;
    }

    private TradingPosition requireOpenPosition(
            String accountId,
            String positionId
    ) {
        TradingPosition position = positionMapper.selectOwnedById(
                accountId,
                positionId
        );
        if (position == null) {
            throw new TradingApiException(HttpStatus.NOT_FOUND, "持仓不存在");
        }
        if (!"OPEN".equals(position.getStatus())
                || position.getQuantity() == null
                || position.getQuantity().signum() == 0) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "该持仓已经平仓，请刷新后重试"
            );
        }
        return position;
    }

    private void requireCancellableMakerClose(
            TradingPosition position,
            ExchangeOrder order
    ) {
        if (order == null
                || !position.getId().equals(order.getTradingPositionId())
                || !Long.valueOf(position.getGeneration()).equals(
                        order.getPositionGeneration()
                )) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "Maker 平仓委托不存在"
            );
        }
        if (!"SYSTEM".equals(order.getOrigin())
                || !"MANUAL_CLOSE".equals(order.getPurpose())
                || !"LIMIT".equals(order.getOrderType())
                || !StringUtils.hasText(order.getClientOrderId())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "只能撤销该持仓的 Maker 平仓委托"
            );
        }
        if (!TradingOrderStateMachine.isRegularActive(order.getStatus())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "Maker 平仓委托已经结束，请刷新持仓"
            );
        }
    }

    private TradingAccount requireOwnedAccount(String userId, String accountId) {
        TradingAccount account = accountMapper.selectOwned(accountId, userId);
        if (account == null) {
            throw new TradingApiException(HttpStatus.NOT_FOUND, "交易账户不存在");
        }
        return account;
    }

    private void requireExecutionFeature() {
        if (!properties.isEnabled()) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "服务器交易账户功能未启用"
            );
        }
        if (!properties.getSync().isEnabled()) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "服务器账户监听尚未启用"
            );
        }
    }

    private NormalizedEntry normalize(EntryCommand command) {
        if (command == null) {
            throw badRequest("请填写下单参数");
        }
        String symbol = text(command.symbol()).toUpperCase(Locale.ROOT);
        if (!symbol.matches("[A-Z0-9]{2,32}")) {
            throw badRequest("交易对无效");
        }
        String direction = text(command.direction()).toUpperCase(Locale.ROOT);
        if (!"LONG".equals(direction) && !"SHORT".equals(direction)) {
            throw badRequest("方向必须是LONG或SHORT");
        }
        if (command.stopPrice() == null || command.stopPrice().signum() <= 0) {
            throw badRequest("请在K线图选择止损价格");
        }
        if (command.entryPrice() != null && command.entryPrice().signum() <= 0) {
            throw badRequest("建仓价格必须大于0");
        }
        return new NormalizedEntry(
                symbol,
                direction,
                command.entryPrice(),
                command.stopPrice()
        );
    }

    private String normalizedIdempotencyKey(String key) {
        String normalized = text(key);
        if (normalized.length() > 80
                || !normalized.matches("[A-Za-z0-9._:-]+")) {
            throw badRequest("Idempotency-Key格式无效");
        }
        return normalized;
    }

    private String normalizedOrderId(String orderId) {
        String normalized = text(orderId);
        if (normalized.length() > 40
                || !normalized.matches("[A-Za-z0-9-]+")) {
            throw badRequest("建仓委托编号无效");
        }
        return normalized;
    }

    private String normalizedPositionId(String positionId) {
        String normalized = text(positionId);
        if (normalized.length() > 40
                || !normalized.matches("[A-Za-z0-9-]+")) {
            throw badRequest("持仓编号无效");
        }
        return normalized;
    }

    private String normalizeCloseOrderType(String orderType) {
        String normalized = text(orderType).toUpperCase(Locale.ROOT);
        if (!"MARKET".equals(normalized) && !"MAKER".equals(normalized)) {
            throw badRequest("平仓方式必须是 MARKET 或 MAKER");
        }
        return normalized;
    }

    private String text(String value) {
        if (!StringUtils.hasText(value)) {
            throw badRequest("下单参数不完整");
        }
        return value.trim();
    }

    private String json(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Cannot encode trading request", exception);
        }
    }

    private String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(
                    value.getBytes(StandardCharsets.UTF_8)
            );
            return java.util.HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    static String deterministicId(String prefix, String id, int length) {
        String compact = id.replace("-", "");
        return prefix + compact.substring(0, Math.min(length, compact.length()));
    }

    private TradingApiException badRequest(String message) {
        return new TradingApiException(HttpStatus.BAD_REQUEST, message);
    }

    public record EntryCommand(
            String symbol,
            String direction,
            BigDecimal entryPrice,
            BigDecimal stopPrice
    ) {
    }

    public record EntryCommandView(
            String commandId,
            String status,
            String planId,
            String planStatus,
            String symbol,
            String direction,
            String entryOrderType,
            BigDecimal configuredRAmount,
            BigDecimal referenceEntryPrice,
            BigDecimal requestedEntryPrice,
            BigDecimal initialStopPrice,
            BigDecimal plannedQuantity,
            BigDecimal plannedRiskAmount,
            String clientOrderId,
            String errorCode,
            String errorMessage
    ) {
        static EntryCommandView from(
                TradingCommand command,
                TradingPositionPlan plan
        ) {
            return new EntryCommandView(
                    command.getId(),
                    command.getStatus(),
                    plan == null ? null : plan.getId(),
                    plan == null ? null : plan.getStatus(),
                    plan == null ? null : plan.getSymbol(),
                    plan == null ? null : plan.getDirection(),
                    plan == null ? null : plan.getEntryOrderType(),
                    plan == null ? null : plan.getConfiguredRAmount(),
                    plan == null ? null : plan.getReferenceEntryPrice(),
                    plan == null ? null : plan.getRequestedEntryPrice(),
                    plan == null ? null : plan.getInitialStopPrice(),
                    plan == null ? null : plan.getPlannedQuantity(),
                    plan == null ? null : plan.getPlannedQuantity()
                            .multiply(plan.getRiskPerUnit()),
                    command.getClientOrderId(),
                    command.getErrorCode(),
                    BinanceErrorTranslator.storedErrorMessage(
                            command.getErrorCode()
                    )
            );
        }
    }

    private record NormalizedEntry(
            String symbol,
            String direction,
            BigDecimal entryPrice,
            BigDecimal stopPrice
    ) {
        Map<String, Object> requestPayload() {
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("symbol", symbol);
            payload.put("direction", direction);
            payload.put("entryPrice", entryPrice);
            payload.put("stopPrice", stopPrice);
            return payload;
        }
    }

    private record PersistedEntry(
            TradingCommand command,
            TradingPositionPlan plan,
            boolean duplicate
    ) {
    }

    private record PersistedCancel(
            TradingCommand command,
            boolean duplicate
    ) {
    }
}
