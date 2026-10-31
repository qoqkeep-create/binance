package db.migration.common;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Keeps live four-hour touch rearming and signal insertion durable and atomic. */
public final class V14__four_hour_ema_pullback_episodes extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        execute(connection, """
                create table if not exists four_hour_ema_pullback_state (
                    exchange varchar(16) not null,
                    market_type varchar(16) not null,
                    contract_type varchar(16) not null,
                    pair varchar(32) not null,
                    direction varchar(16) null,
                    phase varchar(16) not null default 'WAITING',
                    last_event_ms bigint not null default -1,
                    last_bucket_open_ms bigint not null default -1,
                    last_intrabar_bucket_open_ms bigint not null default -1,
                    last_price decimal(38, 18) null,
                    last_source_open_ms bigint not null default -1,
                    last_source_high decimal(38, 18) null,
                    last_source_low decimal(38, 18) null,
                    primary key (exchange, market_type, contract_type, pair)
                )
                """);
        if (!hasColumn(connection, "touch_event_time_ms")) {
            execute(connection, "alter table strategy_signal "
                    + "add column touch_event_time_ms bigint not null default 0");
        }
        // The deliberately small legacy H2 test schema has no flip column/index.
        // Real schemas keep the original 15m/1h identity by using touch time zero.
        if (!hasColumn(connection, "flip_open_time_ms")) {
            return;
        }
        if (hasIndex(connection, "uk_strategy_signal_once")) {
            String product = connection.getMetaData().getDatabaseProductName();
            execute(connection, product.equalsIgnoreCase("H2")
                    ? "drop index uk_strategy_signal_once"
                    : "alter table strategy_signal drop index uk_strategy_signal_once");
        }
        execute(connection, """
                create unique index uk_strategy_signal_once on strategy_signal (
                    exchange, market_type, contract_type, pair, interval_code,
                    strategy_code, flip_open_time_ms, direction, touch_event_time_ms
                )
                """);
    }

    private boolean hasColumn(Connection connection, String column) throws SQLException {
        for (String table : tableCandidates()) {
            try (ResultSet columns = connection.getMetaData().getColumns(
                    connection.getCatalog(), null, table, null
            )) {
                while (columns.next()) {
                    if (column.equalsIgnoreCase(columns.getString("COLUMN_NAME"))) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private boolean hasIndex(Connection connection, String index) throws SQLException {
        for (String table : tableCandidates()) {
            try (ResultSet indexes = connection.getMetaData().getIndexInfo(
                    connection.getCatalog(), null, table, false, false
            )) {
                while (indexes.next()) {
                    if (index.equalsIgnoreCase(indexes.getString("INDEX_NAME"))) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private String[] tableCandidates() {
        String table = "strategy_signal";
        return new String[]{table, table.toUpperCase(Locale.ROOT)};
    }

    private void execute(Connection connection, String sql) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }
}
