-- Flyway V1: market data, indicators, signals and APP users.
create table if not exists market_kline (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment 'id，业务唯一键UUID',
    create_time datetime default null comment '创建时间',
    update_time datetime default null comment '更新时间',
    create_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '创建人',
    update_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '更新人',
    delete_state tinyint default 0 comment '删除状态：0正常，1删除',

    exchange varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'BINANCE' comment '交易所',
    market_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'USDM' comment '市场类型：USDM表示U本位合约',
    contract_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'PERPETUAL' comment '合约类型：PERPETUAL表示永续合约',
    pair varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易对，例如BTCUSDC',
    interval_code varchar(8) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment 'K线周期，例如1m、5m、15m、1h、4h、1d',

    open_time_ms bigint not null comment 'K线开盘时间，毫秒时间戳',
    close_time_ms bigint not null comment 'K线收盘时间，毫秒时间戳',
    event_time_ms bigint default null comment '币安事件推送时间，毫秒时间戳',

    open_price decimal(38, 18) not null comment '开盘价',
    high_price decimal(38, 18) not null comment '最高价',
    low_price decimal(38, 18) not null comment '最低价',
    close_price decimal(38, 18) not null comment '收盘价',

    volume decimal(38, 18) not null comment '成交量',
    quote_volume decimal(38, 18) default null comment '成交额',
    trade_count bigint default null comment '成交笔数',
    taker_buy_volume decimal(38, 18) default null comment '主动买入成交量',
    taker_buy_quote_volume decimal(38, 18) default null comment '主动买入成交额',

    closed_state tinyint not null default 1 comment 'K线状态：0未收盘，1已收盘',
    source_interval varchar(8) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default '1m' comment '来源周期，原生K线为自身周期，聚合K线通常来自1m',

    primary key (id),
    unique key uk_market_kline_biz (
        exchange,
        market_type,
        contract_type,
        pair,
        interval_code,
        open_time_ms
    ),
    key idx_market_kline_query (
        pair,
        contract_type,
        interval_code,
        open_time_ms desc
    ),
    key idx_market_kline_time (
        interval_code,
        open_time_ms desc
    )
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '币安USD-M永续合约K线表，保存1m原生K线和本地聚合K线';

create table if not exists market_indicator (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment 'id，业务唯一键UUID',
    create_time datetime default null comment '创建时间',
    update_time datetime default null comment '更新时间',
    create_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '创建人',
    update_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '更新人',
    delete_state tinyint default 0 comment '删除状态：0正常，1删除',

    exchange varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'BINANCE' comment '交易所',
    market_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'USDM' comment '市场类型：USDM表示U本位合约',
    contract_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'PERPETUAL' comment '合约类型：PERPETUAL表示永续合约',
    pair varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易对，例如BTCUSDC',
    interval_code varchar(8) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment 'K线周期',
    open_time_ms bigint not null comment '指标对应K线开盘时间，毫秒时间戳',
    close_time_ms bigint not null comment '指标对应K线收盘时间，毫秒时间戳',
    indicator_code varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '指标编码，例如EMA144、SUPER_TREND',
    indicator_value decimal(38, 18) not null comment '指标主值',
    direction varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '指标方向，例如LONG、SHORT',
    extra_json text character set utf8mb4 collate utf8mb4_0900_ai_ci comment '指标扩展信息JSON',

    primary key (id),
    unique key uk_market_indicator_biz (
        exchange,
        market_type,
        contract_type,
        pair,
        interval_code,
        indicator_code,
        open_time_ms
    ),
    key idx_market_indicator_query (
        pair,
        contract_type,
        interval_code,
        indicator_code,
        open_time_ms desc
    )
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '技术指标表，保存EMA、SuperTrend等指标结果';

create table if not exists strategy_signal (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment 'id，业务唯一键UUID',
    create_time datetime default null comment '创建时间',
    update_time datetime default null comment '更新时间',
    create_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '创建人',
    update_user varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci default null comment '更新人',
    delete_state tinyint default 0 comment '删除状态：0正常，1删除',

    exchange varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'BINANCE' comment '交易所',
    market_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'USDM' comment '市场类型：USDM表示U本位合约',
    contract_type varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null default 'PERPETUAL' comment '合约类型：PERPETUAL表示永续合约',
    pair varchar(32) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '交易对，例如BTCUSDC',
    interval_code varchar(8) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '策略运行K线周期',
    strategy_code varchar(64) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '策略编码',
    direction varchar(16) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '信号方向：LONG、SHORT',
    signal_time_ms bigint not null comment '信号生成时间，毫秒时间戳',
    trigger_open_time_ms bigint not null comment '触发信号的K线开盘时间，毫秒时间戳',
    flip_open_time_ms bigint not null comment 'SuperTrend翻转K线开盘时间，毫秒时间戳',
    price decimal(38, 18) not null comment '触发信号时的收盘价',
    score decimal(10, 4) not null comment '信号评分',
    pattern_code varchar(64) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '反转K线形态编码',
    reason_json text character set utf8mb4 collate utf8mb4_0900_ai_ci comment '信号原因JSON',

    primary key (id),
    unique key uk_strategy_signal_once (
        exchange,
        market_type,
        contract_type,
        pair,
        interval_code,
        strategy_code,
        flip_open_time_ms,
        direction
    ),
    key idx_strategy_signal_query (
        pair,
        strategy_code,
        interval_code,
        signal_time_ms desc
    )
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '策略信号表，保存已触发的通知信号';

create table if not exists app_user (
    id varchar(40) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '用户ID',
    create_time datetime not null comment '创建时间',
    update_time datetime not null comment '更新时间',
    delete_state tinyint not null default 0 comment '删除状态：0正常，1删除',
    account varchar(64) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '登录账号',
    email varchar(128) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '邮箱',
    display_name varchar(64) character set utf8mb4 collate utf8mb4_0900_ai_ci not null comment '显示名称',
    password_hash varchar(128) character set ascii collate ascii_bin not null comment 'PBKDF2-SHA256密码摘要',
    password_salt varchar(64) character set ascii collate ascii_bin not null comment '独立随机盐',
    enabled_state tinyint not null default 1 comment '启用状态：0禁用，1启用',

    primary key (id),
    unique key uk_app_user_account (account),
    unique key uk_app_user_email (email)
) engine = InnoDB
  default charset = utf8mb4
  collate = utf8mb4_0900_ai_ci
  comment = '应用登录用户';
