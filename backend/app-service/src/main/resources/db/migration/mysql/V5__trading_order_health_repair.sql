-- Flyway V5: immutable execution snapshot audit and persisted order repair cursors.
alter table trading_position_plan
    add column execution_snapshot_json text character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '建仓时冻结的完整执行设置与策略快照JSON' after exit_strategy_revision,
    add column execution_snapshot_hash varchar(64) character set ascii collate ascii_bin default null comment '执行快照SHA-256' after execution_snapshot_json,
    add column last_order_health_check_ms bigint default null comment '最近保护与止盈订单健康巡检时间' after last_strategy_evaluated_ms,
    add column next_protection_repair_at_ms bigint default null comment '下一次保护单允许补挂时间' after last_order_health_check_ms,
    add column protection_repair_attempts int not null default 0 comment '连续保护单补挂失败次数' after next_protection_repair_at_ms;

alter table trading_position_plan_level
    add column reduction_revision bigint not null default 0 comment '止盈减仓订单修复版本' after reduction_client_order_id,
    add column reduction_order_base_executed_quantity decimal(38, 18) not null default 0 comment '当前减仓订单提交前累计已成交数量' after executed_reduction_quantity,
    add column reduction_next_retry_at_ms bigint default null comment '下一次减仓单允许补挂时间' after reduction_order_base_executed_quantity,
    add column reduction_repair_attempts int not null default 0 comment '连续减仓单补挂失败次数' after reduction_next_retry_at_ms;
