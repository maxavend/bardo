#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-dmg.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bardo-dmg-fixture-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

mkdir -p "$TEST_ROOT/invalid-root"
INVALID_DMG="$TEST_ROOT/invalid.dmg"
if ! hdiutil create -quiet -volname "Invalid Bardo" -srcfolder "$TEST_ROOT/invalid-root" -ov -format UDZO "$INVALID_DMG"; then
    echo "Unable to create the invalid DMG fixture; a macOS disk-image device is required." >&2
    exit 2
fi

set +e
VERIFY_DMG_ONLY=1 DMG_PATH="$INVALID_DMG" "$VERIFY_SCRIPT" >"$TEST_ROOT/invalid.log" 2>&1
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
    echo "The DMG verifier accepted an image without Bardo.app." >&2
    cat "$TEST_ROOT/invalid.log" >&2
    exit 1
fi

if ! grep -Fq 'Bardo.app' "$TEST_ROOT/invalid.log"; then
    echo "The invalid-image fixture could not reach the Bardo.app assertion." >&2
    cat "$TEST_ROOT/invalid.log" >&2
    exit 1
fi
echo "Invalid-image fixture rejected as expected."

if [ -n "${VALID_DMG_PATH:-}" ]; then
    VERIFY_DMG_ONLY=1 DMG_PATH="$VALID_DMG_PATH" "$VERIFY_SCRIPT"
    echo "Existing valid-image fixture accepted as expected: $VALID_DMG_PATH"
fi
