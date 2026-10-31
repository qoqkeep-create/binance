package com.oovso.trading;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import lombok.Data;

@Data
@TableName("trading_account")
public class TradingAccount {

    @TableId(type = IdType.INPUT)
    private String id;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
    private Integer deleteState;
    private String appUserId;
    private String exchange;
    private String marketType;
    private String environment;
    private String label;
    private String quoteAsset;
    private String credentialCiphertext;
    private String credentialNonce;
    private String credentialFingerprint;
    private String apiKeyMasked;
    private String credentialKeyVersion;
    private String positionMode;
    private String status;
    private String syncStatus;
    private BigDecimal totalMarginBalance;
    private BigDecimal unrealizedProfit;
    private Long lastVerifiedAtMs;
    private Long lastSyncedAtMs;
    private Long streamGeneration;
    private Long lastStreamEventMs;
    private Long lastStreamConnectedAtMs;
    private Long lastReconciledAtMs;
    private Long lastFullDiscoveryAtMs;
    private String lastSyncErrorCode;
    private Integer consecutiveSyncFailureCount;
    private Long reconcileRevision;
    private Long executionFenceToken;
    private Long version;
}
