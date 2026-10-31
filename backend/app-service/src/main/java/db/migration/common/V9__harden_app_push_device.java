package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Adds APNs topic diagnostics and durable invalid-token state. */
public final class V9__harden_app_push_device extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        addColumnIfMissing(
                connection,
                "app_push_device",
                "bundle_identifier",
                "alter table app_push_device "
                        + "add column bundle_identifier varchar(255) null"
        );
        addColumnIfMissing(
                connection,
                "app_push_device",
                "invalidated_time_ms",
                "alter table app_push_device "
                        + "add column invalidated_time_ms bigint null"
        );
        addColumnIfMissing(
                connection,
                "app_push_device",
                "invalid_reason",
                "alter table app_push_device "
                        + "add column invalid_reason varchar(64) null"
        );
    }

    private void addColumnIfMissing(
            Connection connection,
            String table,
            String column,
            String sql
    ) throws SQLException {
        if (!columnExists(connection, table, column)) {
            execute(connection, sql);
        }
    }

    private boolean columnExists(
            Connection connection,
            String table,
            String column
    ) throws SQLException {
        DatabaseMetaData metadata = connection.getMetaData();
        for (String candidate : candidates(table)) {
            try (ResultSet columns = metadata.getColumns(
                    connection.getCatalog(),
                    connection.getSchema(),
                    candidate,
                    null
            )) {
                while (columns.next()) {
                    String existing = columns.getString("COLUMN_NAME");
                    if (existing != null
                            && existing.equalsIgnoreCase(column)) {
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
