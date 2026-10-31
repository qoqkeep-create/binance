package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface ExchangeOrderMapper extends BaseMapper<ExchangeOrder> {

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'REGULAR'
              and (
                (#{clientOrderId} is not null and client_order_id = #{clientOrderId})
                or (#{exchangeOrderId} is not null and exchange_order_id = #{exchangeOrderId})
              )
            order by update_time desc
            limit 1
            """)
    ExchangeOrder selectRegularByIdentity(
            @Param("accountId") String accountId,
            @Param("clientOrderId") String clientOrderId,
            @Param("exchangeOrderId") String exchangeOrderId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'ALGO'
              and (
                (#{clientAlgoId} is not null and client_algo_id = #{clientAlgoId})
                or (#{exchangeAlgoId} is not null and exchange_algo_id = #{exchangeAlgoId})
              )
            order by update_time desc
            limit 1
            """)
    ExchangeOrder selectAlgoByIdentity(
            @Param("accountId") String accountId,
            @Param("clientAlgoId") String clientAlgoId,
            @Param("exchangeAlgoId") String exchangeAlgoId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'REGULAR'
              and exchange_order_id = #{exchangeOrderId}
            limit 1
            """)
    ExchangeOrder selectRegularByExchangeId(
            @Param("accountId") String accountId,
            @Param("exchangeOrderId") String exchangeOrderId
    );

    @Select("""
            select * from exchange_order
            where id = #{orderId}
              and trading_account_id = #{accountId}
              and order_class = 'REGULAR'
            limit 1
            """)
    ExchangeOrder selectOwnedRegularById(
            @Param("accountId") String accountId,
            @Param("orderId") String orderId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED',
                'NEW', 'TRIGGERING', 'TRIGGERED'
              )
            order by symbol, order_class, create_time
            """)
    List<ExchangeOrder> selectActiveByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'REGULAR'
              and order_type = 'LIMIT'
              and purpose <> 'MANUAL_CLOSE'
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW'
              )
            order by exchange_create_ms desc, create_time desc
            """)
    List<ExchangeOrder> selectActiveLimitByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'REGULAR'
              and origin = 'SYSTEM'
              and purpose = 'MANUAL_CLOSE'
              and order_type = 'LIMIT'
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW'
              )
            order by create_time
            """)
    List<ExchangeOrder> selectActiveManualClosesByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'REGULAR'
              and origin = 'SYSTEM'
              and purpose = 'MANUAL_CLOSE'
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW'
              )
            order by create_time
            """)
    List<ExchangeOrder> selectActiveManualCloseOrdersByAccount(
            @Param("accountId") String accountId
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and trading_position_id = #{positionId}
              and position_generation = #{positionGeneration}
              and order_class = 'REGULAR'
              and origin = 'SYSTEM'
              and purpose = 'MANUAL_CLOSE'
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW'
              )
            order by create_time desc
            limit 1
            """)
    ExchangeOrder selectActiveManualClose(
            @Param("accountId") String accountId,
            @Param("positionId") String positionId,
            @Param("positionGeneration") long positionGeneration
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and trading_position_id = #{positionId}
              and position_generation = #{positionGeneration}
              and order_class = 'REGULAR'
              and origin = 'SYSTEM'
              and purpose = 'MANUAL_CLOSE'
            order by create_time desc
            limit 1
            """)
    ExchangeOrder selectLatestManualClose(
            @Param("accountId") String accountId,
            @Param("positionId") String positionId,
            @Param("positionGeneration") long positionGeneration
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and trading_position_id = #{positionId}
              and position_generation = #{positionGeneration}
              and origin = 'SYSTEM'
              and purpose = 'TAKE_PROFIT'
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW',
                'TRIGGERING', 'TRIGGERED'
              )
            order by create_time
            """)
    List<ExchangeOrder> selectActiveSystemTakeProfits(
            @Param("accountId") String accountId,
            @Param("positionId") String positionId,
            @Param("positionGeneration") long positionGeneration
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and order_class = 'ALGO'
              and origin = 'SYSTEM'
              and purpose = 'STOP'
              and symbol = #{symbol}
              and position_side = #{positionSide}
              and status in (
                'INTENT', 'SUBMITTING', 'UNKNOWN', 'UNRESOLVED',
                'NEW', 'TRIGGERING', 'TRIGGERED'
              )
            order by create_time
            """)
    List<ExchangeOrder> selectActiveSystemStops(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("positionSide") String positionSide
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and symbol = #{symbol}
              and position_side = #{positionSide}
              and (
                purpose in ('TAKE_PROFIT', 'STOP')
                or order_type in (
                  'TAKE_PROFIT', 'TAKE_PROFIT_MARKET',
                  'STOP', 'STOP_MARKET'
                )
              )
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED', 'NEW',
                'TRIGGERING', 'TRIGGERED'
              )
            order by create_time
            """)
    List<ExchangeOrder> selectActivePositionProtection(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("positionSide") String positionSide
    );

    @Select("""
            select * from exchange_order
            where trading_account_id = #{accountId}
              and purpose <> 'MANUAL_CLOSE'
            order by exchange_update_ms desc, create_time desc
            limit #{limit}
            """)
    List<ExchangeOrder> selectRecentByAccount(
            @Param("accountId") String accountId,
            @Param("limit") int limit
    );

    @Insert("""
            insert into exchange_order (
                id, create_time, update_time, trading_account_id,
                trading_position_id, position_generation, order_class,
                origin, purpose, symbol, side, position_side, order_type,
                time_in_force, working_type, client_order_id,
                exchange_order_id, client_algo_id, exchange_algo_id,
                actual_order_id, quantity, price, trigger_price,
                executed_quantity, cumulative_quote, average_price,
                reduce_only, close_position, status, exchange_status,
                execution_type, reject_reason, exchange_create_ms,
                exchange_update_ms, last_event_ms,
                last_reconcile_revision, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{tradingPositionId}, #{positionGeneration}, #{orderClass},
                #{origin}, #{purpose}, #{symbol}, #{side}, #{positionSide},
                #{orderType}, #{timeInForce}, #{workingType},
                #{clientOrderId}, #{exchangeOrderId}, #{clientAlgoId},
                #{exchangeAlgoId}, #{actualOrderId}, #{quantity}, #{price},
                #{triggerPrice}, #{executedQuantity}, #{cumulativeQuote},
                #{averagePrice}, #{reduceOnly}, #{closePosition}, #{status},
                #{exchangeStatus}, #{executionType}, #{rejectReason},
                #{exchangeCreateMs}, #{exchangeUpdateMs}, #{lastEventMs},
                #{lastReconcileRevision}, #{version}
            )
            """)
    int insertOrder(ExchangeOrder order);

    @Update("""
            update exchange_order set
                update_time = #{updateTime},
                trading_position_id = #{tradingPositionId},
                position_generation = #{positionGeneration},
                origin = #{origin},
                purpose = #{purpose},
                symbol = #{symbol},
                side = #{side},
                position_side = #{positionSide},
                order_type = #{orderType},
                time_in_force = #{timeInForce},
                working_type = #{workingType},
                client_order_id = #{clientOrderId},
                exchange_order_id = #{exchangeOrderId},
                client_algo_id = #{clientAlgoId},
                exchange_algo_id = #{exchangeAlgoId},
                actual_order_id = #{actualOrderId},
                quantity = #{quantity},
                price = #{price},
                trigger_price = #{triggerPrice},
                executed_quantity = #{executedQuantity},
                cumulative_quote = #{cumulativeQuote},
                average_price = #{averagePrice},
                reduce_only = #{reduceOnly},
                close_position = #{closePosition},
                status = #{status},
                exchange_status = #{exchangeStatus},
                execution_type = #{executionType},
                reject_reason = #{rejectReason},
                exchange_create_ms = #{exchangeCreateMs},
                exchange_update_ms = #{exchangeUpdateMs},
                last_event_ms = #{lastEventMs},
                last_reconcile_revision = #{lastReconcileRevision},
                version = version + 1
            where id = #{id} and version = #{version}
            """)
    int updateOrder(ExchangeOrder order);

    @Update("""
            update exchange_order set
                update_time = current_timestamp,
                status = 'UNRESOLVED',
                last_reconcile_revision = #{reconcileRevision},
                version = version + 1
            where id = #{id}
              and status in (
                'INTENT', 'SUBMITTING', 'LIVE', 'PARTIALLY_FILLED',
                'CANCEL_PENDING', 'UNKNOWN', 'UNRESOLVED',
                'NEW', 'TRIGGERING', 'TRIGGERED'
              )
            """)
    int markUnresolved(
            @Param("id") String id,
            @Param("reconcileRevision") long reconcileRevision
    );
}
