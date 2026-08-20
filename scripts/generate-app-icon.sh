#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Brand/BardoAppIcon.png"
OUTPUT="$ROOT/Bardo/Resources/BardoAppIcon.icns"
WORKDIR="$(mktemp -d)"
ICONSET="$WORKDIR/BardoAppIcon.iconset"
NORMALIZED_SOURCE="$WORKDIR/BardoAppIcon.png"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing app icon source: $SOURCE" >&2
  exit 1
fi

# GitHub connector uploads may preserve binary artwork as its base64 text.
# Normalize either representation back to the exact PNG bytes before using sips.
if [[ "$(xxd -p -l 8 "$SOURCE")" == "89504e470d0a1a0a" ]]; then
  cp "$SOURCE" "$NORMALIZED_SOURCE"
else
  /usr/bin/base64 -D < "$SOURCE" > "$NORMALIZED_SOURCE"
fi

if [[ "$(xxd -p -l 8 "$NORMALIZED_SOURCE")" != "89504e470d0a1a0a" ]]; then
  echo "Bardo app icon source did not decode to a PNG." >&2
  exit 1
fi

sips -g pixelWidth -g pixelHeight "$NORMALIZED_SOURCE" >/dev/null
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

make_icon() {
  local size="$1"
  local filename="$2"
  sips -s format png -z "$size" "$size" "$NORMALIZED_SOURCE" --out "$ICONSET/$filename" >/dev/null
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
