#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?Pass a notarized ConfigSSH.app path}"
if [[ ! -d "$app_path" || ! -f "$app_path/Contents/Info.plist" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 2
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
if [[ "$bundle_id" != "cn.wuewa.configssh" ]]; then
  echo "Unexpected Bundle ID: $bundle_id" >&2
  exit 2
fi
if [[ ! -f "$app_path/Contents/Resources/LICENSE.txt" ]]; then
  echo "MIT license is missing from the app bundle." >&2
  exit 2
fi
signing_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
  echo "Not signed with Developer ID Application; refuse public release." >&2
  exit 2
fi
codesign --verify --deep --strict "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"
echo "Release package checks passed: $app_path"
