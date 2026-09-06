#!/usr/bin/env bash
# Build PowerFlow and assemble it into a menu-bar .app bundle.
#
#   ./build.sh            build + bundle into ./build/PowerFlow.app
#   ./build.sh install    also copy into ~/Applications and relaunch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PowerFlow"
BUNDLE_ID="com.dylan.powerflow"
VERSION="1.0"
OUT="build/${APP_NAME}.app"

echo "==> compiling"
swift build -c release

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/${APP_NAME}" "$OUT/Contents/MacOS/${APP_NAME}"

if command -v python3 >/dev/null && python3 -c "import PIL" 2>/dev/null; then
  python3 scripts/make-icon.py "$OUT/Contents/Resources/AppIcon.icns" >/dev/null
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu-bar only: no Dock tile, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Reads battery telemetry locally; makes no network connections.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT" 2>/dev/null || echo "    (ad-hoc signing skipped)"
echo "==> built $OUT"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/${APP_NAME}.app"
  echo "==> installing to $DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  cp -R "$OUT" "$DEST"
  open "$DEST"
  echo "==> ${APP_NAME} is running in the menu bar"
fi
