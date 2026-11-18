#!/usr/bin/env python3
"""Generate Gen3BattleBlobs.swift + extend Gen3TableBlobs with Seaglass item/move names.

Emits compact id|… blobs parsed lazily at runtime (same style as gen_gen3_tables.py).
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "upstream/app/src/main/kotlin/com/pokedaisy/app/companion/data"
OUT = ROOT / "ios/Sources/Companion"

NAME_RE = re.compile(r'^\s*(\d+) to "((?:[^"\\]|\\.)*)"', re.M)
MOVE_RE = re.compile(r'^\s*(\d+) to MoveInfo\("((?:[^"\\]|\\.)*)",\s*(\d+),\s*(\d+)\)', re.M)
TYPES_RE = re.compile(r'^\s*(\d+) to SpeciesTypes\((\d+),\s*(\d+)\)', re.M)
CHART_RE = re.compile(r'^\s*(\d+) to (\d+),?', re.M)
# type names maps use `N to "Name"` — same as NAME_RE


def parse_map(path, rx):
    text = (DATA / path).read_text()
    return list(rx.finditer(text))


def blob(name, lines):
    body = "\n".join(lines)
    return f'  static let {name}: String = #"""\n{body}\n"""#\n'


def name_blob(name, path):
    rows = []
    for m in parse_map(path, NAME_RE):
        rows.append(f"{m.group(1)}|{m.group(2).replace(chr(92)+chr(34), chr(34))}")
    rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    return blob(name, rows), len(rows)


def move_blob(name, path):
    rows = []
    for m in parse_map(path, MOVE_RE):
        rows.append(f"{m.group(1)}|{m.group(2).replace(chr(92)+chr(34), chr(34))}|{m.group(3)}|{m.group(4)}")
    rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    return blob(name, rows), len(rows)


def types_blob(name, path):
    rows = []
    for m in parse_map(path, TYPES_RE):
        rows.append(f"{m.group(1)}|{m.group(2)}|{m.group(3)}")
    rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    return blob(name, rows), len(rows)


def _map_chunk(text, var_name):
    """Slice from `val var_name` through the closing `)` of its mapOf (plain or `by lazy`)."""
    marker = f"val {var_name}"
    i = text.find(marker)
    if i < 0:
        raise SystemExit(f"missing {var_name}")
    chunk = text[i:]
    # Prefer the first mapOf's closing paren (may be indented: `    )`).
    m = re.search(r"\nmapOf\(", chunk)
    start = m.start() if m else 0
    rest = chunk[start:]
    end = re.search(r"\n\s*\)\s*(?:\n|$)", rest)
    if not end:
        raise SystemExit(f"no mapOf close for {var_name}")
    return rest[: end.end()]


def chart_blob(name, path, var_name):
    """Parse `val var_name: Map<Int, Int> = mapOf(` (or by lazy) block only."""
    text = (DATA / path).read_text()
    chunk = _map_chunk(text, var_name)
    rows = []
    for m in CHART_RE.finditer(chunk):
        # skip type-name entries that look like `1 to "Normal"` — CHART_RE won't match quotes
        rows.append(f"{m.group(1)}|{m.group(2)}")
    rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    return blob(name, rows), len(rows)


def type_names_blob(name, path, var_name):
    text = (DATA / path).read_text()
    chunk = _map_chunk(text, var_name)
    rows = []
    for m in NAME_RE.finditer(chunk):
        rows.append(f"{m.group(1)}|{m.group(2)}")
    rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    return blob(name, rows), len(rows)


def main():
    # --- Seaglass item names into Gen3TableBlobs (append / regenerate names file section) ---
    items_sg, n_items_sg = name_blob("itemsSeaglass", "ItemNamesSeaglass.kt")
    moves_sg_names = []
    for m in parse_map("MoveDataSeaglass.kt", MOVE_RE):
        moves_sg_names.append(f"{m.group(1)}|{m.group(2).replace(chr(92)+chr(34), chr(34))}")
    moves_sg_names.sort(key=lambda s: int(s.split("|", 1)[0]))
    moves_sg_name_blob = blob("movesSeaglass", moves_sg_names)

    # Patch Gen3TableBlobs: regenerate full file via existing script first, then append seaglass extras.
    import subprocess
    subprocess.check_call(["python3", str(ROOT / "scripts/gen_gen3_tables.py")])
    blobs_path = OUT / "Gen3TableBlobs.swift"
    text = blobs_path.read_text()
    # Preserve hand-maintained dex remap blobs (not in gen_gen3_tables.py).
    def take_blob(name: str) -> str:
        nonlocal text
        m = re.search(
            rf'(  static let {name}: String = #"""\n.*?"""#\n)',
            text, re.S,
        )
        if not m:
            return ""
        blob = m.group(1)
        text = text[: m.start()] + text[m.end() :]
        return blob

    preserved = []
    for name in ("seaglassDexNational", "modernEmeraldDexSpecies"):
        b = take_blob(name)
        if not b:
            try:
                head = subprocess.check_output(
                    ["git", "show", f"HEAD:ios/Sources/Companion/Gen3TableBlobs.swift"],
                    cwd=str(ROOT), text=True,
                )
                m = re.search(
                    rf'(  static let {name}: String = #"""\n.*?"""#\n)',
                    head, re.S,
                )
                if m:
                    b = m.group(1)
            except Exception:
                pass
        if b:
            preserved.append(b)

    text = text.rstrip()
    if text.endswith("}"):
        text = text[:-1]
    if "itemsSeaglass" not in text:
        text += items_sg
        text += moves_sg_name_blob
    for b in preserved:
        # Avoid duplicating if regen left the blob in place.
        name = re.search(r"static let (\w+):", b).group(1)
        if name not in text:
            text += b
    text += "}\n"
    blobs_path.write_text(text)

    # --- Battle blobs ---
    counts = {}
    parts = ["// Generated by scripts/gen_battle_tables.py from upstream/ Kotlin tables. Do not hand-edit.\n\n"]
    parts.append("enum Gen3BattleBlobs {\n")

    b, n = move_blob("movesRetail", "MoveData.kt"); parts.append(b); counts["movesRetail"] = n
    b, n = move_blob("movesSeaglass", "MoveDataSeaglass.kt"); parts.append(b); counts["movesSeaglass"] = n
    b, n = move_blob("movesUnbound", "MoveDataUnbound.kt"); parts.append(b); counts["movesUnbound"] = n
    b, n = move_blob("movesModernEmerald", "ModernEmeraldGen.kt"); parts.append(b); counts["movesModernEmerald"] = n
    b, n = move_blob("movesYellow", "MoveDataYellow.kt"); parts.append(b); counts["movesYellow"] = n
    b, n = move_blob("movesCrystal", "MoveDataCrystal.kt"); parts.append(b); counts["movesCrystal"] = n
    b, n = move_blob("movesPolished", "MoveDataPolishedCrystal.kt"); parts.append(b); counts["movesPolished"] = n
    b, n = move_blob("movesPrism", "MoveDataPrism.kt"); parts.append(b); counts["movesPrism"] = n
    b, n = move_blob("movesHns", "MoveDataHns.kt"); parts.append(b); counts["movesHns"] = n
    # Per-hack move tables (ActiveTables.kt) — keep in sync with Gen3BattleData TipProfile.
    for swift_name, kt in (
        ("movesWishes", "MoveDataWishes.kt"),
        ("movesLazarus", "MoveDataLazarus.kt"),
        ("movesRowe", "MoveDataRowe.kt"),
        ("movesSoulGold", "MoveDataSoulGold.kt"),
        ("movesRadicalRed", "MoveDataRadicalRed.kt"),
        ("movesTeamRocketV3", "MoveDataTeamRocketV3.kt"),
        ("movesTmt2", "MoveDataTmt2.kt"),
    ):
        b, n = move_blob(swift_name, kt); parts.append(b); counts[swift_name] = n

    b, n = types_blob("speciesTypesRetail", "SpeciesTypes.kt"); parts.append(b); counts["speciesTypesRetail"] = n
    b, n = types_blob("speciesTypesSeaglass", "SpeciesTypesSeaglass.kt"); parts.append(b); counts["speciesTypesSeaglass"] = n
    b, n = types_blob("speciesTypesUnbound", "SpeciesTypesUnbound.kt"); parts.append(b); counts["speciesTypesUnbound"] = n
    # Classic preset (MODERN TYPES / FAIRY TYPE off) — same resolution as ModernEmerald.speciesTypes(Settings()).
    me_text = (DATA / "ModernEmeraldGen.kt").read_text()

    def me_types_map(var_name):
        chunk = _map_chunk(me_text, var_name)
        out = {}
        for m in TYPES_RE.finditer(chunk):
            out[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
        return out

    me_base = me_types_map("speciesTypesModernEmerald")
    me_classic = me_types_map("classicTypesModernEmerald")
    me_no_fairy = me_types_map("noFairyTypesModernEmerald")
    me_resolved = {}
    for sid, pair in me_base.items():
        if sid in me_classic:
            me_resolved[sid] = me_classic[sid]
        elif sid in me_no_fairy:
            me_resolved[sid] = me_no_fairy[sid]
        else:
            me_resolved[sid] = pair
    me_type_rows = [f"{k}|{v[0]}|{v[1]}" for k, v in sorted(me_resolved.items())]
    parts.append(blob("speciesTypesModernEmerald", me_type_rows))
    counts["speciesTypesModernEmerald"] = len(me_type_rows)
    b, n = types_blob("speciesTypesYellow", "SpeciesTypesYellow.kt"); parts.append(b); counts["speciesTypesYellow"] = n
    b, n = types_blob("speciesTypesCrystal", "SpeciesTypesCrystal.kt"); parts.append(b); counts["speciesTypesCrystal"] = n
    b, n = types_blob("speciesTypesPolished", "SpeciesTypesPolishedCrystal.kt"); parts.append(b); counts["speciesTypesPolished"] = n
    b, n = types_blob("speciesTypesPrism", "SpeciesTypesPrism.kt"); parts.append(b); counts["speciesTypesPrism"] = n
    b, n = types_blob("speciesTypesHns", "SpeciesTypesHns.kt"); parts.append(b); counts["speciesTypesHns"] = n
    for swift_name, kt in (
        ("speciesTypesWishes", "SpeciesTypesWishes.kt"),
        ("speciesTypesLazarus", "SpeciesTypesLazarus.kt"),
        ("speciesTypesRowe", "SpeciesTypesRowe.kt"),
        ("speciesTypesSoulGold", "SpeciesTypesSoulGold.kt"),
        ("speciesTypesRadicalRed", "SpeciesTypesRadicalRed.kt"),
        ("speciesTypesTeamRocketV3", "SpeciesTypesTeamRocketV3.kt"),
        ("speciesTypesTmt2", "SpeciesTypesTmt2.kt"),
    ):
        b, n = types_blob(swift_name, kt); parts.append(b); counts[swift_name] = n
    # National Dex order types (Gen 4/5 companion + Platinum / B2W2 tips) from Black's personal table.
    black_text = (DATA / "Gen5TablesBlack.kt").read_text()
    black_chunk = _map_chunk(black_text, "speciesTypesBlack")
    black_rows = [f"{m.group(1)}|{m.group(2)}|{m.group(3)}" for m in TYPES_RE.finditer(black_chunk)]
    black_rows.sort(key=lambda s: int(s.split("|", 1)[0]))
    parts.append(blob("speciesTypesNational", black_rows))
    counts["speciesTypesNational"] = len(black_rows)

    # Vanilla type names (inline from TypeChartUtil)
    vanilla_names = "\n".join([
        "0|Normal", "1|Fighting", "2|Flying", "3|Poison", "4|Ground",
        "5|Rock", "6|Bug", "7|Ghost", "8|Steel", "9|???",
        "10|Fire", "11|Water", "12|Grass", "13|Electric", "14|Psychic",
        "15|Ice", "16|Dragon", "17|Dark",
    ])
    parts.append(blob("typeNamesRetail", vanilla_names.split("\n")))
    # Modern Emerald: Fairy as type 18.
    me_type_names = vanilla_names + "\n18|Fairy"
    parts.append(blob("typeNamesModernEmerald", me_type_names.split("\n")))
    b, n = type_names_blob("typeNamesSeaglass", "TypeChartHns.kt", "typeNamesHns"); parts.append(b); counts["typeNamesSeaglass"] = n
    b, n = type_names_blob("typeNamesUnbound", "TypeChartUnbound.kt", "typeNamesUnbound"); parts.append(b); counts["typeNamesUnbound"] = n
    b, n = type_names_blob("typeNamesYellow", "TypeChartYellow.kt", "typeNamesYellow"); parts.append(b); counts["typeNamesYellow"] = n
    b, n = type_names_blob("typeNamesCrystal", "TypeChartCrystal.kt", "typeNamesCrystal"); parts.append(b); counts["typeNamesCrystal"] = n
    b, n = type_names_blob("typeNamesPolished", "TypeChartPolishedCrystal.kt", "typeNamesPolishedCrystal"); parts.append(b); counts["typeNamesPolished"] = n
    b, n = type_names_blob("typeNamesPrism", "TypeChartPrism.kt", "typeNamesPrism"); parts.append(b); counts["typeNamesPrism"] = n
    b, n = type_names_blob("typeNamesHns", "TypeChartHns.kt", "typeNamesHns"); parts.append(b); counts["typeNamesHns"] = n
    for swift_name, kt, var in (
        ("typeNamesWishes", "TypeChartWishes.kt", "typeNamesWishes"),
        ("typeNamesLazarus", "TypeChartLazarus.kt", "typeNamesLazarus"),
        ("typeNamesRowe", "TypeChartRowe.kt", "typeNamesRowe"),
        ("typeNamesSoulGold", "TypeChartSoulGold.kt", "typeNamesSoulGold"),
        ("typeNamesTeamRocketV3", "TypeChartTeamRocketV3.kt", "typeNamesTeamRocketV3"),
        ("typeNamesTmt2", "TypeChartTmt2.kt", "typeNamesTmt2"),
    ):
        b, n = type_names_blob(swift_name, kt, var); parts.append(b); counts[swift_name] = n

    b, n = chart_blob("typeChartRetail", "TypeChart.kt", "typeEffectiveness"); parts.append(b); counts["typeChartRetail"] = n
    b, n = chart_blob("typeChartSeaglass", "TypeChartHns.kt", "typeEffectivenessHns"); parts.append(b); counts["typeChartSeaglass"] = n
    b, n = chart_blob("typeChartHns", "TypeChartHns.kt", "typeEffectivenessHns"); parts.append(b); counts["typeChartHns"] = n
    b, n = chart_blob("typeChartUnbound", "TypeChartUnbound.kt", "typeEffectivenessUnbound"); parts.append(b); counts["typeChartUnbound"] = n
    # Classic preset uses Gen VI+ chart; "Modern" chart is the alternate.
    b, n = chart_blob("typeChartModernEmerald", "ModernEmeraldGen.kt", "typeChartGen6ModernEmerald"); parts.append(b); counts["typeChartModernEmerald"] = n
    b, n = chart_blob("typeChartYellow", "TypeChartYellow.kt", "typeEffectivenessYellow"); parts.append(b); counts["typeChartYellow"] = n
    b, n = chart_blob("typeChartCrystal", "TypeChartCrystal.kt", "typeEffectivenessCrystal"); parts.append(b); counts["typeChartCrystal"] = n
    b, n = chart_blob("typeChartPolished", "TypeChartPolishedCrystal.kt", "typeEffectivenessPolishedCrystal"); parts.append(b); counts["typeChartPolished"] = n
    b, n = chart_blob("typeChartPrism", "TypeChartPrism.kt", "typeEffectivenessPrism"); parts.append(b); counts["typeChartPrism"] = n
    for swift_name, kt, var in (
        ("typeChartWishes", "TypeChartWishes.kt", "typeEffectivenessWishes"),
        ("typeChartLazarus", "TypeChartLazarus.kt", "typeEffectivenessLazarus"),
        ("typeChartRowe", "TypeChartRowe.kt", "typeEffectivenessRowe"),
        ("typeChartSoulGold", "TypeChartSoulGold.kt", "typeEffectivenessSoulGold"),
        ("typeChartTeamRocketV3", "TypeChartTeamRocketV3.kt", "typeEffectivenessTeamRocketV3"),
        ("typeChartTmt2", "TypeChartTmt2.kt", "typeEffectivenessTmt2"),
    ):
        b, n = chart_blob(swift_name, kt, var); parts.append(b); counts[swift_name] = n
    # Species display names for GB/GBC suggestion chips (National-aligned Yellow/Crystal; Polished's own ids).
    b, n = name_blob("speciesNamesYellow", "SpeciesNamesYellow.kt"); parts.append(b); counts["speciesNamesYellow"] = n
    b, n = name_blob("speciesNamesCrystal", "SpeciesNamesCrystal.kt"); parts.append(b); counts["speciesNamesCrystal"] = n
    b, n = name_blob("speciesNamesPolished", "SpeciesNamesPolishedCrystal.kt"); parts.append(b); counts["speciesNamesPolished"] = n
    b, n = name_blob("speciesNamesPrism", "SpeciesNamesPrism.kt"); parts.append(b); counts["speciesNamesPrism"] = n
    b, n = name_blob("itemNamesPrism", "ItemNamesPrism.kt"); parts.append(b); counts["itemNamesPrism"] = n
    b, n = name_blob("speciesNamesHns", "SpeciesNamesHns.kt"); parts.append(b); counts["speciesNamesHns"] = n

    parts.append("}\n")
    (OUT / "Gen3BattleBlobs.swift").write_text("".join(parts))
    print("Gen3BattleBlobs:", counts)
    print("itemsSeaglass:", n_items_sg, "movesSeaglass names:", len(moves_sg_names))

    # HnS / Crystal Enhanced name tables into Gen3TableBlobs (species + items + moves).
    items_hns, n_items_hns = name_blob("itemsHns", "ItemNamesHns.kt")
    moves_hns_names = []
    for m in parse_map("MoveDataHns.kt", MOVE_RE):
        moves_hns_names.append(f"{m.group(1)}|{m.group(2).replace(chr(92)+chr(34), chr(34))}")
    moves_hns_names.sort(key=lambda s: int(s.split("|", 1)[0]))
    moves_hns_name_blob = blob("movesHns", moves_hns_names)
    species_hns, n_sp_hns = name_blob("speciesHns", "SpeciesNamesHns.kt")
    blobs_path = OUT / "Gen3TableBlobs.swift"
    t = blobs_path.read_text()
    for name, chunk in (
        ("itemsHns", items_hns),
        ("movesHns", moves_hns_name_blob),
        ("speciesHns", species_hns),
    ):
        if f"static let {name}:" in t:
            t = re.sub(
                rf"  static let {name}: String = #\"\"\".*?\"\"\"#\n",
                chunk,
                t,
                count=1,
                flags=re.S,
            )
        else:
            if t.rstrip().endswith("}"):
                t = t.rstrip()[:-1] + chunk + "}\n"
            else:
                t += chunk
    blobs_path.write_text(t)
    print("HnS table blobs:", n_items_hns, "items,", len(moves_hns_names), "moves,", n_sp_hns, "species")


if __name__ == "__main__":
    main()
