package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingPositionMapper extends BaseMapper<TradingPosition> {

    @Select("""
            select * from trading_position
            where trading_account_id = #{accountId}
            order by symbol, position_side
            """)
    List<TradingPosition> selectByAccount(@Param("accountId") String accountId);

    @Select("""
            select * from trading_position
            where trading_account_id = #{accountId} and status = 'OPEN'
            order by symbol, position_side
            """)
    List<TradingPosition> selectOpenByAccount(@Param("accountId") String accountId);

    @Select("""
            select * from trading_position
            where trading_account_id = #{accountId}
              and symbol = #{symbol}
              and position_side = #{positionSide}
            limit 1
            """)
    TradingPosition selectByKey(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("positionSide") String positionSide
    );

    @Select("""
            select * from trading_position
            where id = #{positionId}
              and trading_account_id = #{accountId}
            limit 1
            """)
    TradingPosition selectOwnedById(
            @Param("accountId") String accountId,
            @Param("positionId") String positionId
    );

    @Insert("""
            insert into trading_position (
                id, create_time, update_time, trading_account_id, symbol,
                position_side, generation, quantity, entry_price,
                break_even_price, mark_price, liquidation_price, leverage,
                margin_type, isolated_margin, unrealized_profit, status,
                exchange_update_ms, last_event_ms,
                last_reconcile_revision, continuity_status, source, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{symbol}, #{positionSide}, #{generation}, #{quantity},
                #{entryPrice}, #{breakEvenPrice}, #{markPrice},
                #{liquidationPrice}, #{leverage}, #{marginType},
                #{isolatedMargin}, #{unrealizedProfit}, #{status},
                #{exchangeUpdateMs}, #{lastEventMs},
                #{lastReconcileRevision}, #{continuityStatus}, #{source},
                #{version}
            ) on duplicate key update
                update_time = values(update_time),
                generation = values(generation),
                quantity = values(quantity),
                entry_price = values(entry_price),
                break_even_price = values(break_even_price),
                mark_price = values(mark_price),
                liquidation_price = values(liquidation_price),
                leverage = values(leverage),
                margin_type = values(margin_type),
                isolated_margin = values(isolated_margin),
                unrealized_profit = values(unrealized_profit),
                status = values(status),
                exchange_update_ms = greatest(
                    exchange_update_ms,
                    values(exchange_update_ms)
                ),
                last_event_ms = greatest(last_event_ms, values(last_event_ms)),
                last_reconcile_revision = greatest(
                    last_reconcile_revision,
                    values(last_reconcile_revision)
                ),
                continuity_status = values(continuity_status),
                source = values(source),
                version = version + 1
            """)
    int upsert(TradingPosition position);

    @Update("""
            update trading_position set
                update_time = current_timestamp,
                quantity = 0,
                status = 'CLOSED',
                version = version + 1
            where id = #{id} and trading_account_id = #{accountId}
              and status = 'OPEN'
            """)
    int closeById(
            @Param("id") String id,
            @Param("accountId") String accountId
    );

    @Update("""
            update trading_position set
                update_time = current_timestamp,
                quantity = 0,
                status = 'CLOSED',
                last_reconcile_revision = #{reconcileRevision},
                source = 'REST',
                version = version + 1
            where id = #{id} and trading_account_id = #{accountId}
              and status = 'OPEN'
            """)
    int closeByIdAtRevision(
            @Param("id") String id,
            @Param("accountId") String accountId,
            @Param("reconcileRevision") long reconcileRevision
    );

    @Update("""
            update trading_position set
                update_time = current_timestamp,
                continuity_status = 'UNCERTAIN',
                version = version + 1
            where id = #{id} and trading_account_id = #{accountId}
              and status = 'OPEN'
            """)
    int markContinuityUncertain(
            @Param("id") String id,
            @Param("accountId") String accountId
    );

    @Update("""
            update trading_position set
                update_time = current_timestamp,
                leverage = #{leverage},
                version = version + 1
            where trading_account_id = #{accountId}
              and symbol = #{symbol}
              and status = 'OPEN'
            """)
    int updateLeverageBySymbol(
            @Param("accountId") String accountId,
            @Param("symbol") String symbol,
            @Param("leverage") int leverage
    );

    @Update("""
            update trading_position set
                update_time = current_timestamp,
                quantity = 0,
                status = 'CLOSED',
                version = version + 1
            where trading_account_id = #{accountId} and status = 'OPEN'
            """)
    int closeAll(@Param("accountId") String accountId);
}
