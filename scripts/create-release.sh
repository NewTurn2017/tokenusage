#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIR="${TOKEN_USAGE_RELEASE_DIR:-$ROOT_DIR/build/release}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tokenusage-release-stage.XXXXXX")"
EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tokenusage-release-extract.XXXXXX")"
APP_PATH="$STAGING_ROOT/Token Usage.app"

cleanup() {
    rm -rf "$STAGING_ROOT" "$EXTRACT_ROOT"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
TOKEN_USAGE_APP_DIR="$APP_PATH" "$ROOT_DIR/scripts/package-app.sh"
"$ROOT_DIR/scripts/validate-release.sh" "$APP_PATH"

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")"
ARCHES="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/TokenUsageApp")"
if [[ " $ARCHES " == *' arm64 '* && " $ARCHES " == *' x86_64 '* ]]; then
    ARCH_LABEL="universal"
else
    ARCH_LABEL="${ARCHES// /-}"
fi
ARCHIVE_NAME="TokenUsage-$VERSION-macos-$ARCH_LABEL.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$ARCHIVE_NAME" >"$ARCHIVE_NAME.sha256"
)
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_ROOT"
EXTRACTED_APP="$EXTRACT_ROOT/Token Usage.app"
"$ROOT_DIR/scripts/validate-release.sh" "$EXTRACTED_APP"
"$ROOT_DIR/scripts/validate-relocated-app.sh" "$EXTRACTED_APP"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 -c "$ARCHIVE_NAME.sha256" >/dev/null
)

printf 'create-release: PASS\n'
printf 'archive: %s\n' "$ARCHIVE_PATH"
printf 'checksum: %s\n' "$CHECKSUM_PATH"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS"; then
    printf 'signing: local ad-hoc; NOT publicly notarized\n'
else
    SIGNING_AUTHORITY="$(sed -n 's/^Authority=//p' <<<"$SIGNATURE_DETAILS" | head -n 1)"
    printf 'signing: %s; hardened runtime; NOT notarized\n' "$SIGNING_AUTHORITY"
fi
