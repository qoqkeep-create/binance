package com.oovso.migration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import db.migration.common.V14__four_hour_ema_pullback_episodes;
import db.migration.common.V15__four_hour_ema_pullback_cooldown;
import java.sql.Connection;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.UUID;
import org.flywaydb.core.api.migration.Context;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class FourHourEmaPullbackCooldownMigrationTest {

    @Test
    void backfillsLatestMainAlertAcrossDirectionsAndPreservesObservationState() throws Exception {
        DriverManagerDataSource dataSource = dataSource(false);
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.update("""
                insert into four_hour_ema_pullback_state (
                    exchange, market_type, contract_type, pair, direction, phase,
                    last_event_ms, last_source_open_ms, last_source_high, last_source_low
                ) values ('BINANCE', 'USDM', 'PERPETUAL', 'ETHUSDC', 'SHORT',
                          'TOUCHING', 8000, 7500, 110, 90)
                """);
        jdbc.update("""
                insert into four_hour_ema_pullback_state (
                    exchange, market_type, contract_type, pair
                ) values ('BINANCE', 'USDM', 'PERPETUAL', 'SOLUSDC')
                """);
        insert(jdbc, "first", "ETHUSDC", "4h", "SUPER_EMA144_PULLBACK_REVERSAL", "LONG", 4_000, 4_100);
        insert(jdbc, "latest", "ETHUSDC", "4h", "SUPER_EMA144_PULLBACK_REVERSAL", "SHORT", 5_000, 7_000);
        insert(jdbc, "hourly", "ETHUSDC", "1h", "SUPER_EMA144_PULLBACK_REVERSAL", "LONG", 90_000, 90_000);
        insert(jdbc, "secondary", "ETHUSDC", "4h", "SECONDARY_REVERSAL_ALERT", "SHORT", 99_000, 99_000);
        insert(jdbc, "legacy", "ZECUSDC", "4h", "SUPER_EMA144_PULLBACK_REVERSAL", "SHORT", 10_000, 0);
        insert(jdbc, "hourly-only", "BTCUSDC", "1h", "SUPER_EMA144_PULLBACK_REVERSAL", "LONG", 20_000, 0);

        migrate(dataSource);

        assertEquals(7_000L, lastAlert(jdbc, "ETHUSDC"));
        assertEquals(10_000L, lastAlert(jdbc, "ZECUSDC"));
        assertEquals(-1L, lastAlert(jdbc, "SOLUSDC"));
        assertEquals(0, jdbc.queryForObject(
                "select count(1) from four_hour_ema_pullback_state where pair = 'BTCUSDC'",
                Integer.class
        ));
        assertEquals("TOUCHING", jdbc.queryForObject(
                "select phase from four_hour_ema_pullback_state where pair = 'ETHUSDC'", String.class
        ));
        assertEquals(8_000L, jdbc.queryForObject(
                "select last_event_ms from four_hour_ema_pullback_state where pair = 'ETHUSDC'", Long.class
        ));
        assertEquals(7_500L, jdbc.queryForObject(
                "select last_source_open_ms from four_hour_ema_pullback_state where pair = 'ETHUSDC'", Long.class
        ));
        assertEquals("WAITING", jdbc.queryForObject(
                "select phase from four_hour_ema_pullback_state where pair = 'ZECUSDC'", String.class
        ));

        // Retrying the migration must not regress a newer durable alert time.
        jdbc.update("update four_hour_ema_pullback_state set last_alert_time_ms = 12000 where pair = 'ETHUSDC'");
        migrate(dataSource);
        assertEquals(12_000L, lastAlert(jdbc, "ETHUSDC"));
    }

    @Test
    void creationTimeInTheServerZoneTakesPriorityOverExchangeEventTimestamps() throws Exception {
        DriverManagerDataSource dataSource = dataSource(true);
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        long lastCreatedMillis = 1_000_000_000L;
        insert(jdbc, "last-created", "ETHUSDC", "4h", "SUPER_EMA144_PULLBACK_REVERSAL",
                "SHORT", 90_000, 95_000);
        insert(jdbc, "future-event", "ETHUSDC", "4h", "SUPER_EMA144_PULLBACK_REVERSAL",
                "LONG", lastCreatedMillis * 2, lastCreatedMillis * 2);
        jdbc.update("update strategy_signal set create_time = ? where id = ?",
                LocalDateTime.ofInstant(Instant.ofEpochMilli(lastCreatedMillis), ZoneId.systemDefault()),
                "last-created");
        jdbc.update("update strategy_signal set create_time = ? where id = ?",
                LocalDateTime.ofInstant(Instant.ofEpochMilli(lastCreatedMillis - 10_000), ZoneId.systemDefault()),
                "future-event");

        migrate(dataSource);

        assertEquals(lastCreatedMillis, lastAlert(jdbc, "ETHUSDC"));
    }

    private DriverManagerDataSource dataSource(boolean createTime) throws Exception {
        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                "jdbc:h2:mem:cooldown_migration_" + UUID.randomUUID()
                        + ";MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
                "sa", ""
        );
        new JdbcTemplate(dataSource).execute("""
                create table strategy_signal (
                    id varchar(40) primary key,
                    exchange varchar(16), market_type varchar(16),
                    contract_type varchar(16), pair varchar(32), interval_code varchar(8),
                    strategy_code varchar(64), direction varchar(16), signal_time_ms bigint%s
                )
                """.formatted(createTime ? ", create_time timestamp" : ""));
        try (Connection connection = dataSource.getConnection()) {
            Context context = mock(Context.class);
            when(context.getConnection()).thenReturn(connection);
            new V14__four_hour_ema_pullback_episodes().migrate(context);
        }
        return dataSource;
    }

    private void migrate(DriverManagerDataSource dataSource) throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            Context context = mock(Context.class);
            when(context.getConnection()).thenReturn(connection);
            new V15__four_hour_ema_pullback_cooldown().migrate(context);
        }
    }

    private long lastAlert(JdbcTemplate jdbc, String pair) {
        return jdbc.queryForObject(
                "select last_alert_time_ms from four_hour_ema_pullback_state where pair = ?",
                Long.class, pair
        );
    }

    private void insert(
            JdbcTemplate jdbc, String id, String pair, String interval,
            String strategy, String direction, long signalTime, long touchTime
    ) {
        jdbc.update("""
                insert into strategy_signal (
                    id, exchange, market_type, contract_type, pair, interval_code,
                    strategy_code, direction, signal_time_ms, touch_event_time_ms
                ) values (?, 'BINANCE', 'USDM', 'PERPETUAL', ?, ?, ?, ?, ?, ?)
                """, id, pair, interval, strategy, direction, signalTime, touchTime);
    }
}
