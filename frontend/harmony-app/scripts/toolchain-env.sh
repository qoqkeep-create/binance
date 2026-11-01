#!/bin/sh
# Shared by the build/doctor/install entry points; does not modify shell profiles.
TASK_STUDIO="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
case "$TASK_STUDIO" in *.app) TASK_STUDIO="$TASK_STUDIO/Contents" ;; esac
if [ -n "${HARMONY_TOOLCHAIN_HOME:-}" ]; then
  TASK_TOOLCHAIN="$HARMONY_TOOLCHAIN_HOME"
elif [ -d "$TASK_STUDIO" ]; then
  TASK_TOOLCHAIN="$TASK_STUDIO"
else
  TASK_TOOLCHAIN="${DEVECO_CLI_CLT_PATH:-$HOME/Library/Developer/HarmonyOS/command-line-tools}"
fi
HARMONY_SDK_HOME="${HARMONY_SDK_HOME:-$TASK_TOOLCHAIN/sdk}"
if [ -d "$TASK_TOOLCHAIN/tools" ]; then
  HVIGOR_HOME="${HVIGOR_HOME:-$TASK_TOOLCHAIN/tools/hvigor}"
  HARMONY_NODE="${HARMONY_NODE:-$TASK_TOOLCHAIN/tools/node/bin/node}"
  HARMONY_OHPM="${HARMONY_OHPM:-$TASK_TOOLCHAIN/tools/ohpm/bin/ohpm}"
else
  HVIGOR_HOME="${HVIGOR_HOME:-$TASK_TOOLCHAIN/hvigor}"
  HARMONY_NODE="${HARMONY_NODE:-$TASK_TOOLCHAIN/tool/node/bin/node}"
  HARMONY_OHPM="${HARMONY_OHPM:-$TASK_TOOLCHAIN/ohpm/bin/ohpm}"
fi
if [ ! -x "$HARMONY_NODE" ]; then HARMONY_NODE="$(command -v node || true)"; fi
HARMONY_HDC="${HARMONY_HDC:-$HARMONY_SDK_HOME/default/openharmony/toolchains/hdc}"
if [ -z "${JAVA_HOME:-}" ]; then
  for TASK_JAVA in "$TASK_TOOLCHAIN/jbr/Contents/Home" "$HOME/Library/Developer/HarmonyOS/jdk-21/Contents/Home" /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; do
    if [ -x "$TASK_JAVA/bin/java" ]; then JAVA_HOME="$TASK_JAVA"; break; fi
  done
fi
if [ -n "${JAVA_HOME:-}" ]; then PATH="$JAVA_HOME/bin:$PATH"; export JAVA_HOME; fi
if [ -n "$HARMONY_NODE" ]; then PATH="$(dirname "$HARMONY_NODE"):$PATH"; fi
PATH="$(dirname "$HARMONY_OHPM"):$(dirname "$HARMONY_HDC"):$PATH"
DEVECO_SDK_HOME="$HARMONY_SDK_HOME"
export HVIGOR_HOME HARMONY_NODE HARMONY_OHPM HARMONY_HDC HARMONY_SDK_HOME DEVECO_SDK_HOME PATH
