#!/bin/bash
# TradeTools 统一部署脚本（仓库版本化）。
# 链路：timer(30s)/Gitee webhook -> /opt/riskon/deploy.sh（bootstrap）-> 本脚本。
# 保障：flock 单实例（进程死亡自动释放）、各阶段超时、失败即时告警（企微+TG）、
#       部署后 HTTP 健康校验、失败自动回滚到上次成功版本。
set -euo pipefail

LOG_FILE=/var/log/tradetools-deploy.log
LOCK_FILE=/tmp/tradetools-deploy.lock
REPO_DIR=/opt/riskon/tradetools
ENV_FILE="$REPO_DIR/.env.docker"
LAST_GOOD_FILE=/opt/riskon/.last-good-hash
LAST_ATTEMPT_FILE=/opt/riskon/.last-deploy-attempt
FAILED_COMMIT_FILE=/opt/riskon/.failed-deploy-hash
FETCH_ALERT_FILE=/opt/riskon/.last-fetch-alert
# fetch 告警冷却（秒）：跨境链路瞬时抖动不刷屏，同一故障 30 分钟内只报一次
FETCH_ALERT_COOLDOWN=1800
CORE_CONTAINERS="tradetools-frontend-1 tradetools-backend-1 tradetools-scheduler-1 tradetools-tradingview-webhook-1 tradetools-redis-1 tradetools-mysql-1"
HEALTH_RETRIES=12
HEALTH_INTERVAL=5
# 站点不健康时的重建冷却期（秒），防止 30s 轮询引发构建风暴
REDEPLOY_COOLDOWN=600

# shellcheck source=lib/deploy-state.sh
. "$REPO_DIR/deploy/lib/deploy-state.sh"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "$(date): Deploy already running, skip" >> "$LOG_FILE"
  exit 0
fi

log() {
  echo "$(date): $1" >> "$LOG_FILE"
}

env_value() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true
}

HTTP_PORT="$(env_value HTTP_PORT)"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="$(env_value HTTPS_PORT)"
HTTPS_PORT="${HTTPS_PORT:-8444}"
ALERT_TOKEN="$(env_value MARKET_ANALYSIS_ALERT_TOKEN)"

# 失败告警：经 tradingview-webhook 容器的 /internal/ops-alert 推企微+TG（尽力而为）
send_alert() {
  local title="$1" text="$2"
  [ -n "$ALERT_TOKEN" ] || return 0
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
' "$title" "$text" "$ALERT_TOKEN" >> "$LOG_FILE" 2>&1 || true
}

cleanup_compose_recreate_containers() {
  local stale_names
  stale_names="$(docker ps -a --format '{{.Names}}' | grep -E '^[0-9a-f]{12}_(tradetools|tradingtools)-(frontend|backend|scheduler|tradingview-webhook|mysql|redis)-1$' || true)"
  if [ -n "$stale_names" ]; then
    log "Removing stale recreate containers: $(echo "$stale_names" | tr '\n' ' ')"
    echo "$stale_names" | xargs -r docker rm -f >> "$LOG_FILE" 2>&1 || true
  fi
}

containers_running() {
  local name
  for name in $CORE_CONTAINERS; do
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$name"; then
      return 1
    fi
  done
  return 0
}

# HTTP 级健康（本地直连前端容器，不走 CDN）：
# ① 首页 200 证明前端 nginx 存活；
# ② 深度健康接口确认数据库、迁移和 scheduler 心跳全部就绪。
health_ok() {
  curl -skf -m 5 -o /dev/null "https://127.0.0.1:${HTTPS_PORT}/" || return 1
  curl -skf -m 8 -o /dev/null "https://127.0.0.1:${HTTPS_PORT}/v1/health"
}

wait_healthy() {
  local i
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    if health_ok; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

sync_stale_containers() {
  # compose 偶发不重建镜像已更新的服务，逐服务比对镜像 ID，落后则强制重建
  local svc current_img latest_img
  for svc in frontend backend scheduler tradingview-webhook; do
    current_img=$(docker inspect "tradetools-${svc}-1" --format '{{.Image}}' 2>/dev/null || echo none)
    latest_img=$(docker image inspect "tradetools-${svc}:latest" --format '{{.Id}}' 2>/dev/null || echo none)
    if [ "$current_img" != "$latest_img" ]; then
      log "Image drift detected for ${svc}, force-recreating"
      timeout 300 docker compose --env-file .env.docker up -d --force-recreate "$svc" >> "$LOG_FILE" 2>&1 || true
    fi
  done
}

build_and_up() {
  timeout 600 docker compose --env-file .env.docker up -d --build --remove-orphans >> "$LOG_FILE" 2>&1 || return 1
  # 无状态应用服务无条件强制重建，从根上杜绝 compose 镜像漂移（--no-deps 不触碰 mysql/redis）
  timeout 300 docker compose --env-file .env.docker up -d --force-recreate --no-deps frontend backend scheduler tradingview-webhook >> "$LOG_FILE" 2>&1 || return 1
  sync_stale_containers
  cleanup_compose_recreate_containers
  return 0
}

log 'Starting docker deployment'
cleanup_compose_recreate_containers
cd "$REPO_DIR"

LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null || echo none)"
export GIT_SSH_COMMAND="ssh -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
# 跨境链路偶发抖动时单次 fetch 可能超时：静默重试 3 次，仍失败才告警（带冷却）
FETCH_OK=0
for FETCH_ATTEMPT in 1 2 3; do
  if timeout 60 git fetch origin main >> "$LOG_FILE" 2>&1; then
    FETCH_OK=1
    break
  fi
  log "git fetch attempt ${FETCH_ATTEMPT}/3 failed"
  sleep 5
done
if [ "$FETCH_OK" = "0" ]; then
  log "git fetch failed after 3 attempts (timeout/network)"
  NOW_TS="$(date +%s)"
  LAST_FETCH_ALERT="$(cat "$FETCH_ALERT_FILE" 2>/dev/null || echo 0)"
  if [ $((NOW_TS - LAST_FETCH_ALERT)) -ge "$FETCH_ALERT_COOLDOWN" ]; then
    echo "$NOW_TS" > "$FETCH_ALERT_FILE"
    send_alert "部署告警：git fetch 失败" "服务器拉取 Gitee main 连续 3 次失败，本轮部署跳过，下个周期自动重试。若持续出现请检查部署密钥与网络。"
  fi
  exit 1
fi
REMOTE_HEAD="$(git rev-parse origin/main 2>/dev/null || echo none)"

if failed_commit_matches "$FAILED_COMMIT_FILE" "$REMOTE_HEAD"; then
  log "Remote commit is marked failed; waiting for a new revision (${REMOTE_HEAD:0:7})"
  exit 0
fi
clear_failed_commit_for_new_revision "$FAILED_COMMIT_FILE" "$REMOTE_HEAD"

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] && containers_running && health_ok; then
  log "No new commit and site healthy, skip deployment (${LOCAL_HEAD:0:7})"
  exit 0
fi

# 站点不健康但没有新代码时：冷却期内不重复重建，避免构建风暴
NOW_TS="$(date +%s)"
LAST_ATTEMPT="$(cat "$LAST_ATTEMPT_FILE" 2>/dev/null || echo 0)"
if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] && [ $((NOW_TS - LAST_ATTEMPT)) -lt "$REDEPLOY_COOLDOWN" ]; then
  log "Site unhealthy but last attempt was <${REDEPLOY_COOLDOWN}s ago, skip (${LOCAL_HEAD:0:7})"
  exit 0
fi
echo "$NOW_TS" > "$LAST_ATTEMPT_FILE"

git reset --hard origin/main >> "$LOG_FILE" 2>&1
APP_VERSION="$(git show -s --format=%cd --date=format:%m.%d.%H%M HEAD)（$(git rev-parse --short HEAD)）"
export APP_VERSION

if build_and_up && wait_healthy; then
  echo "$REMOTE_HEAD" > "$LAST_GOOD_FILE"
  clear_failed_commit "$FAILED_COMMIT_FILE"
  log "Docker deployment completed: ${APP_VERSION}"
  exit 0
fi

log "Deployment FAILED at ${REMOTE_HEAD:0:7}, health check not passed"
if ! record_failed_commit "$FAILED_COMMIT_FILE" "$REMOTE_HEAD"; then
  log "Could not persist failed commit marker for ${REMOTE_HEAD:0:7}"
fi
send_alert "部署失败：${REMOTE_HEAD:0:7}" "提交 ${REMOTE_HEAD:0:7} 部署后健康校验未通过，正在尝试自动回滚。"

LAST_GOOD="$(cat "$LAST_GOOD_FILE" 2>/dev/null || true)"
if [ -n "$LAST_GOOD" ] && [ "$LAST_GOOD" != "$REMOTE_HEAD" ]; then
  log "Auto rollback to ${LAST_GOOD:0:7}"
  git reset --hard "$LAST_GOOD" >> "$LOG_FILE" 2>&1
  if build_and_up && wait_healthy; then
    log "Rollback completed: ${LAST_GOOD:0:7}"
    send_alert "已自动回滚：${LAST_GOOD:0:7}" "坏提交 ${REMOTE_HEAD:0:7} 已回滚到 ${LAST_GOOD:0:7}，站点已恢复。请排查该提交。"
  else
    log "Rollback FAILED, manual intervention required"
    send_alert "严重：回滚失败，需人工介入" "提交 ${REMOTE_HEAD:0:7} 部署失败，回滚到 ${LAST_GOOD:0:7} 后站点仍未恢复，请立即处理。"
  fi
else
  send_alert "部署失败：无可回滚版本" "提交 ${REMOTE_HEAD:0:7} 部署失败，且没有已知的上次成功版本可回滚，请人工介入。"
fi
exit 1
