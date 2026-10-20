#!/bin/bash
# Builds LatCyr as a proper .app bundle, signed with Developer ID when the
# certificate is in the keychain, ad-hoc otherwise.
# A bundled app gets its own TCC identity, so Accessibility and Input
# Monitoring permissions apply to LatCyr.app itself (not the terminal).
#
# Usage: ./scripts/package-app.sh
# Output: dist/LatCyr.app
#
# Version: CFBundleShortVersionString comes from the VERSION file,
# CFBundleVersion (the build number) from the commit count — it only grows,
# and two builds of different commits never share one.
#
# Architectures: a universal binary (arm64 + x86_64), so the app runs on
# Apple Silicon and Intel Macs.
#
# Signing: SIGN_IDENTITY overrides the identity. By default the script uses
# "Developer ID Application: … (JHWW538CH9)" if it is in the keychain, with the
# hardened runtime and a secure timestamp (both required for notarization).
# A Developer ID signature's designated requirement is the team + bundle ID,
# so TCC permissions survive re-packaging. Without the certificate it falls
# back to an ad-hoc signature, whose requirement is the code hash: then every
# re-package drops the TCC permissions already granted.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="LatCyr"
DIST="dist/${APP_NAME}.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD)"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS"
mkdir -p "$DIST/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "$DIST/Contents/MacOS/${APP_NAME}"
cp "Resources/exceptions.txt" "$DIST/Contents/Resources/exceptions.txt"

cat > "$DIST/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

TEAM_ID="JHWW538CH9"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .* (${TEAM_ID})\)\".*/\1/p" | head -n 1)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DIST"
    SIGNED_WITH="$SIGN_IDENTITY"
else
    echo "package-app: no Developer ID certificate, signing ad-hoc" >&2
    codesign --force --sign - "$DIST"
    SIGNED_WITH="ad-hoc"
fi
codesign --verify --strict "$DIST"
echo "Packaged: $DIST ($VERSION, build $BUILD, $(lipo -archs "$DIST/Contents/MacOS/${APP_NAME}"), $SIGNED_WITH)"
