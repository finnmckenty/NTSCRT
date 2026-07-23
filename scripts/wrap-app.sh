#!/usr/bin/env bash
# Wrap the SPM-built crt-app executable in a minimal .app bundle so it
# launches as a proper foreground macOS app (window gets focus, dock entry,
# Cmd-Q quits). Run after `swift build -c release --product crt-app`.
#
# Usage: wrap-app.sh [release|debug]   (default: release)
#
# Output: build/NTSCRT.app — drag to /Applications or `open` it directly.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

if [[ ! -x ".build/$CONFIG/crt-app" ]]; then
  echo "build first: swift build -c $CONFIG --product crt-app" >&2
  exit 1
fi

APP=build/NTSCRT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp ".build/$CONFIG/crt-app" "$APP/Contents/MacOS/NTSCRT"
cp Vendor/librashader/librashader.dylib "$APP/Contents/Frameworks/librashader.dylib"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
    <key>CFBundleShortVersionString</key>     <string>0.1</string>
    <key>CFBundleVersion</key>                <string>1</string>
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

# Ad-hoc sign so Gatekeeper lets it run.
codesign --force --deep --sign - "$APP" >/dev/null

echo "built: $APP"
echo "run:   open $APP"
