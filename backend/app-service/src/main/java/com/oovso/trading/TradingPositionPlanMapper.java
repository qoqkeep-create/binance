package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingPositionPlanMapper
        extends BaseMapper<TradingPositionPlan> {

    @Select("""
            select * from trading_position_plan
            where trading_command_id = #{commandId}
            limit 1
            """)
    TradingPositionPlan selectByCommand(@Param("commandId") String commandId);

    @Select("""
            select * from trading_position_plan
            where trading_account_id = #{accountId}
              and entry_client_order_id = #{clientOrderId}
            limit 1
            """)
    TradingPositionPlan selectByEntryClientOrderId(
            @Param("accountId") String accountId,
            @Param("clientOrderId") String clientOrderId
    );

    @Select("""
            select * from trading_position_plan
            where id = #{planId} and trading_account_id = #{accountId}
            limit 1
            """)
    TradingPositionPlan selectOwned(
            @Param("planId") String planId,
            @Param("accountId") String accountId
    );

    @Select("""
            select * from trading_position_plan
            where trading_account_id = #{accountId}
              and status in (
                'ENTRY_PENDING', 'ENTRY_LIVE', 'ACTIVE', 'DEGRADED',
                'MANUAL_CLOSING'
              )
            order by create_time asc
            """)
    List<TradingPositionPlan> selectActiveByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from trading_position_plan
            where trading_account_id = #{accountId}
              and symbol = #{symbol}
              and position_side = #{positionSide}
              and status in (
                'ENTRY_PENDING', 'ENTRY_LIVE', 'ACTIVE', 'DEGRADED',
                'MANUAL_CLOSING'
              )
            order by create_time desc
            limit 1
            """)
    TradingPositionPlan selectActiveByKey(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("positionSide") String positionSide
    );

    @Select("""
            select count(*) from trading_position_plan
            where trading_account_id = #{accountId}
              and symbol = #{symbol}
              and position_side = #{positionSide}
              and status in (
                'ENTRY_PENDING', 'ENTRY_LIVE', 'ACTIVE', 'DEGRADED',
                'MANUAL_CLOSING'
              )
            """)
    int countActiveByKey(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("positionSide") String positionSide
    );

    @Insert("""
            insert into trading_position_plan (
                id, create_time, update_time, trading_account_id,
                trading_command_id, trading_position_id,
                position_generation, symbol, direction, position_side,
                entry_side, status, entry_order_type,
                take_profit_order_type, stop_loss_order_type, working_type,
                order_settings_revision, exit_strategy_id,
                exit_strategy_revision, execution_snapshot_json,
                execution_snapshot_hash, settlement_asset,
                configured_r_amount, actual_initial_r_amount,
                reference_entry_price, requested_entry_price,
                average_entry_price, initial_stop_price,
                current_stop_price, risk_per_unit, planned_quantity,
                initial_filled_quantity, filled_quantity,
                protected_quantity, remaining_quantity, price_tick,
                quantity_step, market_quantity_step, min_quantity,
                min_notional, fallback_market_stop_r,
                entry_client_order_id, primary_stop_client_algo_id,
                fallback_stop_client_algo_id, stop_revision,
                last_strategy_evaluated_ms, last_order_health_check_ms,
                next_protection_repair_at_ms, protection_repair_attempts,
                execution_fence_token,
                last_error_code, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{tradingCommandId}, #{tradingPositionId},
                #{positionGeneration}, #{symbol}, #{direction},
                #{positionSide}, #{entrySide}, #{status},
                #{entryOrderType}, #{takeProfitOrderType},
                #{stopLossOrderType}, #{workingType},
                #{orderSettingsRevision}, #{exitStrategyId},
                #{exitStrategyRevision}, #{executionSnapshotJson},
                #{executionSnapshotHash}, #{settlementAsset},
                #{configuredRAmount}, #{actualInitialRAmount},
                #{referenceEntryPrice}, #{requestedEntryPrice},
                #{averageEntryPrice}, #{initialStopPrice},
                #{currentStopPrice}, #{riskPerUnit}, #{plannedQuantity},
                #{initialFilledQuantity}, #{filledQuantity},
                #{protectedQuantity}, #{remainingQuantity}, #{priceTick},
                #{quantityStep}, #{marketQuantityStep}, #{minQuantity},
                #{minNotional}, #{fallbackMarketStopR},
                #{entryClientOrderId}, #{primaryStopClientAlgoId},
                #{fallbackStopClientAlgoId}, #{stopRevision},
                #{lastStrategyEvaluatedMs}, #{lastOrderHealthCheckMs},
                #{nextProtectionRepairAtMs}, #{protectionRepairAttempts},
                #{executionFenceToken},
                #{lastErrorCode}, #{version}
            )
            """)
    int insertPlan(TradingPositionPlan plan);

    @Update("""
            update trading_position_plan set
                update_time = #{updateTime},
                trading_position_id = #{tradingPositionId},
                position_generation = #{positionGeneration},
                status = #{status},
                actual_initial_r_amount = #{actualInitialRAmount},
                average_entry_price = #{averageEntryPrice},
                current_stop_price = #{currentStopPrice},
                risk_per_unit = #{riskPerUnit},
                initial_filled_quantity = #{initialFilledQuantity},
                filled_quantity = #{filledQuantity},
                protected_quantity = #{protectedQuantity},
                remaining_quantity = #{remainingQuantity},
                primary_stop_client_algo_id = #{primaryStopClientAlgoId},
                fallback_stop_client_algo_id = #{fallbackStopClientAlgoId},
                stop_revision = #{stopRevision},
                last_strategy_evaluated_ms = #{lastStrategyEvaluatedMs},
                last_order_health_check_ms = #{lastOrderHealthCheckMs},
                next_protection_repair_at_ms = #{nextProtectionRepairAtMs},
                protection_repair_attempts = #{protectionRepairAttempts},
                execution_fence_token = #{executionFenceToken},
                last_error_code = #{lastErrorCode},
                version = version + 1
            where id = #{id}
              and trading_account_id = #{tradingAccountId}
              and version = #{version}
            """)
    int updatePlan(TradingPositionPlan plan);
}
