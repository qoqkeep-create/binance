package com.oovso.indicator;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface MarketIndicatorMapper extends BaseMapper<MarketIndicator> {

    @Insert("""
            insert into market_indicator (
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
                open_time_ms,
                close_time_ms,
                indicator_code,
                indicator_value,
                direction,
                extra_json
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
                #{openTimeMs},
                #{closeTimeMs},
                #{indicatorCode},
                #{indicatorValue},
                #{direction},
                #{extraJson}
            )
            on duplicate key update
                update_time = values(update_time),
                update_user = values(update_user),
                delete_state = values(delete_state),
                close_time_ms = values(close_time_ms),
                indicator_value = values(indicator_value),
                direction = values(direction),
                extra_json = values(extra_json)
            """)
    int upsert(MarketIndicator indicator);
}
