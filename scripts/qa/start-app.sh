#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

APP_PATH="${TOKEN_USAGE_APP_PATH:-${1:-$QA_ROOT_DIR/build/TokenUsage.app}}"
APP_PATH="$(qa_absolute_path "$APP_PATH")"
BINARY_PATH="$APP_PATH/Contents/MacOS/TokenUsageApp"
[[ -x "$BINARY_PATH" ]] || { qa_fail "missing app executable: $(qa_redact_path "$BINARY_PATH")"; exit 1; }

qa_prepare_state
if existing_pid="$(qa_state_pid 2>/dev/null)" && qa_pid_running "$existing_pid"; then
    printf 'qa-start: already running pid=%s\n' "$existing_pid"
    exit 0
fi

printf '%s' "$APP_PATH" >"$QA_STATE_DIR/app.path"
LOG_PATH="$QA_STATE_DIR/app.log"
: >"$LOG_PATH"
nohup "$BINARY_PATH" </dev/null >>"$LOG_PATH" 2>&1 &
pid=$!
printf '%s' "$pid" >"$QA_STATE_DIR/app.pid"

printf 'qa-start: launched pid=%s app=%s\n' "$pid" "$(qa_redact_path "$APP_PATH")"
