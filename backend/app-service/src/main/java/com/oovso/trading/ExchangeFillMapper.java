package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface ExchangeFillMapper extends BaseMapper<ExchangeFill> {

    @Insert("""
            insert ignore into exchange_fill (
                id, create_time, trading_account_id, exchange_order_row_id,
                symbol, trade_id, order_id, side, position_side, price,
                quantity, quote_quantity, commission, commission_asset,
                realized_pnl, maker, trade_time_ms
            ) values (
                #{id}, #{createTime}, #{tradingAccountId},
                #{exchangeOrderRowId}, #{symbol}, #{tradeId}, #{orderId},
                #{side}, #{positionSide}, #{price}, #{quantity},
                #{quoteQuantity}, #{commission}, #{commissionAsset},
                #{realizedPnl}, #{maker}, #{tradeTimeMs}
            )
            """)
    int insertIgnore(ExchangeFill fill);

    @Select("""
            select * from exchange_fill
            where trading_account_id = #{accountId}
            order by trade_time_ms desc
            limit #{limit}
            """)
    List<ExchangeFill> selectRecentByAccount(
            @Param("accountId") String accountId,
            @Param("limit") int limit
    );

    @Select("""
            select * from (
                select * from exchange_fill
                where trading_account_id = #{accountId}
                order by trade_time_ms desc, id desc
                limit #{limit}
            ) recent_fills
            order by trade_time_ms, id
            """)
    List<ExchangeFill> selectRecentForPositionHistory(
            @Param("accountId") String accountId,
            @Param("limit") int limit
    );
}
