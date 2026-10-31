#!/bin/sh
set -eu

echo "Ensuring the Metal Toolchain is available..."

if xcodebuild -showComponent MetalToolchain >/dev/null 2>&1; then
    echo "Metal Toolchain is already available."
    exit 0
fi

attempt=1
max_attempts=3

while :; do
    if download_output=$(xcodebuild -downloadComponent MetalToolchain 2>&1); then
        printf '%s\n' "$download_output"
        exit 0
    fi

    printf '%s\n' "$download_output" >&2

    case "$download_output" in
        *"Metal Toolchain is already imported"*)
            echo "Metal Toolchain became available during download."
            exit 0
            ;;
    esac

    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Failed to install the Metal Toolchain after $attempt attempts." >&2
        exit 1
    fi

    echo "Metal Toolchain download failed; retrying..." >&2
    sleep $((attempt * 10))
    attempt=$((attempt + 1))
done
