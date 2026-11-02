#!/bin/zsh
# Draws the website's favicons and app icons from Bardo/Resources/AppIcon.icon, rendered by
# Icon Composer on the icon's dark plum fill, the one the dark website sits on.
# Run capas_icono.py first. Needs Xcode (ictool) and ImageMagick.
#
#     zsh design/mascota/image-v2/iconos_web.sh
set -euo pipefail
ROOT=${0:A:h:h:h:h}
ICON=$ROOT/Bardo/Resources/AppIcon.icon
WEB=$ROOT/web/public
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
PLUM='rgb(45,29,67)'
TMP=$(mktemp -d)
trap 'rm -rf -- "${TMP:?}"' EXIT

# Icon Composer's Default rendition with the dark fill as the only fill.
cp -R $ICON $TMP/web.icon
sed -i '' 's#srgb:0.97647,0.96471,0.99216,1.00000#srgb:0.17647,0.11373,0.26275,1.00000#' $TMP/web.icon/icon.json
"$ICTOOL" $TMP/web.icon --export-image --output-file $TMP/icon.png --platform macOS \
  --rendition Default --width 1024 --height 1024 --scale 1 > /dev/null

squircle() { magick $TMP/icon.png -filter Lanczos -resize ${1}x${1} -depth 8 -strip -quality 92 "$2"; }
squircle 512 $WEB/icon-512.png
squircle 192 $WEB/icon-192.png
squircle 96 $WEB/favicon-96.png
squircle 320 $WEB/assets/marca/icono-bardo.webp
squircle 128 $WEB/assets/marca/icono-bardo-128.webp
magick $TMP/icon.png \( -clone 0 -resize 48x48 \) \( -clone 0 -resize 32x32 \) \( -clone 0 -resize 16x16 \) \
  -delete 0 -define icon:format=png $WEB/favicon.ico

# Full squares, for systems that round the corners themselves.
flat() { # size, head share, output
  magick $ICON/Assets/cara.png $ICON/Assets/boina.png -composite -resize $(( 1024 * $2 / 80 ))x \
    -background "$PLUM" -gravity center -extent 1024x1024 -flatten -filter Lanczos -resize ${1}x${1} -depth 8 -strip "$3"
}
flat 180 80 $WEB/apple-touch-icon.png
flat 512 64 $WEB/maskable-512.png
