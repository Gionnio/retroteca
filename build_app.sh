#!/bin/bash
# Build Retroteca and create build/Retroteca.app.
# Requirements: Xcode (Swift 5.9+), macOS 14+.
#
# Usage: ./build_app.sh            → build/Retroteca.app
#        ./build_app.sh --install  → also installed in /Applications and opened
#        ./build_app.sh --zip      → also dist/Retroteca_v<version>.zip
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
VERSION="0.1.1"
BUILD_NUMBER="2"
NAME="Retroteca"
BUNDLE_ID="com.github.gionnio.Retroteca"
APP="$BUILD/$NAME.app"

echo "▸ Legal check"
bash "$ROOT/tools/check_legal.sh"

echo "▸ Test"
(cd app && swift test --quiet)

echo "▸ Build"
(cd app && swift build -c release --arch arm64)
BIN_DIR="$(cd app && swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Retroteca" "$APP/Contents/MacOS/Retroteca"
cp -R "$ROOT/app/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$ROOT/catalog/"*.json "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Retroteca</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>it</string>
    <key>CFBundleLocalizations</key><array><string>it</string><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Gionnio. MIT License.</string>
</dict>
</plist>
PLIST

if [ -d "$ROOT/icon/AppIcon.iconset" ]; then
    iconutil -c icns "$ROOT/icon/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Stable signature with the "Gionnio Code Signing" certificate, so macOS keeps permissions across builds;
# ad-hoc when the certificate is missing. No hardened runtime (no Team ID).
SIGN_IDENTITY="${SIGN_IDENTITY:-Gionnio Code Signing}"
if security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    SIGN="$SIGN_IDENTITY"
else
    SIGN="-"
    echo "⚠️  Certificate \"$SIGN_IDENTITY\" not found: ad-hoc signature (macOS will ask for permissions again after each build)."
fi
codesign --force --deep --sign "$SIGN" "$APP"
codesign --force --identifier "$BUNDLE_ID" --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
echo "✅ $APP"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Install in /Applications"
    osascript -e "quit app \"$NAME\"" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
fi

if [ "${1:-}" = "--zip" ]; then
    mkdir -p "$ROOT/dist"
    ZIP_OUT="$ROOT/dist/${NAME}_v$VERSION.zip"
    rm -f "$ZIP_OUT"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_OUT"
    echo "📦 $ZIP_OUT"
    shasum -a 256 "$ZIP_OUT"
fi
