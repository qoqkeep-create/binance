package com.oovso.trading;

import java.time.Duration;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.stereotype.Service;

@Service
public class TradingAccountLeaseService {

    private static final Logger log = LoggerFactory.getLogger(
            TradingAccountLeaseService.class
    );

    private static final DefaultRedisScript<Long> RENEW_SCRIPT =
            new DefaultRedisScript<>("""
                    if redis.call('get', KEYS[1]) == ARGV[1] then
                      return redis.call('pexpire', KEYS[1], ARGV[2])
                    end
                    return 0
                    """, Long.class);

    private static final DefaultRedisScript<Long> RELEASE_SCRIPT =
            new DefaultRedisScript<>("""
                    if redis.call('get', KEYS[1]) == ARGV[1] then
                      return redis.call('del', KEYS[1])
                    end
                    return 0
                    """, Long.class);

    private final StringRedisTemplate redisTemplate;
    private final TradingProperties properties;
    private final String instanceId = UUID.randomUUID().toString();

    public TradingAccountLeaseService(
            StringRedisTemplate redisTemplate,
            TradingProperties properties
    ) {
        this.redisTemplate = redisTemplate;
        this.properties = properties;
    }

    public Lease tryAcquire(String accountId) {
        String key = "trading:account-session:" + accountId;
        String value = instanceId + ':' + UUID.randomUUID();
        try {
            Boolean acquired = redisTemplate.opsForValue().setIfAbsent(
                    key,
                    value,
                    Duration.ofMillis(ttlMillis())
            );
            return Boolean.TRUE.equals(acquired)
                    ? new Lease(key, value)
                    : null;
        } catch (RuntimeException exception) {
            log.warn(
                    "Trading account lease acquisition failed accountId={}: {}",
                    accountId,
                    exception.getMessage()
            );
            return null;
        }
    }

    public boolean renew(Lease lease) {
        try {
            Long renewed = redisTemplate.execute(
                    RENEW_SCRIPT,
                    List.of(lease.key()),
                    lease.value(),
                    Long.toString(ttlMillis())
            );
            return Long.valueOf(1).equals(renewed);
        } catch (RuntimeException exception) {
            log.warn("Trading account lease renewal failed: {}", exception.getMessage());
            return false;
        }
    }

    public void release(Lease lease) {
        if (lease == null) {
            return;
        }
        try {
            redisTemplate.execute(
                    RELEASE_SCRIPT,
                    List.of(lease.key()),
                    lease.value()
            );
        } catch (RuntimeException exception) {
            log.warn("Trading account lease release failed: {}", exception.getMessage());
        }
    }

    private long ttlMillis() {
        return Math.max(5_000, properties.getSync().getLeaseTtlMillis());
    }

    public record Lease(String key, String value) {
    }
}
