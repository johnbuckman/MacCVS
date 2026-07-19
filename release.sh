#!/bin/bash
# Build a universal MacCVS.app, Developer ID sign it with a hardened runtime,
# notarize + staple, and produce dist/MacCVS-<version>.zip for a GitHub release.
#
# Env overrides:
#   MACCVS_SIGN_ID        codesign identity (default: Developer ID Application: Vid Tadel (XLS3XF57J8))
#   MACCVS_NOTARY_PROFILE notarytool keychain profile (default: bping-notary)
set -e
cd "$(dirname "$0")"

APP_NAME="MacCVS"
BUNDLE_ID="com.johnbuckman.maccvs"
VERSION="0.2.0"
SHORT_VERSION="0.2-alpha"
ID="${MACCVS_SIGN_ID:-Developer ID Application: Vid Tadel (XLS3XF57J8)}"
NOTARY_PROFILE="${MACCVS_NOTARY_PROFILE:-bping-notary}"

security find-identity -v -p codesigning 2>/dev/null | grep -q "$ID" || {
    echo "Signing identity not found: $ID"; exit 1; }

echo "==> Building universal release"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/$APP_NAME"

APP="dist/$APP_NAME.app"
rm -rf dist; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp bin/cvs "$APP/Contents/Resources/cvs"          # bundled universal cvs
chmod +x "$APP/Contents/Resources/cvs"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Codesigning (Developer ID, hardened runtime, timestamp)"
xattr -cr "$APP"
# Nested executables first (the bundled cvs), then the main binary, then the app.
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/Resources/cvs"
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --timestamp --sign "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="dist/$APP_NAME-$SHORT_VERSION.zip"
echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $ZIP"
