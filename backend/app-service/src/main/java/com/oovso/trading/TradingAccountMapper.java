package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface TradingAccountMapper extends BaseMapper<TradingAccount> {

    @Select("""
            select * from trading_account
            where app_user_id = #{userId}
              and exchange = 'BINANCE'
              and market_type = 'USDM'
              and environment = 'LIVE'
              and delete_state = 0
            limit 1
            """)
    TradingAccount selectByUser(@Param("userId") String userId);

    @Select("""
            select * from trading_account
            where id = #{accountId}
              and app_user_id = #{userId}
              and delete_state = 0
              and status in ('ACTIVE', 'PAUSED')
            limit 1
            """)
    TradingAccount selectActiveOwned(
            @Param("accountId") String accountId,
            @Param("userId") String userId
    );

    @Select("""
            select * from trading_account
            where id = #{accountId}
              and app_user_id = #{userId}
              and delete_state = 0
              and status <> 'DISABLED'
            limit 1
            """)
    TradingAccount selectOwned(
            @Param("accountId") String accountId,
            @Param("userId") String userId
    );

    @Select("""
            select * from trading_account
            where id = #{accountId}
              and app_user_id = #{userId}
              and delete_state = 0
              and status <> 'DISABLED'
            limit 1
            for update
            """)
    TradingAccount selectOwnedForUpdate(
            @Param("accountId") String accountId,
            @Param("userId") String userId
    );

    @Select("""
            select * from trading_account
            where id = #{accountId}
              and delete_state = 0
              and status in ('ACTIVE', 'PAUSED')
              and credential_ciphertext is not null
            limit 1
            """)
    TradingAccount selectListenableById(@Param("accountId") String accountId);

    @Select("""
            select * from trading_account
            where delete_state = 0
              and status in ('ACTIVE', 'PAUSED')
              and credential_ciphertext is not null
              and credential_nonce is not null
            order by id
            """)
    List<TradingAccount> selectListenableAccounts();

    @Insert("""
            insert into trading_account (
                id, create_time, update_time, delete_state, app_user_id,
                exchange, market_type, environment, label, quote_asset,
                credential_ciphertext, credential_nonce,
                credential_fingerprint, api_key_masked,
                credential_key_version, position_mode, status, sync_status,
                total_margin_balance, unrealized_profit,
                last_verified_at_ms, last_synced_at_ms,
                stream_generation, last_stream_event_ms,
                last_stream_connected_at_ms, last_reconciled_at_ms,
                last_full_discovery_at_ms, last_sync_error_code,
                consecutive_sync_failure_count, reconcile_revision,
                execution_fence_token, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{deleteState},
                #{appUserId}, #{exchange}, #{marketType}, #{environment},
                #{label}, #{quoteAsset}, #{credentialCiphertext},
                #{credentialNonce}, #{credentialFingerprint},
                #{apiKeyMasked}, #{credentialKeyVersion}, #{positionMode},
                #{status}, #{syncStatus}, #{totalMarginBalance},
                #{unrealizedProfit}, #{lastVerifiedAtMs}, #{lastSyncedAtMs},
                #{streamGeneration}, #{lastStreamEventMs},
                #{lastStreamConnectedAtMs}, #{lastReconciledAtMs},
                #{lastFullDiscoveryAtMs}, #{lastSyncErrorCode},
                #{consecutiveSyncFailureCount}, #{reconcileRevision},
                #{executionFenceToken}, #{version}
            )
            """)
    int insertAccount(TradingAccount account);

    @Update("""
            update trading_account set
                update_time = #{updateTime},
                quote_asset = #{quoteAsset},
                credential_ciphertext = #{credentialCiphertext},
                credential_nonce = #{credentialNonce},
                credential_fingerprint = #{credentialFingerprint},
                api_key_masked = #{apiKeyMasked},
                credential_key_version = #{credentialKeyVersion},
                position_mode = #{positionMode},
                status = 'ACTIVE',
                sync_status = #{syncStatus},
                total_margin_balance = #{totalMarginBalance},
                unrealized_profit = #{unrealizedProfit},
                last_verified_at_ms = #{lastVerifiedAtMs},
                last_synced_at_ms = #{lastSyncedAtMs},
                last_sync_error_code = null,
                consecutive_sync_failure_count = 0,
                execution_fence_token = execution_fence_token + 1,
                version = version + 1
            where id = #{id} and app_user_id = #{appUserId}
              and version = #{version}
            """)
    int updateBinding(TradingAccount account);

    @Update("""
            update trading_account set
                update_time = #{updateTime},
                quote_asset = #{quoteAsset},
                position_mode = #{positionMode},
                total_margin_balance = #{totalMarginBalance},
                unrealized_profit = #{unrealizedProfit},
                last_synced_at_ms = #{lastSyncedAtMs},
                version = version + 1
            where id = #{id} and app_user_id = #{appUserId}
              and status = 'ACTIVE' and delete_state = 0
              and version = #{version}
            """)
    int updateSnapshot(TradingAccount account);

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                credential_ciphertext = null,
                credential_nonce = null,
                credential_fingerprint = null,
                api_key_masked = null,
                credential_key_version = null,
                status = 'DISABLED',
                sync_status = 'STOPPED',
                total_margin_balance = 0,
                unrealized_profit = 0,
                execution_fence_token = execution_fence_token + 1,
                version = version + 1
            where id = #{accountId} and app_user_id = #{userId}
              and delete_state = 0 and status = 'ACTIVE'
            """)
    int disable(
            @Param("accountId") String accountId,
            @Param("userId") String userId
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                sync_status = 'CONNECTING',
                execution_fence_token = execution_fence_token + 1,
                last_sync_error_code = null,
                version = version + 1
            where id = #{accountId}
              and delete_state = 0
              and status in ('ACTIVE', 'PAUSED')
              and credential_ciphertext is not null
            """)
    int claimFence(@Param("accountId") String accountId);

    @Select("""
            select execution_fence_token from trading_account
            where id = #{accountId} and delete_state = 0
            """)
    Long selectFenceToken(@Param("accountId") String accountId);

    @Select("""
            select count(*) from trading_account
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
              and status in ('ACTIVE', 'PAUSED')
            """)
    int isFenceCurrent(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                sync_status = #{syncStatus},
                last_sync_error_code = #{errorCode},
                consecutive_sync_failure_count = case
                    when #{failure} = 1 then consecutive_sync_failure_count + 1
                    else 0
                end,
                version = version + 1
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
            """)
    int updateSyncStatus(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken,
            @Param("syncStatus") String syncStatus,
            @Param("errorCode") String errorCode,
            @Param("failure") int failure
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                sync_status = 'BUFFERING',
                stream_generation = stream_generation + 1,
                last_stream_connected_at_ms = #{connectedAtMs},
                last_sync_error_code = null,
                version = version + 1
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
            """)
    int markStreamConnected(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken,
            @Param("connectedAtMs") long connectedAtMs
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                last_stream_event_ms = greatest(
                    coalesce(last_stream_event_ms, 0),
                    #{eventTimeMs}
                ),
                version = version + 1
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
            """)
    int markStreamEvent(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken,
            @Param("eventTimeMs") long eventTimeMs
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                quote_asset = #{quoteAsset},
                position_mode = #{positionMode},
                total_margin_balance = #{totalMarginBalance},
                unrealized_profit = #{unrealizedProfit},
                last_synced_at_ms = #{reconciledAtMs},
                last_reconciled_at_ms = #{reconciledAtMs},
                last_full_discovery_at_ms = case
                    when #{fullDiscovery} = 1 then #{reconciledAtMs}
                    else last_full_discovery_at_ms
                end,
                reconcile_revision = #{reconcileRevision},
                version = version + 1
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
            """)
    int updateReconciledSnapshot(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken,
            @Param("quoteAsset") String quoteAsset,
            @Param("positionMode") String positionMode,
            @Param("totalMarginBalance") java.math.BigDecimal totalMarginBalance,
            @Param("unrealizedProfit") java.math.BigDecimal unrealizedProfit,
            @Param("reconciledAtMs") long reconciledAtMs,
            @Param("reconcileRevision") long reconcileRevision,
            @Param("fullDiscovery") int fullDiscovery
    );

    @Update("""
            update trading_account set
                update_time = current_timestamp,
                status = 'CREDENTIAL_ERROR',
                sync_status = 'AUTH_FAILED',
                last_sync_error_code = #{errorCode},
                consecutive_sync_failure_count = consecutive_sync_failure_count + 1,
                execution_fence_token = execution_fence_token + 1,
                version = version + 1
            where id = #{accountId}
              and execution_fence_token = #{fenceToken}
              and delete_state = 0
            """)
    int markCredentialError(
            @Param("accountId") String accountId,
            @Param("fenceToken") long fenceToken,
            @Param("errorCode") String errorCode
    );

}
