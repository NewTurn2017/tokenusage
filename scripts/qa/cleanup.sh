#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

qa_prepare_state
pid="$(qa_state_pid 2>/dev/null || true)"
status='not-running'
if [[ -n "$pid" ]] && qa_pid_running "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    if qa_pid_running "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    if qa_pid_running "$pid"; then
        qa_fail "could not stop TokenUsageApp pid=$pid"
        exit 1
    fi
    status='stopped'
fi
rm -f "$QA_STATE_DIR/app.pid" "$QA_STATE_DIR/app.path"
printf 'qa-cleanup: %s\n' "$status"
