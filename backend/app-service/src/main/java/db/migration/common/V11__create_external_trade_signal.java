package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Persists external trade signals for the target user's reference feed. */
public final class V11__create_external_trade_signal
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        execute(
                connection,
                """
                create table if not exists external_trade_signal (
                    id varchar(40) not null,
                    target_app_user_id varchar(40) not null,
                    signal_type varchar(8) not null,
                    symbol varchar(30) not null,
                    price decimal(38, 18) not null,
                    quantity decimal(38, 18) not null,
                    stop_loss_price decimal(38, 18) null,
                    received_time_ms bigint not null,
                    primary key (id)
                )
                """
        );
        createIndexIfMissing(
                connection,
                "external_trade_signal",
                "idx_external_trade_signal_user_time",
                "create index idx_external_trade_signal_user_time "
                        + "on external_trade_signal ("
                        + "target_app_user_id, received_time_ms, id)"
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
