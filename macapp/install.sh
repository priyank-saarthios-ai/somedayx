#!/bin/bash
# Build SomedayX (search everything you've saved on X, from the menu bar),
# install it to ~/Applications and open it. The app owns every permission it
# needs (notifications, login item, Accessibility for double-tap ⌥).
#
#   macapp/install.sh              # check requirements, build, install, open
#   macapp/install.sh --uninstall  # quit and remove the app (keeps your data)
#
# Your data lives in ~/Library/Application Support/SomedayX, never in this folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/SomedayX.app"
BUNDLE_ID="com.somedayx.app"
DATA="$HOME/Library/Application Support/SomedayX"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
need() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

stop() {
  # This app, and the names it had before (Stash, Saved Tweets).
  for id in "$BUNDLE_ID" com.xsearch.stash com.xsearch.savedtweets; do
    osascript -e "tell application id \"$id\" to quit" 2>/dev/null || true
  done
  for label in com.xsearch.menubar com.xsearch.sync; do  # launch agents from the first versions
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
  sleep 1
  pkill -f "SomedayX.app/Contents/MacOS/SomedayX" 2>/dev/null || true
  pkill -f "Stash.app/Contents/MacOS/Stash" 2>/dev/null || true
  rm -rf "$HOME/Applications/Stash.app" "$HOME/Applications/Saved Tweets.app"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop
  rm -rf "$APP"
  say "Uninstalled. Your data is still in: $DATA"
  echo "To delete it too (your saves, models and the logged-in X session): rm -rf \"$DATA\""
  echo "If SomedayX still shows in System Settings → General → Login Items, remove it there."
  exit 0
fi

# ---------- requirements ----------
say "Checking requirements…"
macos="$(sw_vers -productVersion)"
[[ "${macos%%.*}" -ge 14 ]] || need "macOS 14 or newer is needed (this Mac has $macos)."
[[ "$(uname -m)" == "arm64" ]] || echo "! This Mac has an Intel chip: SomedayX works, but Gemma will be slow."
command -v swiftc >/dev/null || need "Xcode Command Line Tools are needed: run  xcode-select --install  then try again."
if ! command -v brew >/dev/null && { ! command -v uv >/dev/null || ! command -v llama-server >/dev/null; }; then
  need "Homebrew is needed to install uv and llama.cpp: https://brew.sh"
fi
command -v uv >/dev/null || { say "Installing uv (runs the Python side)…"; brew install uv; }
command -v llama-server >/dev/null || { say "Installing llama.cpp (runs Gemma on this Mac)…"; brew install llama.cpp; }
UV="$(command -v uv)"

say "Setting up Python…"
(cd "$ROOT" && "$UV" sync --quiet)
if [[ ! -d "/Applications/Google Chrome.app" ]]; then
  say "Google Chrome isn't installed; downloading Chromium for syncing with X…"
  (cd "$ROOT" && "$UV" run playwright install chromium)
fi

# ---------- build ----------
say "Building…"
BUILD="$ROOT/macapp/build"
mkdir -p "$BUILD" "$HOME/Applications"
swiftc -O -o "$BUILD/SomedayX" "$ROOT/macapp/SomedayX.swift"
swiftc -O -o "$BUILD/somedayx-ocr" "$ROOT/macapp/somedayx-ocr.swift"  # reads text in images (Apple Vision)
rm -rf "$BUILD/SomedayX.iconset"
swift "$ROOT/macapp/make_icon.swift" "$BUILD/SomedayX.iconset"
iconutil -c icns "$BUILD/SomedayX.iconset" -o "$BUILD/SomedayX.icns"

stop

# From the Stash days: move data out of the code folder, keep app settings.
(cd "$ROOT" && "$UV" run python -c "from somedayx.db import connect; connect()")
if defaults read com.xsearch.stash >/dev/null 2>&1; then
  if ! defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    defaults export com.xsearch.stash - | defaults import "$BUNDLE_ID" -
  fi
  defaults delete com.xsearch.stash  # carried over once; never again
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/SomedayX" "$APP/Contents/MacOS/SomedayX"
cp "$BUILD/SomedayX.icns" "$APP/Contents/Resources/SomedayX.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SomedayX</string>
  <key>CFBundleDisplayName</key><string>SomedayX</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SomedayX</string>
  <key>CFBundleIconFile</key><string>SomedayX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>SDXProjectDir</key><string>$ROOT</string>
  <key>SDXUvPath</key><string>$UV</string>
</dict></plist>
PLIST
# A real signing identity keeps permissions (Accessibility, notifications)
# across rebuilds. Without one, ad-hoc signing works but macOS may ask again
# after each rebuild.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

open "$APP"
say "Installed $APP"
echo "Double-tap ⌥ (or press ⌥⌘X) to search your X saves. The first launch walks you through the rest."
