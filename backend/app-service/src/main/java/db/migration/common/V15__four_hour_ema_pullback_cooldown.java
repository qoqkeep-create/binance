package db.migration.common;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.Locale;
import org.flywaydb.core.api.migration.BaseJavaMigration;
import org.flywaydb.core.api.migration.Context;

/** Retains the last successful four-hour main alert across restarts and upgrades. */
public final class V15__four_hour_ema_pullback_cooldown extends BaseJavaMigration {

    @Override
    public void migrate(Context context) throws Exception {
        Connection connection = context.getConnection();
        if (!hasColumn(connection, "four_hour_ema_pullback_state", "last_alert_time_ms")) {
            try (Statement statement = connection.createStatement()) {
                statement.execute("alter table four_hour_ema_pullback_state "
                        + "add column last_alert_time_ms bigint not null default -1");
            }
        }
        String createdTime = hasColumn(connection, "strategy_signal", "create_time")
                ? "max(create_time)" : "null";
        try (Statement statement = connection.createStatement();
             ResultSet signals = statement.executeQuery("""
                     select exchange, market_type, contract_type, pair,
                            %s as last_created_time,
                            max(case when touch_event_time_ms > 0 then touch_event_time_ms
                                     else signal_time_ms end) as last_alert_event_ms
                     from strategy_signal
                     where interval_code = '4h'
                       and strategy_code = 'SUPER_EMA144_PULLBACK_REVERSAL'
                       and exchange is not null and market_type is not null
                       and contract_type is not null and pair is not null
                     group by exchange, market_type, contract_type, pair
                     """.formatted(createdTime));
             PreparedStatement insert = connection.prepareStatement("""
                     insert ignore into four_hour_ema_pullback_state (
                         exchange, market_type, contract_type, pair, last_alert_time_ms
                     ) values (?, ?, ?, ?, ?)
                     """);
             PreparedStatement update = connection.prepareStatement("""
                     update four_hour_ema_pullback_state
                     set last_alert_time_ms = ?
                     where exchange = ? and market_type = ? and contract_type = ? and pair = ?
                       and last_alert_time_ms < ?
                     """)) {
            while (signals.next()) {
                LocalDateTime created = signals.getObject("last_created_time", LocalDateTime.class);
                long lastAlert = created == null ? signals.getLong("last_alert_event_ms")
                        // Strategy signals use LocalDateTime.now() in the server JVM zone.
                        : created.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
                if ((created == null && signals.wasNull()) || lastAlert < 0) {
                    continue;
                }
                for (int index = 1; index <= 4; index++) {
                    insert.setString(index, signals.getString(index));
                    update.setString(index + 1, signals.getString(index));
                }
                insert.setLong(5, lastAlert);
                insert.executeUpdate();
                update.setLong(1, lastAlert);
                update.setLong(6, lastAlert);
                update.executeUpdate();
            }
        }
    }

    private boolean hasColumn(Connection connection, String tableName, String columnName)
            throws SQLException {
        for (String table : new String[]{tableName, tableName.toUpperCase(Locale.ROOT)}) {
            try (ResultSet columns = connection.getMetaData().getColumns(
                    connection.getCatalog(), null, table, null
            )) {
                while (columns.next()) {
                    if (columnName.equalsIgnoreCase(columns.getString("COLUMN_NAME"))) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
}
