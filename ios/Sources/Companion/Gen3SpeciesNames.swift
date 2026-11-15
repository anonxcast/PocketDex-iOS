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

  static let itemsRetail: [Int: String] = parse(Gen3TableBlobs.itemsRetail)
  static let itemsUnbound: [Int: String] = parse(Gen3TableBlobs.itemsUnbound)
  /// Emerald Seaglass / pokeemerald-expansion item ids (different from retail).
  static let itemsSeaglass: [Int: String] = parse(Gen3TableBlobs.itemsSeaglass)
  static let movesRetail: [Int: String] = parse(Gen3TableBlobs.movesRetail)
  static let movesUnbound: [Int: String] = parse(Gen3TableBlobs.movesUnbound)
  static let movesSeaglass: [Int: String] = parse(Gen3TableBlobs.movesSeaglass)
  static let mapSecFireRed: [Int: String] = parse(Gen3TableBlobs.mapSecFireRed)
  static let mapSecEmerald: [Int: String] = parse(Gen3TableBlobs.mapSecEmerald)
  static let mapSecUnbound: [Int: String] = parse(Gen3TableBlobs.mapSecUnbound)

  private static let speciesYellow: [Int: String] = parse(Gen3BattleBlobs.speciesNamesYellow)
  private static let speciesCrystal: [Int: String] = parse(Gen3BattleBlobs.speciesNamesCrystal)
  private static let speciesPolished: [Int: String] = parse(Gen3BattleBlobs.speciesNamesPolished)

  static func species(_ id: Int, tables: Gen3Tables) -> String {
    switch tables {
    case .national:
      if id == 0xFD { return "Egg" }
      return nationalName(id)
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
    case .unbound:
      return itemsUnbound[id] ?? itemsRetail[id] ?? "Item #\(id)"
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
    if tables != .unbound { return id }
    if itemsRetail[id] != nil { return id }
    let name = item(id, tables: .unbound)
    if name.hasPrefix("Item #") { return id }
    return retailItemByNormalizedName[normalizeSpeciesName(name)] ?? id
  }

  static func move(_ id: Int, tables: Gen3Tables) -> String {
    if id == 0 { return "—" }
    switch tables {
    case .national:
      return movesSeaglass[id] ?? movesRetail[id] ?? "Move #\(id)"
    case .unbound:
      return movesUnbound[id] ?? movesRetail[id] ?? "Move #\(id)"
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
  static func mapSec(_ id: Int, game: Gen3Game) -> String? {
    switch game {
    case .emerald: return mapSecEmerald[id]
    case .fireRed: return mapSecFireRed[id]
    case .unbound: return mapSecUnbound[id] ?? mapSecFireRed[id]
    }
  }

  static func nationalName(_ n: Int) -> String {
    speciesNational[n] ?? "#\(n)"
  }

  /// Map a game's Pokédex flag index to the National Dex / species id used for names & icons.
  /// Retail bits are already National; Seaglass (and similar) use Hoenn-first numbering.
  static func nationalForDexNumber(_ n: Int, configId: String) -> Int {
    switch configId {
    case "emerald_seaglass":
      // Seaglass Hoenn-first dex (#007 = Mudkip, not Squirtle).
      return seaglassDexNational[n] ?? n
    default:
      // Radical Red / Unbound / retail: flag index is already National / species id.
      return n
    }
  }

  static func dexDisplayName(_ n: Int, configId: String) -> String {
    nationalName(nationalForDexNumber(n, configId: configId))
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
    if tables == .unbound, speciesUnbound[id] == "Egg" || speciesUnbound[id] == "Bad Egg" {
      return nil
    }
    switch tables {
    case .national, .yellow, .crystal:
      return speciesNational[id] != nil || id <= 1025 ? id : nil
    case .polished:
      // Polished's early ids match National; forms / later entries resolve by name.
      if id <= 251, speciesNational[id] != nil { return id }
      fallthrough
    case .retail, .unbound:
      let raw = species(id, tables: tables)
      if raw.hasPrefix("Species #") { return nil }
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
