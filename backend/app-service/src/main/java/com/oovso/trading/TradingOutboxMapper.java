package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingOutboxMapper extends BaseMapper<TradingOutbox> {

    @Insert("""
            insert into trading_outbox (
                id, create_time, update_time, trading_account_id,
                app_user_id, channel, event_name, event_key, symbol,
                payload_json, status, attempts, available_at_ms,
                locked_at_ms, published_at_ms
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{appUserId}, #{channel}, #{eventName}, #{eventKey},
                #{symbol}, #{payloadJson}, #{status}, #{attempts},
                #{availableAtMs}, #{lockedAtMs}, #{publishedAtMs}
            )
            """)
    int insertOutbox(TradingOutbox outbox);

    @Select("""
            select * from trading_outbox
            where status = 'PENDING' and available_at_ms <= #{nowMillis}
            order by create_time
            limit #{limit}
            """)
    List<TradingOutbox> selectPending(
            @Param("nowMillis") long nowMillis,
            @Param("limit") int limit
    );

    @Update("""
            update trading_outbox set
                update_time = current_timestamp,
                status = 'PROCESSING',
                locked_at_ms = #{lockedAtMillis}
            where id = #{id} and status = 'PENDING'
            """)
    int claim(
            @Param("id") String id,
            @Param("lockedAtMillis") long lockedAtMillis
    );

    @Update("""
            update trading_outbox set
                update_time = current_timestamp,
                status = 'PUBLISHED',
                attempts = attempts + 1,
                published_at_ms = #{publishedAtMillis}
            where id = #{id} and status = 'PROCESSING'
            """)
    int markPublished(
            @Param("id") String id,
            @Param("publishedAtMillis") long publishedAtMillis
    );

    @Update("""
            update trading_outbox set
                update_time = current_timestamp,
                attempts = attempts + 1,
                status = case when attempts + 1 >= 10 then 'FAILED' else 'PENDING' end,
                available_at_ms = #{availableAtMillis},
                locked_at_ms = null
            where id = #{id} and status = 'PROCESSING'
            """)
    int markRetry(
            @Param("id") String id,
            @Param("availableAtMillis") long availableAtMillis
    );

    @Update("""
            update trading_outbox set
                update_time = current_timestamp,
                status = 'PENDING',
                locked_at_ms = null,
                available_at_ms = #{availableAtMillis}
            where status = 'PROCESSING'
              and locked_at_ms < #{staleBeforeMillis}
            """)
    int releaseStaleClaims(
            @Param("staleBeforeMillis") long staleBeforeMillis,
            @Param("availableAtMillis") long availableAtMillis
    );
}
