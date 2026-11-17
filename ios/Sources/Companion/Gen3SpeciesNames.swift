import Foundation

/// Name lookups for the Gen 3 companion. Tables live in `Gen3TableBlobs` ("id|name" lines, generated from the
/// upstream Kotlin tables by scripts/gen_gen3_tables.py) and are parsed once, lazily.
enum Gen3Names {
  private static func parse(_ blob: String) -> [Int: String] {
    var out: [Int: String] = [:]
    out.reserveCapacity(blob.count / 12)
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"), let id = Int(line[line.startIndex..<bar]) else { continue }
      out[id] = String(line[line.index(after: bar)...])
    }
    return out
  }

  /// Retail FireRed / Emerald internal species ids (1...411; 277+ are Hoenn's in-game order).
  static let speciesRetail: [Int: String] = parse(Gen3TableBlobs.speciesRetail)
  /// Unbound's expanded species table.
  static let speciesUnbound: [Int: String] = parse(Gen3TableBlobs.speciesUnbound)
  /// National Dex order (1...1025); used for Pokédex flags (bit n-1 = National #n).
  static let speciesNational: [Int: String] = parse(Gen3TableBlobs.speciesNational)
  /// Modern Emerald v3.6 (Emerald ids + extras through 461).
  static let speciesModernEmerald: [Int: String] = parse(Gen3TableBlobs.speciesModernEmerald)
  /// Seaglass game-dex # → National/species id (Hoenn-first numbering).
  private static let seaglassDexNational: [Int: Int] = {
    var out: [Int: Int] = [:]
    for line in Gen3TableBlobs.seaglassDexNational.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"),
            let dex = Int(line[line.startIndex..<bar]),
            let nat = Int(line[line.index(after: bar)...]) else { continue }
      out[dex] = nat
    }
    return out
  }()

  /// Modern Emerald Pokédex flag index (its NATIONAL_DEX_*) → internal species id.
  private static let modernEmeraldDexSpecies: [Int: Int] = {
    var out: [Int: Int] = [:]
    for line in Gen3TableBlobs.modernEmeraldDexSpecies.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"),
            let dex = Int(line[line.startIndex..<bar]),
            let species = Int(line[line.index(after: bar)...]) else { continue }
      out[dex] = species
    }
    return out
  }()

  /// Internal species id for a companion dex cell (flag index → species), when the ROM needs it.
  static func speciesIdForDexNumber(_ n: Int, configId: String) -> Int {
    switch configId {
    case "modern_emerald":
      return modernEmeraldDexSpecies[n] ?? n
    case "emerald_seaglass":
      // Seaglass dex cells are already Hoenn-first; map to National for lookups that need it.
      return seaglassDexNational[n] ?? n
    default:
      return n
    }
  }

  static let itemsRetail: [Int: String] = parse(Gen3TableBlobs.itemsRetail)
  static let itemsUnbound: [Int: String] = parse(Gen3TableBlobs.itemsUnbound)
  /// Emerald Seaglass / pokeemerald-expansion item ids (different from retail).
  static let itemsSeaglass: [Int: String] = parse(Gen3TableBlobs.itemsSeaglass)
  /// Heart and Soul / Crystal Enhanced expansion item ids.
  static let itemsHns: [Int: String] = parse(Gen3TableBlobs.itemsHns)
  static let itemsModernEmerald: [Int: String] = parse(Gen3TableBlobs.itemsModernEmerald)
  static let movesRetail: [Int: String] = parse(Gen3TableBlobs.movesRetail)
  static let movesUnbound: [Int: String] = parse(Gen3TableBlobs.movesUnbound)
  static let movesSeaglass: [Int: String] = parse(Gen3TableBlobs.movesSeaglass)
  static let movesHns: [Int: String] = parse(Gen3TableBlobs.movesHns)
  static let movesModernEmerald: [Int: String] = parse(Gen3TableBlobs.movesModernEmerald)
  /// Heart and Soul / Crystal Enhanced species names (National-order expanded).
  static let speciesHns: [Int: String] = parse(Gen3TableBlobs.speciesHns)
  static let mapSecFireRed: [Int: String] = parse(Gen3TableBlobs.mapSecFireRed)
  static let mapSecEmerald: [Int: String] = parse(Gen3TableBlobs.mapSecEmerald)
  static let mapSecUnbound: [Int: String] = parse(Gen3TableBlobs.mapSecUnbound)
  static let mapSecModernEmerald: [Int: String] = parse(Gen3TableBlobs.mapSecModernEmerald)
  static let mapSecSoulGold: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecSoulGold)
  static let mapSecHns: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecHns)
  static let mapSecRowe: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecRowe)
  static let mapSecLazarus: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecLazarus)
  static let mapSecTeamRocket: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecTeamRocket)
  static let mapSecTeamRocketV3: [Int: String] = parse(Gen3HackMapSecBlobs.mapSecTeamRocketV3)

  private static let speciesYellow: [Int: String] = parse(Gen3BattleBlobs.speciesNamesYellow)
  private static let speciesCrystal: [Int: String] = parse(Gen3BattleBlobs.speciesNamesCrystal)
  private static let speciesPolished: [Int: String] = parse(Gen3BattleBlobs.speciesNamesPolished)

  static func species(_ id: Int, tables: Gen3Tables) -> String {
    switch tables {
    case .national:
      if id == 0xFD { return "Egg" }
      return nationalName(id)
    case .hns:
      if id == 0xFD { return "Egg" }
      return speciesHns[id] ?? speciesNational[id] ?? "Species #\(id)"
    case .yellow:
      if id == 0xFD { return "Egg" }
      return speciesYellow[id] ?? nationalName(id)
    case .crystal:
      if id == 0xFD { return "Egg" }
      return speciesCrystal[id] ?? nationalName(id)
    case .polished:
      if id == 0xFF || id == 0xFD { return "Egg" }
      return speciesPolished[id] ?? nationalName(id)
    case .unbound:
      // Prefer Unbound’s table; fall back to retail FR ids then National for later gens.
      return speciesUnbound[id] ?? speciesRetail[id] ?? speciesNational[id] ?? "Species #\(id)"
    case .modernEmerald:
      if id == 462 { return "Egg" }
      return speciesModernEmerald[id] ?? speciesRetail[id] ?? "Species #\(id)"
    case .retail:
      if id == 412 { return "Egg" }
      return speciesRetail[id] ?? "Species #\(id)"
    }
  }

  static func item(_ id: Int, tables: Gen3Tables) -> String {
    if id == 0 { return "—" }
    switch tables {
    case .national:
      return itemsSeaglass[id] ?? itemsRetail[id] ?? "Item #\(id)"
    case .hns:
      return itemsHns[id] ?? itemsSeaglass[id] ?? itemsRetail[id] ?? "Item #\(id)"
    case .unbound:
      return itemsUnbound[id] ?? itemsRetail[id] ?? "Item #\(id)"
    case .modernEmerald:
      return itemsModernEmerald[id] ?? itemsRetail[id] ?? "Item #\(id)"
    case .retail:
      return itemsRetail[id] ?? "Item #\(id)"
    case .yellow, .crystal, .polished:
      // GB/GBC item names aren't fully ported yet; keep a stable placeholder.
      return itemsRetail[id] ?? "Item #\(id)"
    }
  }

  /// Retail bag-icon id for an item under the active tables (Unbound remaps many item numbers).
  static func itemIconId(_ id: Int, tables: Gen3Tables) -> Int {
    guard id > 0 else { return 0 }
    if tables != .unbound && tables != .modernEmerald && tables != .hns && tables != .national {
      return id
    }
    if itemsRetail[id] != nil { return id }
    let name = item(id, tables: tables)
    if name.hasPrefix("Item #") { return id }
    return retailItemByNormalizedName[normalizeSpeciesName(name)] ?? id
  }

  static func move(_ id: Int, tables: Gen3Tables) -> String {
    if id == 0 { return "—" }
    switch tables {
    case .national:
      return movesSeaglass[id] ?? movesRetail[id] ?? "Move #\(id)"
    case .hns:
      return movesHns[id] ?? movesSeaglass[id] ?? movesRetail[id] ?? "Move #\(id)"
    case .unbound:
      return movesUnbound[id] ?? movesRetail[id] ?? "Move #\(id)"
    case .modernEmerald:
      return movesModernEmerald[id] ?? movesRetail[id] ?? "Move #\(id)"
    case .retail:
      return movesRetail[id] ?? "Move #\(id)"
    case .yellow:
      return Gen3BattleData.moveInfo(id, tables: .yellow)?.name ?? movesRetail[id] ?? "Move #\(id)"
    case .crystal:
      return Gen3BattleData.moveInfo(id, tables: .crystal)?.name ?? movesRetail[id] ?? "Move #\(id)"
    case .polished:
      return Gen3BattleData.moveInfo(id, tables: .polished)?.name ?? "Move #\(id)"
    }
  }

  /// MAPSEC name. Retail FireRed's header ids start at 0x58 (Kanto), Emerald's at 0.
  /// Hack ROMs use their own region-map tables (SoulGold / HnS / ROWE / Team Rocket).
  static func mapSec(_ id: Int, game: Gen3Game, tables: Gen3Tables = .retail, configId: String = "") -> String? {
    switch configId {
    case "heart_and_soul", "crystal_enhanced":
      return mapSecHns[id] ?? mapSecEmerald[id]
    case "soulgold", "soulgold_v1_2", "soulgold_v1_2b", "soulgold_v1_2c", "soulgold_v1_2_1":
      return mapSecSoulGold[id]
    case "rowe":
      return mapSecRowe[id] ?? mapSecEmerald[id]
    case "lazarus":
      return mapSecLazarus[id] ?? mapSecEmerald[id]
    case "team_rocket_v3":
      return mapSecTeamRocketV3[id] ?? mapSecEmerald[id]
    case "team_rocket":
      return mapSecTeamRocket[id] ?? mapSecFireRed[id]
    default:
      break
    }
    if tables == .modernEmerald {
      return mapSecModernEmerald[id] ?? mapSecEmerald[id]
    }
    switch game {
    case .emerald: return mapSecEmerald[id]
    case .fireRed: return mapSecFireRed[id]
    case .unbound: return mapSecUnbound[id] ?? mapSecFireRed[id]
    }
  }

  static func nationalName(_ n: Int) -> String {
    speciesNational[n] ?? "#\(n)"
  }

  /// Map a game's Pokédex flag index to the National Dex number used for icons.
  /// Retail / CFRU / Gen 4–5 bits are already National; Seaglass is Hoenn-first; ME uses its own NATIONAL_DEX_*.
  static func nationalForDexNumber(_ n: Int, configId: String) -> Int {
    switch configId {
    case "emerald_seaglass":
      // Seaglass Hoenn-first dex (#007 = Mudkip, not Squirtle).
      return seaglassDexNational[n] ?? n
    case "modern_emerald":
      // Flag bit = ME NATIONAL_DEX_*; resolve species then real National for icons.
      let sid = modernEmeraldDexSpecies[n] ?? n
      return nationalNumber(species: sid, tables: .modernEmerald) ?? n
    case "polished_crystal":
      return nationalNumber(species: n, tables: .polished) ?? n
    case "crystal", "gold", "silver":
      return n  // Gen 2 species id == National for 1…251
    case "yellow", "red", "blue", "green":
      return n
    default:
      // Radical Red / Unbound / SoulGold / retail / DS: flag index is National.
      return n
    }
  }

  static func dexDisplayName(_ n: Int, configId: String) -> String {
    switch configId {
    case "modern_emerald":
      return species(speciesIdForDexNumber(n, configId: configId), tables: .modernEmerald)
    case "polished_crystal":
      return species(n, tables: .polished)
    case "crystal", "gold", "silver":
      return species(n, tables: .crystal)
    case "yellow", "red", "blue", "green":
      return species(n, tables: .yellow)
    case "unbound", "unbound_with_dex", "unbound_fr":
      // Unbound dex flags are National; prefer National names (Unbound table is species-id keyed).
      return nationalName(n)
    case "heart_and_soul", "crystal_enhanced":
      return species(n, tables: .hns)
    default:
      return nationalName(nationalForDexNumber(n, configId: configId))
    }
  }

  /// Reverse map of National Dex names → numbers (for icon lookup from retail / Unbound ids).
  private static let nationalByName: [String: Int] = {
    var out: [String: Int] = [:]
    out.reserveCapacity(speciesNational.count)
    for (id, name) in speciesNational {
      out[name.uppercased()] = id
    }
    return out
  }()

  private static let nationalByNormalizedName: [String: Int] = {
    var out: [String: Int] = [:]
    out.reserveCapacity(speciesNational.count)
    for (id, name) in speciesNational {
      out[normalizeSpeciesName(name)] = id
    }
    return out
  }()

  private static let retailItemByNormalizedName: [String: Int] = {
    var out: [String: Int] = [:]
    out.reserveCapacity(itemsRetail.count)
    for (id, name) in itemsRetail {
      out[normalizeSpeciesName(name)] = id
    }
    return out
  }()

  /// Unbound truncates some names in its species table — map to National spellings for icons.
  private static let unboundNameAliases: [String: String] = [
    "FLETCHINDR": "FLETCHINDER",
    "CRABMINBLE": "CRABOMINABLE",
    "BLACPHALON": "BLACEPHALON",
    "CORVSQUIRE": "CORVISQUIRE",
    "CORVKNIGHT": "CORVIKNIGHT",
    "BARASKEWDA": "BARRASKEWDA",
    "CENTSKORCH": "CENTISKORCH",
    "POLTEGEIST": "POLTEAGEIST",
    "STONJORNER": "STONJOURNER",
    "BASCULEGON": "BASCULEGION",
    "FARFETCHD": "FARFETCHD",
    "SIRFETCHD": "SIRFETCHD",
  ]

  private static func normalizeSpeciesName(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    var out = ""
    out.reserveCapacity(folded.count)
    for ch in folded {
      switch ch {
      case "a"..."z", "A"..."Z", "0"..."9": out.append(ch)
      default: break // drop spaces, punctuation, apostrophes
      }
    }
    return out.uppercased()
  }

  /// Best-effort National Dex number for a species id under the active name tables (sprite lookup).
  static func nationalNumber(species id: Int, tables: Gen3Tables) -> Int? {
    guard id > 0 else { return nil }
    if id == 0xFD || id == 0xFF || (tables == .retail && id == 412) { return nil } // Egg
    if tables == .modernEmerald, id == 462 { return nil }
    if tables == .unbound, speciesUnbound[id] == "Egg" || speciesUnbound[id] == "Bad Egg" {
      return nil
    }
    switch tables {
    case .national, .yellow, .crystal:
      return speciesNational[id] != nil || id <= 1025 ? id : nil
    case .hns:
      // HnS / Crystal Enhanced use National-order species ids (with extras beyond 1025).
      if speciesNational[id] != nil || id <= 1025 { return id }
      let raw = species(id, tables: tables)
      if raw.hasPrefix("Species #") || raw == "Egg" { return nil }
      if let hit = nationalNumber(matchingName: raw) { return hit }
      if let space = raw.lastIndex(of: " ") {
        let base = String(raw[..<space])
        if let hit = nationalNumber(matchingName: base) { return hit }
      }
      return id <= 2000 ? id : nil
    case .polished:
      // Polished's early ids match National; forms / later entries resolve by name.
      if id <= 251, speciesNational[id] != nil { return id }
      fallthrough
    case .retail, .unbound, .modernEmerald:
      let raw = species(id, tables: tables)
      if raw.hasPrefix("Species #") || raw == "Egg" { return nil }
      if let hit = nationalNumber(matchingName: raw) { return hit }
      // Unown B / Deoxys Attack / etc. → base species icon.
      if let space = raw.lastIndex(of: " ") {
        let base = String(raw[..<space])
        if let hit = nationalNumber(matchingName: base) { return hit }
      }
      return nil
    }
  }

  private static func nationalNumber(matchingName raw: String) -> Int? {
    if let exact = nationalByName[raw.uppercased()] { return exact }
    let norm = normalizeSpeciesName(raw)
    if let alias = unboundNameAliases[norm], let hit = nationalByNormalizedName[alias] {
      return hit
    }
    return nationalByNormalizedName[norm]
  }
}
