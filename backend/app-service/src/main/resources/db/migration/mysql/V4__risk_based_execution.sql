-- Flyway V4: R-based entry sizing and persisted execution-plan state.
alter table trading_command
    add column request_json text character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '规范化交易请求JSON' after request_hash,
    add column dispatched_at_ms bigint default null comment '首次发往交易所时间' after error_code,
    add column completed_at_ms bigint default null comment '命令终态时间' after dispatched_at_ms;

create table trading_position_plan (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '执行计划ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    trading_command_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '建仓命令ID',
    trading_position_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '账户镜像仓位ID',
    position_generation bigint default null comment '账户镜像仓位代次',
    symbol varchar(32) character set ascii collate ascii_bin not null comment '交易对',
    direction varchar(8) character set ascii collate ascii_bin not null comment 'LONG/SHORT',
    position_side varchar(16) character set ascii collate ascii_bin not null comment 'BOTH/LONG/SHORT',
    entry_side varchar(8) character set ascii collate ascii_bin not null comment 'BUY/SELL',
    status varchar(32) character set ascii collate ascii_bin not null comment 'ENTRY_PENDING/ENTRY_LIVE/ACTIVE/DEGRADED/CLOSED/FAILED/CANCELED',
    entry_order_type varchar(32) character set ascii collate ascii_bin not null comment 'MAKER_ONLY/LIMIT/MARKET',
    take_profit_order_type varchar(32) character set ascii collate ascii_bin not null comment 'MAKER_ONLY/LIMIT/MARKET',
    stop_loss_order_type varchar(32) character set ascii collate ascii_bin not null comment 'LIMIT/MARKET/NONE',
    working_type varchar(24) character set ascii collate ascii_bin not null default 'MARK_PRICE' comment '保护单触发价类型',
    order_settings_revision bigint not null comment '下单设置快照修订号',
    exit_strategy_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '止盈止损策略快照来源',
    exit_strategy_revision bigint default null comment '策略快照修订号',
    settlement_asset varchar(16) character set ascii collate ascii_bin not null comment 'R结算资产',
    configured_r_amount decimal(38, 18) not null comment '下单时冻结的基础止损金额R',
    actual_initial_r_amount decimal(38, 18) default null comment '按实际成交均价计算的初始风险金额',
    reference_entry_price decimal(38, 18) not null comment '计算仓位时服务器参考价',
    requested_entry_price decimal(38, 18) default null comment '限价或Maker建仓价',
    average_entry_price decimal(38, 18) default null comment '实际建仓均价',
    initial_stop_price decimal(38, 18) not null comment '用户划线的初始止损价',
    current_stop_price decimal(38, 18) default null comment '当前已确认保护止损价',
    risk_per_unit decimal(38, 18) not null comment '每单位合约初始风险价差',
    planned_quantity decimal(38, 18) not null comment '按R向下规整后的建仓数量',
    initial_filled_quantity decimal(38, 18) default null comment '建仓终止后冻结的初始成交数量',
    filled_quantity decimal(38, 18) not null default 0 comment '累计建仓成交数量',
    protected_quantity decimal(38, 18) not null default 0 comment '当前保护单覆盖数量',
    remaining_quantity decimal(38, 18) not null default 0 comment '当前剩余仓位绝对数量',
    price_tick decimal(38, 18) not null comment '交易对价格最小步长快照',
    quantity_step decimal(38, 18) not null comment '建仓数量步长快照',
    market_quantity_step decimal(38, 18) not null comment '市价数量步长快照',
    min_quantity decimal(38, 18) not null comment '最小下单数量快照',
    min_notional decimal(38, 18) not null default 0 comment '最小名义价值快照',
    fallback_market_stop_r decimal(18, 6) default null comment '限价止损保底市价单与当前止损的R间距依据',
    entry_client_order_id varchar(36) character set ascii collate ascii_bin not null comment '确定性建仓客户端订单ID',
    primary_stop_client_algo_id varchar(36) character set ascii collate ascii_bin default null comment '当前主止损Algo客户端ID',
    fallback_stop_client_algo_id varchar(36) character set ascii collate ascii_bin default null comment '当前保底止损Algo客户端ID',
    stop_revision bigint not null default 0 comment '止损替换版本',
    last_strategy_evaluated_ms bigint default null comment '最近每分钟策略评估时间',
    execution_fence_token bigint default null comment '最后执行动作的账户fencing token',
    last_error_code varchar(64) character set ascii collate ascii_bin default null comment '脱敏执行错误码',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_position_plan_command (trading_command_id),
    unique key uk_trading_position_plan_entry_client (trading_account_id, entry_client_order_id),
    key idx_trading_position_plan_active (trading_account_id, status, symbol, position_side)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '以损定仓并驱动保护单和分级退出的持久化执行计划';

create table trading_position_plan_level (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '执行计划级别ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_position_plan_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '执行计划ID',
    source_level_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '配置级别来源ID',
    level_no int not null comment '级别序号',
    trigger_r decimal(18, 6) not null comment '盈利触发R倍数快照',
    reduce_percent decimal(8, 4) not null default 0 comment '按初始仓位减仓比例快照',
    move_stop_mode varchar(32) character set ascii collate ascii_bin not null default 'NONE' comment 'NONE/FIXED_R/TRAILING_PROFIT_R',
    move_stop_r decimal(18, 6) default null comment '固定止损R位置或浮盈回撤R距离',
    status varchar(24) character set ascii collate ascii_bin not null default 'PENDING' comment 'PENDING/ACTIVE/COMPLETED/FAILED',
    reduction_status varchar(24) character set ascii collate ascii_bin not null default 'NONE' comment 'NONE/PENDING/LIVE/COMPLETED/UNKNOWN/FAILED',
    reduction_client_order_id varchar(36) character set ascii collate ascii_bin default null comment '分级减仓客户端订单ID',
    planned_reduction_quantity decimal(38, 18) not null default 0 comment '按初始仓位规整后的计划减仓数量',
    executed_reduction_quantity decimal(38, 18) not null default 0 comment '已成交减仓数量',
    triggered_price decimal(38, 18) default null comment '首次触发时标记价',
    triggered_at_ms bigint default null comment '首次触发时间',
    stop_move_activated tinyint not null default 0 comment '是否已激活该级止损动作',
    last_error_code varchar(64) character set ascii collate ascii_bin default null comment '脱敏执行错误码',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_position_plan_level (trading_position_plan_id, level_no),
    unique key uk_trading_position_level_client (reduction_client_order_id),
    key idx_trading_position_level_status (trading_position_plan_id, status, level_no)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '开放仓位冻结后的分级减仓与止损棘轮执行状态';
