#!/bin/bash
# Configure this app's own update key without ever printing the private half.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
tool="$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
[[ -x "$tool" ]] || { echo 'Resolve the Xcode project packages first (see RELEASE.md).' >&2; exit 1; }
account=com.local.Picker
config=Config/Updates.xcconfig
committed="$(sed -n 's/^SPARKLE_PUBLIC_KEY = *//p' "$config")"
if [[ -n "$committed" ]]; then
    public_key="$("$tool" --account "$account" -p)"
    [[ "$public_key" == "$committed" ]] || { echo 'Key mismatch. Recover the original key; never rotate a published key implicitly.' >&2; exit 1; }
else
    "$tool" --account "$account" > /dev/null
    public_key="$("$tool" --account "$account" -p)"
    printf '// Public verification key. Keep the private key in Keychain and GitHub Secrets.\nSPARKLE_PUBLIC_KEY = %s\n' "$public_key" > "$config"
fi
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/picker-update-key.XXXXXX")"
trap 'rm -rf "$secret_dir"' EXIT
"$tool" --account "$account" -x "$secret_dir/key" > /dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo torbensko/picker < "$secret_dir/key"
echo 'Picker update signing configured. The original private key remains in your login Keychain.'
