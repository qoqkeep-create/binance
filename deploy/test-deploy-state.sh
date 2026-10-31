#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy-state.sh
. "$SCRIPT_DIR/lib/deploy-state.sh"

TEST_DIR="$(mktemp -d /tmp/tradetools-deploy-state.XXXXXX)"
STATE_FILE="$TEST_DIR/failed-commit"
trap 'rm -rf "$TEST_DIR"' EXIT

record_failed_commit "$STATE_FILE" abc123
failed_commit_matches "$STATE_FILE" abc123
if failed_commit_matches "$STATE_FILE" def456; then
  echo "a different revision must not be blocked" >&2
  exit 1
fi

clear_failed_commit_for_new_revision "$STATE_FILE" abc123
[ -f "$STATE_FILE" ]
clear_failed_commit_for_new_revision "$STATE_FILE" def456
[ ! -e "$STATE_FILE" ]

record_failed_commit "$STATE_FILE" def456
clear_failed_commit "$STATE_FILE"
[ ! -e "$STATE_FILE" ]

echo "deploy state tests passed"
