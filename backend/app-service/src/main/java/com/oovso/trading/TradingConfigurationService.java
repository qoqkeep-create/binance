package com.oovso.trading;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.function.LongSupplier;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class TradingConfigurationService {

    static final int MAX_LEVELS = 5;
    static final int DEFAULT_LOSS_PERCENTAGE = 3;
    static final long INCREASE_DELAY_MILLIS = 2 * 60 * 60 * 1000L;
    static final String MAKER_ONLY = "MAKER_ONLY";
    static final String LIMIT = "LIMIT";
    static final String MARKET = "MARKET";
    static final String NONE = "NONE";

    private static final BigDecimal ONE_HUNDRED = new BigDecimal("100");
    private static final BigDecimal MAX_TRIGGER_R = new BigDecimal("1000");
    private static final BigDecimal MIN_TRIGGER_R = new BigDecimal("0.1");
    private static final BigDecimal MAX_FIXED_MOVE_R = new BigDecimal("1000");
    private static final BigDecimal MIN_FIXED_MOVE_R = new BigDecimal("-100");

    private final TradingProperties properties;
    private final TradingAccountMapper accountMapper;
    private final TradingExitStrategyMapper strategyMapper;
    private final TradingExitStrategyLevelMapper levelMapper;
    private final TradingLossLimitMapper lossLimitMapper;
    private final TradingOrderSettingsMapper orderSettingsMapper;
    private final TransactionTemplate transactionTemplate;
    private final LongSupplier currentTimeMillis;

    @Autowired
    public TradingConfigurationService(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingExitStrategyMapper strategyMapper,
            TradingExitStrategyLevelMapper levelMapper,
            TradingLossLimitMapper lossLimitMapper,
            TradingOrderSettingsMapper orderSettingsMapper,
            PlatformTransactionManager transactionManager
    ) {
        this(
                properties,
                accountMapper,
                strategyMapper,
                levelMapper,
                lossLimitMapper,
                orderSettingsMapper,
                transactionManager,
                System::currentTimeMillis
        );
    }

    TradingConfigurationService(
            TradingProperties properties,
            TradingAccountMapper accountMapper,
            TradingExitStrategyMapper strategyMapper,
            TradingExitStrategyLevelMapper levelMapper,
            TradingLossLimitMapper lossLimitMapper,
            TradingOrderSettingsMapper orderSettingsMapper,
            PlatformTransactionManager transactionManager,
            LongSupplier currentTimeMillis
    ) {
        this.properties = properties;
        this.accountMapper = accountMapper;
        this.strategyMapper = strategyMapper;
        this.levelMapper = levelMapper;
        this.lossLimitMapper = lossLimitMapper;
        this.orderSettingsMapper = orderSettingsMapper;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
        this.currentTimeMillis = currentTimeMillis;
    }

    public List<ExitStrategyView> strategies(
            String userId,
            String accountId
    ) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        return strategyMapper.selectByAccount(accountId).stream()
                .map(this::toStrategyView)
                .toList();
    }

    public ExitStrategyView createStrategy(
            String userId,
            String accountId,
            ExitStrategyCommand command
    ) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        validateStrategy(command);

        TradingExitStrategy strategy = transactionTemplate.execute(status -> {
            TradingExitStrategy created = newStrategy(accountId, command.name());
            requireUpdated(strategyMapper.insertStrategy(created));
            insertLevels(created.getId(), command.levels(), created.getCreateTime());
            return created;
        });
        return new ExitStrategyView(
                strategy.getId(),
                strategy.getStrategyName(),
                strategy.getStrategyRevision(),
                viewsFromCommands(command.levels())
        );
    }

    public ExitStrategyView updateStrategy(
            String userId,
            String accountId,
            String strategyId,
            ExitStrategyCommand command
    ) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        validateStrategy(command);

        TradingExitStrategy strategy = transactionTemplate.execute(status -> {
            TradingExitStrategy current = requireStrategy(accountId, strategyId);
            current.setStrategyName(command.name().trim());
            current.setStrategyRevision(current.getStrategyRevision() + 1);
            current.setUpdateTime(LocalDateTime.now());
            requireUpdated(strategyMapper.updateStrategy(current));
            levelMapper.deleteByStrategy(strategyId);
            insertLevels(strategyId, command.levels(), current.getUpdateTime());
            return current;
        });
        return new ExitStrategyView(
                strategy.getId(),
                strategy.getStrategyName(),
                strategy.getStrategyRevision(),
                viewsFromCommands(command.levels())
        );
    }

    public void deleteStrategy(
            String userId,
            String accountId,
            String strategyId
    ) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        transactionTemplate.executeWithoutResult(status -> {
            requireStrategy(accountId, strategyId);
            orderSettingsMapper.clearDefaultStrategy(
                    accountId,
                    strategyId,
                    LocalDateTime.now()
            );
            levelMapper.deleteByStrategy(strategyId);
            requireUpdated(strategyMapper.deleteOwned(strategyId, accountId));
        });
    }

    public OrderSettingsView orderSettings(String userId, String accountId) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        TradingOrderSettings settings = transactionTemplate.execute(
                status -> ensureOrderSettings(account)
        );
        return toOrderSettingsView(settings, account);
    }

    public OrderSettingsView updateOrderSettings(
            String userId,
            String accountId,
            OrderSettingsCommand command
    ) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        ValidatedOrderSettings validated = validateOrderSettings(
                accountId,
                command
        );
        TradingOrderSettings updated = transactionTemplate.execute(status -> {
            TradingOrderSettings settings = ensureOrderSettings(account);
            settings.setUpdateTime(LocalDateTime.now());
            settings.setRevision(settings.getRevision() + 1);
            settings.setDefaultExitStrategyId(
                    validated.defaultExitStrategyId()
            );
            settings.setEntryOrderType(validated.entryOrderType());
            settings.setTakeProfitOrderType(
                    validated.takeProfitOrderType()
            );
            settings.setStopLossOrderType(validated.stopLossOrderType());
            settings.setFallbackMarketStopR(
                    validated.fallbackMarketStopR()
            );
            requireUpdated(orderSettingsMapper.updateSettings(settings));
            settings.setVersion(settings.getVersion() + 1);
            return settings;
        });
        return toOrderSettingsView(updated, account);
    }

    public LossLimitView lossLimit(String userId, String accountId) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        TradingLossLimit limit = transactionTemplate.execute(status -> {
            TradingLossLimit current = ensureLossLimit(account);
            return promotePendingIfDue(current);
        });
        return LossLimitView.from(limit, account);
    }

    public LossLimitView updateLossLimit(
            String userId,
            String accountId,
            int percentage
    ) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        if (percentage < 1 || percentage > 25) {
            throw badRequest("止损比例应在1%到25%之间");
        }

        TradingLossLimit updated = transactionTemplate.execute(status -> {
            TradingLossLimit limit = promotePendingIfDue(
                    ensureLossLimit(account)
            );
            BigDecimal proposed = roundedLossAmount(
                    account.getTotalMarginBalance(),
                    percentage
            );
            long now = currentTimeMillis.getAsLong();
            limit.setUpdateTime(LocalDateTime.now());
            limit.setRevision(limit.getRevision() + 1);
            limit.setBalanceSnapshot(normalizeBalance(
                    account.getTotalMarginBalance()
            ));
            limit.setSettlementAsset(account.getQuoteAsset());

            if (proposed.compareTo(limit.getCurrentAmount()) <= 0) {
                limit.setCurrentPercentage(percentage);
                limit.setCurrentAmount(proposed);
                clearPending(limit);
            } else {
                limit.setPendingPercentage(percentage);
                limit.setPendingAmount(proposed);
                limit.setPendingEffectiveAtMs(now + INCREASE_DELAY_MILLIS);
            }
            requireUpdated(lossLimitMapper.updateLimit(limit));
            return limit;
        });
        return LossLimitView.from(updated, account);
    }

    TradingExecutionConfiguration executionConfiguration(
            TradingAccount account
    ) {
        return transactionTemplate.execute(status -> {
            TradingLossLimit limit = promotePendingIfDue(
                    ensureLossLimit(account)
            );
            TradingOrderSettings settings = ensureOrderSettings(account);
            TradingExitStrategy strategy = settings.getDefaultExitStrategyId()
                    == null
                    ? null
                    : strategyMapper.selectOwned(
                            settings.getDefaultExitStrategyId(),
                            account.getId()
                    );
            List<TradingExitStrategyLevel> levels = strategy == null
                    ? List.of()
                    : levelMapper.selectByStrategy(strategy.getId());
            return new TradingExecutionConfiguration(
                    limit,
                    settings,
                    strategy,
                    List.copyOf(levels)
            );
        });
    }

    static BigDecimal roundedLossAmount(
            BigDecimal balance,
            int percentage
    ) {
        BigDecimal safeBalance = normalizeBalance(balance);
        BigDecimal raw = safeBalance
                .multiply(BigDecimal.valueOf(percentage))
                .divide(ONE_HUNDRED, 18, RoundingMode.HALF_UP);
        if (raw.signum() == 0) {
            return BigDecimal.ZERO.setScale(2);
        }
        BigDecimal rounded = raw.compareTo(new BigDecimal("20")) < 0
                ? raw.setScale(0, RoundingMode.HALF_UP)
                : raw.round(new MathContext(1, RoundingMode.HALF_UP));
        return rounded
                .setScale(2, RoundingMode.HALF_UP);
    }

    private TradingExitStrategy newStrategy(String accountId, String name) {
        LocalDateTime now = LocalDateTime.now();
        TradingExitStrategy strategy = new TradingExitStrategy();
        strategy.setId(UUID.randomUUID().toString());
        strategy.setCreateTime(now);
        strategy.setUpdateTime(now);
        strategy.setTradingAccountId(accountId);
        strategy.setStrategyName(name.trim());
        strategy.setStrategyRevision(1L);
        strategy.setVersion(0L);
        return strategy;
    }

    private void insertLevels(
            String strategyId,
            List<ExitStrategyLevelCommand> commands,
            LocalDateTime now
    ) {
        for (int index = 0; index < commands.size(); index++) {
            ExitStrategyLevelCommand command = commands.get(index);
            TradingExitStrategyLevel level = new TradingExitStrategyLevel();
            level.setId(UUID.randomUUID().toString());
            level.setCreateTime(now);
            level.setUpdateTime(now);
            level.setExitStrategyId(strategyId);
            level.setLevelNo(index + 1);
            level.setTriggerR(command.triggerR());
            level.setReducePercent(normalizedReduction(command.reducePercent()));
            level.setMoveStopMode(normalizedMode(command.moveStopMode()));
            level.setMoveStopR("NONE".equals(level.getMoveStopMode())
                    ? null
                    : command.moveStopR());
            requireUpdated(levelMapper.insertLevel(level));
        }
    }

    private ExitStrategyView toStrategyView(TradingExitStrategy strategy) {
        return new ExitStrategyView(
                strategy.getId(),
                strategy.getStrategyName(),
                strategy.getStrategyRevision(),
                levelMapper.selectByStrategy(strategy.getId()).stream()
                        .map(ExitStrategyLevelView::from)
                        .toList()
        );
    }

    private List<ExitStrategyLevelView> viewsFromCommands(
            List<ExitStrategyLevelCommand> commands
    ) {
        return java.util.stream.IntStream.range(0, commands.size())
                .mapToObj(index -> ExitStrategyLevelView.from(
                        commands.get(index),
                        index + 1
                ))
                .toList();
    }

    private void validateStrategy(ExitStrategyCommand command) {
        if (command == null || command.name() == null
                || command.name().trim().isEmpty()) {
            throw badRequest("请输入策略名称");
        }
        if (command.name().trim().length() > 32) {
            throw badRequest("策略名称不能超过32个字符");
        }
        if (command.levels() == null || command.levels().isEmpty()
                || command.levels().size() > MAX_LEVELS) {
            throw badRequest("策略必须包含1到5级止盈止损动作");
        }

        BigDecimal previousTrigger = null;
        BigDecimal remaining = ONE_HUNDRED;
        for (ExitStrategyLevelCommand level : command.levels()) {
            requireRange(
                    level.triggerR(),
                    MIN_TRIGGER_R,
                    MAX_TRIGGER_R,
                    "盈利触发倍数应在0.1R到1000R之间"
            );
            if (previousTrigger != null
                    && level.triggerR().compareTo(previousTrigger) <= 0) {
                throw badRequest("后一级盈利触发倍数必须高于前一级");
            }
            previousTrigger = level.triggerR();

            BigDecimal reduction = normalizedReduction(level.reducePercent());
            requireRange(
                    reduction,
                    BigDecimal.ZERO,
                    ONE_HUNDRED,
                    "减仓比例应在0%到100%之间"
            );
            if (reduction.compareTo(remaining) > 0) {
                throw badRequest("累计减仓比例不能超过100%");
            }

            String mode = normalizedMode(level.moveStopMode());
            if (reduction.signum() == 0 && "NONE".equals(mode)) {
                throw badRequest("每一级至少选择减仓或移动止损中的一项");
            }
            validateMoveStop(mode, level.moveStopR());
            remaining = remaining.subtract(reduction);
        }
    }

    private void validateMoveStop(String mode, BigDecimal moveStopR) {
        switch (mode) {
            case "NONE" -> {
                if (moveStopR != null) {
                    throw badRequest("未移动止损时不能设置止损R位置");
                }
            }
            case "FIXED_R" -> requireRange(
                    moveStopR,
                    MIN_FIXED_MOVE_R,
                    MAX_FIXED_MOVE_R,
                    "固定止损位置应在-100R到1000R之间"
            );
            case "TRAILING_PROFIT_R" -> requireRange(
                    moveStopR,
                    MIN_TRIGGER_R,
                    MAX_TRIGGER_R,
                    "浮盈回撤距离应在0.1R到1000R之间"
            );
            default -> throw badRequest("不支持的移动止损方式");
        }
    }

    private TradingLossLimit ensureLossLimit(TradingAccount account) {
        TradingLossLimit current = lossLimitMapper.selectByAccount(
                account.getId()
        );
        if (current != null) {
            return current;
        }
        LocalDateTime now = LocalDateTime.now();
        TradingLossLimit created = new TradingLossLimit();
        created.setId(UUID.randomUUID().toString());
        created.setCreateTime(now);
        created.setUpdateTime(now);
        created.setTradingAccountId(account.getId());
        created.setRevision(1L);
        created.setCurrentPercentage(DEFAULT_LOSS_PERCENTAGE);
        created.setCurrentAmount(roundedLossAmount(
                account.getTotalMarginBalance(),
                DEFAULT_LOSS_PERCENTAGE
        ));
        created.setBalanceSnapshot(normalizeBalance(
                account.getTotalMarginBalance()
        ));
        created.setSettlementAsset(account.getQuoteAsset());
        created.setVersion(0L);
        if (lossLimitMapper.insertLimit(created) == 1) {
            return created;
        }
        return lossLimitMapper.selectByAccount(account.getId());
    }

    private TradingOrderSettings ensureOrderSettings(TradingAccount account) {
        TradingOrderSettings current = orderSettingsMapper.selectByAccount(
                account.getId()
        );
        if (current != null) {
            return current;
        }
        LocalDateTime now = LocalDateTime.now();
        TradingOrderSettings created = new TradingOrderSettings();
        created.setId(UUID.randomUUID().toString());
        created.setCreateTime(now);
        created.setUpdateTime(now);
        created.setTradingAccountId(account.getId());
        created.setRevision(1L);
        created.setEntryOrderType(MAKER_ONLY);
        created.setTakeProfitOrderType(MAKER_ONLY);
        created.setStopLossOrderType(MARKET);
        created.setVersion(0L);
        if (orderSettingsMapper.insertSettings(created) == 1) {
            return created;
        }
        return orderSettingsMapper.selectByAccount(account.getId());
    }

    private ValidatedOrderSettings validateOrderSettings(
            String accountId,
            OrderSettingsCommand command
    ) {
        if (command == null) {
            throw badRequest("请填写下单设置");
        }
        String strategyId = normalizedOptionalId(
                command.defaultExitStrategyId()
        );
        if (strategyId != null) {
            requireStrategy(accountId, strategyId);
        }

        String entryType = normalizedOrderType(
                command.entryOrderType(),
                false,
                "建仓方式"
        );
        String takeProfitType = normalizedOrderType(
                command.takeProfitOrderType(),
                false,
                "止盈方式"
        );
        String stopLossType = normalizedOrderType(
                command.stopLossOrderType(),
                true,
                "止损方式"
        );

        BigDecimal fallbackR = command.fallbackMarketStopR();
        if (LIMIT.equals(stopLossType)) {
            if (fallbackR == null
                    || fallbackR.compareTo(BigDecimal.ONE) <= 0) {
                throw badRequest("保底市价止损必须大于1R");
            }
        } else if (fallbackR != null) {
            throw badRequest("只有限价止损可以设置保底市价止损");
        }

        return new ValidatedOrderSettings(
                strategyId,
                entryType,
                takeProfitType,
                stopLossType,
                fallbackR
        );
    }

    private String normalizedOrderType(
            String value,
            boolean allowsNone,
            String fieldName
    ) {
        String normalized = value == null
                ? ""
                : value.trim().toUpperCase(Locale.ROOT);
        if (MAKER_ONLY.equals(normalized)
                || LIMIT.equals(normalized)
                || MARKET.equals(normalized)
                || (allowsNone && NONE.equals(normalized))) {
            return normalized;
        }
        throw badRequest(fieldName + "无效");
    }

    private String normalizedOptionalId(String value) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        return value.trim();
    }

    private OrderSettingsView toOrderSettingsView(
            TradingOrderSettings settings,
            TradingAccount account
    ) {
        String accountId = account.getId();
        String strategyName = null;
        if (settings.getDefaultExitStrategyId() != null) {
            TradingExitStrategy strategy = strategyMapper.selectOwned(
                    settings.getDefaultExitStrategyId(),
                    accountId
            );
            if (strategy != null) {
                strategyName = strategy.getStrategyName();
            }
        }
        return new OrderSettingsView(
                accountId,
                settings.getRevision(),
                settings.getDefaultExitStrategyId(),
                strategyName,
                settings.getEntryOrderType(),
                settings.getTakeProfitOrderType(),
                settings.getStopLossOrderType(),
                settings.getFallbackMarketStopR()
        );
    }

    private TradingLossLimit promotePendingIfDue(TradingLossLimit limit) {
        if (limit.getPendingEffectiveAtMs() == null
                || limit.getPendingEffectiveAtMs()
                > currentTimeMillis.getAsLong()) {
            return limit;
        }
        limit.setCurrentPercentage(limit.getPendingPercentage());
        limit.setCurrentAmount(limit.getPendingAmount());
        clearPending(limit);
        limit.setRevision(limit.getRevision() + 1);
        limit.setUpdateTime(LocalDateTime.now());
        requireUpdated(lossLimitMapper.updateLimit(limit));
        limit.setVersion(limit.getVersion() + 1);
        return limit;
    }

    private void clearPending(TradingLossLimit limit) {
        limit.setPendingPercentage(null);
        limit.setPendingAmount(null);
        limit.setPendingEffectiveAtMs(null);
    }

    private TradingExitStrategy requireStrategy(
            String accountId,
            String strategyId
    ) {
        TradingExitStrategy strategy = strategyMapper.selectOwned(
                strategyId,
                accountId
        );
        if (strategy == null) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "止盈止损策略不存在"
            );
        }
        return strategy;
    }

    private TradingAccount requireActiveAccount(
            String userId,
            String accountId
    ) {
        TradingAccount account = accountMapper.selectActiveOwned(
                accountId,
                userId
        );
        if (account == null) {
            throw new TradingApiException(
                    HttpStatus.NOT_FOUND,
                    "交易账户不存在或尚未绑定"
            );
        }
        return account;
    }

    private void requireFeatureEnabled() {
        if (!properties.isEnabled()) {
            throw new TradingApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "服务器交易账户功能未启用"
            );
        }
    }

    private void requireRange(
            BigDecimal value,
            BigDecimal minimum,
            BigDecimal maximum,
            String message
    ) {
        if (value == null
                || value.compareTo(minimum) < 0
                || value.compareTo(maximum) > 0) {
            throw badRequest(message);
        }
    }

    private String normalizedMode(String value) {
        String mode = value == null
                ? "NONE"
                : value.trim().toUpperCase(Locale.ROOT);
        return switch (mode) {
            case "NONE", "FIXED_R", "TRAILING_PROFIT_R" -> mode;
            default -> throw badRequest("不支持的移动止损方式");
        };
    }

    private BigDecimal normalizedReduction(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private void requireUpdated(int rows) {
        if (rows != 1) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "配置已发生变化，请刷新后重试"
            );
        }
    }

    private TradingApiException badRequest(String message) {
        return new TradingApiException(HttpStatus.BAD_REQUEST, message);
    }

    private static BigDecimal normalizeBalance(BigDecimal balance) {
        return balance == null || balance.signum() < 0
                ? BigDecimal.ZERO
                : balance;
    }

    public record ExitStrategyCommand(
            String name,
            List<ExitStrategyLevelCommand> levels
    ) {
    }

    public record ExitStrategyLevelCommand(
            BigDecimal triggerR,
            BigDecimal reducePercent,
            String moveStopMode,
            BigDecimal moveStopR
    ) {
    }

    public record ExitStrategyView(
            String id,
            String name,
            long revision,
            List<ExitStrategyLevelView> levels
    ) {
    }

    public record ExitStrategyLevelView(
            String id,
            int level,
            BigDecimal triggerR,
            BigDecimal reducePercent,
            String moveStopMode,
            BigDecimal moveStopR
    ) {
        static ExitStrategyLevelView from(TradingExitStrategyLevel level) {
            return new ExitStrategyLevelView(
                    level.getId(),
                    level.getLevelNo(),
                    level.getTriggerR(),
                    level.getReducePercent(),
                    level.getMoveStopMode(),
                    level.getMoveStopR()
            );
        }

        static ExitStrategyLevelView from(
                ExitStrategyLevelCommand level,
                int levelNumber
        ) {
            return new ExitStrategyLevelView(
                    null,
                    levelNumber,
                    level.triggerR(),
                    level.reducePercent() == null
                            ? BigDecimal.ZERO
                            : level.reducePercent(),
                    level.moveStopMode() == null
                            ? "NONE"
                            : level.moveStopMode().toUpperCase(Locale.ROOT),
                    level.moveStopR()
            );
        }
    }

    public record LossLimitView(
            String accountId,
            long revision,
            int currentPercentage,
            BigDecimal currentAmount,
            Integer pendingPercentage,
            BigDecimal pendingAmount,
            Long pendingEffectiveAtMillis,
            BigDecimal accountBalance,
            String settlementAsset
    ) {
        static LossLimitView from(
                TradingLossLimit limit,
                TradingAccount account
        ) {
            return new LossLimitView(
                    account.getId(),
                    limit.getRevision(),
                    limit.getCurrentPercentage(),
                    limit.getCurrentAmount(),
                    limit.getPendingPercentage(),
                    limit.getPendingAmount(),
                    limit.getPendingEffectiveAtMs(),
                    normalizeBalance(account.getTotalMarginBalance()),
                    account.getQuoteAsset()
            );
        }
    }

    public record OrderSettingsCommand(
            String defaultExitStrategyId,
            String entryOrderType,
            String takeProfitOrderType,
            String stopLossOrderType,
            BigDecimal fallbackMarketStopR
    ) {
    }

    private record ValidatedOrderSettings(
            String defaultExitStrategyId,
            String entryOrderType,
            String takeProfitOrderType,
            String stopLossOrderType,
            BigDecimal fallbackMarketStopR
    ) {
    }

    public record OrderSettingsView(
            String accountId,
            long revision,
            String defaultExitStrategyId,
            String defaultExitStrategyName,
            String entryOrderType,
            String takeProfitOrderType,
            String stopLossOrderType,
            BigDecimal fallbackMarketStopR
    ) {
    }

    record TradingExecutionConfiguration(
            TradingLossLimit lossLimit,
            TradingOrderSettings orderSettings,
            TradingExitStrategy exitStrategy,
            List<TradingExitStrategyLevel> levels
    ) {
    }
}
