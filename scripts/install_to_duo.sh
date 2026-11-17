#!/usr/bin/env bash
# Install a previously built IPA to Allan's Duo. Run scripts/test_pc_quit.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${POCKETDEX_UDID:-00008160-0009193402600036}"
IPA="${1:-$ROOT/build/ipa/PocketDex.ipa}"

if [[ ! -f "$IPA" ]]; then
  echo "No IPA at $IPA — build with scripts/build_ipa.sh first" >&2
  exit 1
fi

echo "==> PC quit gate"
python3 "$ROOT/scripts/verify_quit_invariants.py"

echo "==> Installing $IPA → $UDID"
xcrun devicectl device install app --device "$UDID" "$IPA"
echo "==> Installed"
