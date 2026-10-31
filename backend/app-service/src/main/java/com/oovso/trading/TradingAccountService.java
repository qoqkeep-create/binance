package com.oovso.trading;

import com.oovso.binance.BinanceContinuousKlineProperties;
import com.oovso.trading.BinanceUsdmPrivateGateway.LeverageBracket;
import com.oovso.trading.BinanceUsdmPrivateGateway.LeverageSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.PositionSnapshot;
import com.oovso.trading.BinanceUsdmPrivateGateway.SymbolRules;
import com.oovso.trading.BinanceUsdmPrivateGateway.VerifiedAccount;
import com.oovso.trading.TradingCredentialCipher.EncryptedCredential;
import com.oovso.trading.TradingPositionHistoryProjector.CurrentFill;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class TradingAccountService {

    private static final Logger log = LoggerFactory.getLogger(
            TradingAccountService.class
    );

    private static final BigDecimal DEFAULT_TAKE_PROFIT = new BigDecimal("3");
    private static final BigDecimal DEFAULT_STOP_LOSS = new BigDecimal("1.5");
    private static final BigDecimal DEFAULT_MAX_LOSS = new BigDecimal("5");

    private final TradingProperties properties;
    private final BinanceContinuousKlineProperties marketProperties;
    private final TradingCredentialCipher credentialCipher;
    private final BinanceUsdmPrivateGateway privateGateway;
    private final TradingAccountMapper accountMapper;
    private final TradingRiskPolicyMapper riskPolicyMapper;
    private final TradingPositionMapper positionMapper;
    private final TransactionTemplate transactionTemplate;
    private TradingAccountSessionManager sessionManager;

    public TradingAccountService(
            TradingProperties properties,
            BinanceContinuousKlineProperties marketProperties,
            TradingCredentialCipher credentialCipher,
            BinanceUsdmPrivateGateway privateGateway,
            TradingAccountMapper accountMapper,
            TradingRiskPolicyMapper riskPolicyMapper,
            TradingPositionMapper positionMapper,
            PlatformTransactionManager transactionManager
    ) {
        this.properties = properties;
        this.marketProperties = marketProperties;
        this.credentialCipher = credentialCipher;
        this.privateGateway = privateGateway;
        this.accountMapper = accountMapper;
        this.riskPolicyMapper = riskPolicyMapper;
        this.positionMapper = positionMapper;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
    }

    @Autowired(required = false)
    void setSessionManager(TradingAccountSessionManager sessionManager) {
        this.sessionManager = sessionManager;
    }

    public List<AccountView> accounts(String userId) {
        requireFeatureEnabled();
        TradingAccount account = accountMapper.selectByUser(userId);
        if (account == null || "DISABLED".equals(account.getStatus())
                || "PENDING_VERIFICATION".equals(account.getStatus())) {
            return List.of();
        }
        return List.of(accountView(account));
    }

    public AccountView bind(
            String userId,
            String apiKey,
            String secretKey
    ) {
        requireFeatureEnabled();
        String preferredAsset = configuredQuoteAsset();
        TradingAccount stored = accountMapper.selectByUser(userId);
        TradingAccount account = stored == null
                ? newAccount(userId, preferredAsset)
                : stored;
        ensureAccountIdentity(account, userId, preferredAsset);

        BinanceCredentials credentials = new BinanceCredentials(
                apiKey.trim(),
                secretKey.trim()
        );
        privateGateway.verify(
                credentials,
                preferredAsset
        );
        try {
            BinanceUsdmPrivateGateway.AccountSetupResult setup =
                    privateGateway.enforceHedgeModeAndMaximumLeverage(
                            credentials,
                            preferredAsset
                    );
            log.info(
                    "Binance account defaults configured during binding "
                            + "accountId={} positionMode={} symbols={}",
                    account.getId(),
                    setup.positionMode(),
                    setup.configuredSymbolCount()
            );
        } catch (BinancePrivateApiException exception) {
            throw BinanceErrorTranslator.tradingApiException(exception);
        }
        VerifiedAccount snapshot = privateGateway.verify(
                credentials,
                preferredAsset
        );
        if (!"HEDGE".equals(snapshot.positionMode())) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "币安账户未能切换为双向持仓模式"
            );
        }
        EncryptedCredential encrypted = credentialCipher.encrypt(
                userId,
                account,
                credentials
        );
        applyBinding(account, encrypted, snapshot);

        transactionTemplate.executeWithoutResult(status -> {
            if (stored == null) {
                accountMapper.insertAccount(account);
            } else {
                requireUpdated(accountMapper.updateBinding(account));
            }
            ensureDefaultRiskPolicy(account);
            synchronizePositions(account, snapshot.positions());
        });

        if (sessionManager != null) {
            sessionManager.restartAccount(account.getId());
        }

        return accountView(account);
    }

    public AccountView refresh(String userId, String accountId) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        BinanceCredentials credentials = credentialCipher.decrypt(
                userId,
                account
        );
        VerifiedAccount snapshot = privateGateway.verify(
                credentials,
                account.getQuoteAsset()
        );
        applySnapshot(account, snapshot);

        transactionTemplate.executeWithoutResult(status -> {
            requireUpdated(accountMapper.updateSnapshot(account));
            synchronizePositions(account, snapshot.positions());
        });
        if (sessionManager != null) {
            sessionManager.requestReconcile(accountId);
        }
        return accountView(account);
    }

    public LeverageView leverage(
            String userId,
            String accountId,
            String symbol
    ) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        String normalized = requireAccountSymbol(account, symbol);
        BinanceCredentials credentials = credentialCipher.decrypt(
                userId,
                account
        );
        try {
            return LeverageView.from(privateGateway.leverage(
                    credentials,
                    normalized
            ));
        } catch (BinancePrivateApiException exception) {
            throw BinanceErrorTranslator.tradingApiException(exception);
        }
    }

    public LeverageView updateLeverage(
            String userId,
            String accountId,
            String symbol,
            int leverage
    ) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        String normalized = requireAccountSymbol(account, symbol);
        BinanceCredentials credentials = credentialCipher.decrypt(
                userId,
                account
        );
        try {
            LeverageView updated = LeverageView.from(
                    privateGateway.changeLeverage(
                            credentials,
                            normalized,
                            leverage
                    )
            );
            positionMapper.updateLeverageBySymbol(
                    accountId,
                    normalized,
                    updated.leverage()
            );
            if (sessionManager != null) {
                sessionManager.requestReconcile(accountId);
            }
            return updated;
        } catch (BinancePrivateApiException exception) {
            throw BinanceErrorTranslator.tradingApiException(exception);
        } catch (IllegalArgumentException exception) {
            throw badRequest(exception.getMessage());
        }
    }

    public void unbind(String userId, String accountId) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        transactionTemplate.executeWithoutResult(status -> {
            requireUpdated(accountMapper.disable(accountId, userId));
            positionMapper.closeAll(accountId);
        });
        if (sessionManager != null) {
            sessionManager.stopAccount(accountId);
        }
    }

    public List<PositionView> positions(String userId, String accountId) {
        requireFeatureEnabled();
        requireActiveAccount(userId, accountId);
        return positionMapper.selectOpenByAccount(accountId).stream()
                .map(PositionView::from)
                .toList();
    }

    public RiskPolicyView riskPolicy(String userId, String accountId) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        TradingRiskPolicy policy = riskPolicyMapper.selectByAccount(accountId);
        if (policy == null) {
            policy = transactionTemplate.execute(status -> {
                TradingRiskPolicy current = riskPolicyMapper.selectByAccount(
                        accountId
                );
                if (current != null) {
                    return current;
                }
                TradingRiskPolicy created = defaultRiskPolicy(account);
                riskPolicyMapper.insertPolicy(created);
                return created;
            });
        }
        return RiskPolicyView.from(policy);
    }

    public RiskPolicyView updateRiskPolicy(
            String userId,
            String accountId,
            RiskPolicyCommand command
    ) {
        requireFeatureEnabled();
        TradingAccount account = requireActiveAccount(userId, accountId);
        validateRiskPolicy(command);

        TradingRiskPolicy updated = transactionTemplate.execute(status -> {
            TradingRiskPolicy policy = riskPolicyMapper.selectByAccount(accountId);
            if (policy == null) {
                policy = defaultRiskPolicy(account);
                riskPolicyMapper.insertPolicy(policy);
            }
            policy.setUpdateTime(LocalDateTime.now());
            policy.setPolicyRevision(policy.getPolicyRevision() + 1);
            policy.setEnabledState(booleanState(command.enabled()));
            policy.setTakeProfitEnabled(
                    booleanState(command.takeProfitEnabled())
            );
            policy.setStopLossEnabled(booleanState(command.stopLossEnabled()));
            policy.setTakeProfitPercent(command.takeProfitPercent());
            policy.setStopLossPercent(command.stopLossPercent());
            policy.setMaxLossAmount(command.maxLossAmount());
            policy.setSettlementAsset(account.getQuoteAsset());
            policy.setWorkingType("MARK_PRICE");
            requireUpdated(riskPolicyMapper.updatePolicy(policy));
            return policy;
        });
        return RiskPolicyView.from(updated);
    }

    private TradingAccount newAccount(String userId, String quoteAsset) {
        LocalDateTime now = LocalDateTime.now();
        TradingAccount account = new TradingAccount();
        account.setId(UUID.randomUUID().toString());
        account.setCreateTime(now);
        account.setUpdateTime(now);
        account.setDeleteState(0);
        account.setAppUserId(userId);
        account.setExchange("BINANCE");
        account.setMarketType("USDM");
        account.setEnvironment("LIVE");
        account.setLabel("实盘");
        account.setQuoteAsset(quoteAsset);
        account.setPositionMode("UNKNOWN");
        account.setStatus("PENDING_VERIFICATION");
        account.setSyncStatus(TradingSyncStatus.STOPPED.name());
        account.setTotalMarginBalance(BigDecimal.ZERO);
        account.setUnrealizedProfit(BigDecimal.ZERO);
        account.setStreamGeneration(0L);
        account.setConsecutiveSyncFailureCount(0);
        account.setReconcileRevision(0L);
        account.setExecutionFenceToken(0L);
        account.setVersion(0L);
        return account;
    }

    private void ensureAccountIdentity(
            TradingAccount account,
            String userId,
            String quoteAsset
    ) {
        account.setAppUserId(userId);
        account.setExchange("BINANCE");
        account.setMarketType("USDM");
        account.setEnvironment("LIVE");
        account.setLabel("实盘");
        account.setQuoteAsset(quoteAsset);
    }

    private void applyBinding(
            TradingAccount account,
            EncryptedCredential encrypted,
            VerifiedAccount snapshot
    ) {
        long nowMillis = snapshot.syncedAtMillis();
        account.setCredentialCiphertext(encrypted.ciphertext());
        account.setCredentialNonce(encrypted.nonce());
        account.setCredentialFingerprint(encrypted.fingerprint());
        account.setApiKeyMasked(encrypted.apiKeyMasked());
        account.setCredentialKeyVersion(encrypted.keyVersion());
        account.setStatus("ACTIVE");
        account.setSyncStatus(properties.getSync().isEnabled()
                ? TradingSyncStatus.CONNECTING.name()
                : TradingSyncStatus.STOPPED.name());
        account.setLastVerifiedAtMs(nowMillis);
        applySnapshot(account, snapshot);
    }

    private void applySnapshot(
            TradingAccount account,
            VerifiedAccount snapshot
    ) {
        account.setUpdateTime(LocalDateTime.now());
        account.setQuoteAsset(snapshot.asset());
        account.setPositionMode(snapshot.positionMode());
        account.setTotalMarginBalance(snapshot.totalMarginBalance());
        account.setUnrealizedProfit(snapshot.unrealizedProfit());
        account.setLastSyncedAtMs(snapshot.syncedAtMillis());
    }

    private void synchronizePositions(
            TradingAccount account,
            List<PositionSnapshot> snapshots
    ) {
        List<TradingPosition> stored = positionMapper.selectByAccount(
                account.getId()
        );
        Map<PositionKey, TradingPosition> storedByKey = new HashMap<>();
        for (TradingPosition position : stored) {
            storedByKey.put(PositionKey.from(position), position);
        }

        Set<PositionKey> seen = new HashSet<>();
        LocalDateTime now = LocalDateTime.now();
        for (PositionSnapshot snapshot : snapshots) {
            PositionKey key = new PositionKey(
                    snapshot.symbol(),
                    snapshot.positionSide()
            );
            seen.add(key);
            TradingPosition current = storedByKey.get(key);
            TradingPosition position = toPosition(
                    account.getId(),
                    snapshot,
                    current,
                    now
            );
            positionMapper.upsert(position);
        }

        for (TradingPosition existing : stored) {
            if ("OPEN".equals(existing.getStatus())
                    && !seen.contains(PositionKey.from(existing))) {
                positionMapper.closeById(existing.getId(), account.getId());
            }
        }
    }

    private TradingPosition toPosition(
            String accountId,
            PositionSnapshot snapshot,
            TradingPosition current,
            LocalDateTime now
    ) {
        TradingPosition position = new TradingPosition();
        position.setId(current == null
                ? UUID.randomUUID().toString()
                : current.getId());
        position.setCreateTime(current == null ? now : current.getCreateTime());
        position.setUpdateTime(now);
        position.setTradingAccountId(accountId);
        position.setSymbol(snapshot.symbol());
        position.setPositionSide(snapshot.positionSide());
        long generation = current == null ? 1 : current.getGeneration();
        if (current != null && "CLOSED".equals(current.getStatus())) {
            generation++;
        }
        position.setGeneration(generation);
        position.setQuantity(snapshot.quantity());
        position.setEntryPrice(snapshot.entryPrice());
        position.setBreakEvenPrice(snapshot.breakEvenPrice());
        position.setMarkPrice(snapshot.markPrice());
        position.setLiquidationPrice(snapshot.liquidationPrice());
        position.setLeverage(snapshot.leverage());
        position.setMarginType(snapshot.marginType());
        position.setIsolatedMargin(snapshot.isolatedMargin());
        position.setUnrealizedProfit(snapshot.unrealizedProfit());
        position.setStatus("OPEN");
        position.setExchangeUpdateMs(snapshot.exchangeUpdateMillis());
        position.setLastEventMs(current == null || current.getLastEventMs() == null
                ? 0L
                : current.getLastEventMs());
        position.setLastReconcileRevision(
                current == null || current.getLastReconcileRevision() == null
                        ? 0L
                        : current.getLastReconcileRevision()
        );
        position.setContinuityStatus(current == null
                || "CLOSED".equals(current.getStatus())
                ? "UNCERTAIN"
                : current.getContinuityStatus() == null
                        ? "CONTINUOUS"
                        : current.getContinuityStatus());
        position.setSource("REST");
        position.setVersion(current == null ? 0L : current.getVersion());
        return position;
    }

    private void ensureDefaultRiskPolicy(TradingAccount account) {
        if (riskPolicyMapper.selectByAccount(account.getId()) == null) {
            riskPolicyMapper.insertPolicy(defaultRiskPolicy(account));
        }
    }

    private TradingRiskPolicy defaultRiskPolicy(TradingAccount account) {
        LocalDateTime now = LocalDateTime.now();
        TradingRiskPolicy policy = new TradingRiskPolicy();
        policy.setId(UUID.randomUUID().toString());
        policy.setCreateTime(now);
        policy.setUpdateTime(now);
        policy.setTradingAccountId(account.getId());
        policy.setPolicyRevision(1L);
        policy.setEnabledState(0);
        policy.setTakeProfitEnabled(1);
        policy.setStopLossEnabled(1);
        policy.setTakeProfitPercent(DEFAULT_TAKE_PROFIT);
        policy.setStopLossPercent(DEFAULT_STOP_LOSS);
        policy.setMaxLossAmount(DEFAULT_MAX_LOSS);
        policy.setSettlementAsset(account.getQuoteAsset());
        policy.setWorkingType("MARK_PRICE");
        policy.setVersion(0L);
        return policy;
    }

    private void validateRiskPolicy(RiskPolicyCommand command) {
        if (command.enabled()
                && !command.takeProfitEnabled()
                && !command.stopLossEnabled()) {
            throw badRequest("至少开启一项止盈或止损保护");
        }
        requireRange(
                command.takeProfitPercent(),
                new BigDecimal("0.1"),
                new BigDecimal("100"),
                "止盈比例应在0.1%到100%之间"
        );
        requireRange(
                command.stopLossPercent(),
                new BigDecimal("0.1"),
                new BigDecimal("100"),
                "止损比例应在0.1%到100%之间"
        );
        requireRange(
                command.maxLossAmount(),
                BigDecimal.ONE,
                new BigDecimal("1000000"),
                "单笔止损额应在1到1,000,000之间"
        );
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

    private void requireUpdated(int updatedRows) {
        if (updatedRows != 1) {
            throw new TradingApiException(
                    HttpStatus.CONFLICT,
                    "交易账户状态已变化，请刷新后重试"
            );
        }
    }

    private String configuredQuoteAsset() {
        String quoteAsset = marketProperties.getQuoteAsset();
        return quoteAsset == null || quoteAsset.isBlank()
                ? "USDC"
                : quoteAsset.trim().toUpperCase(Locale.ROOT);
    }

    private String requireAccountSymbol(
            TradingAccount account,
            String symbol
    ) {
        String normalized = symbol == null
                ? ""
                : symbol.trim().toUpperCase(Locale.ROOT);
        if (normalized.isEmpty()) {
            throw badRequest("请选择交易对");
        }
        try {
            SymbolRules rules = privateGateway.symbolRules(normalized);
            if (!"TRADING".equalsIgnoreCase(rules.status())
                    || !account.getQuoteAsset().equalsIgnoreCase(
                            rules.quoteAsset()
                    )) {
                throw badRequest("只能设置当前报价资产下正在交易的永续合约杠杆");
            }
        } catch (BinancePrivateApiException exception) {
            throw BinanceErrorTranslator.tradingApiException(exception);
        }
        return normalized;
    }

    private int booleanState(boolean value) {
        return value ? 1 : 0;
    }

    private TradingApiException badRequest(String message) {
        return new TradingApiException(HttpStatus.BAD_REQUEST, message);
    }

    AccountView accountView(TradingAccount account) {
        boolean canExecute = properties.getSync().isEnabled()
                && "ACTIVE".equals(account.getStatus())
                && TradingSyncStatus.SYNCED.name().equals(
                        account.getSyncStatus()
                );
        return AccountView.from(account, canExecute);
    }

    private record PositionKey(String symbol, String positionSide) {
        static PositionKey from(TradingPosition position) {
            return new PositionKey(
                    position.getSymbol(),
                    position.getPositionSide()
            );
        }
    }

    public record RiskPolicyCommand(
            boolean enabled,
            boolean takeProfitEnabled,
            boolean stopLossEnabled,
            BigDecimal takeProfitPercent,
            BigDecimal stopLossPercent,
            BigDecimal maxLossAmount
    ) {
    }

    public record AccountView(
            String id,
            String label,
            String status,
            String syncStatus,
            String apiKeyMasked,
            String quoteAsset,
            String positionMode,
            BigDecimal totalMarginBalance,
            BigDecimal unrealizedProfit,
            Long lastVerifiedAtMillis,
            Long lastSyncedAtMillis,
            Long lastStreamEventAtMillis,
            Long lastReconciledAtMillis,
            String degradedReason,
            String degradedMessage,
            boolean canExecute,
            long snapshotRevision
    ) {
        static AccountView from(
                TradingAccount account,
                boolean canExecute
        ) {
            return new AccountView(
                    account.getId(),
                    account.getLabel(),
                    account.getStatus(),
                    account.getSyncStatus() == null
                            ? TradingSyncStatus.STOPPED.name()
                            : account.getSyncStatus(),
                    account.getApiKeyMasked(),
                    account.getQuoteAsset(),
                    account.getPositionMode(),
                    account.getTotalMarginBalance(),
                    account.getUnrealizedProfit(),
                    account.getLastVerifiedAtMs(),
                    account.getLastSyncedAtMs(),
                    account.getLastStreamEventMs(),
                    account.getLastReconciledAtMs(),
                    account.getLastSyncErrorCode(),
                    BinanceErrorTranslator.storedErrorMessage(
                            account.getLastSyncErrorCode()
                    ),
                    canExecute,
                    account.getReconcileRevision() == null
                            ? 0L
                            : account.getReconcileRevision()
            );
        }
    }

    public record PositionView(
            String id,
            String symbol,
            String positionSide,
            long generation,
            BigDecimal quantity,
            BigDecimal entryPrice,
            BigDecimal breakEvenPrice,
            BigDecimal markPrice,
            BigDecimal liquidationPrice,
            int leverage,
            String marginType,
            BigDecimal isolatedMargin,
            BigDecimal unrealizedProfit,
            long exchangeUpdateMillis,
            String makerCloseOrderId,
            BigDecimal makerClosePrice,
            String makerCloseStatus,
            boolean makerCloseCancelable,
            List<BigDecimal> takeProfitPrices,
            List<BigDecimal> stopLossPrices,
            BigDecimal realizedPnl,
            List<PositionRealizedFillView> realizedPnlDetails
    ) {
        static PositionView from(TradingPosition position) {
            return from(
                    position,
                    null,
                    List.of(),
                    List.of(),
                    BigDecimal.ZERO,
                    List.of()
            );
        }

        static PositionView from(
                TradingPosition position,
                ExchangeOrder makerCloseOrder,
                List<BigDecimal> takeProfitPrices,
                List<BigDecimal> stopLossPrices,
                BigDecimal realizedPnl,
                List<PositionRealizedFillView> realizedPnlDetails
        ) {
            return new PositionView(
                    position.getId(),
                    position.getSymbol(),
                    position.getPositionSide(),
                    position.getGeneration(),
                    position.getQuantity(),
                    position.getEntryPrice(),
                    position.getBreakEvenPrice(),
                    position.getMarkPrice(),
                    position.getLiquidationPrice(),
                    position.getLeverage(),
                    position.getMarginType(),
                    position.getIsolatedMargin(),
                    position.getUnrealizedProfit(),
                    position.getExchangeUpdateMs(),
                    makerCloseOrder == null ? null : makerCloseOrder.getId(),
                    makerCloseOrder == null ? null : makerCloseOrder.getPrice(),
                    makerCloseOrder == null ? null : makerCloseOrder.getStatus(),
                    makerCloseOrder != null
                            && TradingOrderStateMachine.isRegularActive(
                                    makerCloseOrder.getStatus()
                            ),
                    takeProfitPrices == null ? List.of() : takeProfitPrices,
                    stopLossPrices == null ? List.of() : stopLossPrices,
                    realizedPnl == null ? BigDecimal.ZERO : realizedPnl,
                    realizedPnlDetails == null
                            ? List.of()
                            : realizedPnlDetails
            );
        }
    }

    public record PositionRealizedFillView(
            String id,
            String side,
            BigDecimal price,
            BigDecimal quantity,
            BigDecimal realizedPnl,
            BigDecimal commission,
            String commissionAsset,
            boolean maker,
            long tradeTimeMillis
    ) {
        static PositionRealizedFillView from(CurrentFill fill) {
            return new PositionRealizedFillView(
                    fill.id(),
                    fill.side(),
                    fill.price(),
                    fill.quantity(),
                    fill.realizedPnl(),
                    fill.commission(),
                    fill.commissionAsset(),
                    fill.maker(),
                    fill.tradeTimeMillis()
            );
        }
    }

    public record LeverageView(
            String symbol,
            int leverage,
            int maxLeverage,
            BigDecimal maxNotionalValue,
            List<LeverageBracket> brackets
    ) {
        static LeverageView from(LeverageSnapshot snapshot) {
            return new LeverageView(
                    snapshot.symbol(),
                    snapshot.leverage(),
                    snapshot.maxLeverage(),
                    snapshot.maxNotionalValue(),
                    snapshot.brackets()
            );
        }
    }

    public record RiskPolicyView(
            String accountId,
            long revision,
            boolean enabled,
            boolean takeProfitEnabled,
            boolean stopLossEnabled,
            BigDecimal takeProfitPercent,
            BigDecimal stopLossPercent,
            BigDecimal maxLossAmount,
            String settlementAsset,
            String workingType
    ) {
        static RiskPolicyView from(TradingRiskPolicy policy) {
            return new RiskPolicyView(
                    policy.getTradingAccountId(),
                    policy.getPolicyRevision(),
                    policy.getEnabledState() == 1,
                    policy.getTakeProfitEnabled() == 1,
                    policy.getStopLossEnabled() == 1,
                    policy.getTakeProfitPercent(),
                    policy.getStopLossPercent(),
                    policy.getMaxLossAmount(),
                    policy.getSettlementAsset(),
                    policy.getWorkingType()
            );
        }
    }
}
