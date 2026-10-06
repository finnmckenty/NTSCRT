#!/usr/bin/env bash
# Build the crt-app executable and wrap it in a minimal .app bundle so it
# launches as a proper foreground macOS app (window gets focus, dock entry,
# Cmd-Q quits).
#
# Usage: wrap-app.sh [release|debug]   (default: release)
#
# Output: build/NTSCRT.app — drag to /Applications or `open` it directly.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

# Always build: this script used to wrap whatever binary the last build
# left, and stamp it with the current git version — so a stale binary went
# out titled as the new code (2026-10-05: the Screen Loop dots "missing").
swift build -c "$CONFIG" --product crt-app

APP=build/NTSCRT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp ".build/$CONFIG/crt-app" "$APP/Contents/MacOS/NTSCRT"
cp Vendor/librashader/librashader.dylib "$APP/Contents/Frameworks/librashader.dylib"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bundled look presets: whatever is in presets/ at build time shows up in the
# Preset menu, so adding one is just dropping a .json file in there.
if [[ -d presets ]]; then
  mkdir -p "$APP/Contents/Resources/presets"
  cp presets/*.json "$APP/Contents/Resources/presets/" 2>/dev/null || true
  # Screen Loop presets keep their own folder.
  if [[ -d "presets/Screen Loop" ]]; then
    mkdir -p "$APP/Contents/Resources/presets/Screen Loop"
    cp "presets/Screen Loop/"*.json "$APP/Contents/Resources/presets/Screen Loop/" 2>/dev/null || true
  fi
fi
# The shader presets, carried the way the release bundle carries them. A
# copy launched from a release bundle at this path reads its shaders from
# here: without them, rewrapping underneath it broke its next export
# ("preset_create … No such file", 2026-10-05). Launched from this bundle,
# the dev build still prefers CRT_PRESETS below — the live Vendor tree.
mkdir -p "$APP/Contents/Resources/slang-shaders"
cp -R Vendor/slang-shaders/crt Vendor/slang-shaders/include "$APP/Contents/Resources/slang-shaders/"
# Optional VHS stage dylib (the app runs without it).
if [[ -f Vendor/ntscrs-capi/ntscrs_capi.dylib ]]; then
  cp Vendor/ntscrs-capi/ntscrs_capi.dylib "$APP/Contents/Frameworks/ntscrs_capi.dylib"
fi

# Set the rpath so the embedded dylib is found.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/NTSCRT" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>NTSCRT</string>
    <key>CFBundleIdentifier</key>             <string>local.ntscrt</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>NTSCRT</string>
    <key>CFBundleDisplayName</key>            <string>NTSCRT</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>REPLACE_VERSION</string>
    <key>CFBundleVersion</key>                <string>REPLACE_VERSION</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <!-- Tell the app where to find the slang-shaders presets.
         For a real distribution you'd copy them into Resources/ and update Paths.swift. -->
    <key>LSEnvironment</key>
    <dict>
        <key>CRT_PRESETS</key>
        <string>REPLACE_PRESETS_PATH</string>
    </dict>
</dict>
</plist>
PLIST

# Fill in absolute path to the bundled slang-shaders submodule so the .app
# can find them when launched from anywhere (LSEnvironment paths must be absolute).
PRESETS_ABS="$(cd Vendor/slang-shaders && pwd)"
/usr/bin/sed -i '' "s|REPLACE_PRESETS_PATH|$PRESETS_ABS|" "$APP/Contents/Info.plist"

# Stamp the git version so the window title says exactly which code this
# is (e.g. "0.10.1-2-g41a5813-dirty"). A dev bundle that silently reports
# a stale version once cost an afternoon. Release tags only: a rollback tag
# like `pre-glitch` sharing a commit with a release would otherwise win and
# title a new build "pre-glitch-4-g…".
VERSION="$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null | sed 's/^v//' || true)"
/usr/bin/sed -i '' "s|REPLACE_VERSION|${VERSION:-dev}|" "$APP/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper lets it run.
codesign --force --deep --sign - "$APP" >/dev/null

echo "built: $APP"
echo "run:   open $APP"
if pgrep -f "$PWD/$APP/Contents/MacOS/NTSCRT" >/dev/null; then
  echo "note:  NTSCRT is running from this bundle — quit and reopen it to get this build."
fi
