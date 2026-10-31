package com.oovso.notification;

import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface PushDeviceMapper {

    @Update("""
            update app_push_device
            set enabled_state = 0,
                update_time_ms = #{now}
            where installation_id = #{installationId}
              and enabled_state = 1
              and not (
                  device_token = #{deviceToken}
                  and environment = #{environment}
              )
            """)
    int disableOtherInstallationTokens(
            @Param("installationId") String installationId,
            @Param("deviceToken") String deviceToken,
            @Param("environment") String environment,
            @Param("now") long now
    );

    @Insert("""
            insert into app_push_device (
                id,
                app_user_id,
                installation_id,
                device_token,
                environment,
                bundle_identifier,
                enabled_state,
                create_time_ms,
                update_time_ms
            ) values (
                #{id},
                #{userId},
                #{installationId},
                #{deviceToken},
                #{environment},
                #{bundleIdentifier},
                1,
                #{now},
                #{now}
            )
            on duplicate key update
                app_user_id = #{userId},
                installation_id = #{installationId},
                bundle_identifier = #{bundleIdentifier},
                enabled_state = case
                    when invalidated_time_ms is null then 1
                    else 0
                end,
                update_time_ms = #{now}
            """)
    int upsert(
            @Param("id") String id,
            @Param("userId") String userId,
            @Param("installationId") String installationId,
            @Param("deviceToken") String deviceToken,
            @Param("environment") String environment,
            @Param("bundleIdentifier") String bundleIdentifier,
            @Param("now") long now
    );

    @Update("""
            update app_push_device
            set enabled_state = 0,
                update_time_ms = #{now}
            where app_user_id = #{userId}
              and installation_id = #{installationId}
              and enabled_state = 1
            """)
    int disableOwnedInstallation(
            @Param("userId") String userId,
            @Param("installationId") String installationId,
            @Param("now") long now
    );

    @Update("""
            update app_push_device
            set enabled_state = 0,
                invalidated_time_ms = #{now},
                invalid_reason = #{reason},
                update_time_ms = #{now}
            where id = #{id}
              and enabled_state = 1
            """)
    int disableById(
            @Param("id") String id,
            @Param("reason") String reason,
            @Param("now") long now
    );

    @Select("""
            select id,
                   device_token as deviceToken,
                   environment
            from app_push_device
            where enabled_state = 1
            order by update_time_ms desc
            """)
    List<RegisteredPushDevice> selectActive();

    @Select("""
            select id,
                   device_token as deviceToken,
                   environment
            from app_push_device
            where app_user_id = #{userId}
              and enabled_state = 1
            order by update_time_ms desc
            """)
    List<RegisteredPushDevice> selectActiveByUser(
            @Param("userId") String userId
    );

    @Select("""
            select d.id,
                   d.device_token as deviceToken,
                   d.environment
            from app_push_device d
            left join strategy_notification_preference p
              on p.app_user_id = d.app_user_id
            where d.enabled_state = 1
              and case #{intervalCode}
                    when '15m' then coalesce(
                        p.fifteen_minute_enabled,
                        1
                    )
                    when '1h' then coalesce(p.one_hour_enabled, 1)
                    when '4h' then coalesce(p.four_hour_enabled, 1)
                    else 0
                  end = 1
            order by d.update_time_ms desc
            """)
    List<RegisteredPushDevice> selectActiveForStrategyInterval(
            @Param("intervalCode") String intervalCode
    );

    @Select("""
            select d.id,
                   d.device_token as deviceToken,
                   d.environment
            from app_push_device d
            left join strategy_notification_preference p
              on p.app_user_id = d.app_user_id
            where d.app_user_id = #{userId}
              and d.enabled_state = 1
              and case #{intervalCode}
                    when '15m' then coalesce(
                        p.fifteen_minute_enabled,
                        1
                    )
                    when '1h' then coalesce(p.one_hour_enabled, 1)
                    when '4h' then coalesce(p.four_hour_enabled, 1)
                    else 0
                  end = 1
            order by d.update_time_ms desc
            """)
    List<RegisteredPushDevice> selectActiveByUserForStrategyInterval(
            @Param("userId") String userId,
            @Param("intervalCode") String intervalCode
    );

    record RegisteredPushDevice(
            String id,
            String deviceToken,
            String environment
    ) {
    }
}
