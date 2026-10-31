#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir=$(CDPATH= cd -- "$script_dir/../TradeTool" && pwd)
benchmark_binary=$(mktemp /tmp/trade-tool-benchmark.XXXXXX)
trap 'rm -f "$benchmark_binary"' EXIT HUP INT TERM

xcrun swiftc -swift-version 5 -parse-as-library \
    "$app_dir/App/ServerSelection.swift" \
    "$app_dir/Core/Networking/ServerNetworkProbe.swift" \
    "$app_dir/Core/Networking/APIClient.swift" \
    "$app_dir/Core/Networking/APIRequest.swift" \
    "$app_dir/Core/Networking/APIEnvelope.swift" \
    "$app_dir/Core/Networking/APIError.swift" \
    "$app_dir/Core/Networking/APIInterceptor.swift" \
    "$app_dir/Core/Auth/AuthModels.swift" \
    "$script_dir/benchmark_servers.swift" \
    -o "$benchmark_binary"
"$benchmark_binary" "$@"
