#!/bin/bash
#
# Usage: Tools/generate-app-icon.sh [--help]
#
# Regenerates every application icon asset from the single programmatic definition in
# Tools/GenerateAppIcon.swift.
#
# macOS:
#   YTDLPGUI/Assets.xcassets/AppIcon.appiconset/*.png + Contents.json
#   Icon/AppIcon.svg      vector master
#   Icon/AppIcon.icns     optional, for DMG backgrounds and documentation
#
# iOS:
#   YTDLPGUI-iOS/Assets.xcassets/AppIcon.appiconset/*.png + Contents.json
#                         one full-bleed 1024px icon each for the light, dark and tinted
#                         Home Screen appearances
#   YTDLPGUI-iOS/Assets.xcassets/AccentColor.colorset/Contents.json
#                         the app's accent colour, taken from the icon's palette
#
# Requires only Xcode's Swift toolchain. Run from anywhere.

set -euo pipefail

usage() {
    # The header comment above doubles as the help text.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 64 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "Generating icon assets…"
swift Tools/GenerateAppIcon.swift

# App Store Connect rejects an iOS icon with an alpha channel, but only at upload time, long
# after the change that caused it. Catch it here instead.
IOS_ICON="YTDLPGUI-iOS/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
if ! sips -g hasAlpha "$IOS_ICON" | grep -q "hasAlpha: no"; then
    echo "error: $IOS_ICON has an alpha channel; the App Store will reject it." >&2
    exit 1
fi

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
