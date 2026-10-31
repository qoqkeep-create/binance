package com.oovso.strategy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.oovso.notification.StrategyNotificationPreferenceService;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.transaction.annotation.Transactional;

@ActiveProfiles("test")
@SpringBootTest
@Transactional
class StrategySignalMapperIntegrationTest {

    private static final String FIRST_ID =
            "00000000-0000-0000-0000-000000000001";

    private static final String SECOND_ID =
            "00000000-0000-0000-0000-000000000002";

    @Autowired
    private StrategySignalMapper signalMapper;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Autowired
    private StrategyNotificationPreferenceService notificationPreferences;

    @Autowired
    private StrategySignalQueryService queryService;

    @Test
    void appliesPerUserIntervalPreferencesAndDefaultsMissingSettingsToEnabled() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        insertSignal(SECOND_ID, "ETHUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        String thirdId = "00000000-0000-0000-0000-000000000003";
        insertSignal(thirdId, "SOLUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        jdbcTemplate.update(
                "update strategy_signal set interval_code = '15m' where id = ?",
                FIRST_ID
        );
        jdbcTemplate.update(
                "update strategy_signal set interval_code = '4h' where id = ?",
                thirdId
        );
        notificationPreferences.update("user-a", false, true, false);

        assertEquals(List.of(SECOND_ID), queryService.query("user-a", null)
                .items().stream().map(item -> item.id()).toList());
        assertEquals(3, queryService.query("user-b", null).items().size());
        assertEquals(0, signalMapper.countVisibleById("user-a", FIRST_ID));
        assertEquals(0, signalMapper.countVisibleById("user-a", thirdId));
        assertEquals(1, signalMapper.countVisibleById("user-b", thirdId));

        notificationPreferences.update("user-a", true, false, true);
        assertEquals(List.of(thirdId, FIRST_ID), queryService.query("user-a", null)
                .items().stream().map(item -> item.id()).toList());
    }

    @Test
    void filtersDisabledIntervalsBeforeLimitAndCursorPagination() {
        for (int index = 1; index <= 33; index++) {
            String id = String.format("00000000-0000-0000-0000-%012d", index);
            insertSignal(id, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
            String interval = switch (index % 3) {
                case 0 -> "4h";
                case 1 -> "15m";
                default -> "1h";
            };
            jdbcTemplate.update(
                    "update strategy_signal set interval_code = ? where id = ?",
                    interval,
                    id
            );
        }
        notificationPreferences.update("user-a", false, true, false);

        var first = queryService.query("user-a", null);
        assertEquals(10, first.items().size());
        assertTrue(first.hasNext());
        assertTrue(first.items().stream().allMatch(item -> "1h".equals(item.interval())));

        var second = queryService.query("user-a", first.nextCursor());
        assertEquals(1, second.items().size());
        assertEquals(SECOND_ID, second.items().getFirst().id());
        assertFalse(second.hasNext());
        assertNull(second.nextCursor());
    }

    @Test
    void allIntervalsDisabledReturnsEmptyFeedWithoutDeletingSignals() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        notificationPreferences.update("user-a", false, false, false);

        var page = queryService.query("user-a", null);
        assertTrue(page.items().isEmpty());
        assertFalse(page.hasNext());
        assertNull(page.nextCursor());
        assertEquals(1, queryService.query("user-b", null).items().size());

        notificationPreferences.update("user-a", true, true, true);
        assertEquals(1, queryService.query("user-a", null).items().size());
    }

    @Test
    void pagesEqualTimestampsByIdAndJoinsReadStatePerUser() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        insertSignal(SECOND_ID, "ETHUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        signalMapper.insertReadReceipt("user-a", SECOND_ID, 123L);

        List<StrategySignalFeedRow> firstPage =
                signalMapper.selectFeedPage(
                        "user-a",
                        Long.MAX_VALUE,
                        "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
                        11
                );

        assertEquals(List.of(SECOND_ID, FIRST_ID), firstPage.stream()
                .map(StrategySignalFeedRow::getId)
                .toList());
        assertEquals(1, firstPage.getFirst().getReadState());
        assertEquals(0, firstPage.getLast().getReadState());

        List<StrategySignalFeedRow> nextPage =
                signalMapper.selectFeedPage(
                        "user-a",
                        1_000L,
                        SECOND_ID,
                        11
                );

        assertEquals(1, nextPage.size());
        assertEquals(FIRST_ID, nextPage.getFirst().getId());

        signalMapper.insertUserStateIfMissing("user-a", FIRST_ID, 200L);
        signalMapper.deleteForUser("user-a", FIRST_ID, 201L);
        assertEquals(0, signalMapper.selectFeedPage(
                "user-a",
                Long.MAX_VALUE,
                "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
                11
        ).stream().filter(row -> FIRST_ID.equals(row.getId())).count());
        assertEquals(1, signalMapper.selectFeedPage(
                "user-b",
                Long.MAX_VALUE,
                "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
                11
        ).stream().filter(row -> FIRST_ID.equals(row.getId())).count());
    }

    @Test
    void hidesLegacyGoldenAndDeathCrossSignals() {
        insertSignal(FIRST_ID, "BTCUSDC", "EMA21_55_MACD_GOLDEN_CROSS");
        insertSignal(SECOND_ID, "ETHUSDC", "EMA21_55_MACD_DEATH_CROSS");

        assertEquals(List.of(), signalMapper.selectFeedPage(
                "user-a",
                Long.MAX_VALUE,
                "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
                11
        ));
    }

    @Test
    void selectsFourHourSourceWatchFromOneHourMonitorCycle() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        jdbcTemplate.update(
                "update strategy_signal set exchange = 'BINANCE', "
                        + "market_type = 'USDM', contract_type = 'PERPETUAL', "
                        + "interval_code = '4h' where id = ?",
                FIRST_ID
        );
        signalMapper.insertUserStateIfMissing("user-a", FIRST_ID, 200L);
        signalMapper.activateReversalAlert("user-a", FIRST_ID, 201L);

        List<StrategySignalReversalWatch> watches =
                signalMapper.selectActiveReversalWatches(
                        "BINANCE",
                        "USDM",
                        "PERPETUAL",
                        "BTCUSDC",
                        "1h"
                );

        assertEquals(1, watches.size());
        assertEquals("4h", watches.getFirst().getSourceIntervalCode());
        assertEquals(201L, watches.getFirst().getRequestedTimeMs());
    }

    @Test
    void selectsFifteenMinuteSourceWatchFromFifteenMinuteMonitorCycle() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        jdbcTemplate.update(
                "update strategy_signal set exchange = 'BINANCE', "
                        + "market_type = 'USDM', contract_type = 'PERPETUAL', "
                        + "interval_code = '15m' where id = ?",
                FIRST_ID
        );
        signalMapper.insertUserStateIfMissing("user-a", FIRST_ID, 200L);
        signalMapper.activateReversalAlert("user-a", FIRST_ID, 201L);

        List<StrategySignalReversalWatch> watches =
                signalMapper.selectActiveReversalWatches(
                        "BINANCE",
                        "USDM",
                        "PERPETUAL",
                        "BTCUSDC",
                        "15m"
                );

        assertEquals(1, watches.size());
        assertEquals("15m", watches.getFirst().getSourceIntervalCode());
        assertEquals(201L, watches.getFirst().getRequestedTimeMs());
    }

    @Test
    void triggeredSecondaryAlertCanBeActivatedAgain() {
        insertSignal(FIRST_ID, "BTCUSDC", "SUPER_EMA144_PULLBACK_REVERSAL");
        jdbcTemplate.update(
                "update strategy_signal set exchange = 'BINANCE', "
                        + "market_type = 'USDM', contract_type = 'PERPETUAL', "
                        + "interval_code = '1h' where id = ?",
                FIRST_ID
        );
        signalMapper.insertUserStateIfMissing("user-a", FIRST_ID, 200L);
        assertEquals(
                1,
                signalMapper.activateReversalAlert(
                        "user-a",
                        FIRST_ID,
                        201L
                )
        );
        assertEquals(
                1,
                signalMapper.claimReversalTrigger(
                        "user-a",
                        FIRST_ID,
                        300L,
                        250L,
                        "MACD_MOMENTUM_DECAY"
                )
        );
        assertEquals(
                1,
                signalMapper.activateReversalAlert(
                        "user-a",
                        FIRST_ID,
                        400L
                )
        );

        List<StrategySignalReversalWatch> watches =
                signalMapper.selectActiveReversalWatches(
                        "BINANCE",
                        "USDM",
                        "PERPETUAL",
                        "BTCUSDC",
                        "1h"
                );

        assertEquals(1, watches.size());
        assertEquals(400L, watches.getFirst().getRequestedTimeMs());
        assertEquals("ACTIVE", jdbcTemplate.queryForObject(
                "select reversal_alert_state "
                        + "from strategy_signal_user_state "
                        + "where app_user_id = 'user-a' "
                        + "and strategy_signal_id = ?",
                String.class,
                FIRST_ID
        ));
        assertEquals(0, jdbcTemplate.queryForObject(
                "select count(1) from strategy_signal_user_state "
                        + "where app_user_id = 'user-a' "
                        + "and strategy_signal_id = ? "
                        + "and reversal_triggered_time_ms is not null",
                Integer.class,
                FIRST_ID
        ));
    }

    private void insertSignal(String id, String symbol, String strategyCode) {
        jdbcTemplate.update(
                "insert into strategy_signal ("
                        + "id, delete_state, pair, interval_code, strategy_code, direction, "
                        + "signal_time_ms, price"
                        + ") values (?, 0, ?, '1h', ?, 'LONG', 1000, 64000.25)",
                id,
                symbol,
                strategyCode
        );
    }
}
