#!/usr/bin/env bash
set -euo pipefail

: "${CONFIGSSH_NOTARY_PROFILE:?Set CONFIGSSH_NOTARY_PROFILE to a notarytool keychain profile}"
app_path="${1:?Pass the signed ConfigSSH.app path}"
if [[ ! -d "$app_path" ]]; then
  echo "App bundle does not exist: $app_path" >&2
  exit 2
fi

signing_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
  echo "Notarization requires a Developer ID Application signature; local/ad-hoc packages are not release artifacts." >&2
  exit 2
fi
codesign --verify --deep --strict "$app_path"
temporary_dir="$(mktemp -d -t configssh-notary)"
archive="$temporary_dir/ConfigSSH.zip"
trap 'if [[ -e "$archive" ]]; then rm "$archive"; fi; rmdir "$temporary_dir"' EXIT
ditto -c -k --keepParent "$app_path" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$CONFIGSSH_NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
