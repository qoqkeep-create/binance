package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.time.LocalDateTime;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingOrderSettingsMapper
        extends BaseMapper<TradingOrderSettings> {

    @Select("""
            select * from trading_order_settings
            where trading_account_id = #{accountId}
            limit 1
            """)
    TradingOrderSettings selectByAccount(
            @Param("accountId") String accountId
    );

    @Insert("""
            insert ignore into trading_order_settings (
                id, create_time, update_time, trading_account_id,
                revision, default_exit_strategy_id, entry_order_type,
                take_profit_order_type, stop_loss_order_type,
                fallback_market_stop_r, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{revision}, #{defaultExitStrategyId}, #{entryOrderType},
                #{takeProfitOrderType}, #{stopLossOrderType},
                #{fallbackMarketStopR}, #{version}
            )
            """)
    int insertSettings(TradingOrderSettings settings);

    @Update("""
            update trading_order_settings set
                update_time = #{updateTime},
                revision = #{revision},
                default_exit_strategy_id = #{defaultExitStrategyId},
                entry_order_type = #{entryOrderType},
                take_profit_order_type = #{takeProfitOrderType},
                stop_loss_order_type = #{stopLossOrderType},
                fallback_market_stop_r = #{fallbackMarketStopR},
                version = version + 1
            where id = #{id} and trading_account_id = #{tradingAccountId}
              and version = #{version}
            """)
    int updateSettings(TradingOrderSettings settings);

    @Update("""
            update trading_order_settings set
                update_time = #{updateTime},
                revision = revision + 1,
                default_exit_strategy_id = null,
                version = version + 1
            where trading_account_id = #{accountId}
              and default_exit_strategy_id = #{strategyId}
            """)
    int clearDefaultStrategy(
            @Param("accountId") String accountId,
            @Param("strategyId") String strategyId,
            @Param("updateTime") LocalDateTime updateTime
    );
}
