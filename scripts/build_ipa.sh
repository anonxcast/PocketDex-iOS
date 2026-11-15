#!/usr/bin/env bash
# Build a signed PocketDex IPA for a connected or generic iOS device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="${DEVELOPMENT_TEAM:-5TNX7VB7Z6}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.anonxcast.pocketdex}"
DERIVED="$ROOT/build/xcode-derived"
ARCHIVE="$ROOT/build/PocketDex.xcarchive"
EXPORT_DIR="$ROOT/build/ipa"
EXPORT_PLIST="$ROOT/build/ExportOptions.plist"

echo "==> Configuring mGBA (if needed)"
if [[ ! -f "$ROOT/build/mgba-ios/Release-iphoneos/libmgba.a" ]]; then
  cmake -S upstream/third_party/mgba -B build/mgba-ios \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_STATIC=ON -DBUILD_SHARED=OFF \
    -DDISABLE_FRONTENDS=ON -DDISABLE_DEPS=ON \
    -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
    -DBUILD_PERF=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF \
    -DBUILD_LIBRETRO=OFF -DBUILD_PYTHON=OFF \
    -DUSE_DEBUGGERS=OFF -DUSE_GDB_STUB=OFF -DUSE_EDITLINE=OFF \
    -DUSE_FFMPEG=OFF -DUSE_DISCORD_RPC=OFF -DUSE_LZMA=OFF \
    -DUSE_LUA=OFF -DUSE_ELF=OFF -DUSE_SQLITE3=OFF \
    -DUSE_LIBZIP=OFF -DUSE_MINIZIP=OFF -DUSE_PNG=OFF -DUSE_ZLIB=OFF \
    -DM_CORE_GBA=ON -DM_CORE_GB=ON \
    -DBUILD_LTO=OFF -DSKIP_INSTALL_ALL=ON
  cmake --build build/mgba-ios --config Release --target mgba -j"$(sysctl -n hw.ncpu)"
fi

echo "==> Configuring melonDS / pknds (if needed)"
bash "$ROOT/scripts/build_melonds_ios.sh"

echo "==> Validating Gen3 companion maps (no duplicate-key crash)"
python3 "$ROOT/scripts/validate_companion_maps.py"

echo "==> Generating Xcode project"
(
  cd ios
  xcodegen generate
)

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>compileBitcode</key>
	<false/>
</dict>
</plist>
EOF

echo "==> Archiving"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
xcodebuild \
  -project "$ROOT/ios/PocketDex.xcodeproj" \
  -scheme PocketDex \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  archive | tee "$ROOT/build/archive.log" | tail -40

echo "==> Exporting IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates | tee "$ROOT/build/export.log" | tail -30

IPA=$(ls "$EXPORT_DIR"/*.ipa | head -1)
echo "==> IPA ready: $IPA"
ls -lh "$IPA"
