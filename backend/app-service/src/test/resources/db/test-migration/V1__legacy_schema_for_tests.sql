create table market_kline (
    id varchar(40) not null,
    interval_code varchar(8) not null,
    primary key (id)
);

create table app_user (
    id varchar(40) not null,
    create_time timestamp not null,
    update_time timestamp not null,
    delete_state tinyint not null default 0,
    account varchar(64) not null,
    email varchar(128) not null,
    display_name varchar(64) not null,
    password_hash varchar(128) not null,
    password_salt varchar(64) not null,
    enabled_state tinyint not null default 1,
    primary key (id),
    unique (account),
    unique (email)
);

create table strategy_signal (
    id varchar(40) not null,
    delete_state tinyint not null default 0,
    exchange varchar(16) not null default 'BINANCE',
    market_type varchar(16) not null default 'USDM',
    contract_type varchar(16) not null default 'PERPETUAL',
    pair varchar(32) not null,
    interval_code varchar(8) not null default '1h',
    strategy_code varchar(64) not null,
    direction varchar(16) not null,
    signal_time_ms bigint not null,
    price decimal(38, 18) not null,
    primary key (id)
);

create table trading_account (
    id varchar(40) not null,
    status varchar(32) not null default 'ACTIVE',
    execution_enabled tinyint not null default 0,
    primary key (id)
);

create index idx_trading_account_status
    on trading_account (status, execution_enabled);

create table trading_position (
    id varchar(40) not null,
    primary key (id)
);

create table trading_outbox (
    id varchar(40) not null,
    primary key (id)
);

insert into market_kline (id, interval_code)
values ('legacy-one-minute', '1m');

insert into market_kline (id, interval_code)
values ('legacy-one-hour', '1h');
