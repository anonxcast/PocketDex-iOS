import Foundation

/// Overworld “who to talk to” tips from Android GuideAreas PEOPLE rows + building heuristics.
enum SmartIslandTalkTips {

  /// What the player receives if they follow the tip — used for “you did it” celebrate.
  enum Reward: Equatable {
    case item(Int)
    case mon(Int)
    case trade(get: Int, wants: Int)
  }

  struct Tip: Equatable {
    var headline: String
    var detail: String
    var urgency: String
    var tipId: String
    /// Prefer indoor / gift NPCs over soft heuristics.
    var priority: Int
    var reward: Reward? = nil
    /// Short label for celebrate copy (“Potion”, “Eevee”, …).
    var rewardLabel: String? = nil
  }

  private struct Row {
    var kind: String
    var id: Int
    var qty: Int
    var wants: Int
    var whereLabel: String
  }

  private static let byGuideSec: [String: [Int: [Row]]] = {
    var out: [String: [Int: [Row]]] = [:]
    for line in SmartIslandTalkTipsGen.rawBlob.split(separator: "\n", omittingEmptySubsequences: true) {
      let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard p.count >= 7,
            let sec = Int(p[1]),
            let id = Int(p[3]),
            let qty = Int(p[4]),
            let wants = Int(p[5]) else { continue }
      let guide = p[0]
      let row = Row(kind: p[2], id: id, qty: qty, wants: wants, whereLabel: p[6])
      out[guide, default: [:]][sec, default: []].append(row)
    }
    return out
  }()

  /// Map companion configId → GuideAreas guide key.
  /// Matches Android `GuideAreas.kt`: only ROMs with real PEOPLE rows get tips.
  /// Hacks with empty area data (Seaglass, Lazarus, …) must NOT borrow Emerald gifts.
  static func guideKey(configId: String) -> String? {
    let id = configId.lowercased()

    // Android GuideAreas → emptyList() for these — building heuristics only.
    let noPeopleMarkers = [
      "seaglass", "lazarus", "wishes", "soulgold", "tmt2", "too_many_types",
      "rowe", "modern_emerald", "elite_redux", "recharged_emerald", "mariomon",
      "glazed", "imperium", "quetzal", "dreamstone", "monomyth", "kaizo", "rogue",
      "team_rocket_v", "emerald_hack",
    ]
    if noPeopleMarkers.contains(where: { id.contains($0) }) {
      return nil
    }

    if id == "heart_and_soul" || id == "crystal_enhanced" { return "heart_and_soul" }
    if id.hasPrefix("firered") || id.contains("crystal_advance") { return "firered" }
    if id.hasPrefix("leafgreen") { return "leafgreen" }
    if id.hasPrefix("unbound") { return "unbound" }
    if id.hasPrefix("radical") { return "radical_red" }
    if id.hasPrefix("rocket") { return "rocket_edition" }
    if id.hasPrefix("odyssey") { return "odyssey" }
    if id.hasPrefix("gaia") { return "gaia" }
    if id == "polished_crystal" || id == "polished" { return "polished_crystal" }
    if id.contains("crystal") && id.contains("enhanced") { return "heart_and_soul" }
    if id == "crystal" || id == "crystal_clear" || (id.contains("crystal") && !id.contains("advance")) {
      return "crystal"
    }
    if id == "gold" || id == "silver" || id == "prism" { return "crystal" }
    if id.hasPrefix("ruby") || id.hasPrefix("sapphire") { return "ruby_sapphire" }
    if id.contains("legacy") && id.contains("emerald") { return "emerald_legacy" }
    // Retail Emerald (+ language dumps). Never emerald_seaglass / kaizo / etc. (filtered above).
    if id == "emerald" || id == "emerald_retail" || id.hasPrefix("emerald_") {
      return "emerald"
    }
    return nil
  }

  static func tips(
    for snap: CompanionSnapshot,
    stickySeed: UInt64,
    limit: Int = 3,
    excluding completed: Set<String> = []
  ) -> [Tip] {
    var out: [Tip] = []
    let place = snap.mapSecName.flatMap { $0.isEmpty ? nil : $0 } ?? "here"
    let tables = snap.tables

    if let guide = guideKey(configId: snap.configId),
       let rows = byGuideSec[guide]?[snap.mapSec], !rows.isEmpty {
      // Stable rotation so tap-cycle / sticky seed flips which NPC is featured.
      let ordered = rows.enumerated().sorted { a, b in
        let sa = (stickySeed &+ UInt64(a.offset) &* 0x9E37) % 997
        let sb = (stickySeed &+ UInt64(b.offset) &* 0x9E37) % 997
        return sa < sb
      }.map(\.element)

      for row in ordered.prefix(limit + 4) {
        if let tip = format(row: row, place: place, tables: tables),
           !completed.contains(tip.tipId) {
          out.append(tip)
        }
        if out.count >= limit { break }
      }
    }

    // Building heuristics when guide has no row (or as extra indoor nudge).
    if let soft = buildingHeuristic(place: place, seed: stickySeed),
       !completed.contains(soft.tipId) {
      if !out.contains(where: { $0.tipId == soft.tipId }) {
        out.append(soft)
      }
    }

    return Array(out.prefix(limit))
  }

  /// Best single tip for the island primary slot (building gifts first).
  static func primaryTip(
    for snap: CompanionSnapshot,
    stickySeed: UInt64,
    excluding completed: Set<String> = []
  ) -> Tip? {
    tips(for: snap, stickySeed: stickySeed, limit: 1, excluding: completed).first
  }

  /// Parse reward from a tip id (for pending quests that only stored the id).
  static func reward(forTipId tipId: String) -> Reward? {
    let p = tipId.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard p.count >= 3, p[0] == "talk" else { return nil }
    switch p[1] {
    case "gift", "key":
      guard let id = Int(p[2]), id > 0 else { return nil }
      return .item(id)
    case "mon", "egg":
      guard let id = Int(p[2]), id > 0 else { return nil }
      return .mon(id)
    case "trade":
      guard p.count >= 4, let get = Int(p[2]), let wants = Int(p[3]), get > 0 else { return nil }
      return .trade(get: get, wants: wants)
    default:
      return nil
    }
  }

  private static func format(row: Row, place: String, tables: Gen3Tables) -> Tip? {
    let whereBit: String
    if row.whereLabel.isEmpty {
      whereBit = "around \(place)"
    } else {
      whereBit = "in the \(prettyWhere(row.whereLabel))"
    }

    switch row.kind {
    case "MON":
      let mon = Gen3Names.species(row.id, tables: tables)
      // Wrong species table for this ROM → don't invent a fake gift mon.
      if mon.hasPrefix("Species #") || mon.hasPrefix("Pokémon #") { return nil }
      return Tip(
        headline: "Talk \(whereBit)",
        detail: "Someone gives \(mon)",
        urgency: "TALK",
        tipId: "talk.mon.\(row.id).\(row.whereLabel)",
        priority: 3,
        reward: .mon(row.id),
        rewardLabel: mon
      )
    case "EGG":
      let mon = Gen3Names.species(row.id, tables: tables)
      if mon.hasPrefix("Species #") || mon.hasPrefix("Pokémon #") { return nil }
      return Tip(
        headline: "Talk \(whereBit)",
        detail: "Egg gift · hatches into \(mon)",
        urgency: "TALK",
        tipId: "talk.egg.\(row.id)",
        priority: 3,
        reward: .mon(row.id),
        rewardLabel: "\(mon) egg"
      )
    case "TRADE":
      let get = Gen3Names.species(row.id, tables: tables)
      let give = Gen3Names.species(row.wants, tables: tables)
      if get.hasPrefix("Species #") || give.hasPrefix("Species #")
          || get.hasPrefix("Pokémon #") || give.hasPrefix("Pokémon #") {
        return nil
      }
      return Tip(
        headline: "Trade \(whereBit)",
        detail: "They want \(give) · you get \(get)",
        urgency: "TRADE",
        tipId: "talk.trade.\(row.id).\(row.wants)",
        priority: 4,
        reward: .trade(get: row.id, wants: row.wants),
        rewardLabel: get
      )
    case "KEY":
      let item = Gen3Names.item(row.id, tables: tables)
      if item.hasPrefix("Item #") { return nil }
      return Tip(
        headline: "Talk \(whereBit)",
        detail: "Key item: \(item)",
        urgency: "KEY",
        tipId: "talk.key.\(row.id).\(row.whereLabel)",
        priority: 4,
        reward: .item(row.id),
        rewardLabel: item
      )
    default:
      let item = Gen3Names.item(row.id, tables: tables)
      let qty = row.qty > 1 ? "×\(row.qty) " : ""
      // Skip unnamed Item # noise when tables don't know the id.
      if item.hasPrefix("Item #") { return nil }
      return Tip(
        headline: "Talk \(whereBit)",
        detail: "Someone gives \(qty)\(item)",
        urgency: "TALK",
        tipId: "talk.gift.\(row.id).\(row.whereLabel)",
        priority: row.whereLabel.isEmpty ? 2 : 3,
        reward: .item(row.id),
        rewardLabel: item
      )
    }
  }

  private static func prettyWhere(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "POKéMON", with: "Pokémon")
      .replacingOccurrences(of: "POKEMON", with: "Pokémon")
  }

  /// Soft tips when the place name itself is a talkable building (all optimized ROMs).
  private static func buildingHeuristic(place: String, seed: UInt64) -> Tip? {
    let u = place.uppercased()
      .replacingOccurrences(of: "É", with: "E")
      .replacingOccurrences(of: "é", with: "E")

    let rules: [(keys: [String], headline: String, detail: String, id: String)] = [
      (["POKEMON CENTER", "POKéMON CENTER", "POKE CENTER", "PKMN CENTER"],
       "Talk to the nurse", "Heal up — Pokémon Center desk", "talk.bldg.center"),
      (["MART", "SHOP", "DEPARTMENT", "POKé MART", "POKE MART"],
       "Talk to the clerk", "Stock potions / balls while you're here", "talk.bldg.mart"),
      (["GYM"],
       "Talk to the Gym Leader", "Challenge when your party's ready", "talk.bldg.gym"),
      (["LAB", "OAK", "ELM", "BIRCH", "ROWAN", "JUNIPER", "SYCAMORE"],
       "Talk to the professor", "Lab NPCs often hold story / starter beats", "talk.bldg.lab"),
      (["MUSEUM"],
       "Talk to staff upstairs", "Museum NPCs sometimes hand out gifts", "talk.bldg.museum"),
      (["FAN CLUB"],
       "Talk to the club chairman", "Fan Club chats can pay off", "talk.bldg.fan"),
      (["GAME CORNER", "CASINO"],
       "Talk to the attendants", "Prizes / coins at the Game Corner", "talk.bldg.corner"),
      (["HOUSE", "HOME", "CONDO", "APARTMENT"],
       "Check houses — talk to everyone", "Indoor NPCs hide gifts and trades", "talk.bldg.house"),
      (["SCHOOL", "TRAINER SCHOOL"],
       "Talk to the teachers", "School NPCs often give early tips / items", "talk.bldg.school"),
      (["PC", "NETWORK CENTER"],
       "Use the PC if you need storage", "Deposit / withdraw before the next fight", "talk.bldg.pc"),
      (["HARBOR", "PORT", "DOCK"],
       "Talk around the docks", "Sailors and clerks often have extras", "talk.bldg.harbor"),
      (["BIKE SHOP"],
       "Talk to the bike shop owner", "Story bikes / vouchers show up here", "talk.bldg.bike"),
      (["CONTEST", "THEATER", "THEATRE"],
       "Talk to contest staff", "Reception desks sometimes hand out items", "talk.bldg.contest"),
      (["LIBRARY"],
       "Browse and talk to readers", "Libraries hide quiet NPC gifts", "talk.bldg.library"),
    ]

    var hits: [Tip] = []
    for rule in rules {
      if rule.keys.contains(where: { u.contains($0) }) {
        hits.append(Tip(
          headline: rule.headline,
          detail: "\(place) · \(rule.detail)",
          urgency: "TALK",
          tipId: rule.id,
          priority: 1
        ))
      }
    }
    guard !hits.isEmpty else { return nil }
    return hits[Int(seed % UInt64(hits.count))]
  }
}

// MARK: - Personal lead voice

enum SmartIslandVoice {
  enum Flavor: String {
    case fire, water, grass, electric, psychic, fighting, ghost, dark, dragon, fairy, steel, ice, flying, bug, rock, ground, poison, normal, mystery
  }

  static func flavor(species: Int, tables: Gen3Tables, configId: String) -> Flavor {
    guard let t = Gen3BattleData.speciesTypes(species, tables: tables, configId: configId) else {
      return .mystery
    }
    // Prefer type1; map common Gen3 / expansion / HnS ids loosely via name tables when needed.
    return mapTypeId(t.type1, tables: tables)
  }

  private static func mapTypeId(_ type: Int, tables: Gen3Tables) -> Flavor {
    // Retail Gen3: 0 Normal … 16 Dark. Expansion/HnS often shift (Normal=1).
    let retail: [Int: Flavor] = [
      0: .normal, 1: .fighting, 2: .flying, 3: .poison, 4: .ground, 5: .rock,
      6: .bug, 7: .ghost, 8: .steel, 9: .fire, 10: .water, 11: .grass,
      12: .electric, 13: .psychic, 14: .ice, 15: .dragon, 16: .dark,
    ]
    if tables == .hns || tables == .national || tables == .unbound {
      // Expansion-style: often 1=Normal … with Fairy later.
      let exp: [Int: Flavor] = [
        1: .normal, 2: .fighting, 3: .flying, 4: .poison, 5: .ground, 6: .rock,
        7: .bug, 8: .ghost, 9: .steel, 10: .mystery /* ??? */, 11: .fire, 12: .water,
        13: .grass, 14: .electric, 15: .psychic, 16: .ice, 17: .dragon, 18: .dark, 19: .fairy,
      ]
      return exp[type] ?? retail[type] ?? .mystery
    }
    return retail[type] ?? .mystery
  }

  static func personalVars(
    leadName: String,
    level: Int,
    pct: Int,
    place: String,
    foe: String?,
    flavor: Flavor
  ) -> [String: String] {
    [
      "lead": leadName,
      "level": "\(level)",
      "pct": "\(pct)",
      "place": place,
      "foe": foe ?? "the foe",
      "voice": flavor.rawValue,
    ]
  }
}
