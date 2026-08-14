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
    size=$(identify -format "%w" "$png")

    # Calculate ribbon dimensions based on icon size
    ribbon_height=$((size / 4))
    font_size=$((size / 8))

    # Create ribbon overlay and composite
    convert "$png" \
        -gravity NorthEast \
        \( -size ${size}x${ribbon_height} xc:none \
           -fill '#000000CC' \
           -draw "polygon 0,0 ${size},0 ${size},${ribbon_height} $((ribbon_height)),${ribbon_height}" \
           -gravity center \
           -font Helvetica-Bold \
           -pointsize $font_size \
           -fill white \
           -annotate +$((size/8))-$((ribbon_height/6)) "DEV" \
        \) \
        -composite \
        "$DEV_ICONSET/$filename"

    echo "Generated: $filename"
done

echo "Done! AppIconDev.appiconset created."
