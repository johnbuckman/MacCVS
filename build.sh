#!/bin/bash
# Build MacCVS as a universal (arm64 + x86_64) .app bundle and install it.
set -e
cd "$(dirname "$0")"

APP_NAME="MacCVS"
BUNDLE_ID="com.johnbuckman.maccvs"
VERSION="0.7.0"
SHORT_VERSION="0.7-alpha"
DEST="/Applications/AI Apps"

echo "== Building universal release =="
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/$APP_NAME"
[ -f "$BIN" ] || BIN=".build/release/$APP_NAME"   # fallback: single-arch

APP="$APP_NAME.app"
echo "== Assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
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

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "== Installing to $DEST =="
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"

echo "Done: $DEST/$APP"
