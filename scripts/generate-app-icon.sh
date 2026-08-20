#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Brand/BardoAppIcon.png"
OUTPUT="$ROOT/Bardo/Resources/BardoAppIcon.icns"
ICONSET="$(mktemp -d)/BardoAppIcon.iconset"

cleanup() {
  rm -rf "$(dirname "$ICONSET")"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing app icon source: $SOURCE" >&2
  exit 1
fi

mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

make_icon() {
  local size="$1"
  local filename="$2"
  sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Generated $OUTPUT"
