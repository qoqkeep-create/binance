package db.migration.common;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Creates the APNs device registry used for server-originated notifications. */
public final class V7__create_app_push_device extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        execute(
                connection,
                """
                create table if not exists app_push_device (
                    id varchar(40) not null,
                    app_user_id varchar(40) not null,
                    installation_id varchar(40) not null,
                    device_token varchar(256) not null,
                    environment varchar(16) not null,
                    enabled_state smallint not null default 1,
                    create_time_ms bigint not null,
                    update_time_ms bigint not null,
                    primary key (id),
                    constraint uk_app_push_device_token
                        unique (device_token, environment)
                )
                """
        );
        createIndexIfMissing(
                connection,
                "app_push_device",
                "idx_app_push_device_active",
                "create index idx_app_push_device_active "
                        + "on app_push_device (enabled_state, environment)"
        );
        createIndexIfMissing(
                connection,
                "app_push_device",
                "idx_app_push_device_installation",
                "create index idx_app_push_device_installation "
                        + "on app_push_device (installation_id, environment)"
        );
        createIndexIfMissing(
                connection,
                "app_push_device",
                "idx_app_push_device_user",
                "create index idx_app_push_device_user "
                        + "on app_push_device (app_user_id, enabled_state)"
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
