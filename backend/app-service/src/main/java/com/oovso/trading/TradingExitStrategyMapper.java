package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingExitStrategyMapper
        extends BaseMapper<TradingExitStrategy> {

    @Select("""
            select * from trading_exit_strategy
            where trading_account_id = #{accountId}
            order by create_time asc, id asc
            """)
    List<TradingExitStrategy> selectByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from trading_exit_strategy
            where id = #{strategyId} and trading_account_id = #{accountId}
            limit 1
            """)
    TradingExitStrategy selectOwned(
            @Param("strategyId") String strategyId,
            @Param("accountId") String accountId
    );

    @Insert("""
            insert into trading_exit_strategy (
                id, create_time, update_time, trading_account_id,
                strategy_name, strategy_revision, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{strategyName}, #{strategyRevision}, #{version}
            )
            """)
    int insertStrategy(TradingExitStrategy strategy);

    @Update("""
            update trading_exit_strategy set
                update_time = #{updateTime},
                strategy_name = #{strategyName},
                strategy_revision = #{strategyRevision},
                version = version + 1
            where id = #{id} and trading_account_id = #{tradingAccountId}
              and version = #{version}
            """)
    int updateStrategy(TradingExitStrategy strategy);

    @Delete("""
            delete from trading_exit_strategy
            where id = #{strategyId} and trading_account_id = #{accountId}
            """)
    int deleteOwned(
            @Param("strategyId") String strategyId,
            @Param("accountId") String accountId
    );
}
