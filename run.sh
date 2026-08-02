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

# App icon = the wallpaper art, squircle-masked. Cached in the scratch dir and
# only rebuilt when the art or the renderer changes.
ICON_SRC=assets/wallpaper.jpg
ICNS="$SCRATCH/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    if [[ ! -f "$ICNS" || "$ICON_SRC" -nt "$ICNS" || tools/make-icon.swift -nt "$ICNS" ]]; then
        PNG="$SCRATCH/AppIcon-1024.png"
        swift tools/make-icon.swift "$ICON_SRC" "$PNG"
        ISET="$SCRATCH/AppIcon.iconset"
        rm -rf "$ISET"; mkdir -p "$ISET"
        for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                    "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                    "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
            px=${spec%% *}; name=${spec##* }
            sips -z "$px" "$px" "$PNG" --out "$ISET/$name.png" >/dev/null
        done
        iconutil -c icns "$ISET" -o "$ICNS"
    fi
    mkdir -p "$APP/Contents/Resources"
    cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>CNVS listens when you toggle voice control (⌥Space).</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>CNVS transcribes voice commands on-device to route them.</string>
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

# A stable, TRUSTED identity, not ad-hoc (-). Ad-hoc gets a fresh signature
# every rebuild, which invalidates TCC grants (Accessibility etc.) each
# build. A self-signed cert ("CNVS Dev") isn't enough either: its chain is
# untrusted, so tccd's re-validation fails and grants flap on/off. The
# Apple Development cert from Xcode has a trusted chain and survives
# rebuilds — grants stick until the cert's yearly renewal.
APPLE_DEV_ID="585FDA2852D267963ADCAFA70A7A441896FE9836" # Apple Development: Harrison Oarton (Q953L6W3ZZ)
codesign --force -s "$APPLE_DEV_ID" "$APP" 2>/dev/null || codesign --force -s - "$APP" 2>/dev/null || true

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
