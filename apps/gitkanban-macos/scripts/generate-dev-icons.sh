#!/bin/bash
# Generate dev app icons with a "DEV" ribbon overlay
# Requires: ImageMagick (brew install imagemagick)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="$SCRIPT_DIR/../GitKanban/Assets.xcassets/AppIcon.appiconset"
DEV_DIR="$SCRIPT_DIR/../GitKanban/Assets.xcassets/AppIconDev.appiconset"

SIZES=(16 32 64 128 256 512 1024)

for size in "${SIZES[@]}"; do
    input="$ICON_DIR/app-icon-$size.png"
    output="$DEV_DIR/app-icon-dev-$size.png"

    if [ ! -f "$input" ]; then
        echo "Skipping $size (source not found)"
        continue
    fi

    # Calculate ribbon size relative to icon
    ribbon_height=$((size / 5))
    font_size=$((size / 8))
    if [ $font_size -lt 6 ]; then font_size=6; fi

    # Create the icon with a diagonal "DEV" ribbon in top-right corner
    magick "$input" \
        -gravity NorthEast \
        \( -size ${size}x${size} xc:none \
           -fill '#000000CC' \
           -draw "polygon 0,0 ${size},0 ${size},$((size/3)) $((size*2/3)),0" \
           -fill white \
           -font Helvetica-Bold \
           -pointsize $font_size \
           -gravity NorthEast \
           -annotate +$((size/12))+$((size/15)) "DEV" \
        \) \
        -composite \
        "$output"

    echo "Generated $output"
done

echo "Done! Dev icons generated in $DEV_DIR"
