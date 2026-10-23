# Releasing Picker

Picker uses Sparkle 2 for updates and GitHub Releases for immutable downloads. The website at `torbensko.com/software/picker/` links to the latest DMG. No separate server or feed upload is needed: Sparkle reads `https://github.com/torbensko/picker/releases/latest/download/appcast.xml`.

## GitHub setup

In [Actions secrets](https://github.com/torbensko/picker/settings/secrets/actions), use the same names as Reclaim:

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate **including its private key** |
| `CERTIFICATE_PASSWORD` | Password for the exported P12 |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for that account |
| `APPLE_TEAM_ID` | Developer team ID |
| `SPARKLE_PRIVATE_KEY` | Picker's own update-signing key; configured by `scripts/configure-updates.sh` |

The `MACOS_RUNNER` repository variable is optional and defaults to `xcode-27`, matching Reclaim. A replacement runner needs Xcode 26+ and support for building both Apple Silicon and Intel. The normal CI workflow needs no signing secrets.

The public Sparkle key is committed in `Config/Updates.xcconfig`. The private key is backed up in your login Keychain under account `com.local.Picker`; never commit it, paste it into logs, or silently generate a replacement after shipping. To re-upload the existing key to GitHub:

```sh
xcodebuild -resolvePackageDependencies -project Picker.xcodeproj -scheme Picker -derivedDataPath build
./scripts/configure-updates.sh
```

The helper refuses a mismatched key. Keep a secure backup of the Keychain item; losing the signing key requires a deliberate Sparkle key migration.

## Publish

1. Update `VERSION` and `RELEASE_NOTES.md`, commit and push to `main`. The packaging script overrides the project version from `VERSION`; the build number comes from the release workflow's increasing run number.
2. Wait for **Test and package** to pass. Its unsigned DMG/ZIP are development artifacts with updates disabled, not website downloads.
3. Run **Build and release** manually from [Actions](https://github.com/torbensko/picker/actions/workflows/release.yml) on `main`.

The release workflow tests, archives a universal app, exports it with Developer ID signing (including Sparkle's helpers), notarizes and staples the app and DMG, and signs the ZIP and appcast with Ed25519. It verifies the archive signature against the key actually embedded in the app, then creates a draft release containing all assets before publishing it. Failed signing, notarization or verification prevents publication. Existing tags/releases are never overwritten.

Downloads are `Picker.dmg`, `Picker.zip`, `appcast.xml` and `SHA256SUMS.txt`. The appcast points to a versioned ZIP URL; website downloads use `/releases/latest/download/Picker.dmg` so later releases need no website edits. The prepared website PR should be merged once the first signed release exists.

## Local checks

```sh
xcodebuild -project Picker.xcodeproj -scheme Picker -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build test CODE_SIGN_IDENTITY=-
./scripts/package.sh --unsigned
./scripts/test-appcast.sh
```

The packaging check generates disposable signing keys and verifies that wrong keys, tampered archives and modified feeds are rejected. It never installs an update or changes your Photos library.

Before the first public release, install a notarized build into Applications and check **Picker → Check for Updates…**. For an end-to-end installation check, test an older signed build against a newer signed release in a disposable account/library. Local unsigned tests cannot validate Developer ID notarization or the complete sandboxed installation/relaunch path.

## Update behavior

Sparkle asks permission for automatic checks and supplies its standard update window. Automatic downloads start off; users can opt in through Sparkle. The Picker menu exposes manual checks and the automatic-check preference. Development builds never start the updater.

The existing bundle identifier remains `com.local.Picker` to preserve the sandbox's analysis cache and review choices. The first Developer ID installation may require Photos access again because its signing identity differs from the local development build.

Sparkle uses its downloader XPC service; the main app does not gain a general network entitlement. PhotoKit analysis and previews retain their existing download rules. Restarting for an update is deferred while scanning, preparing/deleting photos, showing a deletion confirmation, or using the screenshot sheet. Decisions are saved when made and analysis checkpoints remain local.
