#!/usr/bin/env python3
"""Fail the build if Gen3 companion maps could trap Swift on ROM open.

Swift Dictionary *literals* with duplicate keys raise EXC_BREAKPOINT/SIGTRAP the
first time the map is touched — which for Emerald / many GBA hacks is companion
setup during play(). Generated tables must use collision-safe `put` builders.
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GEN = os.path.join(ROOT, "ios/Sources/Companion/Generated")
CHECKS = [
    ("Gen3ConfigsGen.swift", "makeById", r"static let byId:\s*\[String:\s*\(\)\s*->\s*NativeConfig\]\s*=\s*\["),
    ("RomIdentityGen.swift", "makeSha1Map", r"static let sha1ToConfigId:\s*\[String:\s*String\]\s*=\s*\["),
]


def main() -> int:
    errors: list[str] = []
    for name, builder, bad_lit in CHECKS:
        path = os.path.join(GEN, name)
        if not os.path.isfile(path):
            errors.append(f"missing {name}")
            continue
        text = open(path, encoding="utf-8").read()
        if builder not in text:
            errors.append(f"{name}: expected collision-safe {builder}()")
        if re.search(bad_lit, text):
            errors.append(
                f"{name}: unsafe Dictionary literal for companion map "
                f"(duplicate keys crash on GBA ROM open)"
            )
        # Duplicate put("key" …) would be ignored at runtime but still flag regen bugs.
        keys = re.findall(r'put\("([^"]+)"', text)
        seen: dict[str, int] = {}
        for k in keys:
            seen[k] = seen.get(k, 0) + 1
        dups = sorted(k for k, n in seen.items() if n > 1)
        if dups:
            # Warning only — put() first-wins is safe; print so regen cleans them up.
            print(f"warn: {name} has repeated put() keys (first wins): {', '.join(dups[:8])}")

    if errors:
        print("validate_companion_maps FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print("validate_companion_maps: OK (collision-safe Gen3 maps)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
