package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingLossLimitMapper extends BaseMapper<TradingLossLimit> {

    @Select("""
            select * from trading_loss_limit
            where trading_account_id = #{accountId}
            limit 1
            """)
    TradingLossLimit selectByAccount(@Param("accountId") String accountId);

    @Insert("""
            insert ignore into trading_loss_limit (
                id, create_time, update_time, trading_account_id,
                revision, current_percentage, current_amount,
                pending_percentage, pending_amount,
                pending_effective_at_ms, balance_snapshot,
                settlement_asset, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{revision}, #{currentPercentage}, #{currentAmount},
                #{pendingPercentage}, #{pendingAmount},
                #{pendingEffectiveAtMs}, #{balanceSnapshot},
                #{settlementAsset}, #{version}
            )
            """)
    int insertLimit(TradingLossLimit limit);

    @Update("""
            update trading_loss_limit set
                update_time = #{updateTime},
                revision = #{revision},
                current_percentage = #{currentPercentage},
                current_amount = #{currentAmount},
                pending_percentage = #{pendingPercentage},
                pending_amount = #{pendingAmount},
                pending_effective_at_ms = #{pendingEffectiveAtMs},
                balance_snapshot = #{balanceSnapshot},
                settlement_asset = #{settlementAsset},
                version = version + 1
            where id = #{id} and trading_account_id = #{tradingAccountId}
              and version = #{version}
            """)
    int updateLimit(TradingLossLimit limit);
}
