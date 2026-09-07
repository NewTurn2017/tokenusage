#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

APP_PATH="${1:-$QA_ROOT_DIR/build/TokenUsage.app}"
OUTPUT_PATH="${2:-$QA_ROOT_DIR/build/qa-evidence/resource-stability.txt}"
SAMPLE_COUNT="${TOKEN_USAGE_RESOURCE_SAMPLES:-30}"
SAMPLE_INTERVAL="${TOKEN_USAGE_RESOURCE_INTERVAL:-1}"
SETTLE_ATTEMPTS="${TOKEN_USAGE_RESOURCE_SETTLE_ATTEMPTS:-12}"
SETTLE_INTERVAL="${TOKEN_USAGE_RESOURCE_SETTLE_INTERVAL:-5}"
RSS_GROWTH_LIMIT_KB="${TOKEN_USAGE_RSS_GROWTH_LIMIT_KB:-16384}"
CPU_LIMIT_PERCENT="${TOKEN_USAGE_CPU_LIMIT_PERCENT:-10}"
SAMPLE_PATH="$QA_STATE_DIR/resource-stability-sample.txt"
pid=""

cleanup() {
    "$SCRIPT_DIR/cleanup.sh" >/dev/null
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        printf 'cleanup: failed; pid=%s remains\n' "$pid" >>"$OUTPUT_PATH"
        return 1
    fi
    printf 'cleanup: app stopped; app_processes=0\n' >>"$OUTPUT_PATH"
}
trap cleanup EXIT

[[ "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]] || { qa_fail "invalid sample count"; exit 1; }
[[ "$SAMPLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { qa_fail "invalid sample interval"; exit 1; }
[[ "$SETTLE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { qa_fail "invalid settle attempts"; exit 1; }
[[ "$SETTLE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { qa_fail "invalid settle interval"; exit 1; }
[[ "$RSS_GROWTH_LIMIT_KB" =~ ^[1-9][0-9]*$ ]] || {
    qa_fail "invalid RSS growth limit"
    exit 1
}
[[ "$CPU_LIMIT_PERCENT" =~ ^[1-9][0-9]*$ ]] || { qa_fail "invalid CPU limit"; exit 1; }

APP_PATH="$(qa_absolute_path "$APP_PATH")"
OUTPUT_PATH="$(qa_absolute_path "$OUTPUT_PATH")"
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
: >"$OUTPUT_PATH"

"$SCRIPT_DIR/start-app.sh" "$APP_PATH"
pid="$(qa_state_pid)"

cpu_seconds() {
    ps -p "$pid" -o time= | awk -F: '
        NF == 3 { print ($1 * 3600) + ($2 * 60) + $3; next }
        NF == 2 { print ($1 * 60) + $2; next }
        { print $1 }
    '
}

settled=false
settle_cpu="$(cpu_seconds)"
settle_percent=""
for ((attempt = 1; attempt <= SETTLE_ATTEMPTS; attempt++)); do
    sleep "$SETTLE_INTERVAL"
    current_cpu="$(cpu_seconds)"
    settle_percent="$(awk \
        -v start="$settle_cpu" \
        -v end="$current_cpu" \
        -v elapsed="$SETTLE_INTERVAL" \
        'BEGIN { printf "%.2f", ((end - start) / elapsed) * 100 }')"
    if awk -v actual="$settle_percent" -v limit="$CPU_LIMIT_PERCENT" \
        'BEGIN { exit !(actual <= limit) }'
    then
        settled=true
        break
    fi
    settle_cpu="$current_cpu"
done
[[ "$settled" == true ]] || {
    qa_fail "CPU did not settle below ${CPU_LIMIT_PERCENT}%"
    exit 1
}

start_cpu="$current_cpu"
start_wall="$(date +%s)"
min_rss=""
max_rss=0
max_codex_children=0

{
    printf 'app=%s\n' "$(qa_redact_path "$APP_PATH")"
    printf 'pid=%s\n' "$pid"
    printf 'samples=%s\n' "$SAMPLE_COUNT"
    printf 'interval_seconds=%s\n' "$SAMPLE_INTERVAL"
    printf 'settle_attempt=%s\n' "$attempt"
    printf 'settle_window_cpu_percent=%s\n' "$settle_percent"
} >>"$OUTPUT_PATH"

for ((sample = 1; sample <= SAMPLE_COUNT; sample++)); do
    "$SCRIPT_DIR/resource-sample.sh" "$APP_PATH" "$SAMPLE_PATH" >/dev/null
    rss="$(ps -p "$pid" -o rss= | tr -d ' ')"
    codex_children="$(awk -F= '/^codex_app_server_processes=/ { print $2 }' "$SAMPLE_PATH")"
    [[ "$rss" =~ ^[0-9]+$ ]] || { qa_fail "invalid RSS sample"; exit 1; }
    [[ "$codex_children" =~ ^[0-9]+$ ]] || {
        qa_fail "invalid child-process sample"
        exit 1
    }
    if [[ -z "$min_rss" || "$rss" -lt "$min_rss" ]]; then min_rss="$rss"; fi
    if [[ "$rss" -gt "$max_rss" ]]; then max_rss="$rss"; fi
    if [[ "$codex_children" -gt "$max_codex_children" ]]; then
        max_codex_children="$codex_children"
    fi
    printf 'sample=%s rss_kb=%s codex_app_server_processes=%s\n' \
        "$sample" "$rss" "$codex_children" >>"$OUTPUT_PATH"
    if [[ "$sample" -lt "$SAMPLE_COUNT" ]]; then sleep "$SAMPLE_INTERVAL"; fi
done

end_cpu="$(cpu_seconds)"
end_wall="$(date +%s)"
rss_growth_kb=$((max_rss - min_rss))
elapsed_seconds=$((end_wall - start_wall))
cpu_percent="$(awk -v start="$start_cpu" -v end="$end_cpu" -v elapsed="$elapsed_seconds" \
    'BEGIN { if (elapsed <= 0) print 0; else printf "%.2f", ((end - start) / elapsed) * 100 }')"

{
    printf 'rss_min_kb=%s\n' "$min_rss"
    printf 'rss_max_kb=%s\n' "$max_rss"
    printf 'rss_growth_kb=%s\n' "$rss_growth_kb"
    printf 'cpu_percent=%s\n' "$cpu_percent"
    printf 'max_codex_app_server_processes=%s\n' "$max_codex_children"
} >>"$OUTPUT_PATH"

[[ "$rss_growth_kb" -le "$RSS_GROWTH_LIMIT_KB" ]] || {
    qa_fail "RSS growth exceeded ${RSS_GROWTH_LIMIT_KB} KB"
    exit 1
}
awk -v actual="$cpu_percent" -v limit="$CPU_LIMIT_PERCENT" \
    'BEGIN { exit !(actual <= limit) }' || {
    qa_fail "CPU usage exceeded ${CPU_LIMIT_PERCENT}%"
    exit 1
}
[[ "$max_codex_children" -eq 0 ]] || {
    qa_fail "Codex app-server child process remained at a sample boundary"
    exit 1
}

printf 'result=PASS\n' >>"$OUTPUT_PATH"
printf 'resource-stability: PASS rss_growth_kb=%s cpu_percent=%s child_peak=%s\n' \
    "$rss_growth_kb" "$cpu_percent" "$max_codex_children"
