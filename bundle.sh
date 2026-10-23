#!/bin/zsh
# Builds a release binary and wraps it in Punchlist.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Punchlist"
APP="build/Punchlist.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Punchlist"

# Compiles the Icon Composer file into Assets.car (Liquid Glass) plus an .icns fallback.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist build/icon-partial.plist >/dev/null

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Punchlist</string>
    <key>CFBundleDisplayName</key><string>Punchlist</string>
    <key>CFBundleIdentifier</key><string>com.effectivebits.Punchlist</string>
    <key>CFBundleExecutable</key><string>Punchlist</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
