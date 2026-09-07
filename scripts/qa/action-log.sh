#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LOG_PATH="${TOKEN_USAGE_QA_ACTION_LOG:-$QA_ROOT_DIR/build/qa-state/actions.log}"
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)
            [[ $# -ge 2 ]] || { qa_fail '--log requires a path'; exit 1; }
            LOG_PATH="$2"
            shift 2
            ;;
        --action)
            [[ $# -ge 2 ]] || { qa_fail '--action requires a value'; exit 1; }
            ACTION="${ACTION:+$ACTION }$2"
            shift 2
            ;;
        --)
            shift
            ACTION="${ACTION:+$ACTION }$*"
            break
            ;;
        *)
            ACTION="${ACTION:+$ACTION }$1"
            shift
            ;;
    esac
done
[[ -n "$ACTION" ]] || { qa_fail 'an action is required'; exit 1; }

LOG_PATH="$(qa_absolute_path "$LOG_PATH")"
mkdir -p "$(dirname -- "$LOG_PATH")"
printf '%s action=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(qa_redact_line "$ACTION")" >>"$LOG_PATH"
printf 'qa-action-log: recorded action in %s\n' "$(qa_redact_path "$LOG_PATH")"
