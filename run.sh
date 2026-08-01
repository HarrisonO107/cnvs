#!/bin/zsh
# Build CNVS and wrap it in a proper .app bundle, then launch.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/CNVS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/CNVS "$APP/Contents/MacOS/CNVS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CNVS</string>
    <key>CFBundleIdentifier</key><string>com.hfjoandco.cnvs</string>
    <key>CFBundleName</key><string>CNVS</string>
    <key>CFBundleDisplayName</key><string>CNVS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true

# First-run wallpaper install (never overwrites the user's choice)
if [[ -f assets/wallpaper.jpg && ! -f "$HOME/Documents/CNVS/wallpaper.jpg" ]]; then
    mkdir -p "$HOME/Documents/CNVS"
    cp assets/wallpaper.jpg "$HOME/Documents/CNVS/wallpaper.jpg"
fi

if [[ "$1" != "--no-launch" ]]; then
    open "$APP"
fi
echo "CNVS.app ready at $APP"
