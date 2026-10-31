package com.oovso.strategy;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface StrategySignalMapper extends BaseMapper<StrategySignal> {

    @Insert("""
            insert ignore into strategy_signal (
                id,
                create_time,
                update_time,
                create_user,
                update_user,
                delete_state,
                exchange,
                market_type,
                contract_type,
                pair,
                interval_code,
                strategy_code,
                direction,
                signal_time_ms,
                trigger_open_time_ms,
                flip_open_time_ms,
                touch_event_time_ms,
                price,
                score,
                pattern_code,
                reason_json
            ) values (
                #{id},
                #{createTime},
                #{updateTime},
                #{createUser},
                #{updateUser},
                #{deleteState},
                #{exchange},
                #{marketType},
                #{contractType},
                #{pair},
                #{intervalCode},
                #{strategyCode},
                #{direction},
                #{signalTimeMs},
                #{triggerOpenTimeMs},
                #{flipOpenTimeMs},
                #{touchEventTimeMs},
                #{price},
                #{score},
                #{patternCode},
                #{reasonJson}
            )
            """)
    int insertIgnore(StrategySignal signal);

    @Select("""
            select count(1)
            from strategy_signal
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
              and interval_code = #{intervalCode}
              and strategy_code = #{strategyCode}
              and flip_open_time_ms = #{flipOpenTimeMs}
              and direction = #{direction}
              and delete_state = 0
            """)
    int countByFlip(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("pair") String pair,
            @Param("intervalCode") String intervalCode,
            @Param("strategyCode") String strategyCode,
            @Param("flipOpenTimeMs") long flipOpenTimeMs,
            @Param("direction") String direction
    );

    @Select("""
            select s.id,
                   s.pair as symbol,
                   s.interval_code as intervalCode,
                   s.strategy_code as strategyCode,
                   s.direction,
                   s.price as triggerPrice,
                   s.signal_time_ms as signalTimeMs,
                   case when r.strategy_signal_id is null then 0 else 1 end
                       as readState,
                   coalesce(us.reversal_alert_state, 'NONE')
                       as reversalAlertState,
                   us.reversal_pattern_code as reversalPatternCode
            from strategy_signal s
            left join strategy_signal_read r
              on r.strategy_signal_id = s.id
             and r.app_user_id = #{userId}
            left join strategy_signal_user_state us
              on us.strategy_signal_id = s.id
             and us.app_user_id = #{userId}
            left join strategy_notification_preference p
              on p.app_user_id = #{userId}
            where s.delete_state = 0
              and case s.interval_code
                    when '15m' then coalesce(p.fifteen_minute_enabled, 1)
                    when '1h' then coalesce(p.one_hour_enabled, 1)
                    when '4h' then coalesce(p.four_hour_enabled, 1)
                    else 0
                  end = 1
              and s.strategy_code not in (
                    'EMA21_55_MACD_GOLDEN_CROSS',
                    'EMA21_55_MACD_DEATH_CROSS'
              )
              and us.deleted_time_ms is null
              and (
                    s.signal_time_ms < #{beforeSignalTimeMs}
                    or (
                        s.signal_time_ms = #{beforeSignalTimeMs}
                        and s.id < #{beforeId}
                    )
              )
            order by s.signal_time_ms desc, s.id desc
            limit #{limit}
            """)
    List<StrategySignalFeedRow> selectFeedPage(
            @Param("userId") String userId,
            @Param("beforeSignalTimeMs") long beforeSignalTimeMs,
            @Param("beforeId") String beforeId,
            @Param("limit") int limit
    );

    @Select("""
            select count(1)
            from strategy_signal s
            left join strategy_signal_user_state us
              on us.strategy_signal_id = s.id
             and us.app_user_id = #{userId}
            left join strategy_notification_preference p
              on p.app_user_id = #{userId}
            where s.id = #{signalId}
              and s.delete_state = 0
              and case s.interval_code
                    when '15m' then coalesce(p.fifteen_minute_enabled, 1)
                    when '1h' then coalesce(p.one_hour_enabled, 1)
                    when '4h' then coalesce(p.four_hour_enabled, 1)
                    else 0
                  end = 1
              and s.strategy_code not in (
                    'EMA21_55_MACD_GOLDEN_CROSS',
                    'EMA21_55_MACD_DEATH_CROSS'
              )
              and us.deleted_time_ms is null
            """)
    int countVisibleById(
            @Param("userId") String userId,
            @Param("signalId") String signalId
    );

    @Insert("""
            insert into strategy_signal_read (
                app_user_id,
                strategy_signal_id,
                read_time_ms
            ) values (
                #{userId},
                #{signalId},
                #{readTimeMs}
            )
            """)
    int insertReadReceipt(
            @Param("userId") String userId,
            @Param("signalId") String signalId,
            @Param("readTimeMs") long readTimeMs
    );

    @Insert("""
            insert ignore into strategy_signal_user_state (
                app_user_id,
                strategy_signal_id,
                reversal_alert_state,
                create_time_ms,
                update_time_ms
            ) values (
                #{userId},
                #{signalId},
                'NONE',
                #{now},
                #{now}
            )
            """)
    int insertUserStateIfMissing(
            @Param("userId") String userId,
            @Param("signalId") String signalId,
            @Param("now") long now
    );

    @Update("""
            update strategy_signal_user_state
            set reversal_alert_state = 'ACTIVE',
                reversal_requested_time_ms = #{now},
                reversal_triggered_time_ms = null,
                reversal_trigger_open_time_ms = null,
                reversal_pattern_code = null,
                update_time_ms = #{now}
            where app_user_id = #{userId}
              and strategy_signal_id = #{signalId}
              and deleted_time_ms is null
            """)
    int activateReversalAlert(
            @Param("userId") String userId,
            @Param("signalId") String signalId,
            @Param("now") long now
    );

    @Update("""
            update strategy_signal_user_state
            set deleted_time_ms = #{now},
                reversal_alert_state = 'NONE',
                update_time_ms = #{now}
            where app_user_id = #{userId}
              and strategy_signal_id = #{signalId}
              and deleted_time_ms is null
            """)
    int deleteForUser(
            @Param("userId") String userId,
            @Param("signalId") String signalId,
            @Param("now") long now
    );

    @Select("""
            select us.app_user_id as userId,
                   s.id as signalId,
                   s.exchange,
                   s.market_type as marketType,
                   s.contract_type as contractType,
                   s.pair as symbol,
                   s.interval_code as sourceIntervalCode,
                   s.direction,
                   us.reversal_requested_time_ms as requestedTimeMs
            from strategy_signal_user_state us
            join strategy_signal s on s.id = us.strategy_signal_id
            where us.reversal_alert_state = 'ACTIVE'
              and us.deleted_time_ms is null
              and s.delete_state = 0
              and s.exchange = #{exchange}
              and s.market_type = #{marketType}
              and s.contract_type = #{contractType}
              and s.pair = #{symbol}
              and case
                    when s.interval_code = '4h' then '1h'
                    else s.interval_code
                  end = #{monitorIntervalCode}
            """)
    List<StrategySignalReversalWatch> selectActiveReversalWatches(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("symbol") String symbol,
            @Param("monitorIntervalCode") String monitorIntervalCode
    );

    @Update("""
            update strategy_signal_user_state
            set reversal_alert_state = 'TRIGGERED',
                reversal_triggered_time_ms = #{triggeredTimeMs},
                reversal_trigger_open_time_ms = #{triggerOpenTimeMs},
                reversal_pattern_code = #{patternCode},
                update_time_ms = #{triggeredTimeMs}
            where app_user_id = #{userId}
              and strategy_signal_id = #{signalId}
              and reversal_alert_state = 'ACTIVE'
              and deleted_time_ms is null
            """)
    int claimReversalTrigger(
            @Param("userId") String userId,
            @Param("signalId") String signalId,
            @Param("triggeredTimeMs") long triggeredTimeMs,
            @Param("triggerOpenTimeMs") long triggerOpenTimeMs,
            @Param("patternCode") String patternCode
    );
}
