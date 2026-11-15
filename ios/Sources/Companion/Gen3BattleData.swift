import Foundation

/// Move power/type + species types + type chart for live battle suggestions.
enum Gen3BattleData {
  static let typeNone = 255

  struct MoveInfo: Equatable {
    var name: String
    var type: Int
    var power: Int
  }

  struct SpeciesTypes: Equatable {
    var type1: Int
    var type2: Int
  }

  struct MoveSuggestion: Identifiable, Equatable {
    var id: Int { slot }
    var slot: Int
    var moveId: Int
    var name: String
    var typeName: String
    var power: Int
    var pp: Int
    var multiplierPct: Int
    var effectivePower: Int
    var stab: Bool

    var multiplierLabel: String {
      switch multiplierPct {
      case 0: return "0×"
      case 25: return "¼×"
      case 50: return "½×"
      case 100: return "1×"
      case 200: return "2×"
      case 400: return "4×"
      default: return String(format: "%.2g×", Double(multiplierPct) / 100.0)
      }
    }

    var verdict: String {
      if power <= 0 { return "STATUS" }
      if multiplierPct == 0 { return "IMMUNE" }
      if multiplierPct >= 200 { return "SUPER" }
      if multiplierPct < 100 { return "RESIST" }
      return "OK"
    }
  }

  // MARK: - Parsed tables

  private static func parsePairs(_ blob: String) -> [Int: Int] {
    var out: [Int: Int] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let k = Int(parts[0]), let v = Int(parts[1]) else { continue }
      out[k] = v
    }
    return out
  }

  private static func parseNames(_ blob: String) -> [Int: String] {
    var out: [Int: String] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"), let id = Int(line[line.startIndex..<bar]) else { continue }
      out[id] = String(line[line.index(after: bar)...])
    }
    return out
  }

  private static func parseMoves(_ blob: String) -> [Int: MoveInfo] {
    var out: [Int: MoveInfo] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      let p = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
      guard p.count == 4, let id = Int(p[0]), let type = Int(p[2]), let power = Int(p[3]) else { continue }
      out[id] = MoveInfo(name: String(p[1]), type: type, power: power)
    }
    return out
  }

  private static func parseSpeciesTypes(_ blob: String) -> [Int: SpeciesTypes] {
    var out: [Int: SpeciesTypes] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      let p = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      guard p.count == 3, let id = Int(p[0]), let t1 = Int(p[1]), let t2 = Int(p[2]) else { continue }
      out[id] = SpeciesTypes(type1: t1, type2: t2)
    }
    return out
  }

  private static let movesRetail = parseMoves(Gen3BattleBlobs.movesRetail)
  private static let movesSeaglass = parseMoves(Gen3BattleBlobs.movesSeaglass)
  private static let movesUnbound = parseMoves(Gen3BattleBlobs.movesUnbound)
  private static let movesYellow = parseMoves(Gen3BattleBlobs.movesYellow)
  private static let movesCrystal = parseMoves(Gen3BattleBlobs.movesCrystal)
  private static let movesPolished = parseMoves(Gen3BattleBlobs.movesPolished)

  private static let speciesRetail = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesRetail)
  private static let speciesSeaglass = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesSeaglass)
  private static let speciesUnbound = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesUnbound)
  private static let speciesYellow = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesYellow)
  private static let speciesCrystal = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesCrystal)
  private static let speciesPolished = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesPolished)

  private static let typeNamesRetail = parseNames(Gen3BattleBlobs.typeNamesRetail)
  private static let typeNamesSeaglass = parseNames(Gen3BattleBlobs.typeNamesSeaglass)
  private static let typeNamesUnbound = parseNames(Gen3BattleBlobs.typeNamesUnbound)
  private static let typeNamesYellow = parseNames(Gen3BattleBlobs.typeNamesYellow)
  private static let typeNamesCrystal = parseNames(Gen3BattleBlobs.typeNamesCrystal)
  private static let typeNamesPolished = parseNames(Gen3BattleBlobs.typeNamesPolished)

  private static let chartRetail = parsePairs(Gen3BattleBlobs.typeChartRetail)
  private static let chartSeaglass = parsePairs(Gen3BattleBlobs.typeChartSeaglass)
  private static let chartUnbound = parsePairs(Gen3BattleBlobs.typeChartUnbound)
  private static let chartYellow = parsePairs(Gen3BattleBlobs.typeChartYellow)
  private static let chartCrystal = parsePairs(Gen3BattleBlobs.typeChartCrystal)
  private static let chartPolished = parsePairs(Gen3BattleBlobs.typeChartPolished)

  // MARK: - Lookups

  static func moveInfo(_ id: Int, tables: Gen3Tables) -> MoveInfo? {
    guard id > 0 else { return nil }
    switch tables {
    case .national: return movesSeaglass[id] ?? movesRetail[id]
    case .unbound: return movesUnbound[id] ?? movesRetail[id]
    case .retail: return movesRetail[id]
    case .yellow: return movesYellow[id]
    case .crystal: return movesCrystal[id]
    case .polished: return movesPolished[id]
    }
  }

  /// All known move id → display name pairs for a ROM’s table (save-editor catalogs / learnsets).
  static func moveNames(tables: Gen3Tables) -> [Int: String] {
    let source: [Int: MoveInfo]
    switch tables {
    case .national: source = movesSeaglass
    case .unbound: source = movesUnbound
    case .retail: source = movesRetail
    case .yellow: source = movesYellow
    case .crystal: source = movesCrystal
    case .polished: source = movesPolished
    }
    var out: [Int: String] = [:]
    out.reserveCapacity(source.count)
    for (id, info) in source { out[id] = info.name }
    // Expanded / DS tables fall back to retail names for any gaps.
    if tables == .national || tables == .unbound {
      for (id, info) in movesRetail where out[id] == nil { out[id] = info.name }
    }
    return out
  }

  static func speciesTypes(_ species: Int, tables: Gen3Tables) -> SpeciesTypes? {
    guard species > 0 else { return nil }
    switch tables {
    case .national: return speciesSeaglass[species] ?? speciesRetail[species]
    case .unbound: return speciesUnbound[species]
    case .retail: return speciesRetail[species]
    case .yellow: return speciesYellow[species]
    case .crystal: return speciesCrystal[species]
    case .polished: return speciesPolished[species]
    }
  }

  static func typeName(_ type: Int, tables: Gen3Tables) -> String {
    if type == typeNone { return "" }
    let map: [Int: String]
    switch tables {
    case .national: map = typeNamesSeaglass
    case .unbound: map = typeNamesUnbound
    case .retail: map = typeNamesRetail
    case .yellow: map = typeNamesYellow
    case .crystal: map = typeNamesCrystal
    case .polished: map = typeNamesPolished
    }
    return map[type] ?? "Type#\(type)"
  }

  static func singleMultiplierPct(atk: Int, def: Int, tables: Gen3Tables) -> Int {
    let chart: [Int: Int]
    switch tables {
    case .national: chart = chartSeaglass
    case .unbound: chart = chartUnbound
    case .retail: chart = chartRetail
    case .yellow: chart = chartYellow
    case .crystal: chart = chartCrystal
    case .polished: chart = chartPolished
    }
    return chart[atk * 100 + def] ?? 100
  }

  static func multiplierPct(atkType: Int, def1: Int, def2: Int, tables: Gen3Tables) -> Int {
    guard atkType != typeNone, def1 != typeNone else { return 100 }
    var pct = singleMultiplierPct(atk: atkType, def: def1, tables: tables)
    if def2 != typeNone, def2 != def1 {
      pct = pct * singleMultiplierPct(atk: atkType, def: def2, tables: tables) / 100
    }
    return pct
  }

  /// Rank the active battler's moves vs the current foe (damaging moves first by effective power).
  static func suggestions(
    attackerMoves: [Int],
    attackerPP: [Int],
    attackerSpecies: Int,
    foeSpecies: Int,
    tables: Gen3Tables
  ) -> [MoveSuggestion] {
    let foe = speciesTypes(foeSpecies, tables: tables)
    let def1 = foe?.type1 ?? typeNone
    let def2 = foe?.type2 ?? typeNone
    let atkTypes = speciesTypes(attackerSpecies, tables: tables)
    var out: [MoveSuggestion] = []
    for (i, moveId) in attackerMoves.enumerated() where moveId > 0 {
      guard let info = moveInfo(moveId, tables: tables) else {
        out.append(MoveSuggestion(
          slot: i, moveId: moveId, name: Gen3Names.move(moveId, tables: tables),
          typeName: "", power: 0, pp: i < attackerPP.count ? attackerPP[i] : 0,
          multiplierPct: 100, effectivePower: 0, stab: false
        ))
        continue
      }
      let pp = i < attackerPP.count ? attackerPP[i] : 0
      let pct: Int
      let stab: Bool
      if info.power <= 0 {
        pct = 100
        stab = false
      } else {
        pct = multiplierPct(atkType: info.type, def1: def1, def2: def2, tables: tables)
        stab = atkTypes.map { info.type == $0.type1 || info.type == $0.type2 } ?? false
      }
      let stabMul = stab ? 1.5 : 1.0
      let eff = info.power <= 0 || pp <= 0 ? 0 : Int(Double(info.power) * Double(pct) / 100.0 * stabMul)
      out.append(MoveSuggestion(
        slot: i,
        moveId: moveId,
        name: info.name,
        typeName: typeName(info.type, tables: tables),
        power: info.power,
        pp: pp,
        multiplierPct: pct,
        effectivePower: eff,
        stab: stab
      ))
    }
    return out.sorted { a, b in
      if a.effectivePower != b.effectivePower { return a.effectivePower > b.effectivePower }
      if a.power != b.power { return a.power > b.power }
      return a.slot < b.slot
    }
  }

  /// Suggestions for the live battle snapshot (player left battler vs foe left).
  static func liveSuggestions(from snap: CompanionSnapshot) -> (foeName: String, moves: [MoveSuggestion])? {
    guard snap.inBattle, snap.battleMons.count > 1 else { return nil }
    guard let foe = snap.battleMons[1], foe.species > 0 else { return nil }
    // Prefer live battler moves. Polished Crystal often leaves wBattleMon empty during
    // the cry / "A wild…" text — fall back to the party lead so tips still appear.
    let atkMoves: [Int]
    let atkPP: [Int]
    let atkSpecies: Int
    if let ally = snap.battleMons[0], ally.species > 0, ally.moves.contains(where: { $0 > 0 }) {
      atkMoves = ally.moves
      atkPP = ally.pp
      atkSpecies = ally.species
    } else if let lead = snap.party.first(where: { !$0.isEgg && $0.species > 0 }) {
      atkMoves = lead.moves
      atkPP = lead.pp
      atkSpecies = lead.species
    } else {
      return nil
    }
    guard atkMoves.contains(where: { $0 > 0 }) else { return nil }
    let tables = snap.tables
    let moves = suggestions(
      attackerMoves: atkMoves,
      attackerPP: atkPP,
      attackerSpecies: atkSpecies,
      foeSpecies: foe.species,
      tables: tables
    )
    guard !moves.isEmpty else { return nil }
    let foeName = Gen3Names.species(foe.species, tables: tables)
    return (foeName, moves)
  }
}
