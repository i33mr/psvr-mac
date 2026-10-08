#!/bin/bash
# Builds "PSVR Player.app" and installs it (default: /Applications).
# Usage: scripts/build-app.sh [install folder]
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL_DIR="${1:-/Applications}"
APP="build/PSVR Player.app"

swift build -c release --product PSVRPlayerApp
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PSVRPlayerApp "$APP/Contents/MacOS/PSVR Player"

# Icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>PSVR Player</string>
    <key>CFBundleDisplayName</key>          <string>PSVR Player</string>
    <key>CFBundleIdentifier</key>           <string>local.psvr-mac.player</string>
    <key>CFBundleExecutable</key>           <string>PSVR Player</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>Video</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>LSHandlerRank</key>        <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>com.apple.m4v-video</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Local (ad-hoc) signature so macOS treats it as one consistent app.
codesign --force --deep --sign - "$APP"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/PSVR Player.app"
cp -R "$APP" "$INSTALL_DIR/"
# Tell Launch Services about it (Open With menu, Spotlight).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/PSVR Player.app"
echo "installed: $INSTALL_DIR/PSVR Player.app"
