#!/bin/bash
#
# Regenerates every application icon asset from the single programmatic definition in
# Tools/GenerateAppIcon.swift.
#
# Produces:
#   YTDLPGUI/Assets.xcassets/AppIcon.appiconset/*.png + Contents.json
#   Icon/AppIcon.svg      vector master
#   Icon/AppIcon.icns     optional, for DMG backgrounds and documentation
#
# Requires only Xcode's Swift toolchain. Run from anywhere.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "Generating icon assets…"
swift Tools/GenerateAppIcon.swift

ICONSET_SOURCE="YTDLPGUI/Assets.xcassets/AppIcon.appiconset"
STAGING="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$STAGING"

# iconutil expects its own strict naming, which differs from the asset catalogue's.
for spec in "16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2"; do
    read -r size scale <<< "$spec"
    if [ "$scale" = "2" ]; then
        source_name="icon_${size}x${size}@2x.png"
        target_name="icon_${size}x${size}@2x.png"
    else
        source_name="icon_${size}x${size}.png"
        target_name="icon_${size}x${size}.png"
    fi
    cp "$ICONSET_SOURCE/$source_name" "$STAGING/$target_name"
done

mkdir -p Icon
if iconutil --convert icns "$STAGING" --output Icon/AppIcon.icns 2>/dev/null; then
    echo "Wrote Icon/AppIcon.icns"
else
    echo "note: iconutil could not build the .icns; the asset catalogue is still complete." >&2
fi

rm -rf "$(dirname "$STAGING")"
echo "Done."
