#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_DIR="${TOKEN_USAGE_INSTALL_DIR:-${HOME:?}/Applications}"
APP_PATH="$INSTALL_DIR/Token Usage.app"
BUILD_APP_PATH="$ROOT_DIR/build/TokenUsage.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() {
    printf 'install-app: error: %s\n' "$*" >&2
    exit 1
}

redact_path() {
    local value="$1"
    if [[ "$value" == "$HOME" ]]; then
        printf '~'
    elif [[ "$value" == "$HOME"/* ]]; then
        printf '%s/%s' '~' "${value#"$HOME"/}"
    else
        printf '%s' "$value"
    fi
}

[[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || fail "invalid install directory"
[[ -x "$LSREGISTER" ]] || fail "LaunchServices registration tool is unavailable"

mkdir -p "$INSTALL_DIR"
TOKEN_USAGE_APP_DIR="$APP_PATH" "$ROOT_DIR/scripts/package-app.sh"
if [[ -d "$BUILD_APP_PATH" && "$BUILD_APP_PATH" != "$APP_PATH" ]]; then
    "$LSREGISTER" -u "$BUILD_APP_PATH"
fi
"$LSREGISTER" -f "$APP_PATH"
/usr/bin/mdimport "$APP_PATH"

printf 'install-app: installed and registered %s\n' "$(redact_path "$APP_PATH")"
