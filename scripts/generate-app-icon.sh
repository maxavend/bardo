#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT/Brand/BardoAppIcon.base64"
OUTPUT="$ROOT/Bardo/Resources/BardoAppIcon.icns"
WORKDIR="$(mktemp -d)"
ICONSET="$WORKDIR/BardoAppIcon.iconset"
SOURCE="$WORKDIR/BardoAppIcon.png"
EXPECTED_SHA256="c8b68428b6fb55d06f7a5986d51dd8e23e6c7327adf329c92013b1e9b88e38ad"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

for part in part-00 part-01 part-02 part-03; do
  if [[ ! -s "$SOURCE_DIR/$part" ]]; then
    echo "Missing app icon source fragment: $SOURCE_DIR/$part" >&2
    exit 1
  fi
done

cat \
  "$SOURCE_DIR/part-00" \
  "$SOURCE_DIR/part-01" \
  "$SOURCE_DIR/part-02" \
  "$SOURCE_DIR/part-03" \
  | /usr/bin/base64 -D > "$SOURCE"

ACTUAL_SHA256="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Bardo app icon checksum mismatch: $ACTUAL_SHA256" >&2
  exit 1
fi

if [[ "$(xxd -p -l 8 "$SOURCE")" != "89504e470d0a1a0a" ]]; then
  echo "Bardo app icon did not reconstruct to a PNG." >&2
  exit 1
fi

sips -g pixelWidth -g pixelHeight "$SOURCE" >/dev/null
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
echo "Generated $OUTPUT from verified Bardo artwork ($ACTUAL_SHA256)"
