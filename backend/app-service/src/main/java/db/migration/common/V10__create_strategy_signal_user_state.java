package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Adds per-user deletion and one-shot candlestick reversal alert state. */
public final class V10__create_strategy_signal_user_state
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        execute(
                connection,
                """
                create table if not exists strategy_signal_user_state (
                    app_user_id varchar(40) not null,
                    strategy_signal_id varchar(40) not null,
                    deleted_time_ms bigint null,
                    reversal_alert_state varchar(16) not null default 'NONE',
                    reversal_requested_time_ms bigint null,
                    reversal_triggered_time_ms bigint null,
                    reversal_trigger_open_time_ms bigint null,
                    reversal_pattern_code varchar(64) null,
                    create_time_ms bigint not null,
                    update_time_ms bigint not null,
                    primary key (app_user_id, strategy_signal_id)
                )
                """
        );
        createIndexIfMissing(
                connection,
                "strategy_signal_user_state",
                "idx_strategy_signal_user_state_signal",
                "create index idx_strategy_signal_user_state_signal "
                        + "on strategy_signal_user_state (strategy_signal_id)"
        );
        createIndexIfMissing(
                connection,
                "strategy_signal_user_state",
                "idx_strategy_signal_user_state_reversal",
                "create index idx_strategy_signal_user_state_reversal "
                        + "on strategy_signal_user_state ("
                        + "reversal_alert_state, deleted_time_ms, strategy_signal_id)"
        );
    }

    private void createIndexIfMissing(
            Connection connection,
            String table,
            String index,
            String sql
    ) throws SQLException {
        if (!indexExists(connection, table, index)) {
            execute(connection, sql);
        }
    }

    private boolean indexExists(
            Connection connection,
            String table,
            String index
    ) throws SQLException {
        DatabaseMetaData metadata = connection.getMetaData();
        for (String candidate : candidates(table)) {
            try (ResultSet indexes = metadata.getIndexInfo(
                    connection.getCatalog(),
                    connection.getSchema(),
                    candidate,
                    false,
                    false
            )) {
                while (indexes.next()) {
                    String existing = indexes.getString("INDEX_NAME");
                    if (existing != null
                            && existing.equalsIgnoreCase(index)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private void execute(Connection connection, String sql)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private String[] candidates(String identifier) {
        return new String[]{
                identifier,
                identifier.toUpperCase(Locale.ROOT),
                identifier.toLowerCase(Locale.ROOT)
        };
    }
}
