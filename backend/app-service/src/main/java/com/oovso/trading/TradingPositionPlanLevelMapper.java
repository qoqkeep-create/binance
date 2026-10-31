package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingPositionPlanLevelMapper
        extends BaseMapper<TradingPositionPlanLevel> {

    @Select("""
            select * from trading_position_plan_level
            where trading_position_plan_id = #{planId}
            order by level_no asc
            """)
    List<TradingPositionPlanLevel> selectByPlan(
            @Param("planId") String planId
    );

    @Insert("""
            insert into trading_position_plan_level (
                id, create_time, update_time, trading_position_plan_id,
                source_level_id, level_no, trigger_r, reduce_percent,
                move_stop_mode, move_stop_r, status, reduction_status,
                reduction_client_order_id, reduction_revision,
                planned_reduction_quantity, executed_reduction_quantity,
                reduction_order_base_executed_quantity,
                reduction_next_retry_at_ms, reduction_repair_attempts,
                triggered_price,
                triggered_at_ms, stop_move_activated,
                last_error_code, version
            ) values (
                #{id}, #{createTime}, #{updateTime},
                #{tradingPositionPlanId}, #{sourceLevelId}, #{levelNo},
                #{triggerR}, #{reducePercent}, #{moveStopMode},
                #{moveStopR}, #{status}, #{reductionStatus},
                #{reductionClientOrderId}, #{reductionRevision},
                #{plannedReductionQuantity}, #{executedReductionQuantity},
                #{reductionOrderBaseExecutedQuantity},
                #{reductionNextRetryAtMs}, #{reductionRepairAttempts},
                #{triggeredPrice},
                #{triggeredAtMs}, #{stopMoveActivated},
                #{lastErrorCode}, #{version}
            )
            """)
    int insertLevel(TradingPositionPlanLevel level);

    @Update("""
            update trading_position_plan_level set
                update_time = #{updateTime},
                status = #{status},
                reduction_status = #{reductionStatus},
                reduction_client_order_id = #{reductionClientOrderId},
                reduction_revision = #{reductionRevision},
                planned_reduction_quantity = #{plannedReductionQuantity},
                executed_reduction_quantity = #{executedReductionQuantity},
                reduction_order_base_executed_quantity =
                    #{reductionOrderBaseExecutedQuantity},
                reduction_next_retry_at_ms = #{reductionNextRetryAtMs},
                reduction_repair_attempts = #{reductionRepairAttempts},
                triggered_price = #{triggeredPrice},
                triggered_at_ms = #{triggeredAtMs},
                stop_move_activated = #{stopMoveActivated},
                last_error_code = #{lastErrorCode},
                version = version + 1
            where id = #{id}
              and trading_position_plan_id = #{tradingPositionPlanId}
              and version = #{version}
            """)
    int updateLevel(TradingPositionPlanLevel level);
}
