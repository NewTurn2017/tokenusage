#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?usage: validate-relocated-app.sh /path/to/Token Usage.app}"
BINARY_PATH="$APP_PATH/Contents/MacOS/TokenUsageApp"
[[ -x "$BINARY_PATH" ]] || { printf 'validate-relocated-app: error: missing executable\n' >&2; exit 1; }
[[ -x /usr/bin/sandbox-exec ]] || { printf 'validate-relocated-app: error: sandbox-exec unavailable\n' >&2; exit 1; }
[[ -x /usr/bin/sample ]] || { printf 'validate-relocated-app: error: sample unavailable\n' >&2; exit 1; }

STATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tokenusage-relocated-runtime.XXXXXX")"
RUNTIME_HOME="$STATE_ROOT/home"
SAMPLE_PATH="$STATE_ROOT/sample.txt"
mkdir -p "$RUNTIME_HOME"
pid=""

cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$STATE_ROOT"
}
trap cleanup EXIT

# The relocated app gets a disposable home and no network. Explicitly denying the system tools
# used for credential access prevents provider authentication and user sign-in file mutation while
# still exercising AppKit startup and packaged resource resolution.
SANDBOX_PROFILE="(version 1)
(allow default)
(deny network*)
(deny process-exec (literal \"/usr/bin/security\"))
(deny process-exec (literal \"/bin/launchctl\"))
(deny process-exec (literal \"/bin/sh\"))
(deny file-write* (subpath \"${HOME:?}\"))"

env -i \
    HOME="$RUNTIME_HOME" \
    CFFIXED_USER_HOME="$RUNTIME_HOME" \
    CODEX_HOME="$RUNTIME_HOME/.codex" \
    CLAUDE_CONFIG_DIR="$RUNTIME_HOME/.claude" \
    TOKENUSAGE_CODEX_PATH="$RUNTIME_HOME/missing-codex" \
    TOKENUSAGE_CLAUDE_PATH="$RUNTIME_HOME/missing-claude" \
    PATH="/usr/bin:/bin" \
    TMPDIR="$STATE_ROOT" \
    /usr/bin/sandbox-exec -p "$SANDBOX_PROFILE" "$BINARY_PATH" \
    >"$STATE_ROOT/stdout.log" 2>"$STATE_ROOT/stderr.log" &
pid=$!

# sample is the bounded process monitor: it fails if startup terminates (including a missing
# SwiftPM resource-bundle fatal error) and proves the relocated executable remains live in AppKit.
if ! /usr/bin/sample "$pid" 1 1 -file "$SAMPLE_PATH" >/dev/null 2>&1; then
    wait "$pid" 2>/dev/null || true
    printf 'validate-relocated-app: error: relocated app exited during startup\n' >&2
    exit 1
fi
if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    printf 'validate-relocated-app: error: relocated app exited after startup monitoring\n' >&2
    exit 1
fi
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
pid=""

if grep -qiE '(could not load resource bundle|fatal error)' "$STATE_ROOT/stderr.log"; then
    printf 'validate-relocated-app: error: resource loading failed\n' >&2
    exit 1
fi

printf 'validate-relocated-app: PASS (sandboxed; network and auth-helper execution denied; disposable home)\n'
