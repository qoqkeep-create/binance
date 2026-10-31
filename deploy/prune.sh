#!/bin/bash
# 每周卫生任务：清理悬空镜像/构建缓存 + 磁盘水位告警。
# 由 tradetools-prune.timer 触发；只删无容器引用的旧镜像，不碰数据卷。
set -uo pipefail

LOG_FILE=/var/log/tradetools-deploy.log
ENV_FILE=/opt/riskon/tradetools/.env.docker
DISK_ALERT_THRESHOLD=80

log() {
  echo "$(date): [prune] $1" >> "$LOG_FILE"
}

docker image prune -a -f --filter "until=168h" >> "$LOG_FILE" 2>&1
docker builder prune -f --filter "until=72h" >> "$LOG_FILE" 2>&1
log "prune done"

USAGE="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ "${USAGE:-0}" -ge "$DISK_ALERT_THRESHOLD" ]; then
  ALERT_TOKEN="$(grep -E '^MARKET_ANALYSIS_ALERT_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)"
  if [ -n "$ALERT_TOKEN" ]; then
    docker exec tradetools-tradingview-webhook-1 python3 -c '
import json, sys
from urllib.request import Request, urlopen
payload = {"title": sys.argv[1], "text": sys.argv[2], "token": sys.argv[3]}
req = Request(
    "http://127.0.0.1:3000/internal/ops-alert",
    data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urlopen(req, timeout=10)
except Exception as exc:
    print(f"ops-alert failed: {exc}")
' "服务器磁盘告警" "根分区使用率已达 ${USAGE}%（阈值 ${DISK_ALERT_THRESHOLD}%），请检查镜像/日志占用。" "$ALERT_TOKEN" >> "$LOG_FILE" 2>&1 || true
  fi
  log "disk usage ${USAGE}% above threshold, alert sent"
fi
exit 0
