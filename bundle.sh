#!/bin/zsh
# Builds a release binary and wraps it in Punchlist.app.
#
# Optional environment:
#   VERSION        marketing version, e.g. 0.1.0 (default 0.0.0 for local builds)
#   BUILD_NUMBER   build number (default: the number of commits)
#   SIGN_IDENTITY  codesigning identity (default "-", ad-hoc); anything else also enables
#                  the hardened runtime and a secure timestamp, which notarization requires
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Punchlist"
APP="build/Punchlist.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Punchlist"

# Compiles the Icon Composer file into Assets.car (Liquid Glass) plus an .icns fallback.
# actool resolves relative paths against the PWD in its environment, which can be stale,
# so it gets absolute ones; its output is only shown when it fails.
ROOT="$(pwd -P)"
if ! ICON_LOG=$(xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$ROOT/build/icon-partial.plist" \
    --output-format human-readable-text 2>&1); then
    print -r -- "$ICON_LOG" >&2
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Francesco Papagno. GPL-3.0-or-later.</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
