#!/bin/sh

set -eu

expected_lineage=/etc/letsencrypt/live/binance.oovso.com
renewed_lineage=${RENEWED_LINEAGE:-$expected_lineage}
target_dir=/opt/trade-tool/nginx/ssl

# Certbot 会对所有证书执行 deploy hook；其他域名不属于本项目。
if [ "$renewed_lineage" != "$expected_lineage" ]; then
    exit 0
fi

if [ ! -r "$renewed_lineage/fullchain.pem" ] || [ ! -r "$renewed_lineage/privkey.pem" ]; then
    echo "找不到 binance.oovso.com 的 Let's Encrypt 证书。" >&2
    exit 1
fi

install -d -m 700 "$target_dir"
install -m 644 "$renewed_lineage/fullchain.pem" "$target_dir/fullchain.pem"
install -m 600 "$renewed_lineage/privkey.pem" "$target_dir/privkey.pem"

if [ -e /etc/nginx/sites-enabled/trade-tool ]; then
    nginx -t
    systemctl reload nginx
fi

echo 'Trade Tool Nginx certificate synchronized.'
