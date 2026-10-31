package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingRiskPolicyMapper extends BaseMapper<TradingRiskPolicy> {

    @Select("""
            select * from trading_risk_policy
            where trading_account_id = #{accountId}
            limit 1
            """)
    TradingRiskPolicy selectByAccount(@Param("accountId") String accountId);

    @Insert("""
            insert into trading_risk_policy (
                id, create_time, update_time, trading_account_id,
                policy_revision, enabled_state, take_profit_enabled,
                stop_loss_enabled, take_profit_percent,
                stop_loss_percent, max_loss_amount, settlement_asset,
                working_type, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{policyRevision}, #{enabledState}, #{takeProfitEnabled},
                #{stopLossEnabled}, #{takeProfitPercent},
                #{stopLossPercent}, #{maxLossAmount}, #{settlementAsset},
                #{workingType}, #{version}
            )
            """)
    int insertPolicy(TradingRiskPolicy policy);

    @Update("""
            update trading_risk_policy set
                update_time = #{updateTime},
                policy_revision = #{policyRevision},
                enabled_state = #{enabledState},
                take_profit_enabled = #{takeProfitEnabled},
                stop_loss_enabled = #{stopLossEnabled},
                take_profit_percent = #{takeProfitPercent},
                stop_loss_percent = #{stopLossPercent},
                max_loss_amount = #{maxLossAmount},
                settlement_asset = #{settlementAsset},
                working_type = #{workingType},
                version = version + 1
            where id = #{id} and trading_account_id = #{tradingAccountId}
              and version = #{version}
            """)
    int updatePolicy(TradingRiskPolicy policy);
}
