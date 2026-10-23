#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SPARKLE_PRIVATE_KEY:?Missing SPARKLE_PRIVATE_KEY for update signing}"
version="$(cat VERSION)"
plist="$PWD/dist/Picker.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PickerUpdateChannel' "$plist")" == Release ]]
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
tools="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
stage="$(mktemp -d "$PWD/dist/appcast.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp dist/Picker.zip "$stage/Picker.zip"
cp RELEASE_NOTES.md "$stage/Picker.md"
# Immutable archive URLs keep an installed app's update check consistent when /latest advances.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/torbensko/picker/releases/download/v$version/" \
    --embed-release-notes --maximum-deltas 0 --link https://torbensko.com/software/picker/ "$stage"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$stage/appcast.xml"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" > "$stage/public-key.txt"
swift scripts/verify-appcast.swift "$stage/appcast.xml" "$stage/Picker.zip" "$stage/public-key.txt" "$version" "$build_number"
cp "$stage/appcast.xml" dist/appcast.xml
(cd dist && shasum -a 256 Picker.dmg Picker.zip appcast.xml > SHA256SUMS.txt)
echo 'Generated and verified the signed release update feed.'
