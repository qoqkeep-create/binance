package com.oovso.migration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.util.UUID;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.output.MigrateResult;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class FlywayMigrationTest {

    @Test
    void migratesLegacySchemaAndRecordsVersions() throws Exception {
        DataSource dataSource = dataSource();
        Flyway flyway = flyway(dataSource);

        MigrateResult result = flyway.migrate();

        assertEquals(14, result.migrationsExecuted);
        assertEquals("15", flyway.info().current().getVersion().toString());
        assertTrue(hasColumn(dataSource, "strategy_signal", "touch_event_time_ms"));
        assertTrue(hasColumn(dataSource, "four_hour_ema_pullback_state", "last_event_ms"));
        assertTrue(hasColumn(dataSource, "four_hour_ema_pullback_state", "last_alert_time_ms"));
        assertTrue(hasColumn(dataSource, "market_kline", "source_interval"));
        assertTrue(hasColumn(dataSource, "trading_account", "sync_status"));
        assertTrue(hasColumn(
                dataSource,
                "trading_account",
                "reconcile_revision"
        ));
        assertFalse(hasColumn(
                dataSource,
                "trading_account",
                "execution_enabled"
        ));
        assertTrue(hasColumn(
                dataSource,
                "trading_position",
                "continuity_status"
        ));
        assertTrue(hasColumn(dataSource, "trading_outbox", "locked_at_ms"));
        assertTrue(hasColumn(
                dataSource,
                "trading_position_plan",
                "configured_r_amount"
        ));
        assertTrue(hasColumn(
                dataSource,
                "trading_position_plan",
                "execution_snapshot_hash"
        ));
        assertTrue(hasColumn(
                dataSource,
                "trading_position_plan_level",
                "reduction_revision"
        ));
        assertTrue(hasColumn(
                dataSource,
                "app_push_device",
                "device_token"
        ));
        assertTrue(hasColumn(
                dataSource,
                "app_push_device",
                "bundle_identifier"
        ));
        assertTrue(hasColumn(
                dataSource,
                "app_push_device",
                "invalidated_time_ms"
        ));
        assertTrue(hasColumn(
                dataSource,
                "app_push_device",
                "invalid_reason"
        ));
        assertTrue(hasColumn(
                dataSource,
                "strategy_signal_read",
                "read_time_ms"
        ));
        assertTrue(hasColumn(
                dataSource,
                "strategy_signal_user_state",
                "reversal_alert_state"
        ));
        assertTrue(hasColumn(
                dataSource,
                "strategy_notification_preference",
                "fifteen_minute_enabled"
        ));
        assertTrue(hasColumn(
                dataSource,
                "strategy_notification_preference",
                "one_hour_enabled"
        ));
        assertTrue(hasColumn(
                dataSource,
                "strategy_notification_preference",
                "four_hour_enabled"
        ));
        assertFalse(hasTable(dataSource, "external_trade_signal"));
        assertTrue(hasColumn(dataSource, "external_message", "payload_json"));
        assertTrue(hasColumn(
                dataSource,
                "external_message",
                "received_time_ms"
        ));
        assertTrue(hasColumn(
                dataSource,
                "reference_trade_notification",
                "event_id"
        ));
        assertTrue(hasColumn(
                dataSource,
                "reference_trade_notification",
                "notification_type"
        ));
        assertTrue(hasColumn(
                dataSource,
                "reference_trade_notification",
                "content"
        ));

        JdbcTemplate jdbcTemplate = new JdbcTemplate(dataSource);
        assertEquals(
                "1m",
                jdbcTemplate.queryForObject(
                        "select source_interval from market_kline "
                                + "where id = 'legacy-one-minute'",
                        String.class
                )
        );
        assertEquals(
                "1h",
                jdbcTemplate.queryForObject(
                        "select source_interval from market_kline "
                                + "where id = 'legacy-one-hour'",
                        String.class
                )
        );
        assertEquals(0, flyway.migrate().migrationsExecuted);
    }

    @Test
    void baselineVersionZeroStillRunsVersionedMigrations()
            throws Exception {
        DataSource dataSource = dataSource();
        JdbcTemplate jdbcTemplate = new JdbcTemplate(dataSource);
        jdbcTemplate.execute("create table pre_flyway_table (id integer)");

        Flyway flyway = flyway(dataSource);
        flyway.migrate();

        assertEquals("15", flyway.info().current().getVersion().toString());
        assertTrue(hasColumn(dataSource, "trading_account", "sync_status"));
        assertFalse(flyway.info().applied()[0].getVersion().toString().isBlank());
    }

    private Flyway flyway(DataSource dataSource) {
        return Flyway.configure()
                .dataSource(dataSource)
                .locations(
                        "classpath:db/test-migration",
                        "classpath:db/migration/common"
                )
                .baselineOnMigrate(true)
                .baselineVersion("0")
                .cleanDisabled(true)
                .load();
    }

    private DataSource dataSource() {
        String name = "flyway_"
                + UUID.randomUUID().toString().replace("-", "");
        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                "jdbc:h2:mem:" + name
                        + ";MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
                "sa",
                ""
        );
        dataSource.setDriverClassName("org.h2.Driver");
        return dataSource;
    }

    private boolean hasColumn(
            DataSource dataSource,
            String table,
            String column
    ) throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            DatabaseMetaData metadata = connection.getMetaData();
            try (ResultSet result = metadata.getColumns(
                    connection.getCatalog(),
                    null,
                    table,
                    column
            )) {
                return result.next();
            }
        }
    }

    private boolean hasTable(DataSource dataSource, String table)
            throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            DatabaseMetaData metadata = connection.getMetaData();
            try (ResultSet result = metadata.getTables(
                    connection.getCatalog(),
                    null,
                    table,
                    new String[]{"TABLE"}
            )) {
                return result.next();
            }
        }
    }
}
