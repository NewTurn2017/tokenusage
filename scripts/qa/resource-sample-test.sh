#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
test_root="$(mktemp -d -t tokenusage-resource-sample-test)"
state_dir="$test_root/qa-state"
fake_bin="$test_root/bin"
output_path="$test_root/resource.txt"
pid=""

cleanup() {
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    local tmp_parent="${TMPDIR:-/tmp}"
    tmp_parent="${tmp_parent%/}"
    if [[ -n "$test_root" && "$test_root" == "$tmp_parent"/tokenusage-resource-sample-test.* ]]; then
        rm -r -- "$test_root"
    else
        printf 'refusing to remove unexpected test path: %s\n' "$test_root" >&2
    fi
}
trap cleanup EXIT

mkdir -p "$state_dir" "$fake_bin" "$test_root/TokenUsage.app"
cat >"$test_root/TokenUsageApp" <<'EOF'
#!/usr/bin/env bash
while :; do
    /bin/sleep 1
done
EOF
chmod +x "$test_root/TokenUsageApp"
cat >"$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_PGREP_STATUS:-1}" in
    0)
        printf '%s\n' "${FAKE_PGREP_PID:?}"
        ;;
    1)
        exit 1
        ;;
    2)
        printf 'fake pgrep output\n'
        printf 'fake pgrep diagnostic\n' >&2
        exit 2
        ;;
    *)
        exit "${FAKE_PGREP_STATUS}"
        ;;
esac
EOF
chmod +x "$fake_bin/pgrep"

"$test_root/TokenUsageApp" &
pid=$!
printf '%s\n' "$pid" >"$state_dir/app.pid"

PATH="$fake_bin:$PATH" \
TOKEN_USAGE_QA_STATE_DIR="$state_dir" \
    "$SCRIPT_DIR/resource-sample.sh" "$test_root/TokenUsage.app" "$output_path"
grep -Fxq 'codex_app_server_processes=0' "$output_path"
printf 'resource-sample regression: zero matches recorded as codex_app_server_processes=0\n'

FAKE_PGREP_STATUS=0 \
FAKE_PGREP_PID="$$" \
PATH="$fake_bin:$PATH" \
TOKEN_USAGE_QA_STATE_DIR="$state_dir" \
    "$SCRIPT_DIR/resource-sample.sh" "$test_root/TokenUsage.app" "$output_path"
grep -Fxq 'codex_app_server_processes=0' "$output_path"
printf 'resource-sample regression: unrelated global Codex helper excluded\n'

status2_output=''
set +e
status2_output="$(
    FAKE_PGREP_STATUS=2 \
    PATH="$fake_bin:$PATH" \
    TOKEN_USAGE_QA_STATE_DIR="$state_dir" \
        "$SCRIPT_DIR/resource-sample.sh" "$test_root/TokenUsage.app" "$output_path" 2>&1
)"
status2=$?
set -e
[[ "$status2" -eq 2 ]] || {
    printf 'expected pgrep status 2 to propagate, got %s\n' "$status2" >&2
    exit 1
}
[[ "$status2_output" == *'pgrep failed with status 2'* ]] || {
    printf 'missing pgrep status diagnostic: %s\n' "$status2_output" >&2
    exit 1
}
[[ "$status2_output" != *'fake pgrep output'* ]] || {
    printf 'pgrep stdout leaked into failure output: %s\n' "$status2_output" >&2
    exit 1
}
[[ "$status2_output" != *'fake pgrep diagnostic'* ]] || {
    printf 'pgrep stderr leaked into failure output: %s\n' "$status2_output" >&2
    exit 1
}
printf 'resource-sample regression: pgrep status 2 propagated without leaking process output\n'
