#!/bin/bash
# Export the committed artwork to the standard macOS icon sizes.
set -euo pipefail
cd "$(dirname "$0")/.."
iconset=Picker/Assets.xcassets/AppIcon.appiconset
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        sips -z "$pixels" "$pixels" Brand/Picker.png \
            --out "$iconset/icon_${size}x${size}@${scale}x.png" >/dev/null
    done
done
