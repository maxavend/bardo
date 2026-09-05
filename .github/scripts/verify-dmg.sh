#!/usr/bin/env bash
set -euo pipefail

# Build, package, mount and verify a Bardo release image. Set VERIFY_DMG_ONLY=1
# to validate an existing image without invoking XcodeGen or xcodebuild.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

readonly DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.derived-data}"
readonly APP_PATH="${APP_PATH:-$DERIVED_DATA_PATH/Build/Products/Release/Bardo.app}"
readonly DMG_PATH="${DMG_PATH:-Bardo-Test.dmg}"
readonly DMG_ROOT="${DMG_ROOT:-.dmg-root}"
readonly DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Bardo}"
readonly VERIFY_DMG_ONLY="${VERIFY_DMG_ONLY:-0}"
readonly COMMIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"

TEMP_ROOT=""
MOUNT_POINT=""
ATTACHED=0

cleanup() {
    if [ "$ATTACHED" -eq 1 ]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
        ATTACHED=0
    fi
    if [ -n "$TEMP_ROOT" ]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 2
    }
}

for command_name in codesign hdiutil shasum ditto lipo; do
    require_command "$command_name"
done

if [ "$VERIFY_DMG_ONLY" != "1" ]; then
    require_command xcodebuild
    require_command xcodegen
fi

assert_path() {
    local path="$1"
    local description="$2"
    test -e "$path" || {
        echo "DMG validation failed: missing $description at $path" >&2
        return 1
    }
}

validate_app() {
    local app_path="$1"
    assert_path "$app_path" "Bardo.app"
    assert_path "$app_path/Contents/Info.plist" "Bardo.app Info.plist"
    assert_path "$app_path/Contents/MacOS/Bardo" "Bardo executable"
    test -x "$app_path/Contents/MacOS/Bardo" || {
        echo "DMG validation failed: Bardo executable is not executable" >&2
        return 1
    }
    test "$(lipo -archs "$app_path/Contents/MacOS/Bardo")" = "arm64"
    test "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$app_path/Contents/Info.plist")" = "Bardo records microphone audio only when you choose to start a local recording."
    test "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$app_path/Contents/Info.plist")" = "Bardo captures audio from content you explicitly choose using the macOS system sharing picker."
}

validate_signed_app() {
    local app_path="$1"
    validate_app "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    local signature_details
    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
    printf '%s\n' "$signature_details"
    grep -Fq 'Signature=adhoc' <<< "$signature_details"
    local entitlements_path
    entitlements_path="$(mktemp "${TMPDIR:-/tmp}/bardo-entitlements.XXXXXX")"
    trap 'rm -f "$entitlements_path"' RETURN
    codesign -d --entitlements :- "$app_path" >"$entitlements_path" 2>/dev/null
    test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_path")" = "true"
    test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements_path")" = "true"
    rm -f "$entitlements_path"
    trap - RETURN
}

if [ "$VERIFY_DMG_ONLY" != "1" ]; then
    xcodegen generate
    xcodebuild \
        -project Bardo.xcodeproj \
        -scheme Bardo \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        build

    validate_app "$APP_PATH"

    codesign \
        --force \
        --deep \
        --sign - \
        --options runtime \
        --entitlements Bardo/Bardo.entitlements \
        "$APP_PATH"
    validate_signed_app "$APP_PATH"

    rm -rf "$DMG_ROOT" "$DMG_PATH" "$DMG_PATH.sha256"
    mkdir -p "$DMG_ROOT"
    ditto "$APP_PATH" "$DMG_ROOT/Bardo.app"
    ln -s /Applications "$DMG_ROOT/Applications"
    hdiutil create \
        -volname "$DMG_VOLUME_NAME" \
        -srcfolder "$DMG_ROOT" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
else
    test -f "$DMG_PATH"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bardo-dmg-XXXXXX")"
MOUNT_POINT="$TEMP_ROOT/mount"
mkdir -p "$MOUNT_POINT"

echo "Attaching $DMG_PATH read-only at $MOUNT_POINT"
hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    "$DMG_PATH"
ATTACHED=1

MOUNTED_APP="$MOUNT_POINT/Bardo.app"
assert_path "$MOUNTED_APP" "Bardo.app in mounted volume"
assert_path "$MOUNT_POINT/Applications" "/Applications alias in mounted volume"
test -L "$MOUNT_POINT/Applications" || {
    echo "DMG validation failed: Applications entry is not a symbolic link" >&2
    exit 1
}
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
validate_signed_app "$MOUNTED_APP"
echo "Mounted validation passed: Bardo.app and /Applications alias are present."

hdiutil detach "$MOUNT_POINT"
ATTACHED=0

hdiutil verify "$DMG_PATH"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
{
    printf '%s  %s\n' "$DMG_SHA" "$(basename "$DMG_PATH")"
    printf 'github.sha %s\n' "$COMMIT_SHA"
} > "$DMG_PATH.sha256"
echo "SHA-256: $DMG_SHA"
echo "github.sha: $COMMIT_SHA"
