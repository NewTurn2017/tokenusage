#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

pid="$(qa_state_pid 2>/dev/null || true)"
if [[ -z "$pid" ]] || ! qa_pid_running "$pid"; then
    rm -f "$QA_STATE_DIR/app.pid"
    printf 'qa-pid: no running TokenUsageApp process\n' >&2
    exit 1
fi
printf '%s\n' "$pid"
