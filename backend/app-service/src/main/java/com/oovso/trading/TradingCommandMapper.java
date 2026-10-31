package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingCommandMapper extends BaseMapper<TradingCommand> {

    @Select("""
            select * from trading_command
            where app_user_id = #{userId}
              and idempotency_key = #{idempotencyKey}
            limit 1
            """)
    TradingCommand selectByIdempotency(
            @Param("userId") String userId,
            @Param("idempotencyKey") String idempotencyKey
    );

    @Select("""
            select * from trading_command
            where id = #{commandId}
              and trading_account_id = #{accountId}
            limit 1
            """)
    TradingCommand selectOwned(
            @Param("commandId") String commandId,
            @Param("accountId") String accountId
    );

    @Select("""
            select * from trading_command
            where trading_account_id = #{accountId}
              and status in (
                'PERSISTED', 'DISPATCHING', 'CONFIRMING', 'UNKNOWN',
                'RECONCILING'
              )
            order by create_time asc
            limit #{limit}
            """)
    List<TradingCommand> selectDispatchable(
            @Param("accountId") String accountId,
            @Param("limit") int limit
    );

    @Insert("""
            insert into trading_command (
                id, create_time, update_time, trading_account_id,
                app_user_id, idempotency_key, request_hash, request_json,
                command_type, status, client_order_id, client_algo_id,
                result_json, error_code, dispatched_at_ms,
                completed_at_ms, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{appUserId}, #{idempotencyKey}, #{requestHash},
                #{requestJson}, #{commandType}, #{status},
                #{clientOrderId}, #{clientAlgoId}, #{resultJson},
                #{errorCode}, #{dispatchedAtMs}, #{completedAtMs}, #{version}
            )
            """)
    int insertCommand(TradingCommand command);

    @Update("""
            update trading_command set
                update_time = current_timestamp,
                status = #{nextStatus},
                result_json = #{resultJson},
                error_code = #{errorCode},
                dispatched_at_ms = coalesce(
                    dispatched_at_ms,
                    #{dispatchedAtMs}
                ),
                completed_at_ms = #{completedAtMs},
                version = version + 1
            where id = #{commandId}
              and trading_account_id = #{accountId}
              and status = #{expectedStatus}
              and version = #{version}
            """)
    int transition(
            @Param("commandId") String commandId,
            @Param("accountId") String accountId,
            @Param("expectedStatus") String expectedStatus,
            @Param("nextStatus") String nextStatus,
            @Param("resultJson") String resultJson,
            @Param("errorCode") String errorCode,
            @Param("dispatchedAtMs") Long dispatchedAtMs,
            @Param("completedAtMs") Long completedAtMs,
            @Param("version") long version
    );
}
