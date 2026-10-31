package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface TradingExitStrategyLevelMapper
        extends BaseMapper<TradingExitStrategyLevel> {

    @Select("""
            select * from trading_exit_strategy_level
            where exit_strategy_id = #{strategyId}
            order by level_no asc
            """)
    List<TradingExitStrategyLevel> selectByStrategy(
            @Param("strategyId") String strategyId
    );

    @Insert("""
            insert into trading_exit_strategy_level (
                id, create_time, update_time, exit_strategy_id,
                level_no, trigger_r, reduce_percent,
                move_stop_mode, move_stop_r
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{exitStrategyId},
                #{levelNo}, #{triggerR}, #{reducePercent},
                #{moveStopMode}, #{moveStopR}
            )
            """)
    int insertLevel(TradingExitStrategyLevel level);

    @Delete("""
            delete from trading_exit_strategy_level
            where exit_strategy_id = #{strategyId}
            """)
    int deleteByStrategy(@Param("strategyId") String strategyId);
}
