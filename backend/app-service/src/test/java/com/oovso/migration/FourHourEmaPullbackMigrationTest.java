package com.oovso.migration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import db.migration.common.V14__four_hour_ema_pullback_episodes;
import java.sql.Connection;
import java.util.UUID;
import org.flywaydb.core.api.migration.Context;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class FourHourEmaPullbackMigrationTest {

    @Test
    void preservesLegacyOncePerFlipAndAllowsDistinctIntrabarTouchTimes() throws Exception {
        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                "jdbc:h2:mem:touch_migration_" + UUID.randomUUID()
                        + ";MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
                "sa", ""
        );
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("""
                create table strategy_signal (
                    id varchar(40) primary key,
                    exchange varchar(16) not null,
                    market_type varchar(16) not null,
                    contract_type varchar(16) not null,
                    pair varchar(32) not null,
                    interval_code varchar(8) not null,
                    strategy_code varchar(64) not null,
                    flip_open_time_ms bigint not null,
                    direction varchar(16) not null
                )
                """);
        jdbc.execute("""
                create unique index uk_strategy_signal_once on strategy_signal (
                    exchange, market_type, contract_type, pair, interval_code,
                    strategy_code, flip_open_time_ms, direction
                )
                """);
        jdbc.update("""
                insert into strategy_signal values (
                    'legacy', 'BINANCE', 'USDM', 'PERPETUAL', 'ETHUSDC', '1h',
                    'SUPER_EMA144_PULLBACK_REVERSAL', 1000, 'SHORT'
                )
                """);
        try (Connection connection = dataSource.getConnection()) {
            Context context = mock(Context.class);
            when(context.getConnection()).thenReturn(connection);
            new V14__four_hour_ema_pullback_episodes().migrate(context);
        }

        assertEquals(0L, jdbc.queryForObject(
                "select touch_event_time_ms from strategy_signal where id = 'legacy'", Long.class
        ));
        insert(jdbc, "touch-one", "4h", 2_000L);
        insert(jdbc, "touch-two", "4h", 3_000L);
        assertThrows(DuplicateKeyException.class, () -> insert(jdbc, "duplicate", "4h", 2_000L));
        assertThrows(DuplicateKeyException.class, () -> insert(jdbc, "legacy-again", "1h", 0L));
        assertEquals(3, jdbc.queryForObject("select count(1) from strategy_signal", Integer.class));
    }

    private void insert(JdbcTemplate jdbc, String id, String interval, long touchTime) {
        jdbc.update("""
                insert into strategy_signal (
                    id, exchange, market_type, contract_type, pair, interval_code,
                    strategy_code, flip_open_time_ms, direction, touch_event_time_ms
                ) values (
                    ?, 'BINANCE', 'USDM', 'PERPETUAL', 'ETHUSDC', ?,
                    'SUPER_EMA144_PULLBACK_REVERSAL', 1000, 'SHORT', ?
                )
                """, id, interval, touchTime);
    }
}
