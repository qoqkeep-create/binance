package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingExchangeEventMapper
        extends BaseMapper<TradingExchangeEvent> {

    @Insert("""
            insert ignore into trading_exchange_event (
                id, create_time, trading_account_id, event_type, event_hash,
                exchange_event_ms, transaction_ms, received_at_ms,
                entity_key, normalized_summary, applied_state
            ) values (
                #{id}, #{createTime}, #{tradingAccountId}, #{eventType},
                #{eventHash}, #{exchangeEventMs}, #{transactionMs},
                #{receivedAtMs}, #{entityKey}, #{normalizedSummary},
                #{appliedState}
            )
            """)
    int insertIgnore(TradingExchangeEvent event);

    @Update("""
            update trading_exchange_event
            set applied_state = #{state}
            where id = #{id}
            """)
    int updateAppliedState(
            @Param("id") String id,
            @Param("state") String state
    );
}
