#!/usr/bin/env bash
# Build static libpknds.a (melonDS core + pk_nds) for iOS arm64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MELON="$ROOT/upstream/third_party/melonds"
OUT="$ROOT/build/melonds-ios"

if [[ ! -f "$MELON/src/NDS.h" ]]; then
  echo "==> Init melonDS submodule"
  git -C "$ROOT/upstream" submodule update --init third_party/melonds
fi

if [[ -f "$OUT/Release-iphoneos/libpknds.a" ]] || [[ -f "$OUT/libpknds.a" ]]; then
  # Also require libcore nearby / embedded — rebuild if pknds missing pieces later.
  if [[ -f "$OUT/Release-iphoneos/libpknds.a" ]]; then
    echo "==> melonDS already built: $OUT/Release-iphoneos/libpknds.a"
    exit 0
  fi
fi

echo "==> Configuring melonDS / pknds for iOS"
cmake -S "$ROOT/ios/Native/melonds" -B "$OUT" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DENABLE_JIT=OFF \
  -DENABLE_OGLRENDERER=OFF \
  -DBUILD_QT_SDL=OFF \
  -DENABLE_GDBSTUB=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_LTO_RELEASE=OFF

echo "==> Building pknds"
cmake --build "$OUT" --config Release --target pknds -j"$(sysctl -n hw.ncpu)"

# Normalize output path for project.yml
mkdir -p "$OUT/Release-iphoneos"
# Xcode generator may place archives under nested configs
find "$OUT" -name 'libpknds.a' -print
find "$OUT" -name 'libcore.a' -print
PKNDS_A="$(find "$OUT" -name 'libpknds.a' | head -1)"
CORE_A="$(find "$OUT" -name 'libcore.a' | head -1)"
if [[ -z "$PKNDS_A" || -z "$CORE_A" ]]; then
  echo "error: expected libpknds.a and libcore.a under $OUT" >&2
  exit 1
fi
[[ "$PKNDS_A" -ef "$OUT/Release-iphoneos/libpknds.a" ]] || cp -f "$PKNDS_A" "$OUT/Release-iphoneos/libpknds.a"
[[ "$CORE_A" -ef "$OUT/Release-iphoneos/libcore.a" ]] || cp -f "$CORE_A" "$OUT/Release-iphoneos/libcore.a"
# teakra lives under melonds build tree
TEAKRA_A="$(find "$OUT" -name 'libteakra.a' | head -1 || true)"
if [[ -n "$TEAKRA_A" ]]; then
  [[ "$TEAKRA_A" -ef "$OUT/Release-iphoneos/libteakra.a" ]] || cp -f "$TEAKRA_A" "$OUT/Release-iphoneos/libteakra.a"
fi

echo "==> melonDS ready: $OUT/Release-iphoneos/libpknds.a"
