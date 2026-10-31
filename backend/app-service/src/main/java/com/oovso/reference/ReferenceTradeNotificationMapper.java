package com.oovso.reference;

import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface ReferenceTradeNotificationMapper {

    @Insert("""
            insert ignore into reference_trade_notification (
                id,
                external_message_id,
                event_id,
                schema_version,
                notification_type,
                title,
                content,
                occurred_time_ms,
                received_time_ms
            ) values (
                #{id},
                #{externalMessageId},
                #{eventId},
                #{schemaVersion},
                #{notificationType},
                #{title},
                #{content},
                #{occurredTimeMs},
                #{receivedTimeMs}
            )
            """)
    int insertNotification(ReferenceTradeNotificationRow notification);

    @Select("""
            select id,
                   external_message_id as externalMessageId,
                   event_id as eventId,
                   schema_version as schemaVersion,
                   notification_type as notificationType,
                   title,
                   content,
                   occurred_time_ms as occurredTimeMs,
                   received_time_ms as receivedTimeMs
            from reference_trade_notification
            where received_time_ms < #{beforeTimeMs}
               or (
                   received_time_ms = #{beforeTimeMs}
                   and id < #{beforeId}
               )
            order by received_time_ms desc, id desc
            limit #{limit}
            """)
    List<ReferenceTradeNotificationRow> selectPage(
            @Param("beforeTimeMs") long beforeTimeMs,
            @Param("beforeId") String beforeId,
            @Param("limit") int limit
    );
}
