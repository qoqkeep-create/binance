package com.oovso.strategy;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface FourHourEmaPullbackStateMapper {

    @Insert("""
            insert ignore into four_hour_ema_pullback_state (
                exchange, market_type, contract_type, pair, phase,
                last_event_ms, last_alert_time_ms, last_bucket_open_ms, last_intrabar_bucket_open_ms,
                last_source_open_ms
            ) values (
                #{exchange}, #{marketType}, #{contractType}, #{pair}, 'WAITING',
                -1, -1, -1, -1, -1
            )
            """)
    int insertIfMissing(FourHourEmaPullbackState state);

    @Select("""
            select exchange, market_type, contract_type, pair, direction, phase,
                   last_event_ms, last_alert_time_ms, last_bucket_open_ms, last_intrabar_bucket_open_ms,
                   last_price, last_source_open_ms, last_source_high, last_source_low
            from four_hour_ema_pullback_state
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
            for update
            """)
    FourHourEmaPullbackState selectForUpdate(FourHourEmaPullbackState state);

    @Update("""
            update four_hour_ema_pullback_state
            set direction = #{direction}, phase = #{phase},
                last_event_ms = #{lastEventMs},
                last_alert_time_ms = #{lastAlertTimeMs},
                last_bucket_open_ms = #{lastBucketOpenMs},
                last_intrabar_bucket_open_ms = #{lastIntrabarBucketOpenMs},
                last_price = #{lastPrice},
                last_source_open_ms = #{lastSourceOpenMs},
                last_source_high = #{lastSourceHigh},
                last_source_low = #{lastSourceLow}
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
            """)
    int update(FourHourEmaPullbackState state);
}
