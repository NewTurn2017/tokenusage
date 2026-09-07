#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_DIR="${TOKEN_USAGE_APP_DIR:-$ROOT_DIR/build/TokenUsage.app}"
PRODUCT_NAME="TokenUsageApp"
RESOURCE_BUNDLE_NAME="TokenUsage_TokenUsageApp.bundle"
ARCH_LIST="${TOKEN_USAGE_ARCHS:-${TOKEN_USAGE_ARCH:-arm64 x86_64}}"
BINARY_OVERRIDE="${TOKEN_USAGE_BINARY:-}"
RESOURCE_BUNDLE_OVERRIDE="${TOKEN_USAGE_RESOURCE_BUNDLE:-}"
SIGN_IDENTITY="${TOKEN_USAGE_SIGN_IDENTITY:--}"
BUILD_SCRATCH=""
BUILD_LOG=""

fail() {
    printf 'package-app: error: %s\n' "$*" >&2
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

cleanup() {
    [[ -z "$BUILD_LOG" ]] || rm -f "$BUILD_LOG"
    [[ -z "$BUILD_SCRATCH" ]] || rm -rf "$BUILD_SCRATCH"
}
trap cleanup EXIT

read -r -a ARCHES_REQUESTED <<<"$ARCH_LIST"
[[ ${#ARCHES_REQUESTED[@]} -gt 0 ]] || fail "at least one architecture is required"
BUILD_ARGUMENTS=()
for arch in "${ARCHES_REQUESTED[@]}"; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || fail "unsupported architecture: $arch"
    BUILD_ARGUMENTS+=(--arch "$arch")
done

[[ -n "$APP_DIR" && "$APP_DIR" == *.app && "$APP_DIR" != "/" ]] || fail "invalid app output path"
[[ -f "$ROOT_DIR/Resources/Info.plist" ]] || fail "missing Resources/Info.plist"
[[ -f "$ROOT_DIR/LICENSE" ]] || fail "missing project LICENSE"
[[ -f "$ROOT_DIR/Resources/AppIcon/TokenUsage.icns" ]] || fail "missing Resources/AppIcon/TokenUsage.icns"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/Anthropic.svg" ]] || fail "missing Resources/ProviderIcons/Anthropic.svg"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/OpenAI.svg" ]] || fail "missing Resources/ProviderIcons/OpenAI.svg"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/ATTRIBUTION.md" ]] || fail "missing provider attribution"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/anthropic.png" ]] || fail "missing Resources/MenuBarIcons/anthropic.png"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/codex.png" ]] || fail "missing Resources/MenuBarIcons/codex.png"
[[ -f "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/openrouter.png" ]] || fail "missing Resources/MenuBarIcons/openrouter.png"

# Remove only this generated bundle, so a failed attempt cannot leave a stale app.
rm -rf "$APP_DIR"

if [[ -n "$BINARY_OVERRIDE" ]]; then
    [[ -f "$BINARY_OVERRIDE" && -x "$BINARY_OVERRIDE" ]] || fail "missing release binary override: $(basename -- "$BINARY_OVERRIDE")"
    BINARY_PATH="$(cd -- "$(dirname -- "$BINARY_OVERRIDE")" && pwd -P)/$(basename -- "$BINARY_OVERRIDE")"
    if [[ -n "$RESOURCE_BUNDLE_OVERRIDE" ]]; then
        RESOURCE_BUNDLE_PATH="$RESOURCE_BUNDLE_OVERRIDE"
    else
        RESOURCE_BUNDLE_PATH="$(dirname -- "$BINARY_PATH")/$RESOURCE_BUNDLE_NAME"
    fi
else
    BUILD_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tokenusage-release-build.XXXXXX")"
    BUILD_LOG="$(mktemp -t tokenusage-package.XXXXXX)"
    if ! swift build --scratch-path "$BUILD_SCRATCH" -c release \
        "${BUILD_ARGUMENTS[@]}" --product "$PRODUCT_NAME" >"$BUILD_LOG" 2>&1; then
        printf 'package-app: error: release build failed\n' >&2
        tail -n 30 "$BUILD_LOG" >&2 || true
        exit 1
    fi
    BINARY_DIRECTORY="$(swift build --scratch-path "$BUILD_SCRATCH" --show-bin-path \
        -c release "${BUILD_ARGUMENTS[@]}" --product "$PRODUCT_NAME")"
    BINARY_PATH="$BINARY_DIRECTORY/$PRODUCT_NAME"
    RESOURCE_BUNDLE_PATH="$BINARY_DIRECTORY/$RESOURCE_BUNDLE_NAME"
fi

[[ -f "$BINARY_PATH" && -x "$BINARY_PATH" ]] || fail "missing release binary: $(basename -- "$BINARY_PATH")"
[[ -d "$RESOURCE_BUNDLE_PATH" ]] || fail "missing SwiftPM resource bundle: $RESOURCE_BUNDLE_NAME"

ARCHES_ACTUAL="$(/usr/bin/lipo -archs "$BINARY_PATH" 2>/dev/null || true)"
for arch in "${ARCHES_REQUESTED[@]}"; do
    [[ " $ARCHES_ACTUAL " == *" $arch "* ]] || fail "release binary is missing architecture: $arch"
done

mkdir -p "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources/ProviderIcons" \
    "$APP_DIR/Contents/Resources/MenuBarIcons"
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
chmod 0755 "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$ROOT_DIR/Resources/AppIcon/TokenUsage.icns" "$APP_DIR/Contents/Resources/TokenUsage.icns"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/Anthropic.svg" "$APP_DIR/Contents/Resources/ProviderIcons/Anthropic.svg"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/OpenAI.svg" "$APP_DIR/Contents/Resources/ProviderIcons/OpenAI.svg"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/ProviderIcons/ATTRIBUTION.md" "$APP_DIR/Contents/Resources/ATTRIBUTION.md"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/anthropic.png" "$APP_DIR/Contents/Resources/MenuBarIcons/anthropic.png"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/codex.png" "$APP_DIR/Contents/Resources/MenuBarIcons/codex.png"
cp "$ROOT_DIR/Sources/TokenUsageApp/Resources/MenuBarIcons/openrouter.png" "$APP_DIR/Contents/Resources/MenuBarIcons/openrouter.png"
cp -R "$RESOURCE_BUNDLE_PATH" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME"

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null || fail "invalid bundle Info.plist"
LS_UI_ELEMENT="$(/usr/bin/plutil -extract LSUIElement raw -o - "$APP_DIR/Contents/Info.plist")"
[[ "$LS_UI_ELEMENT" == 1 || "$LS_UI_ELEMENT" == true ]] || fail "bundle Info.plist must set LSUIElement=true"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
    SIGNING_DESCRIPTION="ad-hoc signed; NOT publicly notarized"
else
    IDENTITY_LIST="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
    if [[ "$IDENTITY_LIST" != *"\"$SIGN_IDENTITY\""* && "$IDENTITY_LIST" != *" $SIGN_IDENTITY \""* ]]; then
        fail "requested signing identity is not available in the keychain"
    fi
    if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        # A SHA-1 identity is allowed only when its matching keychain row is a Developer ID Application.
        IDENTITY_ROW="$(printf '%s\n' "$IDENTITY_LIST" | grep -F " $SIGN_IDENTITY \"" || true)"
        [[ "$IDENTITY_ROW" == *'"Developer ID Application:'* ]] \
            || fail "public release signing requires a Developer ID Application identity"
    fi

    # Sign embedded Mach-O code inside-out. The SwiftPM resource bundle currently contains no code,
    # but this keeps future helpers/frameworks correctly sealed before the outer app is signed.
    while IFS= read -r -d '' nested_code; do
        [[ "$nested_code" == "$APP_DIR/Contents/MacOS/$PRODUCT_NAME" ]] && continue
        if /usr/bin/file -b "$nested_code" | grep -q 'Mach-O'; then
            /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested_code" >/dev/null
        fi
    done < <(find "$APP_DIR/Contents" -type f -print0)
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
    SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)"
    [[ "$SIGNATURE_DETAILS" == *'Authority=Developer ID Application:'* ]] \
        || fail "result is not signed by a Developer ID Application certificate"
    [[ "$SIGNATURE_DETAILS" == *'flags=0x10000(runtime)'* ]] \
        || fail "hardened runtime was not enabled"
    SIGNING_DESCRIPTION="Developer ID signed with hardened runtime; NOT notarized"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null \
    || fail "signature verification failed"

printf 'package-app: created %s (%s; %s; LSUIElement=1)\n' \
    "$(redact_path "$APP_DIR")" "$ARCHES_ACTUAL" "$SIGNING_DESCRIPTION"
