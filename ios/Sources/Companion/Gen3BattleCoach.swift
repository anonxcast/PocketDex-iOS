import Foundation

/// Smart Island coach — overworld + battle. Reads party, bag, and type charts.
/// Shown for every optimized ROM with a live companion snapshot.
enum Gen3BattleCoach {

  enum ActionKind: String, Equatable {
    case attack
    case heal
    case cure
    case revive
    case switchOut
    case catchBall
    case setup
    case celebrate
    case console
    /// Overworld / between fights.
    case field
  }

  struct Advice: Equatable {
    var foeName: String
    var headline: String
    var detail: String
    var kind: ActionKind
    var moves: [Gen3BattleData.MoveSuggestion]
    var bestMove: Gen3BattleData.MoveSuggestion?
    var allyHpPct: Int
    var foeHpPct: Int?
    var partyAlive: Int
    var partyTotal: Int
    var itemHint: String?
    /// Short urgency line for the island eyebrow (e.g. "LOW HP", "SUPER EFFECTIVE").
    var urgency: String?
    /// Compact data chips (place · ₽ · balls · party · dex).
    var dataChips: [String] = []
    var foeLevel: Int? = nil
    var foeTypes: String? = nil
    /// "Trainer" / "Wild" when in battle.
    var battleKind: String? = nil
    /// Alternate tips the player can cycle with a tap (excluded from == to avoid recursive compare).
    var secondaryTips: [Advice] = []
    /// Stable id for situation sticky / cycle keys.
    var tipId: String? = nil

    static func == (lhs: Advice, rhs: Advice) -> Bool {
      lhs.foeName == rhs.foeName
        && lhs.headline == rhs.headline
        && lhs.detail == rhs.detail
        && lhs.kind == rhs.kind
        && lhs.moves == rhs.moves
        && lhs.bestMove == rhs.bestMove
        && lhs.allyHpPct == rhs.allyHpPct
        && lhs.foeHpPct == rhs.foeHpPct
        && lhs.partyAlive == rhs.partyAlive
        && lhs.partyTotal == rhs.partyTotal
        && lhs.itemHint == rhs.itemHint
        && lhs.urgency == rhs.urgency
        && lhs.dataChips == rhs.dataChips
        && lhs.foeLevel == rhs.foeLevel
        && lhs.foeTypes == rhs.foeTypes
        && lhs.battleKind == rhs.battleKind
        && lhs.tipId == rhs.tipId
    }
  }

  static func placeName(_ snap: CompanionSnapshot) -> String {
    snap.mapSecName.flatMap { $0.isEmpty ? nil : $0 }
      ?? (snap.mapGroup != 0 || snap.mapNum != 0 ? "Map \(snap.mapGroup)-\(snap.mapNum)" : "the field")
  }

  static func hpPct(_ hp: Int, _ maxHp: Int) -> Int {
    Int((Double(hp) / Double(max(1, maxHp)) * 100.0).rounded())
  }

  /// Snapshot-only tip (drawer / fallback). Play HUD prefers `SmartIslandMemory.observe`.
  static func liveAdvice(from snap: CompanionSnapshot) -> Advice? {
    composeAdvice(from: snap, lastWildFoeSpecies: 0, stickySeed: UInt64(Date().timeIntervalSince1970))
  }

  /// Full coach used by Smart Island memory (phrase bank + sticky seed).
  static func composeAdvice(
    from snap: CompanionSnapshot,
    lastWildFoeSpecies: Int,
    stickySeed: UInt64,
    completedTalkTips: Set<String> = []
  ) -> Advice? {
    if snap.inBattle {
      return battleAdvice(from: snap, stickySeed: stickySeed)
    }
    return fieldAdvice(
      from: snap,
      lastWildFoeSpecies: lastWildFoeSpecies,
      stickySeed: stickySeed,
      completedTalkTips: completedTalkTips
    )
  }

  /// Compact chips for the island strip.
  static func dataChips(from snap: CompanionSnapshot, bagBalls: Int) -> [String] {
    var chips: [String] = []
    let place = placeName(snap)
    if place != "the field" { chips.append(place) }
    if let money = snap.money { chips.append("₽\(money)") }
    chips.append("Balls \(bagBalls)")
    let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
    let alive = party.filter { $0.hp > 0 }.count
    chips.append("Party \(alive)/\(party.count)")
    if let dex = snap.dex {
      chips.append("Dex \(dex.caught)/\(dex.seen)")
    }
    return chips
  }

  /// Tap-cycle alternates for the current primary tip.
  static func secondaryTips(
    from snap: CompanionSnapshot,
    primary: Advice,
    lastWildFoeSpecies: Int,
    completedTalkTips: Set<String> = []
  ) -> [Advice] {
    let bag = BagIndex(snap: snap)
    let chips = dataChips(from: snap, bagBalls: bag.ballCount())
    let place = placeName(snap)
    let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
    guard !party.isEmpty else { return [] }
    let alive = party.filter { $0.hp > 0 }.count
    let lead = party.first(where: { $0.hp > 0 }) ?? party[0]
    let leadPct = pct(lead.hp, lead.maxHp)
    let leadName = Gen3Names.species(lead.species, tables: snap.tables)
    var out: [Advice] = []

    // Bag inventory summary.
    if let inv = bag.inventoryLine() {
      out.append(Advice(
        foeName: primary.foeName,
        headline: "Bag check",
        detail: inv,
        kind: .field,
        moves: primary.moves,
        bestMove: primary.bestMove,
        allyHpPct: primary.allyHpPct,
        foeHpPct: primary.foeHpPct,
        partyAlive: alive,
        partyTotal: party.count,
        itemHint: inv,
        urgency: "BAG",
        dataChips: chips,
        foeLevel: primary.foeLevel,
        foeTypes: primary.foeTypes,
        battleKind: primary.battleKind,
        tipId: "sec.bag"
      ))
    }

    // Party HP summary.
    let hpBits = party.prefix(3).map { mon in
      let n = Gen3Names.species(mon.species, tables: snap.tables)
      return "\(n) \(pct(mon.hp, mon.maxHp))%"
    }.joined(separator: " · ")
    out.append(Advice(
      foeName: primary.foeName,
      headline: "Party HP",
      detail: hpBits,
      kind: .field,
      moves: primary.moves,
      bestMove: primary.bestMove,
      allyHpPct: leadPct,
      foeHpPct: primary.foeHpPct,
      partyAlive: alive,
      partyTotal: party.count,
      itemHint: bag.inventoryLine(),
      urgency: "PARTY",
      dataChips: chips,
      foeLevel: primary.foeLevel,
      foeTypes: primary.foeTypes,
      battleKind: primary.battleKind,
      tipId: "sec.party"
    ))

    // Coverage vs last wild foe (field).
    if !snap.inBattle, lastWildFoeSpecies > 0 {
      let ranked = Gen3BattleData.suggestions(
        attackerMoves: lead.moves,
        attackerPP: lead.pp,
        attackerSpecies: lead.species,
        foeSpecies: lastWildFoeSpecies,
        tables: snap.tables,
        configId: snap.configId
      )
      if let top = ranked.first(where: { $0.power > 0 }) {
        let foeN = Gen3Names.species(lastWildFoeSpecies, tables: snap.tables)
        out.append(Advice(
          foeName: foeN,
          headline: "Vs last wild \(foeN)",
          detail: "\(leadName)'s \(top.name) · \(moveWhy(top))",
          kind: .field,
          moves: [],
          bestMove: nil,
          allyHpPct: leadPct,
          foeHpPct: nil,
          partyAlive: alive,
          partyTotal: party.count,
          itemHint: bag.inventoryLine(),
          urgency: "COVER",
          dataChips: chips,
          tipId: "sec.cover"
        ))
      }
    }

    // In-battle alternates: wild catch/chip vs trainer pace/switch.
    if snap.inBattle {
      let trainer = snap.isTrainer == true
      let foeN = primary.foeName
      if trainer {
        let pace = PhraseBank.pick(
          .trainerPace,
          seed: UInt64(snap.mapSec &* 19),
          ["foe": foeN, "party": "\(alive)/\(party.count)"]
        )
        out.append(Advice(
          foeName: foeN,
          headline: pace.0,
          detail: pace.1,
          kind: .field,
          moves: primary.moves,
          bestMove: primary.bestMove,
          allyHpPct: primary.allyHpPct,
          foeHpPct: primary.foeHpPct,
          partyAlive: alive,
          partyTotal: party.count,
          itemHint: bag.inventoryLine(),
          urgency: "TRAINER",
          dataChips: chips,
          foeLevel: primary.foeLevel,
          foeTypes: primary.foeTypes,
          battleKind: "Trainer",
          tipId: "sec.trainer.pace"
        ))
      } else {
        let chip = PhraseBank.pick(
          .wildChip,
          seed: UInt64(snap.mapSec &* 23),
          ["foe": foeN, "fp": "\(primary.foeHpPct ?? 0)", "move": primary.bestMove?.name ?? "a move"]
        )
        out.append(Advice(
          foeName: foeN,
          headline: chip.0,
          detail: chip.1,
          kind: .field,
          moves: primary.moves,
          bestMove: primary.bestMove,
          allyHpPct: primary.allyHpPct,
          foeHpPct: primary.foeHpPct,
          partyAlive: alive,
          partyTotal: party.count,
          itemHint: bag.inventoryLine(),
          urgency: "WILD",
          dataChips: chips,
          foeLevel: primary.foeLevel,
          foeTypes: primary.foeTypes,
          battleKind: "Wild",
          tipId: "sec.wild.chip"
        ))
        if bag.ballCount() > 0 {
          out.append(Advice(
            foeName: foeN,
            headline: "Catch lane open",
            detail: "Balls \(bag.ballCount()) · soften \(foeN) then throw",
            kind: .catchBall,
            moves: primary.moves,
            bestMove: primary.bestMove,
            allyHpPct: primary.allyHpPct,
            foeHpPct: primary.foeHpPct,
            partyAlive: alive,
            partyTotal: party.count,
            itemHint: bag.inventoryLine(),
            urgency: "CATCH",
            dataChips: chips,
            battleKind: "Wild",
            tipId: "sec.wild.catch"
          ))
        }
      }
      let flavor = SmartIslandVoice.flavor(
        species: lead.species, tables: snap.tables, configId: snap.configId
      )
      let personal = PhraseBank.pickPersonal(
        field: false,
        flavor: flavor,
        seed: UInt64(lead.species &* 31),
        vars: SmartIslandVoice.personalVars(
          leadName: leadName, level: lead.level, pct: leadPct, place: place, foe: foeN, flavor: flavor
        ),
        trainer: trainer
      )
      out.append(Advice(
        foeName: foeN,
        headline: personal.0,
        detail: personal.1,
        kind: .field,
        moves: primary.moves,
        bestMove: primary.bestMove,
        allyHpPct: leadPct,
        foeHpPct: primary.foeHpPct,
        partyAlive: alive,
        partyTotal: party.count,
        itemHint: bag.inventoryLine(),
        urgency: trainer ? "PARTNER·T" : "PARTNER·W",
        dataChips: chips,
        battleKind: trainer ? "Trainer" : "Wild",
        tipId: "sec.personal.battle.\(lead.species)"
      ))
    }

    // Who to talk to (tap-cycle alternates).
    if !snap.inBattle {
      for talk in SmartIslandTalkTips.tips(
        for: snap,
        stickySeed: UInt64(snap.mapSec &* 17),
        limit: 2,
        excluding: completedTalkTips
      ) {
        out.append(Advice(
          foeName: place,
          headline: talk.headline,
          detail: talk.detail,
          kind: .field,
          moves: primary.moves,
          bestMove: primary.bestMove,
          allyHpPct: leadPct,
          foeHpPct: primary.foeHpPct,
          partyAlive: alive,
          partyTotal: party.count,
          itemHint: bag.inventoryLine(),
          urgency: talk.urgency,
          dataChips: chips,
          tipId: talk.tipId
        ))
      }
      let flavor = SmartIslandVoice.flavor(
        species: lead.species, tables: snap.tables, configId: snap.configId
      )
      let personal = PhraseBank.pickPersonal(
        field: true,
        flavor: flavor,
        seed: UInt64(lead.species &* 13),
        vars: SmartIslandVoice.personalVars(
          leadName: leadName, level: lead.level, pct: leadPct, place: place, foe: nil, flavor: flavor
        )
      )
      out.append(Advice(
        foeName: place,
        headline: personal.0,
        detail: personal.1,
        kind: .field,
        moves: [],
        bestMove: nil,
        allyHpPct: leadPct,
        foeHpPct: nil,
        partyAlive: alive,
        partyTotal: party.count,
        itemHint: bag.inventoryLine(),
        urgency: "PARTNER",
        dataChips: chips,
        tipId: "sec.personal.\(lead.species)"
      ))
    }

    // Place / money soft tip.
    let moneyBit = snap.money.map { "₽\($0)" } ?? "—"
    out.append(Advice(
      foeName: place,
      headline: place,
      detail: "\(moneyBit) · \(leadName) Lv\(lead.level) · Party \(alive)/\(party.count)",
      kind: .field,
      moves: primary.moves,
      bestMove: primary.bestMove,
      allyHpPct: leadPct,
      foeHpPct: primary.foeHpPct,
      partyAlive: alive,
      partyTotal: party.count,
      itemHint: bag.inventoryLine(),
      urgency: "INFO",
      dataChips: chips,
      foeLevel: primary.foeLevel,
      foeTypes: primary.foeTypes,
      battleKind: primary.battleKind,
      tipId: "sec.info"
    ))

    // Don't duplicate the primary headline.
    return out.filter { $0.headline != primary.headline || $0.detail != primary.detail }
  }

  /// Thin wrapper so SmartIslandMemory can read bag counts without touching private BagIndex.
  struct BagIndexPublic {
    private let bag: BagIndex
    init(snap: CompanionSnapshot) { bag = BagIndex(snap: snap) }
    func ballCount() -> Int { bag.ballCount() }
    func inventoryLine() -> String? { bag.inventoryLine() }
  }

  /// itemId → total quantity across pockets (for quest completion).
  static func itemQuantities(from snap: CompanionSnapshot) -> [Int: Int] {
    var map: [Int: Int] = [:]
    for item in snap.bag where item.itemId > 0 && item.quantity > 0 {
      map[item.itemId, default: 0] += item.quantity
    }
    return map
  }

  /// species → count in party (eggs included when species > 0).
  static func speciesCounts(from snap: CompanionSnapshot) -> [Int: Int] {
    var map: [Int: Int] = [:]
    for mon in snap.party where mon.species > 0 {
      map[mon.species, default: 0] += 1
    }
    return map
  }

  // MARK: - Overworld / field

  private static func fieldAdvice(
    from snap: CompanionSnapshot,
    lastWildFoeSpecies: Int,
    stickySeed: UInt64,
    completedTalkTips: Set<String> = []
  ) -> Advice? {
    let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
    guard !party.isEmpty else { return nil }
    let bag = BagIndex(snap: snap)
    let alive = party.filter { $0.hp > 0 }.count
    let total = party.count
    let lead = party.first(where: { $0.hp > 0 }) ?? party.first!
    let leadPct = pct(lead.hp, lead.maxHp)
    let place = placeName(snap)
    let leadName = Gen3Names.species(lead.species, tables: snap.tables)
    let bagLine = bag.inventoryLine()
    let chips = dataChips(from: snap, bagBalls: bag.ballCount())
    let moneyBit = snap.money.map { " · ₽\($0)" } ?? ""

    func base(
      headline: String,
      detail: String,
      kind: ActionKind,
      urgency: String?,
      allyPct: Int = leadPct,
      tipId: String
    ) -> Advice {
      Advice(
        foeName: place,
        headline: headline,
        detail: detail,
        kind: kind,
        moves: [],
        bestMove: nil,
        allyHpPct: allyPct,
        foeHpPct: nil,
        partyAlive: alive,
        partyTotal: total,
        itemHint: bagLine,
        urgency: urgency,
        dataChips: chips,
        tipId: tipId
      )
    }

    // Fainted mons in party.
    let fainted = party.filter { $0.hp <= 0 }
    if !fainted.isEmpty {
      let who = Gen3Names.species(fainted[0].species, tables: snap.tables)
      if let revive = bag.bestRevive() {
        let line = PhraseBank.pick(
          .revive,
          seed: stickySeed,
          ["who": who, "item": revive.name, "qty": "\(revive.qty)", "count": "\(fainted.count)"]
        )
        return base(headline: line.0, detail: line.1, kind: .revive, urgency: "PARTY", tipId: "field.revive")
      }
      return base(
        headline: "Pokémon Center — \(fainted.count) fainted",
        detail: alive > 0 ? "Heal the team before the next fight" : "Blacked out risk · heal up",
        kind: .field,
        urgency: "HEAL UP",
        tipId: "field.center"
      )
    }

    // Status on any party mon.
    for mon in party {
      guard let status = mon.statusLabel else { continue }
      let who = Gen3Names.species(mon.species, tables: snap.tables)
      let vars: [String: String] = [
        "who": who, "status": status,
        "item": bag.bestStatusCure(for: status)?.name ?? "Full Heal",
        "qty": "\(bag.bestStatusCure(for: status)?.qty ?? 0)",
      ]
      let line = PhraseBank.pick(.status, seed: stickySeed &+ UInt64(mon.species), vars)
      return base(
        headline: line.0,
        detail: bag.bestStatusCure(for: status) != nil ? line.1 : "Grab an antidote / Full Heal when you can",
        kind: .cure,
        urgency: status,
        allyPct: pct(mon.hp, mon.maxHp),
        tipId: "field.status.\(status)"
      )
    }

    // Hurt party — suggest potions from bag.
    let hurt = party
      .map { (mon: $0, p: pct($0.hp, $0.maxHp)) }
      .filter { $0.p > 0 && $0.p <= 60 }
      .sorted { $0.p < $1.p }
    if let worst = hurt.first {
      let missing = max(0, worst.mon.maxHp - worst.mon.hp)
      let who = Gen3Names.species(worst.mon.species, tables: snap.tables)
      if let heal = bag.bestHeal(missingHp: missing, maxHp: worst.mon.maxHp, forceAny: worst.p <= 25) {
        let line = PhraseBank.pick(
          worst.p <= 25 ? .criticalHpWild : .healNudge,
          seed: stickySeed &+ UInt64(worst.p),
          [
            "who": who, "item": heal.name, "qty": "\(heal.qty)", "pct": "\(worst.p)",
            "hp": "\(worst.mon.hp)", "max": "\(worst.mon.maxHp)",
            "hpBit": "\(worst.p)% HP", "foeBit": "",
          ]
        )
        return base(
          headline: line.0,
          detail: line.1,
          kind: .heal,
          urgency: worst.p <= 25 ? "CRITICAL" : "LOW HP",
          allyPct: worst.p,
          tipId: "field.heal"
        )
      }
      if worst.p <= 35 {
        return base(
          headline: "\(who) needs a heal",
          detail: "\(worst.p)% HP · Center or buy potions",
          kind: .heal,
          urgency: "LOW HP",
          allyPct: worst.p,
          tipId: "field.heal.need"
        )
      }
    }

    // Low on balls while exploring.
    if bag.ballCount() == 0 {
      let line = PhraseBank.pick(.bagEmpty, seed: stickySeed, ["place": place])
      return base(headline: line.0, detail: line.1, kind: .field, urgency: "BAG", tipId: "field.balls")
    }

    // Who to talk to — GuideAreas PEOPLE + building heuristics (before soft idle).
    if stickySeed % 2 == 0,
       let talk = SmartIslandTalkTips.primaryTip(
         for: snap, stickySeed: stickySeed, excluding: completedTalkTips
       ) {
      return base(
        headline: talk.headline,
        detail: talk.detail,
        kind: .field,
        urgency: talk.urgency,
        tipId: talk.tipId
      )
    }

    // Soft coverage tip vs last wild when seed picks it.
    if lastWildFoeSpecies > 0, stickySeed % 3 == 0 {
      let ranked = Gen3BattleData.suggestions(
        attackerMoves: lead.moves,
        attackerPP: lead.pp,
        attackerSpecies: lead.species,
        foeSpecies: lastWildFoeSpecies,
        tables: snap.tables,
        configId: snap.configId
      )
      if let top = ranked.first(where: { $0.power > 0 }) {
        let foeN = Gen3Names.species(lastWildFoeSpecies, tables: snap.tables)
        return base(
          headline: "Ready for another \(foeN)?",
          detail: "\(leadName)'s \(top.name) · \(moveWhy(top))",
          kind: .field,
          urgency: "COVER",
          tipId: "field.cover"
        )
      }
    }

    // Personal lead voice / soft idle.
    let flavor = SmartIslandVoice.flavor(
      species: lead.species, tables: snap.tables, configId: snap.configId
    )
    let personal = PhraseBank.pickPersonal(
      field: true,
      flavor: flavor,
      seed: stickySeed &+ UInt64(lead.species),
      vars: SmartIslandVoice.personalVars(
        leadName: leadName, level: lead.level, pct: leadPct, place: place, foe: nil, flavor: flavor
      ).merging([
        "party": "\(alive)/\(total)",
        "money": moneyBit,
        "bag": bagLine ?? "—",
      ]) { _, b in b }
    )
    let idle = PhraseBank.pick(
      .fieldIdle,
      seed: stickySeed,
      [
        "lead": leadName,
        "level": "\(lead.level)",
        "pct": "\(leadPct)",
        "place": place,
        "party": "\(alive)/\(total)",
        "money": moneyBit,
        "bag": bagLine ?? "—",
      ]
    )
    // Prefer personal lines most of the time; keep classic idle as variety.
    let line = stickySeed % 5 == 0 ? idle : personal
    return Advice(
      foeName: place,
      headline: line.0,
      detail: line.1,
      kind: .field,
      moves: [],
      bestMove: nil,
      allyHpPct: leadPct,
      foeHpPct: nil,
      partyAlive: alive,
      partyTotal: total,
      itemHint: bag.battleReadyHint() ?? bagLine,
      urgency: stickySeed % 5 == 0 ? "FIELD" : "PARTNER",
      dataChips: chips,
      tipId: stickySeed % 5 == 0 ? "field.idle" : "field.personal.\(lead.species)"
    )
  }

  // MARK: - Battle

  private static func battleAdvice(from snap: CompanionSnapshot, stickySeed: UInt64) -> Advice? {
    let tip = Gen3BattleData.liveSuggestions(from: snap)
    let moves = tip?.moves ?? []
    let best = moves.first(where: { $0.power > 0 && $0.pp > 0 && $0.multiplierPct > 0 })
      ?? moves.first(where: { $0.pp > 0 })
    let foeName = tip?.foeName
      ?? snap.battleMons[1].map { Gen3Names.species($0.species, tables: snap.tables) }
      ?? "Foe"

    let allyBattle = snap.battleMons[0]
    let foeBattle = snap.battleMons[1]
    let allyParty = snap.party.first(where: { !$0.isEgg && $0.species > 0 && $0.hp > 0 })
      ?? snap.party.first(where: { !$0.isEgg && $0.species > 0 })

    let allyHp = allyBattle.map { $0.hp } ?? allyParty?.hp ?? 0
    var allyMax = allyBattle.map { $0.maxHp } ?? 0
    if allyMax <= 0 { allyMax = allyParty?.maxHp ?? 0 }
    if let partyMax = allyParty?.maxHp, partyMax > allyMax, allyHp <= partyMax {
      allyMax = partyMax
    }
    allyMax = max(1, allyMax)
    let allyPct = pct(allyHp, allyMax)
    let allyStatus = statusLabel(allyBattle?.status1 ?? allyParty.map { UInt32($0.status) } ?? 0)

    let foeHp = foeBattle.map { $0.hp }
    let foeMax = foeBattle.map { max(1, $0.maxHp) }
    let foePct: Int? = {
      guard let hp = foeHp, let maxHp = foeMax, maxHp > 0 else { return nil }
      return pct(hp, maxHp)
    }()
    let foeLevel = foeBattle?.level
    let foeTypes: String? = {
      guard let sid = foeBattle?.species, sid > 0 else { return nil }
      guard let types = Gen3BattleData.speciesTypes(sid, tables: snap.tables, configId: snap.configId) else { return nil }
      var names: [String] = []
      let t1 = Gen3BattleData.typeName(types.type1, tables: snap.tables, configId: snap.configId)
      if !t1.isEmpty { names.append(t1) }
      let t2 = Gen3BattleData.typeName(types.type2, tables: snap.tables, configId: snap.configId)
      if !t2.isEmpty, types.type2 != types.type1 { names.append(t2) }
      return names.isEmpty ? nil : names.joined(separator: "/")
    }()
    let battleKind = snap.isTrainer == true ? "Trainer" : "Wild"

    let alive = snap.party.filter { !$0.isEgg && $0.species > 0 && $0.hp > 0 }.count
    let total = snap.party.filter { !$0.isEgg && $0.species > 0 }.count
    let bag = BagIndex(snap: snap)
    let bagLine = bag.inventoryLine()
    let chips = dataChips(from: snap, bagBalls: bag.ballCount())

    func pack(
      headline: String,
      detail: String,
      kind: ActionKind,
      urgency: String?,
      tipId: String,
      itemHint: String? = bagLine,
      ally: Int = allyPct
    ) -> Advice {
      Advice(
        foeName: foeName,
        headline: headline,
        detail: detail,
        kind: kind,
        moves: moves,
        bestMove: best,
        allyHpPct: ally,
        foeHpPct: foePct,
        partyAlive: alive,
        partyTotal: total,
        itemHint: itemHint,
        urgency: urgency,
        dataChips: chips,
        foeLevel: foeLevel,
        foeTypes: foeTypes,
        battleKind: battleKind,
        tipId: tipId
      )
    }

    // 0) Foe KO — celebrate.
    if let fp = foePct, fp <= 0, allyHp > 0 {
      let line = WinLose.winLine(foe: foeName, trainer: snap.isTrainer == true, seed: stickySeed)
      return pack(headline: line.headline, detail: line.detail, kind: .celebrate, urgency: "YOU WIN", tipId: "bat.win", ally: allyPct)
    }

    // 1) Fainted lead.
    if allyHp <= 0 {
      if alive <= 0 {
        let line = WinLose.loseLine(foe: foeName, trainer: snap.isTrainer == true, seed: stickySeed)
        return pack(headline: line.headline, detail: line.detail, kind: .console, urgency: "DEFEAT", tipId: "bat.lose", ally: 0)
      }
      if let revive = bag.bestRevive() {
        let line = PhraseBank.pick(
          .revive,
          seed: stickySeed,
          ["who": "Lead", "item": revive.name, "qty": "\(revive.qty)", "count": "1"]
        )
        return pack(headline: line.0, detail: line.1, kind: .revive, urgency: "FAINTED", tipId: "bat.revive", ally: 0)
      }
      let line = PhraseBank.pick(
        snap.isTrainer == true ? .faintedTrainer : .faintedWild,
        seed: stickySeed,
        ["alive": "\(alive)"]
      )
      return pack(headline: line.0, detail: line.1, kind: .switchOut, urgency: "FAINTED", tipId: "bat.faint", ally: 0)
    }

    // 2) Status cure from bag.
    if let status = allyStatus, shouldCure(status: status) {
      if let cure = bag.bestStatusCure(for: status) {
        let line = PhraseBank.pick(
          .status,
          seed: stickySeed,
          ["who": "You", "status": status, "item": cure.name, "qty": "\(cure.qty)"]
        )
        return pack(headline: line.0, detail: line.1, kind: .cure, urgency: status, tipId: "bat.status")
      }
    }

    // 3) Critical / low HP — bag heal.
    let missing = max(0, allyMax - allyHp)
    let criticalHp = allyHp > 0 && (allyHp <= 5 || allyPct <= 15)
    let healThreshold = snap.isTrainer == true ? 45 : 35
    if allyPct > 0, criticalHp || allyPct <= healThreshold {
      let foeBit = foePct.map { " · foe \($0)%" } ?? ""
      if let heal = bag.bestHeal(missingHp: missing, maxHp: allyMax, forceAny: criticalHp) {
        let hpBit = allyHp <= 5 ? "\(allyHp) HP left" : "You \(allyPct)%"
        let line = PhraseBank.pick(
          snap.isTrainer == true ? .criticalHpTrainer : .criticalHpWild,
          seed: stickySeed,
          ["item": heal.name, "qty": "\(heal.qty)", "hpBit": hpBit, "foeBit": foeBit, "who": "You", "pct": "\(allyPct)", "hp": "\(allyHp)", "max": "\(allyMax)"]
        )
        return pack(
          headline: line.0,
          detail: line.1,
          kind: .heal,
          urgency: criticalHp ? "CRITICAL" : (snap.isTrainer == true ? "TRAINER HP" : "WILD HP"),
          tipId: snap.isTrainer == true ? "bat.heal.trainer" : "bat.heal.wild"
        )
      }
      if criticalHp || allyPct <= 25 {
        let detail = snap.isTrainer == true
          ? "You \(allyPct)% · trainer fight — heal before their next mon"
          : "You \(allyPct)% (\(allyHp)/\(allyMax))\(foeBit) · no potion matched"
        return pack(
          headline: "Open bag — heal!",
          detail: detail,
          kind: .heal,
          urgency: "CRITICAL",
          tipId: "bat.heal.need"
        )
      }
    }

    // 3b) Wild: soft chip tip when foe is mid-HP (catch prep) — before setup/switch.
    if snap.isTrainer != true, let fp = foePct, fp > 40, fp <= 70, allyPct >= 50,
       let best, best.power > 0, best.pp > 0, stickySeed % 2 == 0 {
      let line = PhraseBank.pick(
        .wildChip,
        seed: stickySeed,
        ["foe": foeName, "fp": "\(fp)", "move": best.name]
      )
      return pack(
        headline: line.0,
        detail: "\(line.1) · or \(best.name)",
        kind: .attack,
        urgency: "CHIP",
        tipId: "bat.wild.chip"
      )
    }

    // 3c) Trainer: pace tip when party is thin or foe still healthy.
    if snap.isTrainer == true, allyPct >= 40, let fp = foePct, fp >= 50,
       stickySeed % 3 == 0 {
      let line = PhraseBank.pick(
        .trainerPace,
        seed: stickySeed,
        ["foe": foeName, "party": "\(alive)/\(total)"]
      )
      return pack(
        headline: line.0,
        detail: line.1,
        kind: .field,
        urgency: "TRAINER",
        tipId: "bat.trainer.pace"
      )
    }

    // 4) Wild catch — ball from bag.
    if snap.isTrainer != true, let fp = foePct, fp <= 40 {
      if let ball = bag.bestBall() {
        let moveBit = best.map { "or chip with \($0.name)" } ?? "then throw"
        let line = PhraseBank.pick(
          .catchWindow,
          seed: stickySeed,
          ["ball": ball.name, "qty": "\(ball.qty)", "fp": "\(fp)", "foe": foeName, "moveBit": moveBit]
        )
        return pack(headline: line.0, detail: line.1, kind: .catchBall, urgency: "CATCH", tipId: "bat.catch")
      }
      if fp <= 25 {
        return pack(
          headline: "Catch window — no balls!",
          detail: "Foe \(fp)% · bag has no Poké Balls",
          kind: .catchBall,
          urgency: "CATCH",
          tipId: "bat.catch.empty"
        )
      }
    }

    // 5) X item once at the start of a favorable fight (foe still healthy).
    if allyPct >= 60, let fp = foePct, fp >= 70,
       let best, best.multiplierPct >= 200, best.pp > 0,
       let xItem = bag.bestOffenseBoost(physical: isPhysicalMove(best)) {
      let why = moveWhy(best)
      let line = PhraseBank.pick(
        snap.isTrainer == true ? .setupTrainer : .setupWild,
        seed: stickySeed,
        ["item": xItem.name, "qty": "\(xItem.qty)", "move": best.name, "why": why, "foe": foeName]
      )
      return pack(
        headline: line.0,
        detail: line.1,
        kind: .setup,
        urgency: snap.isTrainer == true ? "TRAINER SETUP" : "WILD SETUP",
        tipId: snap.isTrainer == true ? "bat.setup.trainer" : "bat.setup.wild"
      )
    }

    // 6) PP restore when the best damaging move is dry.
    if let best, best.power > 0, best.pp <= 0, let ether = bag.bestPPRestore() {
      return pack(
        headline: "Bag → \(ether.name)×\(ether.qty)",
        detail: "\(best.name) is out of PP · restore then fire",
        kind: .setup,
        urgency: "NO PP",
        tipId: "bat.pp"
      )
    }

    // 7) Bad matchup — switch.
    if let switchHint = switchSuggestion(
      snap: snap,
      currentBest: best,
      foeSpecies: foeBattle?.species ?? 0,
      allyPct: allyPct
    ) {
      let trainer = snap.isTrainer == true
      let line = PhraseBank.pick(
        trainer ? .switchOutTrainer : .switchOutWild,
        seed: stickySeed,
        ["alt": switchHint.name, "why": switchHint.detail, "foe": foeName, "lead": Gen3Names.species(allyBattle?.species ?? 0, tables: snap.tables)]
      )
      return pack(
        headline: line.0,
        detail: line.1,
        kind: .switchOut,
        urgency: trainer ? "TRAINER MATCHUP" : "WILD MATCHUP",
        tipId: trainer ? "bat.switch.trainer" : "bat.switch.wild",
        itemHint: bag.quickSupportHint(allyPct: allyPct, allyStatus: allyStatus) ?? bagLine
      )
    }

    // 8) Default attack — wild vs trainer personal voice + bag.
    if let best, best.power > 0 {
      let trainer = snap.isTrainer == true
      let support = bag.quickSupportHint(allyPct: allyPct, allyStatus: allyStatus)
      let why = moveWhy(best)
      let allyName = Gen3Names.species(allyBattle?.species ?? snap.party.first?.species ?? 0, tables: snap.tables)
      let flavor = SmartIslandVoice.flavor(
        species: allyBattle?.species ?? snap.party.first?.species ?? 0,
        tables: snap.tables,
        configId: snap.configId
      )
      let personal = PhraseBank.pickPersonal(
        field: false,
        flavor: flavor,
        seed: stickySeed &+ UInt64(best.slot),
        vars: SmartIslandVoice.personalVars(
          leadName: allyName,
          level: allyBattle?.level ?? 0,
          pct: allyPct,
          place: placeName(snap),
          foe: foeName,
          flavor: flavor
        ),
        trainer: trainer
      )
      let cat: PhraseBank.Category
      if best.multiplierPct >= 200 {
        cat = .superEffective
      } else if best.multiplierPct < 100 {
        cat = .resisted
      } else {
        cat = trainer ? .attackTrainer : .attackWild
      }
      let line = PhraseBank.pick(
        cat,
        seed: stickySeed,
        ["move": best.name, "why": why, "foe": foeName]
      )
      let detail = stickySeed % 2 == 0 ? "\(line.1) · \(personal.0)" : personal.1
      let urgency: String = {
        if best.multiplierPct >= 200 { return "SUPER EFFECTIVE" }
        if best.stab { return trainer ? "TRAINER STAB" : "WILD STAB" }
        return trainer ? "TRAINER" : "WILD"
      }()
      return pack(
        headline: line.0,
        detail: detail,
        kind: .attack,
        urgency: urgency,
        tipId: trainer
          ? "bat.atk.trainer.\(allyBattle?.species ?? 0)"
          : "bat.atk.wild.\(allyBattle?.species ?? 0)",
        itemHint: support ?? bagLine
      )
    }

    if let best {
      return pack(
        headline: best.power <= 0 ? "Status: \(best.name)" : "Use \(best.name)",
        detail: bag.bestPPRestore().map { "PP dry · \($0.name)×\($0.qty) in bag" }
          ?? "No damaging PP — stall or switch",
        kind: best.power <= 0 ? .setup : .attack,
        urgency: "NO PP",
        tipId: "bat.nopp"
      )
    }

    // In battle but moves not readable yet — still coach from bag + HP.
    return pack(
      headline: allyPct <= 40 ? "Watch your HP — bag ready" : "vs \(foeName)",
      detail: bagLine ?? partyLine(alive: alive, total: total),
      kind: .field,
      urgency: "BATTLE",
      tipId: "bat.wait",
      itemHint: bag.battleReadyHint()
    )
  }

  // MARK: - Helpers

  private static func pct(_ hp: Int, _ maxHp: Int) -> Int {
    Int((Double(hp) / Double(max(1, maxHp)) * 100.0).rounded())
  }

  private static func partyLine(alive: Int, total: Int) -> String {
    "Party \(alive)/\(max(total, alive))"
  }

  private static func statusLabel(_ status1: UInt32) -> String? {
    if status1 & 0x07 != 0 { return "SLP" }
    if status1 & 0x88 != 0 { return "PSN" }
    if status1 & 0x10 != 0 { return "BRN" }
    if status1 & 0x20 != 0 { return "FRZ" }
    if status1 & 0x40 != 0 { return "PAR" }
    return nil
  }

  private static func shouldCure(status: String) -> Bool {
    status == "SLP" || status == "FRZ" || status == "PAR"
  }

  private static func isPhysicalMove(_ mv: Gen3BattleData.MoveSuggestion) -> Bool {
    // Rough Gen 3 split: Fighting/Flying/Poison/Ground/Rock/Bug/Ghost/Steel → physical era;
    // modern names still work as a soft hint for X Attack vs X Special.
    let t = mv.typeName.lowercased()
    let physical: Set<String> = [
      "fighting", "flying", "poison", "ground", "rock", "bug", "ghost", "steel", "normal",
    ]
    return physical.contains(t)
  }

  private static func moveWhy(_ mv: Gen3BattleData.MoveSuggestion) -> String {
    var bits: [String] = []
    if mv.multiplierPct >= 400 { bits.append("4× super") }
    else if mv.multiplierPct >= 200 { bits.append("2× super") }
    else if mv.multiplierPct == 0 { bits.append("no effect") }
    else if mv.multiplierPct < 100 { bits.append("resisted \(mv.multiplierLabel)") }
    else { bits.append("neutral \(mv.multiplierLabel)") }
    if mv.stab { bits.append("STAB") }
    if !mv.typeName.isEmpty { bits.append(mv.typeName) }
    bits.append("pwr \(mv.effectivePower)")
    return bits.joined(separator: " · ")
  }

  private static func switchSuggestion(
    snap: CompanionSnapshot,
    currentBest: Gen3BattleData.MoveSuggestion?,
    foeSpecies: Int,
    allyPct: Int
  ) -> (name: String, detail: String)? {
    guard foeSpecies > 0 else { return nil }
    let currentPower = currentBest?.effectivePower ?? 0
    let weakHit = currentPower > 0 && (currentBest?.multiplierPct ?? 100) < 100
    let lowHp = allyPct > 0 && allyPct <= 45
    guard weakHit || lowHp else { return nil }

    let tables = snap.tables
    let configId = snap.configId
    let activeSpecies = snap.battleMons[0]?.species
      ?? snap.party.first(where: { !$0.isEgg && $0.species > 0 })?.species
      ?? 0

    var bestAlt: (name: String, power: Int, mult: Int)?
    for mon in snap.party where !mon.isEgg && mon.species > 0 && mon.hp > 0 && mon.species != activeSpecies {
      let ranked = Gen3BattleData.suggestions(
        attackerMoves: mon.moves,
        attackerPP: mon.pp,
        attackerSpecies: mon.species,
        foeSpecies: foeSpecies,
        tables: tables,
        configId: configId
      )
      guard let top = ranked.first(where: { $0.power > 0 && $0.pp > 0 }) else { continue }
      if bestAlt == nil || top.effectivePower > (bestAlt?.power ?? 0) {
        bestAlt = (Gen3Names.species(mon.species, tables: tables), top.effectivePower, top.multiplierPct)
      }
    }
    guard let alt = bestAlt else { return nil }
    let muchStronger = alt.power >= max(40, Int(Double(currentPower) * 1.5))
    let fixesMatchup = (currentBest?.multiplierPct ?? 100) < 100 && alt.mult >= 200
    guard muchStronger || fixesMatchup else { return nil }
    let why: String
    if fixesMatchup {
      why = "Better type · \(alt.name) hits \(multLabel(alt.mult))"
    } else {
      why = "Hits ~\(alt.power) eff. vs your \(currentPower)"
    }
    return (alt.name, why)
  }

  private static func multLabel(_ pct: Int) -> String {
    switch pct {
    case 0: return "0×"
    case 25: return "¼×"
    case 50: return "½×"
    case 100: return "1×"
    case 200: return "2×"
    case 400: return "4×"
    default: return String(format: "%.2g×", Double(pct) / 100.0)
    }
  }

  // MARK: - Win / lose lines

  private enum WinLose {
    static func winLine(foe: String, trainer: Bool, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) -> (headline: String, detail: String) {
      let line = PhraseBank.pick(trainer ? .winTrainer : .winWild, seed: seed, ["foe": foe])
      return (line.0, line.1)
    }

    static func loseLine(foe: String, trainer: Bool, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) -> (headline: String, detail: String) {
      let line = PhraseBank.pick(trainer ? .loseTrainer : .loseWild, seed: seed, ["foe": foe])
      return (line.0, line.1)
    }

    static func epilogue(won: Bool, foe: String, trainer: Bool) -> String {
      if won {
        return winLine(foe: foe.isEmpty ? "them" : foe, trainer: trainer).headline
      }
      return loseLine(foe: foe.isEmpty ? "them" : foe, trainer: trainer).headline
    }
  }

  static func battleEpilogue(
    previous: CompanionSnapshot?,
    current: CompanionSnapshot?
  ) -> String? {
    guard let prev = previous, prev.inBattle else { return nil }
    guard current == nil || current?.inBattle != true else { return nil }
    let foe = prev.battleMons[1]
    let ally = prev.battleMons[0]
    let allyHp = ally?.hp ?? prev.party.first(where: { !$0.isEgg && $0.species > 0 })?.hp ?? 0
    let foeHp = foe?.hp ?? 1
    let foeName = foe.map { Gen3Names.species($0.species, tables: prev.tables) } ?? "them"
    if foeHp > 0, allyHp > 0 { return nil }
    let won = foeHp <= 0
    return WinLose.epilogue(won: won, foe: foeName, trainer: prev.isTrainer == true)
  }

  // MARK: - Bag

  private struct BagHit: Equatable {
    var name: String
    var qty: Int
  }

  private struct BagIndex {
    private let entries: [(norm: String, display: String, qty: Int)]

    init(snap: CompanionSnapshot) {
      var map: [String: (String, Int)] = [:]
      for item in snap.bag where item.itemId > 0 && item.quantity > 0 {
        let display = Gen3Names.item(item.itemId, tables: snap.tables)
        guard !display.hasPrefix("Item #") else { continue }
        let key = Self.norm(display)
        let prev = map[key]?.1 ?? 0
        map[key] = (display, prev + item.quantity)
      }
      entries = map.map { (norm: $0.key, display: $0.value.0, qty: $0.value.1) }
    }

    private static func norm(_ s: String) -> String {
      s.uppercased()
        .replacingOccurrences(of: "É", with: "E")
        .replacingOccurrences(of: "é", with: "E")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "'", with: "")
    }

    private func pretty(_ raw: String) -> String {
      let lower = raw.lowercased()
      guard lower != raw else { return raw }
      return lower.split(separator: " ").map { part -> String in
        guard let f = part.first else { return String(part) }
        return String(f).uppercased() + part.dropFirst()
      }.joined(separator: " ")
    }

    private func hit(_ keys: [String]) -> BagHit? {
      for key in keys {
        let n = Self.norm(key)
        if let row = entries.first(where: { $0.norm == n && $0.qty > 0 }) {
          return BagHit(name: pretty(row.display), qty: row.qty)
        }
      }
      // Substring fallback (Prism / hack naming).
      for key in keys {
        let n = Self.norm(key)
        if let row = entries.first(where: { $0.qty > 0 && ($0.norm.contains(n) || n.contains($0.norm)) }) {
          return BagHit(name: pretty(row.display), qty: row.qty)
        }
      }
      return nil
    }

    func bestRevive() -> BagHit? {
      hit(["MAX REVIVE", "Max Revive", "REVIVE", "Revive", "REVIVAL HERB", "Revival Herb"])
    }

    func bestStatusCure(for status: String) -> BagHit? {
      if let full = hit([
        "FULL HEAL", "Full Heal", "FULL RESTORE", "Full Restore", "LUM BERRY", "Lum Berry",
        "HEAL POWDER", "LAVA COOKIE", "OLD GATEAU", "BIG MALASADA", "CASTELIACONE",
      ]) {
        return full
      }
      switch status {
      case "PSN": return hit(["ANTIDOTE", "Antidote", "PECHA BERRY", "Pecha Berry"])
      case "BRN": return hit(["BURN HEAL", "Burn Heal", "RAWST BERRY", "Rawst Berry"])
      case "FRZ": return hit(["ICE HEAL", "Ice Heal", "ASPEAR BERRY", "Aspear Berry"])
      case "SLP": return hit(["AWAKENING", "Awakening", "CHESTO BERRY", "Chesto Berry"])
      case "PAR": return hit(["PARALYZE HEAL", "PARLYZ HEAL", "Parlyz Heal", "CHERI BERRY", "Cheri Berry"])
      default: return nil
      }
    }

    func bestHeal(missingHp: Int, maxHp: Int, forceAny: Bool = false) -> BagHit? {
      let ranked: [(keys: [String], amount: Int)] = [
        (["ORAN BERRY", "Oran Berry"], 10),
        (["POTION", "Potion"], 20),
        (["FRESH WATER", "Fresh Water"], 30),
        (["SITRUS BERRY", "Sitrus Berry"], 30),
        (["SUPER POTION", "Super Potion", "SODA POP", "Soda Pop"], 50),
        (["LEMONADE", "Lemonade"], 70),
        (["MOOMOO MILK", "Moomoo Milk", "BERRY JUICE", "Berry Juice"], 100),
        (["HYPER POTION", "Hyper Potion"], 200),
        (["MAX POTION", "Max Potion"], 9999),
        (["FULL RESTORE", "Full Restore"], 9999),
      ]
      var bestCover: (BagHit, Int)?
      var strongest: (BagHit, Int)?
      for row in ranked {
        guard let item = hit(row.keys) else { continue }
        if strongest == nil || row.amount > (strongest?.1 ?? 0) {
          strongest = (item, row.amount)
        }
        if row.amount >= missingHp {
          if bestCover == nil || row.amount < (bestCover?.1 ?? Int.max) {
            bestCover = (item, row.amount)
          }
        }
      }
      if let cover = bestCover { return cover.0 }
      if forceAny || missingHp >= max(8, maxHp / 8) { return strongest?.0 }
      return nil
    }

    func bestBall() -> BagHit? {
      hit([
        "ULTRA BALL", "Ultra Ball", "GREAT BALL", "Great Ball",
        "HEAL BALL", "Heal Ball", "NET BALL", "Net Ball",
        "DUSK BALL", "Dusk Ball", "QUICK BALL", "Quick Ball",
        "TIMER BALL", "Timer Ball", "NEST BALL", "Nest Ball",
        "POKE BALL", "POKé BALL", "Poké Ball", "Master Ball",
      ])
    }

    func bestPPRestore() -> BagHit? {
      hit(["MAX ETHER", "Max Ether", "ETHER", "Ether", "MAX ELIXIR", "Max Elixir", "ELIXIR", "Elixir", "LEPPA BERRY", "Leppa Berry"])
    }

    func bestOffenseBoost(physical: Bool) -> BagHit? {
      if physical {
        return hit(["X ATTACK", "X Attack", "X ATTACK 2", "X ATTACK 3", "X ATTACK 6"])
      }
      return hit(["X SP. ATK", "X SP ATK", "X SPECIAL", "X Special", "X SP. ATK 2", "X SP. ATK 3"])
          ?? hit(["X ATTACK", "X Attack"])
    }

    func ballCount() -> Int {
      entries.reduce(0) { sum, row in
        let n = row.norm
        guard n.contains("BALL") else { return sum }
        return sum + row.qty
      }
    }

    /// Compact bag strip for the island side hint.
    func inventoryLine() -> String? {
      var bits: [String] = []
      if let h = bestHeal(missingHp: 50, maxHp: 100, forceAny: true) {
        bits.append("\(h.name)×\(h.qty)")
      }
      if let b = bestBall() {
        bits.append("\(b.name)×\(b.qty)")
      }
      if let r = bestRevive() {
        bits.append("\(r.name)×\(r.qty)")
      }
      guard !bits.isEmpty else {
        return entries.isEmpty ? "Bag empty" : "Bag \(entries.count) stacks"
      }
      return bits.prefix(3).joined(separator: " · ")
    }

    func battleReadyHint() -> String? {
      inventoryLine().map { "Bag \($0)" }
    }

    func quickSupportHint(allyPct: Int, allyStatus: String?) -> String? {
      if let status = allyStatus, let cure = bestStatusCure(for: status) {
        return "Bag \(cure.name)×\(cure.qty)"
      }
      if allyPct <= 55, let heal = bestHeal(missingHp: 50, maxHp: 100, forceAny: true) {
        return "Bag \(heal.name)×\(heal.qty)"
      }
      return inventoryLine()
    }
  }
}
