#!/bin/zsh
# Build CNVS and wrap it in a proper .app bundle, then launch.
set -e
cd "$(dirname "$0")"

# Scratch dir OUTSIDE iCloud: this repo lives on the synced Desktop, and iCloud
# evicts .build (8k+ dataless files observed 2026-08-01) — evicted reads block
# and swift-build hangs silently at "Planning build".
SCRATCH="$HOME/work/build/cnvs-build"
mkdir -p "$SCRATCH"
swift build -c release --scratch-path "$SCRATCH"

APP=build/CNVS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$SCRATCH/release/CNVS" "$APP/Contents/MacOS/CNVS"

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
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.hfjoandco.cnvs</string>
            <key>CFBundleURLSchemes</key><array><string>cnvs</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true

# Register the cnvs:// URL scheme with LaunchServices (the build listener opens
# phone terminals with `open cnvs://terminal?session=...`).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

# First-run wallpaper install (never overwrites the user's choice)
if [[ -f assets/wallpaper.jpg && ! -f "$HOME/Documents/CNVS/wallpaper.jpg" ]]; then
    mkdir -p "$HOME/Documents/CNVS"
    cp assets/wallpaper.jpg "$HOME/Documents/CNVS/wallpaper.jpg"
fi

if [[ "$1" != "--no-launch" ]]; then
    open "$APP"
fi
echo "CNVS.app ready at $APP"
