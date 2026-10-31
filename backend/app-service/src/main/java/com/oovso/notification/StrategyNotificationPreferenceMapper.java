package com.oovso.notification;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface StrategyNotificationPreferenceMapper {

    @Select("""
            select fifteen_minute_enabled as fifteenMinuteEnabled,
                   one_hour_enabled as oneHourEnabled,
                   four_hour_enabled as fourHourEnabled
            from strategy_notification_preference
            where app_user_id = #{userId}
            """)
    PreferenceRow selectByUser(@Param("userId") String userId);

    @Insert("""
            insert into strategy_notification_preference (
                app_user_id,
                fifteen_minute_enabled,
                one_hour_enabled,
                four_hour_enabled,
                create_time_ms,
                update_time_ms
            ) values (
                #{userId},
                #{fifteenMinuteEnabled},
                #{oneHourEnabled},
                #{fourHourEnabled},
                #{now},
                #{now}
            )
            on duplicate key update
                fifteen_minute_enabled = #{fifteenMinuteEnabled},
                one_hour_enabled = #{oneHourEnabled},
                four_hour_enabled = #{fourHourEnabled},
                update_time_ms = #{now}
            """)
    int upsert(
            @Param("userId") String userId,
            @Param("fifteenMinuteEnabled") int fifteenMinuteEnabled,
            @Param("oneHourEnabled") int oneHourEnabled,
            @Param("fourHourEnabled") int fourHourEnabled,
            @Param("now") long now
    );

    record PreferenceRow(
            int fifteenMinuteEnabled,
            int oneHourEnabled,
            int fourHourEnabled
    ) {
    }
}
