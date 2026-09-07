#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

OUTPUT_PATH="${TOKEN_USAGE_QA_SCREENSHOT:-$QA_ROOT_DIR/build/qa-state/screenshot.png}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { qa_fail '--output requires a path'; exit 1; }
            OUTPUT_PATH="$2"
            shift 2
            ;;
        *)
            OUTPUT_PATH="$1"
            shift
            ;;
    esac
done
OUTPUT_PATH="$(qa_absolute_path "$OUTPUT_PATH")"
command -v /usr/sbin/screencapture >/dev/null 2>&1 || { qa_fail 'screencapture is unavailable'; exit 1; }
mkdir -p "$(dirname -- "$OUTPUT_PATH")"
/usr/sbin/screencapture -x "$OUTPUT_PATH"
printf 'qa-screenshot: captured %s\n' "$(qa_redact_path "$OUTPUT_PATH")"
