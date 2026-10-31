create table trading_command (
    id varchar(40) not null,
    request_json clob,
    primary key (id)
);

create table trading_position_plan (
    id varchar(40) not null,
    trading_command_id varchar(40) not null,
    configured_r_amount decimal(38, 18) not null,
    risk_per_unit decimal(38, 18) not null,
    current_stop_price decimal(38, 18),
    stop_revision bigint not null default 0,
    primary key (id),
    unique (trading_command_id)
);

create table trading_position_plan_level (
    id varchar(40) not null,
    trading_position_plan_id varchar(40) not null,
    level_no int not null,
    trigger_r decimal(18, 6) not null,
    reduce_percent decimal(8, 4) not null default 0,
    move_stop_mode varchar(32) not null,
    move_stop_r decimal(18, 6),
    status varchar(24) not null default 'PENDING',
    primary key (id),
    unique (trading_position_plan_id, level_no)
);
