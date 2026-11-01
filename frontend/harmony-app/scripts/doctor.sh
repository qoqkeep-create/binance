#!/bin/sh
set -u
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$TASK_ROOT/scripts/toolchain-env.sh"
TASK_FAILED=0
printf 'Toolchain: %s\n' "$TASK_TOOLCHAIN"
if [ -f "$HVIGOR_HOME/bin/hvigorw.js" ]; then "$HARMONY_NODE" "$HVIGOR_HOME/bin/hvigorw.js" --version || TASK_FAILED=1; else echo 'Hvigor: missing'; TASK_FAILED=1; fi
if [ -x "$HARMONY_OHPM" ]; then "$HARMONY_OHPM" --version || TASK_FAILED=1; else echo 'ohpm: missing'; TASK_FAILED=1; fi
if [ -f "$HARMONY_SDK_HOME/default/sdk-pkg.json" ]; then
  "$HARMONY_NODE" -e 'const f=require("node:fs");const p=require("node:path");const s=JSON.parse(f.readFileSync(p.join(process.env.HARMONY_SDK_HOME,"default/sdk-pkg.json"),"utf8"));console.log("SDK: "+JSON.stringify(s));' || TASK_FAILED=1
else echo 'SDK: missing'; TASK_FAILED=1; fi
if [ -x "$HARMONY_HDC" ]; then "$HARMONY_HDC" -v || TASK_FAILED=1; else echo 'hdc: missing'; TASK_FAILED=1; fi
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then "$JAVA_HOME/bin/java" -version || TASK_FAILED=1; else echo 'JDK: missing (set JAVA_HOME)'; TASK_FAILED=1; fi
if [ -n "$HARMONY_NODE" ]; then "$HARMONY_NODE" --version || TASK_FAILED=1; else echo 'Node: missing'; TASK_FAILED=1; fi
exit "$TASK_FAILED"
