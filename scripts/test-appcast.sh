#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
tools="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -d 'dist/Picker.app' ]] || { echo 'Run scripts/package.sh --unsigned first.' >&2; exit 1; }
fixture="$(mktemp -d "$PWD/dist/update-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/archives"
# Generated signing keys and copies of our own build only. No installed app,
# production signing key, network feed, or user storage is changed.
swift - "$fixture" <<'SWIFT'
import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public.txt"), atomically: true, encoding: .utf8)
let other = Curve25519.Signing.PrivateKey()
try other.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("wrong-public.txt"), atomically: true, encoding: .utf8)
SWIFT
ditto 'dist/Picker.app' "$fixture/Picker.app"
plist="$fixture/Picker.app/Contents/Info.plist"
key="$(cat "$fixture/public.txt")"
version="$(cat VERSION)"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Picker' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.local.Picker.UpdateFixture' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 777' "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $key" "$plist"
/usr/libexec/PlistBuddy -c 'Set :SUFeedURL https://github.com/torbensko/picker/releases/latest/download/appcast.xml' "$plist"
/usr/libexec/PlistBuddy -c 'Set :SURequireSignedFeed true' "$plist"
/usr/libexec/PlistBuddy -c 'Set :SUVerifyUpdateBeforeExtraction true' "$plist"
codesign --force --sign - "$fixture/Picker.app"
ditto -c -k --keepParent "$fixture/Picker.app" "$fixture/archives/Picker.zip"
cp RELEASE_NOTES.md "$fixture/archives/Picker.md"
"$tools/generate_appcast" --ed-key-file "$fixture/private.txt" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/torbensko/picker/releases/download/v$version/" "$fixture/archives"
feed="$fixture/archives/appcast.xml"
archive="$fixture/archives/Picker.zip"
"$tools/sign_update" --verify --ed-key-file "$fixture/private.txt" "$feed"
swift scripts/verify-appcast.swift "$feed" "$archive" "$fixture/public.txt" "$version" 777
if swift scripts/verify-appcast.swift "$feed" "$archive" "$fixture/wrong-public.txt" "$version" 777; then
    echo 'Wrong signing key was accepted.' >&2; exit 1
fi
cp "$archive" "$fixture/tampered.zip"
printf 'tampered' >> "$fixture/tampered.zip"
if swift scripts/verify-appcast.swift "$feed" "$fixture/tampered.zip" "$fixture/public.txt" "$version" 777; then
    echo 'Tampered archive was accepted.' >&2; exit 1
fi
cp "$feed" "$fixture/tampered.xml"
python3 - "$fixture/tampered.xml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert '/releases/download/v' in text
path.write_text(text.replace('/releases/download/v', '/releases/download/tampered-v', 1))
PY
if "$tools/sign_update" --verify --ed-key-file "$fixture/private.txt" "$fixture/tampered.xml"; then
    echo 'Tampered feed was accepted.' >&2; exit 1
fi
echo 'Update packaging checks passed: valid signatures accepted; wrong keys and modified archives/feeds rejected.'
