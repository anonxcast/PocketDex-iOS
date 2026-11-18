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

  /// Per-ROM battle tip encoding (Android `ActiveTables`). Coarse `Gen3Tables` alone
  /// collapses many expansion hacks onto Gen-5 species types + Seaglass charts — wrong multipliers.
  private enum TipProfile: Equatable {
    case retail
    case unbound
    case seaglass
    case hns
    case modernEmerald
    case yellow
    case crystal
    case polished
    case prism
    case wishes
    case lazarus
    case rowe
    case soulGold
    case radicalRed
    case teamRocketV3
    case tmt2
    /// Gen 4/5 DS: Black personal types + retail (vanilla id) chart/moves.
    case dsNational
    /// Expansion GBA with national species ids but no dedicated dump — HnS/Seaglass stack.
    case expansionNational

    static func resolve(configId: String, tables: Gen3Tables) -> TipProfile {
      let id = configId.lowercased()
      if id.contains("seaglass") { return .seaglass }
      if id.hasPrefix("wishes") { return .wishes }
      if id.hasPrefix("lazarus") { return .lazarus }
      if id.hasPrefix("rowe") { return .rowe }
      if id.hasPrefix("soulgold") { return .soulGold }
      if id.hasPrefix("radical_red") { return .radicalRed }
      if id == "team_rocket_v3" || id.hasPrefix("team_rocket_v3") { return .teamRocketV3 }
      if id.hasPrefix("tmt2") { return .tmt2 }
      if id.hasPrefix("heart_and_soul") || id.hasPrefix("crystal_enhanced") { return .hns }
      if id.hasPrefix("modern_emerald") { return .modernEmerald }
      if id.hasPrefix("prism") { return .prism }
      if id.hasPrefix("unbound") { return .unbound }
      // Retail FireRed shell; national names only — battle tips use vanilla type ids.
      if id.hasPrefix("rocket_edition") { return .retail }
      if Self.isDsConfig(id) { return .dsNational }
      switch tables {
      case .retail: return .retail
      case .unbound: return .unbound
      case .hns: return .hns
      case .modernEmerald: return .modernEmerald
      case .yellow: return .yellow
      case .crystal: return .crystal
      case .polished: return .polished
      case .prism: return .prism
      case .national: return .expansionNational
      }
    }

    private static func isDsConfig(_ id: String) -> Bool {
      let keys = [
        "black2", "white2", "black", "white", "platinum",
        "heartgold", "soulsilver", "diamond", "pearl",
      ]
      return keys.contains { id.contains($0) }
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
  private static let movesModernEmerald = parseMoves(Gen3BattleBlobs.movesModernEmerald)
  private static let movesYellow = parseMoves(Gen3BattleBlobs.movesYellow)
  private static let movesCrystal = parseMoves(Gen3BattleBlobs.movesCrystal)
  private static let movesPolished = parseMoves(Gen3BattleBlobs.movesPolished)
  private static let movesPrism = parseMoves(Gen3BattleBlobs.movesPrism)
  private static let movesHns = parseMoves(Gen3BattleBlobs.movesHns)
  private static let movesWishes = parseMoves(Gen3BattleBlobs.movesWishes)
  private static let movesLazarus = parseMoves(Gen3BattleBlobs.movesLazarus)
  private static let movesRowe = parseMoves(Gen3BattleBlobs.movesRowe)
  private static let movesSoulGold = parseMoves(Gen3BattleBlobs.movesSoulGold)
  private static let movesRadicalRed = parseMoves(Gen3BattleBlobs.movesRadicalRed)
  private static let movesTeamRocketV3 = parseMoves(Gen3BattleBlobs.movesTeamRocketV3)
  private static let movesTmt2 = parseMoves(Gen3BattleBlobs.movesTmt2)

  private static let speciesRetail = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesRetail)
  private static let speciesSeaglass = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesSeaglass)
  private static let speciesUnbound = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesUnbound)
  private static let speciesNational = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesNational)
  private static let speciesModernEmerald = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesModernEmerald)
  private static let speciesYellow = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesYellow)
  private static let speciesCrystal = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesCrystal)
  private static let speciesPolished = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesPolished)
  private static let speciesPrism = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesPrism)
  private static let speciesHns = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesHns)
  private static let speciesWishes = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesWishes)
  private static let speciesLazarus = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesLazarus)
  private static let speciesRowe = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesRowe)
  private static let speciesSoulGold = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesSoulGold)
  private static let speciesRadicalRed = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesRadicalRed)
  private static let speciesTeamRocketV3 = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesTeamRocketV3)
  private static let speciesTmt2 = parseSpeciesTypes(Gen3BattleBlobs.speciesTypesTmt2)

  private static let typeNamesRetail = parseNames(Gen3BattleBlobs.typeNamesRetail)
  private static let typeNamesSeaglass = parseNames(Gen3BattleBlobs.typeNamesSeaglass)
  private static let typeNamesUnbound = parseNames(Gen3BattleBlobs.typeNamesUnbound)
  private static let typeNamesModernEmerald = parseNames(Gen3BattleBlobs.typeNamesModernEmerald)
  private static let typeNamesYellow = parseNames(Gen3BattleBlobs.typeNamesYellow)
  private static let typeNamesCrystal = parseNames(Gen3BattleBlobs.typeNamesCrystal)
  private static let typeNamesPolished = parseNames(Gen3BattleBlobs.typeNamesPolished)
  private static let typeNamesPrism = parseNames(Gen3BattleBlobs.typeNamesPrism)
  private static let typeNamesHns = parseNames(Gen3BattleBlobs.typeNamesHns)
  private static let typeNamesWishes = parseNames(Gen3BattleBlobs.typeNamesWishes)
  private static let typeNamesLazarus = parseNames(Gen3BattleBlobs.typeNamesLazarus)
  private static let typeNamesRowe = parseNames(Gen3BattleBlobs.typeNamesRowe)
  private static let typeNamesSoulGold = parseNames(Gen3BattleBlobs.typeNamesSoulGold)
  private static let typeNamesTeamRocketV3 = parseNames(Gen3BattleBlobs.typeNamesTeamRocketV3)
  private static let typeNamesTmt2 = parseNames(Gen3BattleBlobs.typeNamesTmt2)

  private static let chartRetail = parsePairs(Gen3BattleBlobs.typeChartRetail)
  private static let chartSeaglass = parsePairs(Gen3BattleBlobs.typeChartSeaglass)
  private static let chartUnbound = parsePairs(Gen3BattleBlobs.typeChartUnbound)
  private static let chartModernEmerald = parsePairs(Gen3BattleBlobs.typeChartModernEmerald)
  private static let chartYellow = parsePairs(Gen3BattleBlobs.typeChartYellow)
  private static let chartCrystal = parsePairs(Gen3BattleBlobs.typeChartCrystal)
  private static let chartPolished = parsePairs(Gen3BattleBlobs.typeChartPolished)
  private static let chartPrism = parsePairs(Gen3BattleBlobs.typeChartPrism)
  private static let chartHns = parsePairs(Gen3BattleBlobs.typeChartHns)
  private static let chartWishes = parsePairs(Gen3BattleBlobs.typeChartWishes)
  private static let chartLazarus = parsePairs(Gen3BattleBlobs.typeChartLazarus)
  private static let chartRowe = parsePairs(Gen3BattleBlobs.typeChartRowe)
  private static let chartSoulGold = parsePairs(Gen3BattleBlobs.typeChartSoulGold)
  private static let chartTeamRocketV3 = parsePairs(Gen3BattleBlobs.typeChartTeamRocketV3)
  private static let chartTmt2 = parsePairs(Gen3BattleBlobs.typeChartTmt2)

  // MARK: - Profile → table

  private static func moves(for profile: TipProfile) -> [Int: MoveInfo] {
    switch profile {
    case .retail, .dsNational: return movesRetail
    case .unbound: return movesUnbound
    case .seaglass, .expansionNational: return movesSeaglass
    case .hns: return movesHns
    case .modernEmerald: return movesModernEmerald
    case .yellow: return movesYellow
    case .crystal: return movesCrystal
    case .polished: return movesPolished
    case .prism: return movesPrism
    case .wishes: return movesWishes
    case .lazarus: return movesLazarus
    case .rowe: return movesRowe
    case .soulGold: return movesSoulGold
    case .radicalRed: return movesRadicalRed
    case .teamRocketV3: return movesTeamRocketV3
    case .tmt2: return movesTmt2
    }
  }

  private static func speciesMap(for profile: TipProfile) -> [Int: SpeciesTypes] {
    switch profile {
    case .retail: return speciesRetail
    case .unbound: return speciesUnbound
    case .seaglass: return speciesSeaglass
    case .hns: return speciesHns
    case .modernEmerald: return speciesModernEmerald
    case .yellow: return speciesYellow
    case .crystal: return speciesCrystal
    case .polished: return speciesPolished
    case .prism: return speciesPrism
    case .wishes: return speciesWishes
    case .lazarus: return speciesLazarus
    case .rowe: return speciesRowe
    case .soulGold: return speciesSoulGold
    case .radicalRed: return speciesRadicalRed
    case .teamRocketV3: return speciesTeamRocketV3
    case .tmt2: return speciesTmt2
    case .dsNational: return speciesNational
    // Prefer expansion-encoded typings (HnS), then Seaglass customs — never Gen-5 Black ids.
    case .expansionNational: return speciesHns
    }
  }

  private static func typeNames(for profile: TipProfile) -> [Int: String] {
    switch profile {
    case .retail, .dsNational: return typeNamesRetail
    case .unbound, .radicalRed: return typeNamesUnbound
    case .seaglass, .expansionNational: return typeNamesSeaglass
    case .hns: return typeNamesHns
    case .modernEmerald: return typeNamesModernEmerald
    case .yellow: return typeNamesYellow
    case .crystal: return typeNamesCrystal
    case .polished: return typeNamesPolished
    case .prism: return typeNamesPrism
    case .wishes: return typeNamesWishes
    case .lazarus: return typeNamesLazarus
    case .rowe: return typeNamesRowe
    case .soulGold: return typeNamesSoulGold
    case .teamRocketV3: return typeNamesTeamRocketV3
    case .tmt2: return typeNamesTmt2
    }
  }

  private static func chart(for profile: TipProfile) -> [Int: Int] {
    switch profile {
    case .retail, .dsNational: return chartRetail
    case .unbound, .radicalRed: return chartUnbound
    case .seaglass, .expansionNational: return chartSeaglass
    case .hns: return chartHns
    case .modernEmerald: return chartModernEmerald
    case .yellow: return chartYellow
    case .crystal: return chartCrystal
    case .polished: return chartPolished
    case .prism: return chartPrism
    case .wishes: return chartWishes
    case .lazarus: return chartLazarus
    case .rowe: return chartRowe
    case .soulGold: return chartSoulGold
    case .teamRocketV3: return chartTeamRocketV3
    case .tmt2: return chartTmt2
    }
  }

  private static func profile(tables: Gen3Tables, configId: String) -> TipProfile {
    TipProfile.resolve(configId: configId, tables: tables)
  }

  // MARK: - Lookups

  static func moveInfo(_ id: Int, tables: Gen3Tables, configId: String = "") -> MoveInfo? {
    guard id > 0 else { return nil }
    let p = profile(tables: tables, configId: configId)
    let primary = moves(for: p)
    if let hit = primary[id] { return hit }
    // Fallbacks mirror Android ActiveTables layering.
    switch p {
    case .hns, .wishes, .lazarus, .soulGold, .teamRocketV3, .tmt2, .expansionNational, .seaglass:
      return movesSeaglass[id] ?? movesRetail[id]
    case .radicalRed, .rowe, .unbound:
      return movesUnbound[id] ?? movesRetail[id]
    case .modernEmerald:
      return movesRetail[id]
    case .retail, .dsNational, .yellow, .crystal, .polished, .prism:
      return nil
    }
  }

  /// All known move id → display name pairs for a ROM’s table (save-editor catalogs / learnsets).
  static func moveNames(tables: Gen3Tables, configId: String = "") -> [Int: String] {
    let p = profile(tables: tables, configId: configId)
    let source = moves(for: p)
    var out: [Int: String] = [:]
    out.reserveCapacity(source.count)
    for (id, info) in source { out[id] = info.name }
    switch p {
    case .expansionNational, .hns, .seaglass, .wishes, .lazarus, .soulGold, .teamRocketV3, .tmt2,
         .unbound, .radicalRed, .rowe, .modernEmerald, .dsNational:
      for (id, info) in movesRetail where out[id] == nil { out[id] = info.name }
    case .retail, .yellow, .crystal, .polished, .prism:
      break
    }
    return out
  }

  static func speciesTypes(_ species: Int, tables: Gen3Tables, configId: String = "") -> SpeciesTypes? {
    guard species > 0 else { return nil }
    let p = profile(tables: tables, configId: configId)
    if let hit = speciesMap(for: p)[species] { return hit }
    switch p {
    case .hns:
      return speciesSeaglass[species] ?? speciesNational[species]
    case .expansionNational, .seaglass:
      return speciesSeaglass[species] ?? speciesHns[species] ?? speciesRetail[species]
    case .wishes, .lazarus, .soulGold, .teamRocketV3, .tmt2:
      return speciesHns[species] ?? speciesSeaglass[species]
    case .radicalRed, .rowe:
      return speciesUnbound[species] ?? speciesRetail[species]
    case .modernEmerald:
      return speciesRetail[species]
    case .dsNational:
      return speciesSeaglass[species] ?? speciesRetail[species]
    case .retail, .unbound, .yellow, .crystal, .polished, .prism:
      return nil
    }
  }

  static func typeName(_ type: Int, tables: Gen3Tables, configId: String = "") -> String {
    if type == typeNone { return "" }
    let map = typeNames(for: profile(tables: tables, configId: configId))
    return map[type] ?? "Type#\(type)"
  }

  static func singleMultiplierPct(atk: Int, def: Int, tables: Gen3Tables, configId: String = "") -> Int {
    let chart = chart(for: profile(tables: tables, configId: configId))
    return chart[atk * 100 + def] ?? 100
  }

  static func multiplierPct(atkType: Int, def1: Int, def2: Int, tables: Gen3Tables, configId: String = "") -> Int {
    guard atkType != typeNone, def1 != typeNone else { return 100 }
    var pct = singleMultiplierPct(atk: atkType, def: def1, tables: tables, configId: configId)
    if def2 != typeNone, def2 != def1 {
      pct = pct * singleMultiplierPct(atk: atkType, def: def2, tables: tables, configId: configId) / 100
    }
    return pct
  }

  /// Rank the active battler's moves vs the current foe (damaging moves first by effective power).
  static func suggestions(
    attackerMoves: [Int],
    attackerPP: [Int],
    attackerSpecies: Int,
    foeSpecies: Int,
    tables: Gen3Tables,
    configId: String = ""
  ) -> [MoveSuggestion] {
    let foe = speciesTypes(foeSpecies, tables: tables, configId: configId)
    let def1 = foe?.type1 ?? typeNone
    let def2 = foe?.type2 ?? typeNone
    let atkTypes = speciesTypes(attackerSpecies, tables: tables, configId: configId)
    var out: [MoveSuggestion] = []
    for (i, moveId) in attackerMoves.enumerated() where moveId > 0 {
      guard let info = moveInfo(moveId, tables: tables, configId: configId) else {
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
        pct = multiplierPct(atkType: info.type, def1: def1, def2: def2, tables: tables, configId: configId)
        stab = atkTypes.map { info.type == $0.type1 || info.type == $0.type2 } ?? false
      }
      let stabMul = stab ? 1.5 : 1.0
      let eff = info.power <= 0 || pp <= 0 ? 0 : Int(Double(info.power) * Double(pct) / 100.0 * stabMul)
      out.append(MoveSuggestion(
        slot: i,
        moveId: moveId,
        name: info.name,
        typeName: typeName(info.type, tables: tables, configId: configId),
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
    let configId = snap.configId
    let moves = suggestions(
      attackerMoves: atkMoves,
      attackerPP: atkPP,
      attackerSpecies: atkSpecies,
      foeSpecies: foe.species,
      tables: tables,
      configId: configId
    )
    guard !moves.isEmpty else { return nil }
    let foeName = Gen3Names.species(foe.species, tables: tables)
    return (foeName, moves)
  }
}
