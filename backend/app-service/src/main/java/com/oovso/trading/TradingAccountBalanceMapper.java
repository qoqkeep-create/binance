package com.oovso.trading;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import java.util.List;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface TradingAccountBalanceMapper
        extends BaseMapper<TradingAccountBalance> {

    @Select("""
            select * from trading_account_balance
            where trading_account_id = #{accountId}
            order by asset
            """)
    List<TradingAccountBalance> selectByAccount(
            @Param("accountId") String accountId
    );

    @Insert("""
            insert into trading_account_balance (
                id, create_time, update_time, trading_account_id, asset,
                wallet_balance, cross_wallet_balance, balance_change,
                last_event_ms, last_reconcile_revision, version
            ) values (
                #{id}, #{createTime}, #{updateTime}, #{tradingAccountId},
                #{asset}, #{walletBalance}, #{crossWalletBalance},
                #{balanceChange}, #{lastEventMs}, #{lastReconcileRevision},
                #{version}
            ) on duplicate key update
                update_time = values(update_time),
                wallet_balance = if(
                    values(last_reconcile_revision) > last_reconcile_revision
                    or values(last_event_ms) >= last_event_ms,
                    values(wallet_balance),
                    wallet_balance
                ),
                cross_wallet_balance = if(
                    values(last_reconcile_revision) > last_reconcile_revision
                    or values(last_event_ms) >= last_event_ms,
                    values(cross_wallet_balance),
                    cross_wallet_balance
                ),
                balance_change = if(
                    values(last_reconcile_revision) > last_reconcile_revision
                    or values(last_event_ms) >= last_event_ms,
                    values(balance_change),
                    balance_change
                ),
                last_event_ms = greatest(last_event_ms, values(last_event_ms)),
                last_reconcile_revision = greatest(
                    last_reconcile_revision,
                    values(last_reconcile_revision)
                ),
                version = version + 1
            """)
    int upsert(TradingAccountBalance balance);
}
