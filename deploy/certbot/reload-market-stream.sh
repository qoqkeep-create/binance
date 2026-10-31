#!/bin/sh
set -eu

if [ "${RENEWED_LINEAGE:-}" != /etc/letsencrypt/live/stream.ba.wow211.com ]; then
    exit 0
fi

nginx -t
systemctl reload nginx
