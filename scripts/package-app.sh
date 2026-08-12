#!/bin/bash
# Builds LatCyr as a proper .app bundle with ad-hoc code signature.
# A bundled app gets its own TCC identity, so Accessibility and Input
# Monitoring permissions apply to LatCyr.app itself (not the terminal).
#
# Usage: ./scripts/package-app.sh
# Output: dist/LatCyr.app
#
# Note: re-running this re-signs the bundle, which changes its code hash and
# drops any TCC permissions already granted. Grant permissions to the final
# bundle and do not re-package unless you re-grant.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LatCyr"
DIST="dist/${APP_NAME}.app"

swift build -c release

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS"
mkdir -p "$DIST/Contents/Resources"

cp ".build/release/${APP_NAME}" "$DIST/Contents/MacOS/${APP_NAME}"
cp "Resources/exceptions.txt" "$DIST/Contents/Resources/exceptions.txt"

cat > "$DIST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>LatCyr</string>
    <key>CFBundleDisplayName</key>
    <string>LatCyr</string>
    <key>CFBundleIdentifier</key>
    <string>com.latcyr.app</string>
    <key>CFBundleExecutable</key>
    <string>LatCyr</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$DIST"
echo "Packaged: $DIST"
