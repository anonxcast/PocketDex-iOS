#!/usr/bin/env bash
# Build static libpknds.a (melonDS core + pk_nds) for iOS arm64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MELON="$ROOT/upstream/third_party/melonds"
OUT="$ROOT/build/melonds-ios"
# Bump when CMake JIT / arch flags change so the early-exit cache invalidates.
JIT_STAMP_CONTENT="jit=off compile-out arch=ARM64 v12-minimal-ds"
JIT_STAMP_FILE="$OUT/.pocketdex-jit-stamp"

if [[ ! -f "$MELON/src/NDS.h" ]]; then
  echo "==> Init melonDS submodule"
  git -C "$ROOT/upstream" submodule update --init third_party/melonds
fi

NEED_REBUILD=1
if [[ -f "$OUT/Release-iphoneos/libpknds.a" && -f "$OUT/Release-iphoneos/libcore.a" && -f "$JIT_STAMP_FILE" ]]; then
  if [[ "$(cat "$JIT_STAMP_FILE")" == "$JIT_STAMP_CONTENT" ]]; then
    echo "==> melonDS already built: $OUT/Release-iphoneos/libpknds.a"
    NEED_REBUILD=0
  fi
fi

if [[ "$NEED_REBUILD" -eq 1 ]]; then
  echo "==> Configuring melonDS / pknds for iOS (interpreter only — JIT compiled out)"
  rm -rf "$OUT"
  cmake -S "$ROOT/ios/Native/melonds" -B "$OUT" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DARCHITECTURE=ARM64 \
    -DENABLE_JIT=OFF \
    -DENABLE_OGLRENDERER=OFF \
    -DBUILD_QT_SDL=OFF \
    -DENABLE_GDBSTUB=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_LTO_RELEASE=OFF

  echo "==> Building pknds"
  cmake --build "$OUT" --config Release --target pknds -j"$(sysctl -n hw.ncpu)"

  mkdir -p "$OUT/Release-iphoneos"
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
  TEAKRA_A="$(find "$OUT" -name 'libteakra.a' | head -1 || true)"
  if [[ -n "$TEAKRA_A" ]]; then
    [[ "$TEAKRA_A" -ef "$OUT/Release-iphoneos/libteakra.a" ]] || cp -f "$TEAKRA_A" "$OUT/Release-iphoneos/libteakra.a"
  fi
  printf '%s\n' "$JIT_STAMP_CONTENT" > "$JIT_STAMP_FILE"
fi

echo "==> melonDS ready: $OUT/Release-iphoneos/libpknds.a"
