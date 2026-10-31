-- Flyway V2: trading account configuration and read-only exchange fact mirror.
create table if not exists trading_account (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    delete_state tinyint not null default 0 comment '删除状态：0正常，1删除',
    app_user_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '所属APP用户',
    exchange varchar(16) character set ascii collate ascii_bin not null default 'BINANCE' comment '交易所',
    market_type varchar(16) character set ascii collate ascii_bin not null default 'USDM' comment '市场类型',
    environment varchar(16) character set ascii collate ascii_bin not null default 'LIVE' comment '交易环境：LIVE或DEMO',
    label varchar(64) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default '实盘' comment '账户显示名称',
    quote_asset varchar(16) character set ascii collate ascii_bin not null comment '结算资产',
    credential_ciphertext text character set ascii collate ascii_bin comment 'AES-GCM凭证密文',
    credential_nonce varchar(32) character set ascii collate ascii_bin default null comment 'AES-GCM随机nonce',
    credential_fingerprint varchar(64) character set ascii collate ascii_bin default null comment 'API Key不可逆指纹',
    api_key_masked varchar(32) character set ascii collate ascii_bin default null comment 'API Key掩码',
    credential_key_version varchar(32) character set ascii collate ascii_bin default null comment '加密主密钥版本',
    position_mode varchar(16) character set ascii collate ascii_bin not null default 'UNKNOWN' comment '持仓模式',
    status varchar(32) character set ascii collate ascii_bin not null default 'PENDING_VERIFICATION' comment '账户状态',
    sync_status varchar(32) character set ascii collate ascii_bin not null default 'STOPPED' comment '账户同步状态',
    execution_enabled tinyint not null default 0 comment '是否允许真实执行；Phase 1固定关闭',
    total_margin_balance decimal(38, 18) not null default 0 comment '最近同步保证金余额',
    unrealized_profit decimal(38, 18) not null default 0 comment '最近同步未实现盈亏',
    last_verified_at_ms bigint default null comment '最后验证时间',
    last_synced_at_ms bigint default null comment '最后同步时间',
    stream_generation bigint not null default 0 comment '用户流连接代次',
    last_stream_event_ms bigint default null comment '最近交易所用户流事件时间',
    last_stream_connected_at_ms bigint default null comment '最近用户流连接时间',
    last_reconciled_at_ms bigint default null comment '最近完整或轻量对账时间',
    last_full_discovery_at_ms bigint default null comment '最近全量挂单发现时间',
    last_sync_error_code varchar(64) character set ascii collate ascii_bin default null comment '脱敏同步错误码',
    consecutive_sync_failure_count int not null default 0 comment '连续同步失败次数',
    reconcile_revision bigint not null default 0 comment 'REST对账修订号',
    execution_fence_token bigint not null default 0 comment '未来多实例执行fencing token',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_account_user_market (
        app_user_id,
        exchange,
        market_type,
        environment
    ),
    key idx_trading_account_status (status, execution_enabled),
    key idx_trading_account_fingerprint (credential_fingerprint)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'APP用户绑定的Binance USD-M交易账户';

create table if not exists trading_risk_policy (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '风控策略ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    policy_revision bigint not null default 1 comment '策略修订号',
    enabled_state tinyint not null default 0 comment '是否启用配置；不代表真实执行已开启',
    take_profit_enabled tinyint not null default 1 comment '是否配置固定止盈',
    stop_loss_enabled tinyint not null default 1 comment '是否配置固定止损',
    take_profit_percent decimal(12, 6) not null default 3 comment '固定止盈百分比',
    stop_loss_percent decimal(12, 6) not null default 1.5 comment '固定止损百分比',
    max_loss_amount decimal(38, 18) not null default 5 comment '单笔最大计划亏损额',
    settlement_asset varchar(16) character set ascii collate ascii_bin not null comment '风险金额结算资产',
    working_type varchar(16) character set ascii collate ascii_bin not null default 'MARK_PRICE' comment '未来保护单触发价格类型',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_risk_policy_account (trading_account_id)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '按交易账户保存的止盈止损风控参数';

create table if not exists trading_position (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '仓位ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    symbol varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易对',
    position_side varchar(16) character set ascii collate ascii_bin not null comment 'BOTH/LONG/SHORT',
    generation bigint not null default 1 comment '仓位生命周期代次',
    quantity decimal(38, 18) not null default 0 comment '带方向仓位数量',
    entry_price decimal(38, 18) not null default 0 comment '开仓均价',
    break_even_price decimal(38, 18) not null default 0 comment '盈亏平衡价',
    mark_price decimal(38, 18) not null default 0 comment '标记价格',
    liquidation_price decimal(38, 18) not null default 0 comment '预估强平价',
    leverage int not null default 1 comment '杠杆倍数',
    margin_type varchar(16) character set ascii collate ascii_bin not null default 'cross' comment '保证金模式',
    isolated_margin decimal(38, 18) not null default 0 comment '逐仓保证金',
    unrealized_profit decimal(38, 18) not null default 0 comment '未实现盈亏',
    status varchar(16) character set ascii collate ascii_bin not null default 'OPEN' comment 'OPEN/CLOSED',
    exchange_update_ms bigint not null default 0 comment '交易所更新时间',
    last_event_ms bigint not null default 0 comment '最近用户流事件时间',
    last_reconcile_revision bigint not null default 0 comment '最近REST对账修订号',
    continuity_status varchar(16) character set ascii collate ascii_bin not null default 'CONTINUOUS' comment 'CONTINUOUS/UNCERTAIN',
    source varchar(16) character set ascii collate ascii_bin not null default 'REST' comment 'REST/USER_STREAM',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_position_current (
        trading_account_id,
        symbol,
        position_side
    ),
    key idx_trading_position_open (trading_account_id, status, symbol)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'Binance USD-M当前仓位只读镜像';

create table if not exists trading_exit_strategy (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '分级止盈止损策略ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    strategy_name varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '策略名称',
    strategy_revision bigint not null default 1 comment '策略修订号',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    key idx_exit_strategy_account (trading_account_id, create_time)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '按R倍数分级执行的止盈止损策略配置';

create table if not exists trading_exit_strategy_level (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '策略级别ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    exit_strategy_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '所属分级策略ID',
    level_no int not null comment '级别序号，1到5',
    trigger_r decimal(18, 6) not null comment '盈利达到多少R时触发',
    reduce_percent decimal(8, 4) not null default 0 comment '按初始仓位计算的减仓百分比',
    move_stop_mode varchar(32) character set ascii collate ascii_bin not null default 'NONE' comment 'NONE/FIXED_R/TRAILING_PROFIT_R',
    move_stop_r decimal(18, 6) default null comment '固定R位置或浮盈回撤R距离',

    primary key (id),
    unique key uk_exit_strategy_level (exit_strategy_id, level_no)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '分级止盈止损策略的每级动作';

create table if not exists trading_loss_limit (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '止损额配置ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    revision bigint not null default 1 comment '配置修订号',
    current_percentage int not null default 3 comment '当前生效的余额百分比，1到25',
    current_amount decimal(38, 18) not null comment '当前冻结生效的止损金额',
    pending_percentage int default null comment '等待生效的调高比例',
    pending_amount decimal(38, 18) default null comment '等待生效的调高金额',
    pending_effective_at_ms bigint default null comment '调高止损额的生效时间',
    balance_snapshot decimal(38, 18) not null comment '计算当前配置时的余额快照',
    settlement_asset varchar(16) character set ascii collate ascii_bin not null comment '结算资产',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_loss_limit_account (trading_account_id)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '按余额百分比计算并冻结的单笔止损额配置';

create table if not exists trading_order_settings (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '下单配置ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    revision bigint not null default 1 comment '配置修订号',
    default_exit_strategy_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '默认止盈止损策略ID',
    entry_order_type varchar(32) character set ascii collate ascii_bin not null default 'MAKER_ONLY' comment 'MAKER_ONLY/LIMIT/MARKET',
    take_profit_order_type varchar(32) character set ascii collate ascii_bin not null default 'MAKER_ONLY' comment 'MAKER_ONLY/LIMIT/MARKET',
    stop_loss_order_type varchar(32) character set ascii collate ascii_bin not null default 'MARKET' comment 'LIMIT/MARKET/NONE',
    fallback_market_stop_r decimal(18, 6) default null comment '限价止损失效后的保底市价止损R位置',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_order_settings_account (trading_account_id),
    key idx_order_settings_strategy (default_exit_strategy_id)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '账户级下单、止盈与止损方式配置';

create table if not exists trading_account_balance (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '余额镜像ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    asset varchar(16) character set ascii collate ascii_bin not null comment '资产代码',
    wallet_balance decimal(38, 18) not null default 0 comment '钱包余额',
    cross_wallet_balance decimal(38, 18) not null default 0 comment '全仓钱包余额',
    balance_change decimal(38, 18) not null default 0 comment '最近余额变化',
    last_event_ms bigint not null default 0 comment '最近用户流事件时间',
    last_reconcile_revision bigint not null default 0 comment '最近REST对账修订号',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_account_balance_asset (trading_account_id, asset)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'Binance USD-M分资产余额镜像';

create table if not exists exchange_order (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '订单镜像ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    trading_position_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '关联仓位ID',
    position_generation bigint default null comment '关联仓位代次',
    order_class varchar(16) character set ascii collate ascii_bin not null comment 'REGULAR/ALGO',
    origin varchar(16) character set ascii collate ascii_bin not null default 'EXTERNAL' comment 'SYSTEM/EXTERNAL',
    purpose varchar(24) character set ascii collate ascii_bin not null default 'UNKNOWN' comment 'ENTRY/EXIT/STOP/TAKE_PROFIT/UNKNOWN',
    symbol varchar(32) character set ascii collate ascii_bin not null comment '交易对',
    side varchar(8) character set ascii collate ascii_bin not null comment 'BUY/SELL',
    position_side varchar(16) character set ascii collate ascii_bin not null default 'BOTH' comment 'BOTH/LONG/SHORT',
    order_type varchar(32) character set ascii collate ascii_bin not null default 'UNKNOWN' comment '订单类型',
    time_in_force varchar(16) character set ascii collate ascii_bin default null comment '有效方式',
    working_type varchar(24) character set ascii collate ascii_bin default null comment '触发价格类型',
    client_order_id varchar(64) character set ascii collate ascii_bin default null comment '普通订单客户端ID',
    exchange_order_id varchar(64) character set ascii collate ascii_bin default null comment '普通订单交易所ID',
    client_algo_id varchar(64) character set ascii collate ascii_bin default null comment 'Algo客户端ID',
    exchange_algo_id varchar(64) character set ascii collate ascii_bin default null comment 'Algo交易所ID',
    actual_order_id varchar(64) character set ascii collate ascii_bin default null comment 'Algo触发后的普通订单ID',
    quantity decimal(38, 18) not null default 0 comment '委托数量',
    price decimal(38, 18) not null default 0 comment '委托价格',
    trigger_price decimal(38, 18) not null default 0 comment '触发价格',
    executed_quantity decimal(38, 18) not null default 0 comment '累计成交数量',
    cumulative_quote decimal(38, 18) not null default 0 comment '累计成交额',
    average_price decimal(38, 18) not null default 0 comment '成交均价',
    reduce_only tinyint not null default 0 comment '是否只减仓',
    close_position tinyint not null default 0 comment '是否全平仓',
    status varchar(32) character set ascii collate ascii_bin not null comment '系统规范状态',
    exchange_status varchar(32) character set ascii collate ascii_bin default null comment 'Binance原始状态',
    execution_type varchar(32) character set ascii collate ascii_bin default null comment '最近执行类型',
    reject_reason varchar(128) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '脱敏拒绝原因',
    exchange_create_ms bigint not null default 0 comment '交易所创建时间',
    exchange_update_ms bigint not null default 0 comment '交易所更新时间',
    last_event_ms bigint not null default 0 comment '最近用户流事件时间',
    last_reconcile_revision bigint not null default 0 comment '最近REST对账修订号',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_exchange_order_client (trading_account_id, order_class, client_order_id),
    unique key uk_exchange_order_exchange (trading_account_id, order_class, exchange_order_id),
    unique key uk_exchange_algo_client (trading_account_id, order_class, client_algo_id),
    unique key uk_exchange_algo_exchange (trading_account_id, order_class, exchange_algo_id),
    key idx_exchange_order_active (trading_account_id, order_class, status, symbol),
    key idx_exchange_order_updated (trading_account_id, exchange_update_ms)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'Binance普通订单与Algo条件单镜像';

create table if not exists exchange_fill (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '成交镜像ID',
    create_time datetime not null comment '创建时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    exchange_order_row_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '本地订单镜像ID',
    symbol varchar(32) character set ascii collate ascii_bin not null comment '交易对',
    trade_id varchar(64) character set ascii collate ascii_bin not null comment 'Binance成交ID',
    order_id varchar(64) character set ascii collate ascii_bin not null comment 'Binance普通订单ID',
    side varchar(8) character set ascii collate ascii_bin not null comment 'BUY/SELL',
    position_side varchar(16) character set ascii collate ascii_bin not null default 'BOTH' comment 'BOTH/LONG/SHORT',
    price decimal(38, 18) not null default 0 comment '成交价格',
    quantity decimal(38, 18) not null default 0 comment '成交数量',
    quote_quantity decimal(38, 18) not null default 0 comment '成交额',
    commission decimal(38, 18) not null default 0 comment '手续费',
    commission_asset varchar(16) character set ascii collate ascii_bin default null comment '手续费资产',
    realized_pnl decimal(38, 18) not null default 0 comment '已实现盈亏',
    maker tinyint not null default 0 comment '是否Maker成交',
    trade_time_ms bigint not null comment '成交时间',

    primary key (id),
    unique key uk_exchange_fill_trade (trading_account_id, symbol, trade_id),
    key idx_exchange_fill_account_time (trading_account_id, trade_time_ms)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'Binance USD-M成交明细镜像';

create table if not exists trading_exchange_event (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易所事件Inbox ID',
    create_time datetime not null comment '创建时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    event_type varchar(64) character set ascii collate ascii_bin not null comment '用户流事件类型',
    event_hash varchar(64) character set ascii collate ascii_bin not null comment '语义SHA-256',
    exchange_event_ms bigint not null default 0 comment '事件时间E',
    transaction_ms bigint not null default 0 comment '交易时间T',
    received_at_ms bigint not null comment '服务器接收时间',
    entity_key varchar(160) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '关联实体脱敏键',
    normalized_summary text character set utf8mb4 collate utf8mb4_0900_ai_ci comment '必要规范字段JSON',
    applied_state varchar(24) character set ascii collate ascii_bin not null default 'RECEIVED' comment 'RECEIVED/APPLIED/IGNORED/FAILED',

    primary key (id),
    unique key uk_trading_exchange_event_hash (trading_account_id, event_hash),
    key idx_trading_exchange_event_time (trading_account_id, received_at_ms)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = 'Binance账户用户流幂等Inbox';

create table if not exists trading_outbox (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '事务Outbox ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    app_user_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '事件所属APP用户',
    channel varchar(32) character set ascii collate ascii_bin not null comment 'APP实时频道',
    event_name varchar(32) character set ascii collate ascii_bin not null comment '事件名称',
    event_key varchar(160) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '事件顺序键',
    symbol varchar(32) character set ascii collate ascii_bin default null comment '可选交易对',
    payload_json text character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '私有事件JSON',
    status varchar(16) character set ascii collate ascii_bin not null default 'PENDING' comment 'PENDING/PUBLISHED/FAILED',
    attempts int not null default 0 comment '发布尝试次数',
    available_at_ms bigint not null comment '下次可发布时间',
    locked_at_ms bigint default null comment '发布者原子认领时间',
    published_at_ms bigint default null comment '发布时间',

    primary key (id),
    key idx_trading_outbox_pending (status, available_at_ms, create_time)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '交易事实提交后的APP私有事件Outbox';

create table if not exists trading_command (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '未来交易命令ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    trading_account_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易账户ID',
    app_user_id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '发起用户',
    idempotency_key varchar(80) character set ascii collate ascii_bin not null comment 'HTTP幂等键',
    request_hash varchar(64) character set ascii collate ascii_bin not null comment '请求体SHA-256',
    command_type varchar(32) character set ascii collate ascii_bin not null comment '命令类型',
    status varchar(32) character set ascii collate ascii_bin not null comment '命令状态',
    client_order_id varchar(64) character set ascii collate ascii_bin default null comment '确定性普通订单ID',
    client_algo_id varchar(64) character set ascii collate ascii_bin default null comment '确定性Algo ID',
    result_json text character set utf8mb4 collate utf8mb4_0900_ai_ci comment '脱敏结果JSON',
    error_code varchar(64) character set ascii collate ascii_bin default null comment '脱敏错误码',
    version bigint not null default 0 comment '乐观锁版本',

    primary key (id),
    unique key uk_trading_command_idempotency (app_user_id, idempotency_key),
    key idx_trading_command_account_status (trading_account_id, status)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '未来真实交易写请求的幂等命令事实';
