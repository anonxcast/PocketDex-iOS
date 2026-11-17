#!/usr/bin/env bash
# PC gate before any phone install: quit invariants + device compile (no install).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Quit / Exit invariants"
python3 "$ROOT/scripts/verify_quit_invariants.py"

echo "==> Host deadlock demo (why main must not take g_lock during play)"
cat > /tmp/pd_glock_demo.c <<'EOF'
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void *holder(void *arg) {
  (void)arg;
  pthread_mutex_lock(&lock);
  /* Simulate Expand frame holding g_lock. */
  usleep(300000);
  pthread_mutex_unlock(&lock);
  return NULL;
}

int main(void) {
  pthread_t t;
  pthread_create(&t, NULL, holder, NULL);
  usleep(20000); /* let holder take the lock */

  if (pthread_mutex_trylock(&lock) == 0) {
    fprintf(stderr, "FAIL: expected main to see lock held by frame thread\n");
    pthread_mutex_unlock(&lock);
    return 1;
  }
  printf("OK: main would freeze if it took g_lock while a frame runs\n");
  pthread_join(t, NULL);
  return 0;
}
EOF
clang /tmp/pd_glock_demo.c -o /tmp/pd_glock_demo
/tmp/pd_glock_demo

echo "==> Device compile check (archive only — will NOT install to phone)"
# Fast path: build without full export if libs already present
if [[ ! -f "$ROOT/build/mgba-ios/Release-iphoneos/libmgba.a" ]]; then
  echo "mGBA device lib missing; run scripts/build_ipa.sh once for libs"
  exit 1
fi
(
  cd "$ROOT/ios"
  xcodegen generate >/dev/null
)
xcodebuild \
  -project "$ROOT/ios/PocketDex.xcodeproj" \
  -scheme PocketDex \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$ROOT/build/pc-check-derived" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5TNX7VB7Z6}" \
  CODE_SIGN_STYLE=Automatic \
  build \
  | tee "$ROOT/build/pc-check.log" \
  | tail -25

echo "==> PC checks passed. Phone install is a separate step."
