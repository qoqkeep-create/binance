#!/usr/bin/env bash
set -euo pipefail
root=/opt/trade-tools-integrated
release_dir=$(cd "$(dirname "$0")/../.." && pwd)
release_name=$(basename "$release_dir")
export INTEGRATED_RELEASE="$release_name"
compose=(docker compose --project-name tradetools-integrated --env-file "$root/server.env" -f "$release_dir/compose.integrated.yaml" --profile pro)
test -s "$root/server.env"
ln -sfn "$root/server.env" "$release_dir/server.env"
"${compose[@]}" build api
"${compose[@]}" up -d redis
"${compose[@]}" run --rm --no-deps api python manage.py migrate --noinput
"${compose[@]}" run --rm --no-deps api python manage.py bootstrap_mobile
"${compose[@]}" up -d --no-build api market worker scheduler
ln -sfn "$release_dir" "$root/current"
"${compose[@]}" ps
