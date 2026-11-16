#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="${CONFIGSSH_BUNDLE_ID:-cn.wuewa.configssh}"
app_version="${CONFIGSSH_VERSION:-0.1.0}"
app_output="${CONFIGSSH_APP_OUTPUT:-$repo_root/dist/ConfigSSH.app}"

if [[ ! "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]]; then
  echo "Invalid CONFIGSSH_BUNDLE_ID" >&2
  exit 2
fi
if [[ ! "$app_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid CONFIGSSH_VERSION" >&2
  exit 2
fi
if [[ -e "$app_output" ]]; then
  echo "Output already exists: $app_output" >&2
  exit 2
fi

cd "$repo_root"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$(dirname "$app_output")" "$app_output/Contents/MacOS" "$app_output/Contents/Resources"
cp "$binary_dir/ConfigSSH" "$app_output/Contents/MacOS/ConfigSSH"
cp "$repo_root/Assets/ConfigSSH.icns" "$app_output/Contents/Resources/ConfigSSH.icns"
cp "$repo_root/LICENSE" "$app_output/Contents/Resources/LICENSE.txt"
cp -R "$binary_dir/ConfigSSH_ConfigSSH.bundle" "$app_output/Contents/Resources/ConfigSSH_ConfigSSH.bundle"
chmod 755 "$app_output/Contents/MacOS/ConfigSSH"

cat > "$app_output/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ConfigSSH</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>ConfigSSH</string>
    <key>CFBundleDisplayName</key><string>ConfigSSH</string>
    <key>CFBundleIconFile</key><string>ConfigSSH.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$app_version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key><string>ConfigSSH uses automation to open SSH sessions in the terminal apps you choose.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

plutil -lint "$app_output/Contents/Info.plist"
if [[ -n "${CONFIGSSH_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$repo_root/ConfigSSH.entitlements" \
    --sign "$CONFIGSSH_SIGNING_IDENTITY" "$app_output"
  codesign --verify --deep --strict "$app_output"
  signing_details="$(codesign -dv --verbose=4 "$app_output" 2>&1)"
  if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
    echo "Direct-download release requires a Developer ID Application certificate." >&2
    # This run created $app_output (it refuses existing output), so remove the rejected bundle.
    rm -rf -- "$app_output"
    exit 2
  fi
else
  echo "No Developer ID signing identity supplied; this app is for local validation only." >&2
fi
echo "$app_output"
