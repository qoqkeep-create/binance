#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$TASK_ROOT/scripts/toolchain-env.sh"
if [ "$#" -ne 2 ]; then echo '用法: scripts/install-debug.sh <hdc设备标识> <已签名debug.hap路径>' >&2; exit 2; fi
TASK_DEVICE="$1"
TASK_HAP="$2"
TASK_HDC="$HARMONY_HDC"
if ! command -v "$TASK_HDC" >/dev/null 2>&1; then echo '未找到 hdc，请设置 HARMONY_HDC 为 SDK toolchains/hdc 的完整路径。' >&2; exit 2; fi
if [ ! -f "$TASK_HAP" ] || [ "${TASK_HAP##*.}" != hap ]; then echo '请提供已签名的 HAP 文件。' >&2; exit 2; fi
if [ -z "$TASK_DEVICE" ] || [ "$TASK_DEVICE" = '[Empty]' ]; then echo '请用 hdc list targets 选择一台已授权设备。' >&2; exit 2; fi
# Install/update only the explicitly selected device. No uninstall, reset, or trading API calls.
"$TASK_HDC" -t "$TASK_DEVICE" install -r "$TASK_HAP"
"$TASK_HDC" -t "$TASK_DEVICE" shell aa start -a EntryAbility -b com.waibao2025.trade.harmony
