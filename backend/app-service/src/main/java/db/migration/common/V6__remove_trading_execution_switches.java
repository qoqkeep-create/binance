package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/**
 * Removes the legacy account-level execution switch. Order availability is
 * derived from the account lifecycle, synchronization state and fencing.
 */
public final class V6__remove_trading_execution_switches
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        if (columnExists(
                connection,
                "trading_account",
                "execution_enabled"
        )) {
            boolean statusIndexExists = indexExists(
                    connection,
                    "trading_account",
                    "idx_trading_account_status"
            );
            if (statusIndexExists) {
                dropIndex(connection, "idx_trading_account_status");
            }
            execute(
                    connection,
                    "alter table trading_account "
                            + "drop column execution_enabled"
            );
            if (statusIndexExists && columnExists(
                    connection,
                    "trading_account",
                    "status"
            )) {
                execute(
                        connection,
                        "create index idx_trading_account_status "
                                + "on trading_account (status)"
                );
            }
        }
    }

    private void dropIndex(Connection connection, String index)
            throws SQLException {
        String product = connection.getMetaData()
                .getDatabaseProductName()
                .toLowerCase(Locale.ROOT);
        if (product.contains("mysql")) {
            execute(
                    connection,
                    "alter table trading_account drop index " + index
            );
            return;
        }
        execute(connection, "drop index " + index);
    }

    private void execute(Connection connection, String sql)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private boolean indexExists(
            Connection connection,
            String table,
            String index
    ) throws SQLException {
        DatabaseMetaData metadata = connection.getMetaData();
        for (String tableCandidate : candidates(table)) {
            try (ResultSet indexes = metadata.getIndexInfo(
                    connection.getCatalog(),
                    connection.getSchema(),
                    tableCandidate,
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

    private boolean columnExists(
            Connection connection,
            String table,
            String column
    ) throws SQLException {
        DatabaseMetaData metadata = connection.getMetaData();
        for (String tableCandidate : candidates(table)) {
            for (String columnCandidate : candidates(column)) {
                if (hasColumn(
                        metadata,
                        connection.getCatalog(),
                        null,
                        tableCandidate,
                        columnCandidate
                ) || hasColumn(
                        metadata,
                        null,
                        null,
                        tableCandidate,
                        columnCandidate
                ) || hasColumn(
                        metadata,
                        connection.getCatalog(),
                        connection.getSchema(),
                        tableCandidate,
                        columnCandidate
                )) {
                    return true;
                }
            }
        }
        return false;
    }

    private boolean hasColumn(
            DatabaseMetaData metadata,
            String catalog,
            String schema,
            String table,
            String column
    ) throws SQLException {
        try (ResultSet columns = metadata.getColumns(
                catalog,
                schema,
                table,
                column
        )) {
            return columns.next();
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
