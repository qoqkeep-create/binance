package db.migration.common;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Stores per-user strategy notification interval preferences. */
public final class V13__create_strategy_notification_preference
        extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        execute(
                context.getConnection(),
                """
                create table if not exists strategy_notification_preference (
                    app_user_id varchar(40) not null,
                    fifteen_minute_enabled smallint not null default 1,
                    one_hour_enabled smallint not null default 1,
                    four_hour_enabled smallint not null default 1,
                    create_time_ms bigint not null,
                    update_time_ms bigint not null,
                    primary key (app_user_id)
                )
                """
        );
    }

    private void execute(Connection connection, String sql)
            throws SQLException {
        try (Statement statement = connection.createStatement()) {
            statement.execute(sql);
        }
    }
}
