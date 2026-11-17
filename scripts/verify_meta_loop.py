#!/usr/bin/env python3
"""PC gate: GameDetail must not re-task on artworkStore.revision after saveMeta."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
detail = (ROOT / "ios/Sources/GameDetailView.swift").read_text()
store = (ROOT / "ios/Sources/Artwork/RomArtworkStore.swift").read_text()
errors = []

if re.search(r'\.task\(id:\s*"\\?\(rom\.artworkKey\)-\\?\(artworkStore\.revision\)"', detail):
    errors.append("GameDetailView.task must not depend on artworkStore.revision")
if ".task(id: rom.artworkKey)" not in detail and "task(id: rom.artworkKey)" not in detail:
    errors.append("GameDetailView.task should key only on rom.artworkKey")
if "metaContentEqual" not in store:
    errors.append("RomArtworkStore.saveMeta must skip no-op writes (metaContentEqual)")
if "if let existing, Self.metaContentEqual" not in store and "metaContentEqual(existing" not in store:
    errors.append("saveMeta must early-return when meta content unchanged")

if errors:
    print("verify_meta_loop: FAIL")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("verify_meta_loop: OK")
