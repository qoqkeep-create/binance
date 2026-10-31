package com.oovso.market;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface MarketKlineMapper extends BaseMapper<MarketKline> {

    @Insert("""
            insert into market_kline (
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
                event_time_ms,
                open_price,
                high_price,
                low_price,
                close_price,
                volume,
                quote_volume,
                trade_count,
                taker_buy_volume,
                taker_buy_quote_volume,
                closed_state,
                source_interval
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
                #{eventTimeMs},
                #{openPrice},
                #{highPrice},
                #{lowPrice},
                #{closePrice},
                #{volume},
                #{quoteVolume},
                #{tradeCount},
                #{takerBuyVolume},
                #{takerBuyQuoteVolume},
                #{closedState},
                #{sourceInterval}
            )
            on duplicate key update
                update_time = values(update_time),
                update_user = values(update_user),
                delete_state = values(delete_state),
                close_time_ms = values(close_time_ms),
                event_time_ms = values(event_time_ms),
                open_price = values(open_price),
                high_price = values(high_price),
                low_price = values(low_price),
                close_price = values(close_price),
                volume = values(volume),
                quote_volume = values(quote_volume),
                trade_count = values(trade_count),
                taker_buy_volume = values(taker_buy_volume),
                taker_buy_quote_volume = values(taker_buy_quote_volume),
                closed_state = values(closed_state),
                source_interval = values(source_interval)
            """)
    int upsert(MarketKline kline);

    @Select("""
            select *
            from market_kline
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
              and interval_code = #{intervalCode}
              and open_time_ms >= #{startOpenTimeMs}
              and open_time_ms < #{endOpenTimeMs}
              and closed_state = 1
              and delete_state = 0
            order by open_time_ms asc
            """)
    List<MarketKline> selectClosedInRange(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("pair") String pair,
            @Param("intervalCode") String intervalCode,
            @Param("startOpenTimeMs") long startOpenTimeMs,
            @Param("endOpenTimeMs") long endOpenTimeMs
    );

    @Select("""
            select open_time_ms
            from market_kline
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
              and interval_code = #{intervalCode}
              and open_time_ms >= #{startOpenTimeMs}
              and open_time_ms < #{endOpenTimeMs}
              and closed_state = 1
              and delete_state = 0
            order by open_time_ms asc
            """)
    List<Long> selectClosedOpenTimesInRange(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("pair") String pair,
            @Param("intervalCode") String intervalCode,
            @Param("startOpenTimeMs") long startOpenTimeMs,
            @Param("endOpenTimeMs") long endOpenTimeMs
    );

    @Select("""
            select *
            from market_kline
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
              and interval_code = #{intervalCode}
              and closed_state = 1
              and delete_state = 0
            order by open_time_ms desc
            limit #{limit}
            """)
    List<MarketKline> selectLatestClosed(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("pair") String pair,
            @Param("intervalCode") String intervalCode,
            @Param("limit") int limit
    );

    @Select("""
            select *
            from market_kline
            where exchange = #{exchange}
              and market_type = #{marketType}
              and contract_type = #{contractType}
              and pair = #{pair}
              and interval_code = #{intervalCode}
              and open_time_ms < #{beforeOpenTimeMs}
              and closed_state = 1
              and delete_state = 0
            order by open_time_ms desc
            limit #{limit}
            """)
    List<MarketKline> selectClosedBefore(
            @Param("exchange") String exchange,
            @Param("marketType") String marketType,
            @Param("contractType") String contractType,
            @Param("pair") String pair,
            @Param("intervalCode") String intervalCode,
            @Param("beforeOpenTimeMs") long beforeOpenTimeMs,
            @Param("limit") int limit
    );
}
