#!/bin/sh

set -eu

env_file=${1:-}

if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
    echo '用法：validate-production-env.sh /path/to/.env.production' >&2
    exit 1
fi

read_env_value() {
    key=$1
    awk -v wanted="$key" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            separator = index(line, "=")
            if (separator == 0) { next }
            name = substr(line, 1, separator - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == wanted) {
                value = substr(line, separator + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$env_file"
}

require_secret() {
    key=$1
    value=$(read_env_value "$key")
    case "$value" in
        ''|change_me*|CHANGE_ME*|replace_me*|REPLACE_ME*)
            echo "生产环境变量 $key 不能为空或保留占位值。" >&2
            exit 1
            ;;
    esac
}

is_true() {
    value=$(read_env_value "$1")
    case "$value" in
        true|TRUE|True|1|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

require_secret MYSQL_PASSWORD
require_secret MYSQL_ROOT_PASSWORD
require_secret REDIS_PASSWORD
require_secret TRADING_CREDENTIAL_MASTER_KEY

validate_memory_limit() {
    key=$1
    value=$(read_env_value "$key")
    if [ -n "$value" ] && ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*([.][0-9]+)?[kKmMgGtTpP]?[bB]?$'; then
        echo "$key 必须是 Docker 可识别的内存值，例如 768m 或 1g。" >&2
        exit 1
    fi
}

validate_memory_limit APP_MEMORY_LIMIT
validate_memory_limit MYSQL_MEMORY_LIMIT
validate_memory_limit REDIS_MEMORY_LIMIT

master_key=$(read_env_value TRADING_CREDENTIAL_MASTER_KEY)
master_key_bytes=$(printf '%s' "$master_key" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
if [ "$master_key_bytes" != '32' ]; then
    echo 'TRADING_CREDENTIAL_MASTER_KEY 必须是 32 字节随机值的 Base64。' >&2
    exit 1
fi

rest_base_url=$(read_env_value BINANCE_TRADING_REST_BASE_URL)
user_stream_url=$(read_env_value BINANCE_TRADING_USER_STREAM_BASE_URL)
case "$rest_base_url$user_stream_url" in
    *testnet*)
        echo '生产环境文件不能包含 Binance Futures Testnet 地址。' >&2
        exit 1
        ;;
esac

if is_true APNS_NOTIFICATION_ENABLED; then
    require_secret APNS_TEAM_ID
    require_secret APNS_KEY_ID
    require_secret APNS_PRIVATE_KEY_BASE64
    require_secret APNS_TOPIC

    apns_key=$(read_env_value APNS_PRIVATE_KEY_BASE64)
    if ! printf '%s' "$apns_key" \
        | base64 -d 2>/dev/null \
        | grep -q 'BEGIN PRIVATE KEY'; then
        echo 'APNS_PRIVATE_KEY_BASE64 必须是 Apple AuthKey_*.p8 文件整体的 Base64。' >&2
        exit 1
    fi
fi

external_message_enabled=$(read_env_value EXTERNAL_MESSAGE_ENABLED)
external_message_key=$(read_env_value EXTERNAL_MESSAGE_API_KEY)
if [ -z "$external_message_enabled" ]; then
    external_message_enabled=$(read_env_value EXTERNAL_TRADE_SIGNAL_ENABLED)
fi
if [ -z "$external_message_key" ]; then
    external_message_key=$(read_env_value EXTERNAL_TRADE_SIGNAL_API_KEY)
fi
case "$external_message_enabled" in
    true|TRUE|True|1|yes|YES|Yes)
    if [ "${#external_message_key}" -lt 32 ]; then
        echo 'EXTERNAL_MESSAGE_API_KEY 不得少于 32 个字符。' >&2
        exit 1
    fi
    ;;
esac

if is_true WEBHOOK_NOTIFICATION_ENABLED; then
    require_secret STRATEGY_SIGNAL_WEBHOOK_URL
    require_secret STRATEGY_SIGNAL_WEBHOOK_KEY
    webhook_url=$(read_env_value STRATEGY_SIGNAL_WEBHOOK_URL)
    case "$webhook_url" in
        https://*) ;;
        *)
            echo 'STRATEGY_SIGNAL_WEBHOOK_URL 必须是完整 HTTPS 地址。' >&2
            exit 1
            ;;
    esac
    case "$webhook_url" in
        *\?*|*\#*)
            echo 'STRATEGY_SIGNAL_WEBHOOK_URL 不能包含查询参数或片段；访问 key 请单独配置。' >&2
            exit 1
            ;;
    esac
fi

admin_password=$(read_env_value APP_ADMIN_PASSWORD)
if [ -n "$admin_password" ] && [ "${#admin_password}" -lt 12 ]; then
    echo 'APP_ADMIN_PASSWORD 配置后不得少于 12 位。' >&2
    exit 1
fi

if is_true APP_REGISTRATION_ENABLED; then
    echo '警告：生产环境 APP_REGISTRATION_ENABLED=true，当前允许用户自助注册。' >&2
fi

if ! is_true TRADING_ACCOUNT_SYNC_ENABLED; then
    echo '提示：TRADING_ACCOUNT_SYNC_ENABLED 未开启，生产服务不会启动 Binance 账户同步。'
fi

java_tool_options=$(read_env_value JAVA_TOOL_OPTIONS)
case "$java_tool_options" in
    *-Xmx*) ;;
    *) echo '警告：JAVA_TOOL_OPTIONS 未设置 -Xmx；共享服务器上建议显式限制 Java 堆。' >&2 ;;
esac

echo '生产环境变量校验通过（未输出任何密钥内容）。'
