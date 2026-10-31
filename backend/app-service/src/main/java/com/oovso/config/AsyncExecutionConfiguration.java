package com.oovso.config;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableAsync
public class AsyncExecutionConfiguration {

    @Bean(destroyMethod = "shutdownNow")
    public ExecutorService marketKlineEventExecutor() {
        return Executors.newThreadPerTaskExecutor(
                Thread.ofVirtual().name("market-kline-event-", 0).factory()
        );
    }
}
