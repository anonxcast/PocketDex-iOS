#!/usr/bin/env python3
"""Generate iOS companion Gen3 tables from upstream gamedata + Poller SHA-1 identity.

Source of truth: upstream/gamedata (same as Android / 3DS). After editing TOMLs or
Poller.kt hashes (needs Python 3.11+ for tomllib):

  python3.12 scripts/gen_ios_companion.py

Writes:
  ios/Sources/Companion/Generated/Gen3ConfigsGen.swift
  ios/Sources/Companion/Generated/RomIdentityGen.swift
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
UPSTREAM = os.path.join(ROOT, "upstream")
sys.path.insert(0, os.path.join(UPSTREAM, "scripts"))

import gen_gamedata as gd  # noqa: E402

OUT_DIR = os.path.join(ROOT, "ios/Sources/Companion/Generated")
CONFIGS_OUT = os.path.join(OUT_DIR, "Gen3ConfigsGen.swift")
IDENTITY_OUT = os.path.join(OUT_DIR, "RomIdentityGen.swift")
POLLER = os.path.join(
    UPSTREAM, "app/src/main/kotlin/com/pokedaisy/app/companion/data/Poller.kt"
)
TARGET_3DS = os.path.join(UPSTREAM, "gamedata/targets/3ds.toml")

# Paths into NativeConfig / pokedex record (same idea as gamedata/targets/3ds.toml).
RAM_PATHS = {
    "playerParty": "playerParty",
    "playerPartyCount": "playerPartyCount",
    "battleMons": "battleMons",
    "battlerPositions": "battlerPositions",
    "battlersCount": "battlersCount",
    "battleTypeFlags": "battleTypeFlags",
    "gMain": "gMain",
    "saveBlock1Ptr": "saveBlock1Ptr",
    "saveBlock2Ptr": "saveBlock2Ptr",
    "mapHeader": "mapHeader",
    "bagPockets": "bagPockets",
    "bagPocketCount": "bagPocketCount",
    "encryptionKeyOff": "encryptionKeyOff",
    "moneyOff": "moneyOff",
    "staticSaveBlocks": "staticSaveBlocks",
    "enemyParty": "enemyParty",
    "battleMonLayout": "battleMonLayout",
    "bagPocketOrder": "bagPocketOrder",
    "dexSeenCopy1": "pokedex.flags.seenCopies.0",
    "dexSeenCopy2": "pokedex.flags.seenCopies.1",
    "dexBytes": "pokedex.flags.bytes",
    "dexSeenOff": "pokedex.flags.seen",
    "dexCaughtOff": "pokedex.flags.caught",
    "dexBlock": "pokedex.flags.block",
    "nationalCount": "pokedex.nationalCount",
    "nationalMagicOff": "pokedex.nationalMagicOff",
    "nationalMagic": "pokedex.nationalMagic",
}

POCKET_IDS = {
    "POCKET_ITEMS": 0,
    "POCKET_POKE_BALLS": 1,
    "POCKET_TM_HM": 2,
    "POCKET_BERRIES": 3,
    "POCKET_KEY_ITEMS": 4,
    "POCKET_MEDICINE": 0,  # fold into items for iOS bag UI
    "POCKET_MAIL": 0,
    "POCKET_BATTLE_ITEMS": 0,
    "POCKET_MEGA_STONES": 4,
}

EMERALD_ORDER = [0, 1, 2, 3, 4]
FIRERED_ORDER = [0, 4, 1, 2, 3]

DISPLAY_NAMES = {
    "emerald_retail": "Pokémon Emerald",
    "emerald": "Pokémon Emerald",
    "emerald_es": "Pokémon Emerald (S)",
    "emerald_de": "Pokémon Emerald (D)",
    "emerald_fr": "Pokémon Emerald (F)",
    "emerald_it": "Pokémon Emerald (I)",
    "emerald_ja": "Pokémon Emerald (J)",
    "firered_rev0": "Pokémon FireRed",
    "firered_rev1": "Pokémon FireRed (Rev 1)",
    "leafgreen_rev0": "Pokémon LeafGreen",
    "leafgreen_rev1": "Pokémon LeafGreen (Rev 1)",
    "leafgreen": "Pokémon LeafGreen",
    "ruby": "Pokémon Ruby",
    "sapphire": "Pokémon Sapphire",
    "port_axve0": "Pokémon Ruby (Rev 0)",
    "port_axpe0": "Pokémon Sapphire (Rev 0)",
    "unbound_with_dex": "Pokémon Unbound",
    "unbound": "Pokémon Unbound",
    "unbound_fr": "Pokémon Unbound (FR)",
    "emerald_seaglass": "Pokémon Emerald Seaglass",
    "radical_red_v4_1": "Pokémon Radical Red",
    "gaia_v3_2": "Pokémon Gaia",
    "odyssey": "Pokémon Odyssey",
    "emerald_legacy": "Pokémon Emerald Legacy",
    "emerald_kaizo": "Pokémon Emerald Kaizo",
    "modern_emerald": "Pokémon Modern Emerald",
}


def hex_u32(v) -> str:
    if v is None or v is gd.NONE:
        return "0"
    return f"0x{int(v) & 0xFFFFFFFF:08X}"


def resolve_raw(resolver, key, path):
    try:
        v, f = resolver.walk(key, path, f"{key}.{path}")
        return v, f
    except gd.GameDataError:
        return None, None


def resolve_int(resolver, key, path, default=0) -> int:
    v, _ = resolve_raw(resolver, key, path)
    if v is None or v is gd.NONE:
        return default
    if isinstance(v, bool):
        return int(v)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def pocket_order(resolver, key: str) -> list[int]:
    v, _ = resolve_raw(resolver, key, "bagPocketOrder")
    if isinstance(v, str):
        # Named list in records, or Kotlin val like EMERALD_BAG_POCKET_ORDER.
        if v in resolver.records and resolver.records[v]["kind"] == "list":
            items = resolver.records[v]["items"]
            return [POCKET_IDS.get(i, 0) for i in items]
        ids = gd.kotlin_pocket_order(v, resolver.records, f"{key}.bagPocketOrder")
        if ids:
            # ids are PD_POCKET_* strings from C path — map back.
            rev = {
                "PD_POCKET_ITEMS": 0,
                "PD_POCKET_BALLS": 1,
                "PD_POCKET_TMHM": 2,
                "PD_POCKET_BERRIES": 3,
                "PD_POCKET_KEY": 4,
                "PD_POCKET_MEDICINE": 0,
                "PD_POCKET_MAIL": 0,
                "PD_POCKET_BATTLE_ITEMS": 0,
                "PD_POCKET_MEGA_STONES": 4,
            }
            return [rev.get(i, 0) for i in ids]
        if "FIRERED" in v or "UNBOUND" in v or "RADICAL" in v:
            return list(FIRERED_ORDER)
        return list(EMERALD_ORDER)
    if isinstance(v, list) and v:
        out = []
        for i in v:
            if isinstance(i, str):
                out.append(POCKET_IDS.get(i, 0))
            else:
                out.append(int(i))
        return out
    # Heuristic from config id.
    fr = (
        "firered", "leafgreen", "unbound", "radical", "gaia", "odyssey", "cfru",
        "orange", "ultra_violet", "amethyst", "celia", "gs_chronicles", "sword",
        "ash_gray", "rocket_edition", "ghost",
    )
    if any(s in key for s in fr):
        return list(FIRERED_ORDER)
    return list(EMERALD_ORDER)


def battle_layout(resolver, key: str) -> str:
    v, _ = resolve_raw(resolver, key, "battleMonLayout")
    if isinstance(v, str) and "EXPANSION" in v:
        return ".expansion"
    if isinstance(v, str) and ("TMT2" in v or "TEAM_ROCKET" in v or "WISHES" in v
                               or "ROWE" in v or "SOULGOLD" in v or "ELITE" in v
                               or "MONOMYTH" in v):
        # Custom layouts iOS doesn't model yet — expansion size is closer than vanilla for most.
        if "VANILLA" in v:
            return ".vanilla"
        return ".expansion"
    # Known expansion rebuilds even if record still says vanilla.
    if any(s in key for s in (
        "seaglass", "soulgold", "quetzal", "rogue", "modern_emerald",
        "recharged_emerald", "lazarus", "imperium", "wishes", "dreamstone",
        "mariomon", "elite_redux", "team_rocket", "monomyth", "rowe", "tmt2",
    )):
        return ".expansion"
    return ".vanilla"


def game_kind(key: str) -> str:
    if "unbound" in key:
        return ".unbound"
    if any(s in key for s in (
        "firered", "leafgreen", "radical", "gaia", "odyssey", "orange",
        "ultra_violet", "amethyst", "celia", "ash_gray", "rocket_edition",
        "ghost", "sword", "gs_chronicles",
    )):
        return ".fireRed"
    return ".emerald"


def tables_kind(key: str, national_count: int) -> str:
    if "unbound" in key:
        return ".unbound"
    if any(s in key for s in (
        "seaglass", "soulgold", "quetzal", "modern_emerald", "rogue",
        "recharged_emerald", "elite_redux", "mariomon", "wishes", "dreamstone",
        "imperium", "lazarus", "monomyth", "team_rocket",
    )):
        return ".national"
    if national_count and national_count > 386:
        return ".national"
    return ".retail"


def display_name(key: str) -> str:
    if key in DISPLAY_NAMES:
        return DISPLAY_NAMES[key]
    pretty = key.replace("_", " ").title()
    return f"Pokémon {pretty}"


def target_configs() -> dict[str, str]:
    """gamedata key -> NATIVE_* suffix from 3ds.toml (configs the ports ship)."""
    text = open(TARGET_3DS, encoding="utf-8").read()
    out: dict[str, str] = {}
    for m in re.finditer(
        r"^\[config\.([a-z0-9_]+)\]\n(?:.*?\n)*?name\s*=\s*'([A-Z0-9_]+)'",
        text,
        re.M,
    ):
        out[m.group(1)] = m.group(2)
    return out


def dex_flag_block_lit(resolver, key: str) -> str:
    """Map gamedata DexFlagBlock.* → Swift DexFlagBlock case."""
    raw, _ = resolve_raw(resolver, key, "pokedex.flags.block")
    if raw is None or raw is gd.NONE:
        return ".saveBlock2"
    s = str(raw)
    if "SAVE_BLOCK_1" in s:
        return ".saveBlock1"
    if "FIXED" in s:
        return ".fixed"
    return ".saveBlock2"


def emit_config(resolver, key: str) -> str | None:
    vals_int = {n: resolve_int(resolver, key, p) for n, p in RAM_PATHS.items()
                if n not in ("battleMonLayout", "bagPocketOrder", "staticSaveBlocks", "dexBlock")}
    static = bool(resolve_int(resolver, key, "staticSaveBlocks"))
    if vals_int["playerParty"] == 0 or vals_int["gMain"] == 0:
        return None

    order = pocket_order(resolver, key)
    order_lit = "[" + ", ".join(str(x) for x in order) + "]"
    enc = vals_int["encryptionKeyOff"]
    # Android: encryptionKeyOff < 0 means plain bag qty / money (no XOR).
    # hex_u32(-1) used to emit 0xFFFFFFFF, which the sampler treated as a real SB2 offset.
    if (
        static
        or key in ("ruby", "sapphire")
        or key.startswith("port_ax")
        or enc < 0
        or (enc & 0xFFFFFFFF) == 0xFFFFFFFF
    ):
        enc_lit = "nil"
    else:
        enc_lit = hex_u32(enc)

    copies = []
    if vals_int["dexSeenCopy1"]:
        copies.append(hex_u32(vals_int["dexSeenCopy1"]))
    if vals_int["dexSeenCopy2"]:
        copies.append(hex_u32(vals_int["dexSeenCopy2"]))
    copies_lit = "[" + ", ".join(copies) + "]"

    dex_bytes = vals_int["dexBytes"] or 52
    national = vals_int["nationalCount"] or 386
    pokedex_v, _ = resolve_raw(resolver, key, "pokedex")
    has_dex = (
        pokedex_v is not None
        and pokedex_v is not gd.NONE
        and pokedex_v != "none"
        and not (isinstance(pokedex_v, dict) and pokedex_v.get("from") == "none")
    )
    dex_on = (
        has_dex
        and vals_int["dexSeenOff"] != 0
        and vals_int["dexCaughtOff"] != 0
        and dex_bytes > 0
    )
    # nationalMagicOff of -1 means "no national magic" in some records.
    magic_off = vals_int["nationalMagicOff"]
    if magic_off < 0:
        magic_off = 3
    magic = vals_int["nationalMagic"] or 0xB9

    name = display_name(key)
    tables = tables_kind(key, national)
    game = game_kind(key)
    layout = battle_layout(resolver, key)

    return "\n".join([
        f"  static let {key}: NativeConfig = NativeConfig(",
        f'    id: "{key}",',
        f'    displayName: "{name}",',
        f"    game: {game},",
        f"    tables: {tables},",
        f'    playerParty: {hex_u32(vals_int["playerParty"])},',
        f'    playerPartyCount: {hex_u32(vals_int["playerPartyCount"])},',
        f'    battleMons: {hex_u32(vals_int["battleMons"])},',
        f'    battlerPositions: {hex_u32(vals_int["battlerPositions"])},',
        f'    battlersCount: {hex_u32(vals_int["battlersCount"])},',
        f'    battleTypeFlags: {hex_u32(vals_int["battleTypeFlags"])},',
        f'    gMain: {hex_u32(vals_int["gMain"])},',
        f'    saveBlock1Ptr: {hex_u32(vals_int["saveBlock1Ptr"])},',
        f'    saveBlock2Ptr: {hex_u32(vals_int["saveBlock2Ptr"])},',
        f'    mapHeader: {hex_u32(vals_int["mapHeader"])},',
        f'    bagPockets: {hex_u32(vals_int["bagPockets"])},',
        f'    bagPocketCount: {vals_int["bagPocketCount"] or 5},',
        f"    encryptionKeyOff: {enc_lit},",
        f'    moneyOff: {hex_u32(vals_int["moneyOff"])},',
        f"    bagPocketOrder: {order_lit},",
        f"    staticSaveBlocks: {'true' if static else 'false'},",
        f'    enemyParty: {hex_u32(vals_int["enemyParty"])},',
        f"    battleMonLayout: {layout},",
        f"    dexEnabled: {'true' if dex_on else 'false'},",
        f"    dexFlagBlock: {dex_flag_block_lit(resolver, key)},",
        f'    dexSeenOff: {hex_u32(vals_int["dexSeenOff"] or 0x5C)},',
        f'    dexCaughtOff: {hex_u32(vals_int["dexCaughtOff"] or 0x28)},',
        f"    dexBytes: {dex_bytes},",
        f"    dexSeenCopies: {copies_lit},",
        f"    dexNationalMagicOff: {magic_off},",
        f"    dexNationalMagic: {magic},",
        f"    dexNationalCount: {national}",
        "  )",
    ])


def parse_poller_identity(text: str) -> dict[str, str]:
    """Map lowercase sha1 hex -> NATIVE_* name (without NATIVE_ prefix, lower)."""
    # Mixed-case const names exist (…Anniversary_SHA1, …Hotfix_SHA1).
    sha1_name = r"[A-Za-z0-9_]+_SHA1"
    consts: dict[str, str] = {
        m.group(1): m.group(2).lower()
        for m in re.finditer(rf'const val ({sha1_name})\s*=\s*"([0-9a-fA-F]{{40}})"', text)
    }
    # ModernEmerald.V3_6_SHA1 aliases TelemetrySampler.MODERN_EMERALD_V3_6_SHA1.
    if "MODERN_EMERALD_V3_6_SHA1" in consts:
        consts["ModernEmerald.V3_6_SHA1"] = consts["MODERN_EMERALD_V3_6_SHA1"]

    mapping: dict[str, str] = {}

    def add(names: list[str], native: str) -> None:
        key = native.replace("NATIVE_", "").lower()
        for n in names:
            h = consts.get(n)
            if h:
                mapping[h] = key

    # when arms: HASH[, HASH]*[,]\n -> { nativeCfg = NATIVE_X } | NATIVE_X | kind-only
    arm_re = re.compile(
        rf"((?:(?:{sha1_name}|ModernEmerald\.V3_6_SHA1)\s*,\s*)*"
        rf"(?:{sha1_name}|ModernEmerald\.V3_6_SHA1))\s*,?\s*->\s*"
        r"((?:\{[^}]*\}|[^\n]+))",
        re.S,
    )
    for m in arm_re.finditer(text):
        names = re.findall(rf"{sha1_name}|ModernEmerald\.V3_6_SHA1", m.group(1))
        rhs = m.group(2)
        if "gen1Cfg" in rhs or "gen2Cfg" in rhs:
            continue  # Gen 1 / Gen 2 — not Gen3 NativeConfig
        nat = re.search(r"(?:nativeCfg\s*=\s*)?(NATIVE_[A-Z0-9_]+)", rhs)
        if nat and ("nativeCfg" in rhs or rhs.strip().startswith("NATIVE_")):
            add(names, nat.group(1))
        elif "GameKind.UNBOUND" in rhs and "nativeCfg" not in rhs:
            add(names, "NATIVE_UNBOUND_WITH_DEX")

    # if (hash == FOO_SHA1) … nativeCfg = NATIVE_BAR  (and hash == A || hash == B)
    for m in re.finditer(
        rf"hash\s*==\s*({sha1_name})(?:\s*\|\|\s*hash\s*==\s*({sha1_name}))?"
        rf".{{0,200}}?nativeCfg\s*=\s*(NATIVE_[A-Z0-9_]+)",
        text,
        re.S,
    ):
        names = [m.group(1)]
        if m.group(2):
            names.append(m.group(2))
        add(names, m.group(3))

    return mapping


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    schema = gd.load_schema(gd.CONFIG_SCHEMA)
    configs = gd.load_configs(schema)
    records = gd.load_records()
    resolver = gd.Resolver(configs, records, schema)

    curated = target_configs()  # key -> NAME (EMERALD, …)
    # Always include every curated 3ds config; also any non-private with RAM.
    want = set(curated.keys())
    for key, meta in configs.items():
        if meta.get("private"):
            continue
        if key.startswith("port_") and key not in want:
            continue
        # Skip bare `emerald` — prefer emerald_retail (has dex).
        if key == "emerald":
            continue
        want.add(key)

    emitted_blocks = []
    ids = []
    for key in sorted(want):
        if key not in configs:
            print(f"warn: 3ds.toml config {key} missing from gamedata", file=sys.stderr)
            continue
        block = emit_config(resolver, key)
        if block:
            emitted_blocks.append(block)
            ids.append(key)

    # Ordered (id, factoryExpr) pairs. Real configs first; aliases only if free.
    # Never emit a Swift Dictionary *literal* — duplicate keys trap (SIGTRAP) on first
    # touch and kill the app when opening Emerald / any GBA ROM that hits byId.
    by_id_pairs: list[tuple[str, str]] = [(i, i) for i in ids]
    id_set_emit = set(ids)
    aliases = [
        ("emerald", "emerald_retail"),
        ("unbound", "unbound_with_dex"),
    ]
    for alias, target in aliases:
        if target in id_set_emit and alias not in id_set_emit:
            by_id_pairs.append((alias, target))
            id_set_emit.add(alias)
        elif alias in id_set_emit and target in id_set_emit:
            print(
                f"warn: skip byId alias {alias!r} -> {target!r} "
                f"(real config {alias!r} already exists)",
                file=sys.stderr,
            )

    # Fail the generator if any key would still collide (defensive).
    seen_keys: dict[str, str] = {}
    collisions: list[str] = []
    for key, factory in by_id_pairs:
        if key in seen_keys:
            collisions.append(f"{key!r}: {seen_keys[key]} vs {factory}")
        else:
            seen_keys[key] = factory
    if collisions:
        raise SystemExit(
            "gen_ios_companion: duplicate byId keys (would crash iOS on ROM open):\n  "
            + "\n  ".join(collisions)
        )

    put_lines = "\n".join(
        f'    put("{key}", {{ {factory} }})' for key, factory in by_id_pairs
    )

    header = """\
// Generated by scripts/gen_ios_companion.py from upstream/gamedata — do not edit by hand.
// Add/change a hack in gamedata/gen3/hacks/*.toml (+ Poller.kt SHA-1), then re-run the script.
import Foundation

enum Gen3ConfigsGen {
"""
    footer = f"""

  /// All generated configs keyed by gamedata id.
  /// Built via `put` (first wins) so a regen bug can never trap on duplicate keys.
  static let byId: [String: () -> NativeConfig] = makeById()

  private static func makeById() -> [String: () -> NativeConfig] {{
    var d: [String: () -> NativeConfig] = [:]
    d.reserveCapacity({len(by_id_pairs)})
    func put(_ id: String, _ factory: @escaping () -> NativeConfig) {{
      if d[id] == nil {{ d[id] = factory }}
    }}
{put_lines}
    return d
  }}
}}
"""
    with open(CONFIGS_OUT, "w", encoding="utf-8") as fh:
        fh.write(header + "\n\n".join(emitted_blocks) + footer)

    # native name (EMERALD) -> gamedata key
    native_to_key = {name.lower(): key for key, name in curated.items()}
    # Fallbacks when Poller uses a name not in 3ds.toml `name =`
    native_to_key.update({
        "emerald": "emerald_retail",
        "emerald_retail": "emerald_retail",
        "unbound": "unbound_with_dex",
        "unbound_with_dex": "unbound_with_dex",
        "leafgreen": "leafgreen_rev0",
        "firered": "firered_rev0",
    })

    poller = open(POLLER, encoding="utf-8").read()
    identity = parse_poller_identity(poller)
    id_set = set(ids)
    resolved: dict[str, str] = {}
    for h, native_key in identity.items():
        k = native_to_key.get(native_key, native_key)
        if k not in id_set:
            # try prefix match
            cands = [i for i in ids if i == k or i.startswith(k + "_")]
            if len(cands) == 1:
                k = cands[0]
            elif k + "_v4_1" in id_set:
                k = k + "_v4_1"
            elif k + "_v3_2" in id_set:
                k = k + "_v3_2"
        if k in id_set:
            resolved[h] = k
        else:
            print(f"warn: sha1 {h[:12]}… -> {native_key} not in emitted configs", file=sys.stderr)

    # Deduplicate SHA-1 pins (Poller can list the same hash twice across branches).
    sha_seen: dict[str, str] = {}
    sha_collisions: list[str] = []
    for h, k in sorted(resolved.items()):
        if h in sha_seen and sha_seen[h] != k:
            sha_collisions.append(f"{h[:12]}…: {sha_seen[h]} vs {k}")
        elif h not in sha_seen:
            sha_seen[h] = k
    if sha_collisions:
        raise SystemExit(
            "gen_ios_companion: duplicate sha1 pins (would crash iOS Dictionary init):\n  "
            + "\n  ".join(sha_collisions)
        )

    put_sha = "\n".join(
        f'    put("{h}", "{k}")' for h, k in sorted(sha_seen.items())
    )
    id_swift = f"""\
// Generated by scripts/gen_ios_companion.py from Poller.kt SHA-1 pins — do not edit by hand.
import Foundation

enum RomIdentityGen {{
  /// GPIO-masked whole-file SHA-1 → gamedata config id (exact companion profile).
  /// Built via `put` so duplicate pins never trap Swift Dictionary literals.
  static let sha1ToConfigId: [String: String] = makeSha1Map()

  private static func makeSha1Map() -> [String: String] {{
    var d: [String: String] = [:]
    d.reserveCapacity({len(sha_seen)})
    func put(_ sha1: String, _ configId: String) {{
      if d[sha1] == nil {{ d[sha1] = configId }}
    }}
{put_sha}
    return d
  }}
}}
"""
    with open(IDENTITY_OUT, "w", encoding="utf-8") as fh:
        fh.write(id_swift)

    print(
        f"gen_ios_companion: {len(ids)} configs, {len(resolved)} sha1 pins -> "
        f"{os.path.relpath(CONFIGS_OUT, ROOT)}, {os.path.relpath(IDENTITY_OUT, ROOT)}"
    )


if __name__ == "__main__":
    try:
        main()
    except gd.GameDataError as e:
        sys.exit(f"gen_ios_companion: {e}")
