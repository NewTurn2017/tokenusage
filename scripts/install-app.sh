#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_DIR="${TOKEN_USAGE_INSTALL_DIR:-${HOME:?}/Applications}"
APP_PATH="$INSTALL_DIR/Token Usage.app"
BUILD_APP_PATH="$ROOT_DIR/build/TokenUsage.app"
BUNDLE_ID="local.tokenusage.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
QUIT_TIMEOUT_SECONDS=30
STAGING_DIR=""

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

cleanup() {
    [[ -z "$STAGING_DIR" ]] || rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

# Prints the signing team of a bundle, or nothing when it is ad hoc or unsigned.
team_of() {
    /usr/bin/codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | grep -v '^not set$' || true
}

app_is_running() {
    [[ "$(/usr/bin/osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == true ]]
}

# A quit request lets the app finish an in-flight token renewal and save it; killing it could
# lose a rotated refresh token and sign that account out.
quit_running_app() {
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null
    local waited=0
    while app_is_running; do
        ((waited < QUIT_TIMEOUT_SECONDS * 5)) || fail "Token Usage did not quit; quit it from its menu and run this again"
        sleep 0.2
        waited=$((waited + 1))
    done
}

[[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || fail "invalid install directory"
[[ -x "$LSREGISTER" ]] || fail "LaunchServices registration tool is unavailable"

# Saved Claude and Codex accounts live in Keychain items that trust the installed app by its
# designated requirement - bundle ID plus signing team. Signing the new build ad hoc or with
# another team makes every one of those items ask for the login password again, or fail, so the
# install keeps the installed app's team unless explicitly told to change it.
INSTALLED_TEAM=""
[[ -d "$APP_PATH" ]] && INSTALLED_TEAM="$(team_of "$APP_PATH")"
SIGN_IDENTITY="${TOKEN_USAGE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -n "$INSTALLED_TEAM" ]]; then
    SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/.*\"\(Developer ID Application: .* ($INSTALLED_TEAM)\)\"\$/\1/p" | head -n 1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ -n "$INSTALLED_TEAM" && "$SIGN_IDENTITY" == "-" && "${TOKEN_USAGE_ALLOW_SIGNING_CHANGE:-}" != 1 ]]; then
    fail "the installed app is signed by team $INSTALLED_TEAM but no matching Developer ID Application identity is available; an ad hoc build would cut saved accounts off from their Keychain items. Set TOKEN_USAGE_SIGN_IDENTITY, or TOKEN_USAGE_ALLOW_SIGNING_CHANGE=1 to accept that"
fi

mkdir -p "$INSTALL_DIR" "$ROOT_DIR/build"
# Build next to the repository first, so the running app keeps a complete bundle until the swap.
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/install-staging.XXXXXX")"
STAGED_APP="$STAGING_DIR/Token Usage.app"
TOKEN_USAGE_APP_DIR="$STAGED_APP" TOKEN_USAGE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$ROOT_DIR/scripts/package-app.sh"

NEW_TEAM="$(team_of "$STAGED_APP")"
if [[ -n "$INSTALLED_TEAM" && "$NEW_TEAM" != "$INSTALLED_TEAM" && "${TOKEN_USAGE_ALLOW_SIGNING_CHANGE:-}" != 1 ]]; then
    fail "the new build is signed by team ${NEW_TEAM:-ad hoc}, not $INSTALLED_TEAM; saved accounts would lose access to their Keychain items"
fi

WAS_RUNNING=0
if app_is_running; then
    WAS_RUNNING=1
    quit_running_app
fi

rm -rf "$APP_PATH"
mv "$STAGED_APP" "$APP_PATH"
"$LSREGISTER" -u "$STAGED_APP" >/dev/null 2>&1 || true
if [[ -d "$BUILD_APP_PATH" && "$BUILD_APP_PATH" != "$APP_PATH" ]]; then
    "$LSREGISTER" -u "$BUILD_APP_PATH"
fi
"$LSREGISTER" -f "$APP_PATH"
/usr/bin/mdimport "$APP_PATH"

# `open` hands the caller's environment to the app. Launch it with what a login would give it,
# so this shell's CLAUDE_CONFIG_DIR, CODEX_HOME or PATH cannot point it at other accounts.
if [[ "$WAS_RUNNING" == 1 && "${TOKEN_USAGE_NO_LAUNCH:-}" != 1 ]]; then
    /usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}" \
        TMPDIR="${TMPDIR:-/tmp/}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" /usr/bin/open "$APP_PATH"
fi

printf 'install-app: installed and registered %s (team %s)\n' \
    "$(redact_path "$APP_PATH")" "${NEW_TEAM:-ad hoc}"
