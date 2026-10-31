package db.migration.common;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Rebuilds external receipt storage with a generic inbox and reference projection. */
public final class V12__replace_external_trade_signal_with_external_message
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        execute(connection, "drop table if exists external_trade_signal");
        execute(connection, "drop table if exists reference_trade_notification");
        execute(connection, "drop table if exists external_message");
        execute(
                connection,
                """
                create table external_message (
                    id varchar(40) not null,
                    payload_json longtext not null,
                    received_time_ms bigint not null,
                    primary key (id)
                )
                """
        );
        execute(
                connection,
                "create index idx_external_message_received_time "
                        + "on external_message (received_time_ms, id)"
        );
        execute(
                connection,
                """
                create table reference_trade_notification (
                    id varchar(40) not null,
                    external_message_id varchar(40) not null,
                    event_id varchar(191) not null,
                    schema_version int not null,
                    notification_type varchar(32) not null,
                    title varchar(255) not null,
                    content longtext not null,
                    occurred_time_ms bigint not null,
                    received_time_ms bigint not null,
                    primary key (id),
                    unique (external_message_id),
                    unique (event_id)
                )
                """
        );
        execute(
                connection,
                "create index idx_reference_trade_notification_time "
                        + "on reference_trade_notification (received_time_ms, id)"
        );
    }

    private void execute(Connection connection, String sql)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }
}
