#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$TASK_ROOT/scripts/toolchain-env.sh"
TASK_PROJECT="$TASK_ROOT/.local-build/project"
if [ ! -f "$TASK_PROJECT/build-profile.json5" ]; then
  echo '先运行 node scripts/prepare-local.mjs；在生成目录中用 DevEco 配置 SDK 与真机调试签名。' >&2
  exit 2
fi
cd "$TASK_PROJECT"
if [ ! -x "$HARMONY_OHPM" ]; then
  echo '未找到 ohpm。请配置 HARMONY_TOOLCHAIN_HOME / HARMONY_OHPM。' >&2
  exit 2
fi
"$HARMONY_OHPM" install
exec ./hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
