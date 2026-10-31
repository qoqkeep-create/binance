package com.oovso.strategy;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "strategy.super-ema-pullback")
public class SuperEmaPullbackStrategyProperties {

    private boolean enabled = true;

    private String interval = "1h";

    private int historySize = 1_500;

    private FifteenMinute fifteenMinute = new FifteenMinute();

    private FourHour fourHour = new FourHour();

    private int emaMiddlePeriod = 55;

    private int emaPeriod = 144;

    private int superAtrPeriod = 10;

    private double superMultiplier = 6.0;

    private double pullbackTouchToleranceAtrMultiple = 0.1;

    private double pullbackTouchToleranceMaxRate = 0.002;

    private boolean emaCloseConfirmationRequired = false;

    private double emaBreakAllowRate = 0.003;

    private int reversalLookaheadBars = 3;

    private boolean reversalPatternRequired = false;

    private int maxWaitPullbackBars = 30;

    private int relativeExtremeLookbackBars = 5;

    private int relativeExtremeMinComparisonBars = 3;

    private double relativeExtremeMinQualifyingRatio = 0.6;

    private double relativeExtremeToleranceAtrMultiple = 0.5;

    private double relativeExtremeToleranceMaxRate = 0.005;

    private double maxPostTouchMoveAwayAtr = 2.5;

    private double maxPostTouchMoveAwayRate = 0.05;

    private double maxTerminalPatternExtremeDistanceAtr = 0.35;

    private List<String> symbolWhitelist = new ArrayList<>();

    private IndicatorPeriods indicatorPeriods = new IndicatorPeriods();

    private SymbolFilter symbolFilter = new SymbolFilter();

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public String getInterval() {
        return interval;
    }

    public void setInterval(String interval) {
        this.interval = interval;
    }

    public int getHistorySize() {
        return historySize;
    }

    public void setHistorySize(int historySize) {
        this.historySize = historySize;
    }

    public FifteenMinute getFifteenMinute() {
        return fifteenMinute;
    }

    public void setFifteenMinute(FifteenMinute fifteenMinute) {
        this.fifteenMinute = fifteenMinute == null
                ? new FifteenMinute()
                : fifteenMinute;
    }

    public FourHour getFourHour() {
        return fourHour;
    }

    public void setFourHour(FourHour fourHour) {
        this.fourHour = fourHour == null ? new FourHour() : fourHour;
    }

    public int getEmaMiddlePeriod() {
        return emaMiddlePeriod;
    }

    public void setEmaMiddlePeriod(int emaMiddlePeriod) {
        this.emaMiddlePeriod = emaMiddlePeriod;
    }

    public int getEmaPeriod() {
        return emaPeriod;
    }

    public void setEmaPeriod(int emaPeriod) {
        this.emaPeriod = emaPeriod;
    }

    public int getSuperAtrPeriod() {
        return superAtrPeriod;
    }

    public void setSuperAtrPeriod(int superAtrPeriod) {
        this.superAtrPeriod = superAtrPeriod;
    }

    public double getSuperMultiplier() {
        return superMultiplier;
    }

    public void setSuperMultiplier(double superMultiplier) {
        this.superMultiplier = superMultiplier;
    }

    public double getPullbackTouchToleranceAtrMultiple() {
        return pullbackTouchToleranceAtrMultiple;
    }

    public void setPullbackTouchToleranceAtrMultiple(double pullbackTouchToleranceAtrMultiple) {
        this.pullbackTouchToleranceAtrMultiple = pullbackTouchToleranceAtrMultiple;
    }

    public double getPullbackTouchToleranceMaxRate() {
        return pullbackTouchToleranceMaxRate;
    }

    public void setPullbackTouchToleranceMaxRate(double pullbackTouchToleranceMaxRate) {
        this.pullbackTouchToleranceMaxRate = pullbackTouchToleranceMaxRate;
    }

    public boolean isEmaCloseConfirmationRequired() {
        return emaCloseConfirmationRequired;
    }

    public void setEmaCloseConfirmationRequired(boolean emaCloseConfirmationRequired) {
        this.emaCloseConfirmationRequired = emaCloseConfirmationRequired;
    }

    public double getEmaBreakAllowRate() {
        return emaBreakAllowRate;
    }

    public void setEmaBreakAllowRate(double emaBreakAllowRate) {
        this.emaBreakAllowRate = emaBreakAllowRate;
    }

    public int getReversalLookaheadBars() {
        return reversalLookaheadBars;
    }

    public void setReversalLookaheadBars(int reversalLookaheadBars) {
        this.reversalLookaheadBars = reversalLookaheadBars;
    }

    public boolean isReversalPatternRequired() {
        return reversalPatternRequired;
    }

    public void setReversalPatternRequired(boolean reversalPatternRequired) {
        this.reversalPatternRequired = reversalPatternRequired;
    }

    public int getMaxWaitPullbackBars() {
        return maxWaitPullbackBars;
    }

    public void setMaxWaitPullbackBars(int maxWaitPullbackBars) {
        this.maxWaitPullbackBars = maxWaitPullbackBars;
    }

    public int getRelativeExtremeLookbackBars() {
        return relativeExtremeLookbackBars;
    }

    public void setRelativeExtremeLookbackBars(
            int relativeExtremeLookbackBars
    ) {
        this.relativeExtremeLookbackBars = relativeExtremeLookbackBars;
    }

    public int getRelativeExtremeMinComparisonBars() {
        return relativeExtremeMinComparisonBars;
    }

    public void setRelativeExtremeMinComparisonBars(
            int relativeExtremeMinComparisonBars
    ) {
        this.relativeExtremeMinComparisonBars =
                relativeExtremeMinComparisonBars;
    }

    public double getRelativeExtremeMinQualifyingRatio() {
        return relativeExtremeMinQualifyingRatio;
    }

    public void setRelativeExtremeMinQualifyingRatio(
            double relativeExtremeMinQualifyingRatio
    ) {
        this.relativeExtremeMinQualifyingRatio =
                relativeExtremeMinQualifyingRatio;
    }

    public double getRelativeExtremeToleranceAtrMultiple() {
        return relativeExtremeToleranceAtrMultiple;
    }

    public void setRelativeExtremeToleranceAtrMultiple(
            double relativeExtremeToleranceAtrMultiple
    ) {
        this.relativeExtremeToleranceAtrMultiple =
                relativeExtremeToleranceAtrMultiple;
    }

    public double getRelativeExtremeToleranceMaxRate() {
        return relativeExtremeToleranceMaxRate;
    }

    public void setRelativeExtremeToleranceMaxRate(
            double relativeExtremeToleranceMaxRate
    ) {
        this.relativeExtremeToleranceMaxRate =
                relativeExtremeToleranceMaxRate;
    }

    public double getMaxPostTouchMoveAwayAtr() {
        return maxPostTouchMoveAwayAtr;
    }

    public void setMaxPostTouchMoveAwayAtr(double maxPostTouchMoveAwayAtr) {
        this.maxPostTouchMoveAwayAtr = maxPostTouchMoveAwayAtr;
    }

    public double getMaxPostTouchMoveAwayRate() {
        return maxPostTouchMoveAwayRate;
    }

    public void setMaxPostTouchMoveAwayRate(double maxPostTouchMoveAwayRate) {
        this.maxPostTouchMoveAwayRate = maxPostTouchMoveAwayRate;
    }

    public double getMaxTerminalPatternExtremeDistanceAtr() {
        return maxTerminalPatternExtremeDistanceAtr;
    }

    public void setMaxTerminalPatternExtremeDistanceAtr(double maxTerminalPatternExtremeDistanceAtr) {
        this.maxTerminalPatternExtremeDistanceAtr = maxTerminalPatternExtremeDistanceAtr;
    }

    public List<String> getSymbolWhitelist() {
        return symbolWhitelist;
    }

    public void setSymbolWhitelist(List<String> symbolWhitelist) {
        this.symbolWhitelist = symbolWhitelist == null ? new ArrayList<>() : symbolWhitelist;
    }

    public IndicatorPeriods getIndicatorPeriods() {
        return indicatorPeriods;
    }

    public void setIndicatorPeriods(IndicatorPeriods indicatorPeriods) {
        this.indicatorPeriods = indicatorPeriods == null
                ? new IndicatorPeriods()
                : indicatorPeriods;
    }

    public SymbolFilter getSymbolFilter() {
        return symbolFilter;
    }

    public void setSymbolFilter(SymbolFilter symbolFilter) {
        this.symbolFilter = symbolFilter == null ? new SymbolFilter() : symbolFilter;
    }

    public static class FifteenMinute {

        private boolean enabled = true;

        private int historySize = 3_000;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public int getHistorySize() {
            return historySize;
        }

        public void setHistorySize(int historySize) {
            this.historySize = historySize;
        }
    }

    public static class FourHour {

        private boolean enabled = true;

        private int historySize = 500;

        /**
         * Retained for binding older configurations. Four-hour main signals
         * always require strict EMA21/EMA55/EMA144 ordering, regardless of this value.
         */
        private boolean ema144OutermostRequired = true;

        private boolean intrabarAlertEnabled = true;

        private long intrabarAnalysisIntervalMillis = 250;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public int getHistorySize() {
            return historySize;
        }

        public void setHistorySize(int historySize) {
            this.historySize = historySize;
        }

        /** @deprecated Four-hour main signals always require strict EMA ordering. */
        @Deprecated
        public boolean isEma144OutermostRequired() {
            return ema144OutermostRequired;
        }

        /** @deprecated Accepted only to bind older configuration files. */
        @Deprecated
        public void setEma144OutermostRequired(
                boolean ema144OutermostRequired
        ) {
            this.ema144OutermostRequired = ema144OutermostRequired;
        }

        public boolean isIntrabarAlertEnabled() {
            return intrabarAlertEnabled;
        }

        public void setIntrabarAlertEnabled(boolean intrabarAlertEnabled) {
            this.intrabarAlertEnabled = intrabarAlertEnabled;
        }

        public long getIntrabarAnalysisIntervalMillis() {
            return intrabarAnalysisIntervalMillis;
        }

        public void setIntrabarAnalysisIntervalMillis(
                long intrabarAnalysisIntervalMillis
        ) {
            this.intrabarAnalysisIntervalMillis = intrabarAnalysisIntervalMillis;
        }
    }

    public static class IndicatorPeriods {

        private int emaFastPeriod = 21;

        private int macdShortPeriod = 12;

        private int macdLongPeriod = 26;

        private int macdSignalPeriod = 9;

        public int getEmaFastPeriod() {
            return emaFastPeriod;
        }

        public void setEmaFastPeriod(int emaFastPeriod) {
            this.emaFastPeriod = emaFastPeriod;
        }

        public int getMacdShortPeriod() {
            return macdShortPeriod;
        }

        public void setMacdShortPeriod(int macdShortPeriod) {
            this.macdShortPeriod = macdShortPeriod;
        }

        public int getMacdLongPeriod() {
            return macdLongPeriod;
        }

        public void setMacdLongPeriod(int macdLongPeriod) {
            this.macdLongPeriod = macdLongPeriod;
        }

        public int getMacdSignalPeriod() {
            return macdSignalPeriod;
        }

        public void setMacdSignalPeriod(int macdSignalPeriod) {
            this.macdSignalPeriod = macdSignalPeriod;
        }
    }

    public static class SymbolFilter {

        private boolean enabled = true;

        private long initialDelayMillis = 60_000;

        private long refreshIntervalMillis = 3_600_000;

        private long maxSnapshotAgeMillis = 7_200_000;

        private int minListingDays = 180;

        private BigDecimal minQuoteVolume24h = new BigDecimal("50000000");

        private BigDecimal minMedianDailyQuoteVolume30d = new BigDecimal("50000000");

        private BigDecimal minOpenInterestValue = new BigDecimal("20000000");

        private double maxSpreadRate = 0.0005;

        private double maxAbsFundingRate = 0.0005;

        private double maxAbsPriceChangeRate24h = 0.15;

        private double maxAbsOpenInterestChangeRate24h = 0.30;

        private long openInterestRequestDelayMillis = 25;

        private int klineQualityLookbackDays = 30;

        private double maxAbnormalCandleAtrMultiple = 4.0;

        private int maxAbnormalCandleCount = 3;

        private int emaSlopeLookbackBars = 6;

        private int adxPeriod = 14;

        private double minAdx = 20.0;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public long getInitialDelayMillis() {
            return initialDelayMillis;
        }

        public void setInitialDelayMillis(long initialDelayMillis) {
            this.initialDelayMillis = initialDelayMillis;
        }

        public long getRefreshIntervalMillis() {
            return refreshIntervalMillis;
        }

        public void setRefreshIntervalMillis(long refreshIntervalMillis) {
            this.refreshIntervalMillis = refreshIntervalMillis;
        }

        public long getMaxSnapshotAgeMillis() {
            return maxSnapshotAgeMillis;
        }

        public void setMaxSnapshotAgeMillis(long maxSnapshotAgeMillis) {
            this.maxSnapshotAgeMillis = maxSnapshotAgeMillis;
        }

        public int getMinListingDays() {
            return minListingDays;
        }

        public void setMinListingDays(int minListingDays) {
            this.minListingDays = minListingDays;
        }

        public BigDecimal getMinQuoteVolume24h() {
            return minQuoteVolume24h;
        }

        public void setMinQuoteVolume24h(BigDecimal minQuoteVolume24h) {
            this.minQuoteVolume24h = minQuoteVolume24h;
        }

        public BigDecimal getMinMedianDailyQuoteVolume30d() {
            return minMedianDailyQuoteVolume30d;
        }

        public void setMinMedianDailyQuoteVolume30d(BigDecimal minMedianDailyQuoteVolume30d) {
            this.minMedianDailyQuoteVolume30d = minMedianDailyQuoteVolume30d;
        }

        public BigDecimal getMinOpenInterestValue() {
            return minOpenInterestValue;
        }

        public void setMinOpenInterestValue(BigDecimal minOpenInterestValue) {
            this.minOpenInterestValue = minOpenInterestValue;
        }

        public double getMaxSpreadRate() {
            return maxSpreadRate;
        }

        public void setMaxSpreadRate(double maxSpreadRate) {
            this.maxSpreadRate = maxSpreadRate;
        }

        public double getMaxAbsFundingRate() {
            return maxAbsFundingRate;
        }

        public void setMaxAbsFundingRate(double maxAbsFundingRate) {
            this.maxAbsFundingRate = maxAbsFundingRate;
        }

        public double getMaxAbsPriceChangeRate24h() {
            return maxAbsPriceChangeRate24h;
        }

        public void setMaxAbsPriceChangeRate24h(double maxAbsPriceChangeRate24h) {
            this.maxAbsPriceChangeRate24h = maxAbsPriceChangeRate24h;
        }

        public double getMaxAbsOpenInterestChangeRate24h() {
            return maxAbsOpenInterestChangeRate24h;
        }

        public void setMaxAbsOpenInterestChangeRate24h(double maxAbsOpenInterestChangeRate24h) {
            this.maxAbsOpenInterestChangeRate24h = maxAbsOpenInterestChangeRate24h;
        }

        public long getOpenInterestRequestDelayMillis() {
            return openInterestRequestDelayMillis;
        }

        public void setOpenInterestRequestDelayMillis(long openInterestRequestDelayMillis) {
            this.openInterestRequestDelayMillis = openInterestRequestDelayMillis;
        }

        public int getKlineQualityLookbackDays() {
            return klineQualityLookbackDays;
        }

        public void setKlineQualityLookbackDays(int klineQualityLookbackDays) {
            this.klineQualityLookbackDays = klineQualityLookbackDays;
        }

        public double getMaxAbnormalCandleAtrMultiple() {
            return maxAbnormalCandleAtrMultiple;
        }

        public void setMaxAbnormalCandleAtrMultiple(double maxAbnormalCandleAtrMultiple) {
            this.maxAbnormalCandleAtrMultiple = maxAbnormalCandleAtrMultiple;
        }

        public int getMaxAbnormalCandleCount() {
            return maxAbnormalCandleCount;
        }

        public void setMaxAbnormalCandleCount(int maxAbnormalCandleCount) {
            this.maxAbnormalCandleCount = maxAbnormalCandleCount;
        }

        public int getEmaSlopeLookbackBars() {
            return emaSlopeLookbackBars;
        }

        public void setEmaSlopeLookbackBars(int emaSlopeLookbackBars) {
            this.emaSlopeLookbackBars = emaSlopeLookbackBars;
        }

        public int getAdxPeriod() {
            return adxPeriod;
        }

        public void setAdxPeriod(int adxPeriod) {
            this.adxPeriod = adxPeriod;
        }

        public double getMinAdx() {
            return minAdx;
        }

        public void setMinAdx(double minAdx) {
            this.minAdx = minAdx;
        }
    }
}
