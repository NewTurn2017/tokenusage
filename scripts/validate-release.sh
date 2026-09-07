#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_PATH="${1:-$ROOT_DIR/build/TokenUsage.app}"
PRODUCT_NAME="TokenUsageApp"
RESOURCE_BUNDLE_NAME="TokenUsage_TokenUsageApp.bundle"
EXPECTED_ARCH_LIST="${TOKEN_USAGE_EXPECTED_ARCHS:-${TOKEN_USAGE_ARCHS:-${TOKEN_USAGE_ARCH:-arm64 x86_64}}}"
REQUIRE_DEVELOPER_ID="${TOKEN_USAGE_REQUIRE_DEVELOPER_ID:-0}"

fail() {
    printf 'validate-release: error: %s\n' "$*" >&2
    exit 1
}

redact_path() {
    local value="$1"
    if [[ -n "${HOME:-}" && "$value" == "$HOME" ]]; then
        printf '~'
    elif [[ -n "${HOME:-}" && "$value" == "$HOME"/* ]]; then
        printf '%s/%s' '~' "${value#"$HOME"/}"
    else
        printf '%s' "$value"
    fi
}

[[ -d "$APP_PATH" ]] || fail "missing app bundle: $(redact_path "$APP_PATH")"
BINARY_PATH="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
[[ -x "$BINARY_PATH" ]] || fail "missing app executable"
[[ -f "$PLIST_PATH" ]] || fail "missing Info.plist"
[[ -d "$APP_PATH/Contents/Resources/$RESOURCE_BUNDLE_NAME" ]] || fail "missing SwiftPM resource bundle"

/usr/bin/plutil -lint "$PLIST_PATH" >/dev/null || fail "invalid Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST_PATH")" == "local.tokenusage.app" ]] \
    || fail "unexpected bundle identifier"
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$PLIST_PATH")" == "14.0" ]] \
    || fail "unexpected minimum macOS version"
LS_UI_ELEMENT="$(/usr/bin/plutil -extract LSUIElement raw -o - "$PLIST_PATH")"
[[ "$LS_UI_ELEMENT" == 1 || "$LS_UI_ELEMENT" == true ]] || fail "LSUIElement must be true"

for resource in \
    "Contents/Resources/TokenUsage.icns" \
    "Contents/Resources/ATTRIBUTION.md" \
    "Contents/Resources/LICENSE" \
    "Contents/Resources/ProviderIcons/Anthropic.svg" \
    "Contents/Resources/ProviderIcons/OpenAI.svg" \
    "Contents/Resources/MenuBarIcons/anthropic.png" \
    "Contents/Resources/MenuBarIcons/codex.png" \
    "Contents/Resources/MenuBarIcons/openrouter.png"; do
    [[ -f "$APP_PATH/$resource" ]] || fail "missing packaged resource: $resource"
done
for resource in Anthropic.svg OpenAI.svg anthropic.png codex.png openrouter.png ATTRIBUTION.md; do
    [[ -n "$(find "$APP_PATH/Contents/Resources/$RESOURCE_BUNDLE_NAME" -type f -name "$resource" -print -quit)" ]] \
        || fail "missing SwiftPM bundle resource: $resource"
done

ACTUAL_ARCHES="$(/usr/bin/lipo -archs "$BINARY_PATH" 2>/dev/null || true)"
read -r -a EXPECTED_ARCHES <<<"$EXPECTED_ARCH_LIST"
for arch in "${EXPECTED_ARCHES[@]}"; do
    [[ " $ACTUAL_ARCHES " == *" $arch "* ]] || fail "missing expected architecture: $arch"
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null \
    || fail "signature verification failed"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS"; then
    SIGNING_STATUS="ad-hoc signed; NOT publicly notarized"
else
    SIGNING_AUTHORITY="$(sed -n 's/^Authority=//p' <<<"$SIGNATURE_DETAILS" | head -n 1)"
    TEAM_IDENTIFIER="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_DETAILS" | head -n 1)"
    [[ -n "$SIGNING_AUTHORITY" && -n "$TEAM_IDENTIFIER" ]] || fail "incomplete signing identity metadata"
    [[ "$SIGNATURE_DETAILS" == *'flags=0x10000(runtime)'* ]] || fail "hardened runtime is not enabled"
    SIGNING_STATUS="$SIGNING_AUTHORITY; team=$TEAM_IDENTIFIER; hardened runtime; notarization NOT verified"
fi
if [[ "$REQUIRE_DEVELOPER_ID" == 1 ]]; then
    [[ "$SIGNATURE_DETAILS" == *'Authority=Developer ID Application:'* ]] \
        || fail "Developer ID Application signature is required"
    ! grep -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS" || fail "ad-hoc signature is not Developer ID"
elif [[ "$REQUIRE_DEVELOPER_ID" != 0 ]]; then
    fail "TOKEN_USAGE_REQUIRE_DEVELOPER_ID must be 0 or 1"
fi

if strings "$BINARY_PATH" | grep -Fq "$ROOT_DIR"; then
    fail "binary embeds the builder checkout path"
fi

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST_PATH")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST_PATH")"
printf 'validate-release: PASS app=%s version=%s/%s architectures=%s signing="%s"\n' \
    "$(redact_path "$APP_PATH")" "$VERSION" "$BUILD" "$ACTUAL_ARCHES" "$SIGNING_STATUS"
