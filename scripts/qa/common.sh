#!/usr/bin/env bash

QA_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
QA_STATE_DIR="${TOKEN_USAGE_QA_STATE_DIR:-$QA_ROOT_DIR/build/qa-state}"

qa_fail() {
    printf 'qa: error: %s\n' "$*" >&2
    return 1
}

qa_redact_path() {
    local value="$1"
    if [[ -n "${HOME:-}" && "$value" == "$HOME" ]]; then
        printf '~'
    elif [[ -n "${HOME:-}" && "$value" == "$HOME"/* ]]; then
        printf '~/%s' "${value#"$HOME"/}"
    else
        printf '%s' "$value"
    fi
}

qa_redact_line() {
    local value="$1"
    if [[ -n "${HOME:-}" ]]; then
        value="${value//"$HOME"/~}"
    fi
    printf '%s' "$value"
}

qa_absolute_path() {
    local value="$1"
    if [[ "$value" == /* ]]; then
        printf '%s' "$value"
    else
        printf '%s/%s' "$QA_ROOT_DIR" "$value"
    fi
}

qa_prepare_state() {
    umask 077
    mkdir -p "$QA_STATE_DIR"
}

qa_state_pid() {
    [[ -r "$QA_STATE_DIR/app.pid" ]] || return 1
    local pid
    pid="$(<"$QA_STATE_DIR/app.pid")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$pid"
}

qa_pid_running() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    local command_line
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command_line" == *TokenUsageApp* ]]
}
