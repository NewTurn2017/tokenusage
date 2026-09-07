#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

APP_PATH="${1:-$QA_ROOT_DIR/build/TokenUsage.app}"
OUTPUT_PATH="${2:-$QA_ROOT_DIR/build/qa-state/resource.txt}"
APP_PATH="$(qa_absolute_path "$APP_PATH")"
OUTPUT_PATH="$(qa_absolute_path "$OUTPUT_PATH")"
pid="$(qa_state_pid 2>/dev/null || true)"
[[ -n "$pid" ]] && qa_pid_running "$pid" || { qa_fail 'TokenUsageApp is not running'; exit 1; }

codex_matches=''
if codex_matches="$(pgrep -f '(^|/)codex[[:space:]]+app-server([[:space:]]|$)' 2>/dev/null)"; then
    codex_count=0
    for candidate_pid in $codex_matches; do
        current_pid="$candidate_pid"
        while [[ "$current_pid" -gt 1 ]]; do
            parent_pid="$(ps -o ppid= -p "$current_pid" | tr -d ' ')"
            [[ -n "$parent_pid" ]] || break
            if [[ "$parent_pid" -eq "$pid" ]]; then
                codex_count=$((codex_count + 1))
                break
            fi
            [[ "$parent_pid" -ne "$current_pid" ]] || break
            current_pid="$parent_pid"
        done
    done
else
    pgrep_status=$?
    if [[ "$pgrep_status" -eq 1 ]]; then
        codex_count=0
    else
        qa_fail "pgrep failed with status $pgrep_status" || exit "$pgrep_status"
    fi
fi

mkdir -p "$(dirname -- "$OUTPUT_PATH")"
{
    printf 'sampled_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'app=%s\n' "$(qa_redact_path "$APP_PATH")"
    printf 'pid=%s\n' "$pid"
    printf 'processes=\n'
    ps -p "$pid" -o pid=,ppid=,%cpu=,rss=,command= | while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$(qa_redact_line "$line")"
    done
    printf 'codex_app_server_processes=%s\n' "$codex_count"
} >"$OUTPUT_PATH"
printf 'qa-resource: wrote %s\n' "$(qa_redact_path "$OUTPUT_PATH")"
