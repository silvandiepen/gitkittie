#!/bin/bash
# Generate iOS app icons with a DEV ribbon overlay for debug builds.
# Requires ImageMagick: brew install imagemagick

set -e

ASSETS_DIR="$(dirname "$0")/../GitKanban/Assets.xcassets"
SRC_ICONSET="$ASSETS_DIR/AppIcon.appiconset"
DEV_ICONSET="$ASSETS_DIR/AppIconDev.appiconset"

# Create the dev iconset directory
mkdir -p "$DEV_ICONSET"

# Copy the Contents.json
cp "$SRC_ICONSET/Contents.json" "$DEV_ICONSET/Contents.json"

# Find all PNG files and process them
for png in "$SRC_ICONSET"/*.png; do
    [ -e "$png" ] || continue
    filename=$(basename "$png")
    size=$(magick identify -format "%w" "$png")

    # A corner ribbon: a diagonal band across the top-right corner with "DEV" along it.
    # The band runs from the top edge to the right edge, far enough from the corner that
    # iOS's rounded mask does not cut into the text.
    top_near=$((size * 34 / 100))    # where the band's inner edge meets the top
    top_far=$((size * 62 / 100))     # where its outer edge meets the top
    right_near=$((size * 38 / 100))  # outer edge on the right side
    right_far=$((size * 66 / 100))   # inner edge on the right side
    font_size=$((size * 13 / 100))
    # The band's centre, as an offset from the icon's centre.
    offset=$((size * 235 / 1000))

    magick "$png" \
        -fill '#000000D9' \
        -draw "polygon ${top_near},0 ${top_far},0 ${size},${right_near} ${size},${right_far}" \
        -gravity center \
        -font Helvetica-Bold \
        -pointsize "$font_size" \
        -kerning $((size / 100)) \
        -fill white \
        -annotate 45x45+${offset}-${offset} "DEV" \
        "$DEV_ICONSET/$filename"

    echo "Generated: $filename"
done

echo "Done! AppIconDev.appiconset created."
