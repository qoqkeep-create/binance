alter table trading_position_plan
    add column execution_snapshot_json clob;
alter table trading_position_plan
    add column execution_snapshot_hash varchar(64);
alter table trading_position_plan
    add column last_order_health_check_ms bigint;
alter table trading_position_plan
    add column next_protection_repair_at_ms bigint;
alter table trading_position_plan
    add column protection_repair_attempts int not null default 0;

alter table trading_position_plan_level
    add column reduction_revision bigint not null default 0;
alter table trading_position_plan_level
    add column reduction_order_base_executed_quantity decimal(38, 18) not null default 0;
alter table trading_position_plan_level
    add column reduction_next_retry_at_ms bigint;
alter table trading_position_plan_level
    add column reduction_repair_attempts int not null default 0;
