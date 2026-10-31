#!/bin/bash
# 部署引导脚本（安装在服务器 /opt/riskon/deploy.sh，极少变更）。
# 职责：以一次性快照副本方式执行仓库版本化的部署脚本，
# 保证整轮部署行为与当前代码一致，且脚本自我更新无需登录服务器。
REPO_DIR=/opt/riskon/tradetools
RUNNER="$REPO_DIR/deploy/run-deploy.sh"
LOG_FILE=/var/log/tradetools-deploy.log

if [ -f "$RUNNER" ]; then
  TMP="$(mktemp /tmp/tradetools-deploy.XXXXXX)"
  cp "$RUNNER" "$TMP"
  bash "$TMP"
  rc=$?
  rm -f "$TMP"
  exit $rc
fi

echo "$(date): deploy runner missing ($RUNNER)" >> "$LOG_FILE"
exit 1
