#!/usr/bin/env bash
# Build a distributable, self-contained, signed + notarized NTSCRT release.
#
#   ./scripts/make-release.sh <version> [--adhoc]
#
#   <version>   e.g. 0.1.0 — stamped into the bundle and the DMG name.
#   --adhoc     skip Developer ID signing + notarization (local testing of
#               the self-contained bundle only; NOT distributable).
#
# Requirements for a real release:
#   - A "Developer ID Application" certificate in the login keychain
#     (create at developer.apple.com → Certificates, or via Xcode).
#   - notarytool credentials stored once via:
#       xcrun notarytool store-credentials ntscrt-notary \
#           --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#     (uses an app-specific password from appleid.apple.com)
#
# Output: dist/NTSCRT-<version>.dmg

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-release.sh <version> [--adhoc]}"
ADHOC="${2:-}"
PROFILE="ntscrt-notary"
APP=dist/NTSCRT.app
DMG="dist/NTSCRT-$VERSION.dmg"

# ---- signing identity ----
if [[ "$ADHOC" == "--adhoc" ]]; then
  IDENTITY="-"
  echo "== ad-hoc mode: no notarization, local testing only =="
else
  IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "no 'Developer ID Application' certificate found in the keychain." >&2
    echo "create one at developer.apple.com → Certificates, or run with --adhoc." >&2
    exit 1
  fi
  echo "== signing as: $IDENTITY =="
fi

# ---- build everything ----
echo "== building dylibs + app (release) =="
if [[ ! -f Vendor/librashader/librashader.dylib ]]; then
  echo "Vendor/librashader/librashader.dylib missing — see README build steps." >&2
  exit 1
fi
./scripts/build-ntscrs.sh
swift build -c release --product crt-app

# ---- assemble self-contained bundle ----
echo "== assembling $APP =="
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp .build/release/crt-app "$APP/Contents/MacOS/NTSCRT"
cp Vendor/librashader/librashader.dylib "$APP/Contents/Frameworks/"
cp Vendor/ntscrs-capi/ntscrs_capi.dylib "$APP/Contents/Frameworks/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/NTSCRT" 2>/dev/null || true

# Shader presets: the crt/ tree (presets + shaders + textures) and the shared
# include/ headers are all our 7 presets reference. ~10 MB.
mkdir -p "$APP/Contents/Resources/slang-shaders"
cp -R Vendor/slang-shaders/crt "$APP/Contents/Resources/slang-shaders/"
cp -R Vendor/slang-shaders/include "$APP/Contents/Resources/slang-shaders/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>NTSCRT</string>
    <key>CFBundleIdentifier</key>             <string>academy.urm.ntscrt</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>NTSCRT</string>
    <key>CFBundleDisplayName</key>            <string>NTSCRT</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
</dict>
</plist>
PLIST

# ---- sign (inside-out: dylibs first, then the app) ----
echo "== signing =="
SIGN_FLAGS=(--force --timestamp --options runtime)
if [[ "$IDENTITY" == "-" ]]; then
  SIGN_FLAGS=(--force)   # ad-hoc: no timestamp/hardened runtime needed
fi
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/Frameworks/librashader.dylib"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/Frameworks/ntscrs_capi.dylib"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "signature verified"

# ---- notarize + staple ----
if [[ "$IDENTITY" != "-" ]]; then
  echo "== notarizing (this takes a minute or two) =="
  ditto -c -k --keepParent "$APP" dist/NTSCRT-notarize.zip
  xcrun notarytool submit dist/NTSCRT-notarize.zip \
      --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/NTSCRT-notarize.zip
  spctl --assess --type execute --verbose=2 "$APP" && echo "Gatekeeper: accepted"
fi

# ---- DMG ----
echo "== building DMG =="
STAGE=dist/dmg-stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "NTSCRT $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

echo
echo "done: $DMG"
if [[ "$IDENTITY" == "-" ]]; then
  echo "(ad-hoc build — for local testing only, will not pass Gatekeeper elsewhere)"
else
  echo "publish with: gh release create v$VERSION $DMG --title \"NTSCRT $VERSION\""
fi
