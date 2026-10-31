package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/**
 * One-time compatibility migration for databases created before Flyway was
 * introduced. Keep this migration immutable after release; future changes must
 * use a new Flyway version.
 */
public final class V3__legacy_schema_compatibility
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();

        boolean sourceIntervalAdded = addMissingColumn(
                connection,
                "market_kline",
                "source_interval",
                "varchar(8) not null default '1m'"
        );
        if (sourceIntervalAdded) {
            execute(
                    connection,
                    "update market_kline set source_interval = interval_code "
                            + "where interval_code <> '1m'"
            );
        }

        Map<String, String> accountColumns = new LinkedHashMap<>();
        accountColumns.put(
                "sync_status",
                "varchar(32) not null default 'STOPPED'"
        );
        accountColumns.put("stream_generation", "bigint not null default 0");
        accountColumns.put("last_stream_event_ms", "bigint default null");
        accountColumns.put(
                "last_stream_connected_at_ms",
                "bigint default null"
        );
        accountColumns.put("last_reconciled_at_ms", "bigint default null");
        accountColumns.put(
                "last_full_discovery_at_ms",
                "bigint default null"
        );
        accountColumns.put(
                "last_sync_error_code",
                "varchar(64) default null"
        );
        accountColumns.put(
                "consecutive_sync_failure_count",
                "int not null default 0"
        );
        accountColumns.put(
                "reconcile_revision",
                "bigint not null default 0"
        );
        addMissingColumns(connection, "trading_account", accountColumns);

        Map<String, String> positionColumns = new LinkedHashMap<>();
        positionColumns.put("last_event_ms", "bigint not null default 0");
        positionColumns.put(
                "last_reconcile_revision",
                "bigint not null default 0"
        );
        positionColumns.put(
                "continuity_status",
                "varchar(16) not null default 'CONTINUOUS'"
        );
        positionColumns.put(
                "source",
                "varchar(16) not null default 'REST'"
        );
        addMissingColumns(connection, "trading_position", positionColumns);

        addMissingColumn(
                connection,
                "trading_outbox",
                "locked_at_ms",
                "bigint default null"
        );
    }

    private void addMissingColumns(
            Connection connection,
            String table,
            Map<String, String> columns
    ) throws SQLException {
        for (Map.Entry<String, String> column : columns.entrySet()) {
            addMissingColumn(
                    connection,
                    table,
                    column.getKey(),
                    column.getValue()
            );
        }
    }

    private boolean addMissingColumn(
            Connection connection,
            String table,
            String column,
            String definition
    ) throws SQLException {
        if (!tableExists(connection, table)
                || columnExists(connection, table, column)) {
            return false;
        }
        execute(
                connection,
                "alter table " + table + " add column "
                        + column + " " + definition
        );
        return true;
    }

    private void execute(Connection connection, String sql)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }

    private boolean tableExists(Connection connection, String table)
            throws SQLException {
        DatabaseMetaData metadata = connection.getMetaData();
        for (String candidate : candidates(table)) {
            if (hasTable(metadata, connection.getCatalog(), null, candidate)
                    || hasTable(metadata, null, null, candidate)
                    || hasTable(
                            metadata,
                            connection.getCatalog(),
                            connection.getSchema(),
                            candidate
                    )) {
                return true;
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

    private boolean hasTable(
            DatabaseMetaData metadata,
            String catalog,
            String schema,
            String table
    ) throws SQLException {
        try (ResultSet tables = metadata.getTables(
                catalog,
                schema,
                table,
                new String[]{"TABLE"}
        )) {
            return tables.next();
        }
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
