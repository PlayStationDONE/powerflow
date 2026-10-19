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

# SwiftUI in the macOS 27 SDK expands @State through a macro plugin that ships
# with Xcode, not with the Command Line Tools. When only the Command Line Tools
# are installed, the default build can fail with "plugin for module
# 'SwiftUIMacros' not found". Set POWERFLOW_SDK to an older installed SDK to
# build anyway; this script retries with the newest macOS 26.x SDK it finds.
CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
build() {
  if [[ -n "${POWERFLOW_SDK:-}" ]]; then
    swift build -c release --sdk "$POWERFLOW_SDK"
  else
    swift build -c release
  fi
}
echo "==> compiling"
LOG="$(mktemp -t powerflow-build)"
trap 'rm -f "$LOG"' EXIT
if build >"$LOG" 2>&1; then
  tail -n 3 "$LOG"
else
  if [[ -z "${POWERFLOW_SDK:-}" ]]; then
    echo "==> default SDK build failed (first errors below)"
    grep -m 3 'error:' "$LOG" | cut -c1-200 || true
    FALLBACK="$(ls -d "$CLT_SDKS"/MacOSX26*.sdk 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -n "$FALLBACK" ]]; then
      echo "==> retrying with $FALLBACK"
      POWERFLOW_SDK="$FALLBACK" build 2>&1 | tail -n 3
      [[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
    else
      exit 1
    fi
  else
    tail -n 30 "$LOG"; exit 1
  fi
fi

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/${APP_NAME}" "$OUT/Contents/MacOS/${APP_NAME}"

# Menu-bar glyph (template image, 52x36 px shown at 26x18 pt).
cp Resources/MenuBarIcon@2x.png "$OUT/Contents/Resources/MenuBarIcon.png"

# Prefer the committed icon; fall back to the generated one if it is missing.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
elif command -v python3 >/dev/null && python3 -c "import PIL" 2>/dev/null; then
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
    <!-- A regular app (Dock tile and window). The app switches itself to
         menu-bar-only at run time when "Show in Dock" is turned off. -->
    <key>LSUIElement</key><false/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Reads power telemetry locally; stores history only on this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime. There are no entitlements: the
# app is not sandboxed and asks for no special permissions.
codesign --force --sign - --options runtime "$OUT"
codesign --verify --strict "$OUT"
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
