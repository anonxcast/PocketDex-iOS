import Foundation

/// Session memory for Smart Island — notices what you just did and holds short-lived event tips.
@MainActor
final class SmartIslandMemory {
  static let shared = SmartIslandMemory()

  /// How long a soft tip (talk / partner / idle) stays on screen before rotating.
  private static let softHold: TimeInterval = 14.0
  /// How long a transition event (new area / talk nudge) stays pinned.
  private static let eventHold: TimeInterval = 12.0
  /// Quest “you got it” flash.
  private static let celebrateHold: TimeInterval = 6.0
  /// Battle win / lose island tip — keep it punchy, not sticky.
  private static let battleResultHold: TimeInterval = 3.0
  /// Opening “let’s play” before overworld coaching kicks in.
  private static let welcomeHold: TimeInterval = 22.0
  /// Don’t treat title-screen RAM noise as “started playing”.
  private static let welcomeMinBeforeMapDismiss: TimeInterval = 5.0
  /// Minimum gap between map soft-events while walking town doors / interiors.
  private static let mapEventCooldown: TimeInterval = 20.0
  private static let completedTipsKeyPrefix = "pocketdex.smartIsland.done."

  private struct PendingQuest {
    var tipId: String
    var reward: SmartIslandTalkTips.Reward
    var label: String
    var mapSec: Int
    var configId: String
  }

  private var previous: CompanionSnapshot?
  private var eventAdvice: Gen3BattleCoach.Advice?
  private var eventUntil: Date = .distantPast
  private var tipCycle: Int = 0
  private var lastSituationKey: String = ""
  /// Soft tip currently held on the island (avoids talk ↔ partner thrash).
  private var pinnedSoft: Gen3BattleCoach.Advice?
  private var pinnedSoftUntil: Date = .distantPast
  private var lastMapEventAt: Date = .distantPast
  /// Talk tips the island already coached this session (awaiting reward).
  private var pendingQuests: [PendingQuest] = []
  /// Completed talk tip ids (persisted per ROM) — never re-shown.
  private(set) var completedTalkTips: Set<String> = []
  private var completedTipsConfigId: String = ""
  /// Session opening — suppress overworld tips until welcome ends / play starts.
  private var welcomeDone: Bool = false
  private var welcomeStartedAt: Date = .distantPast
  private var welcomeUntil: Date = .distantPast
  private var welcomeAdvice: Gen3BattleCoach.Advice?
  private var welcomeAnchor: (mapGroup: Int, mapNum: Int)?
  private var welcomeConfigId: String = ""
  /// Last wild foe species (for soft field coverage hints).
  private(set) var lastWildFoeSpecies: Int = 0
  private var stickySeed: UInt64 = 0xC0FFEE

  /// One-shot FX pulses (ball throw / catch result) — not tied to the tip text.
  private var pulseQueue: [SmartIslandFXPulse] = []
  private var pulseNonce: UInt64 = 0
  private var pendingCatch: PendingCatch?
  /// Tip to pin after catch FX resolves (wins over other soft events this tick).
  private var catchTipOverride: Gen3BattleCoach.Advice?

  private struct PendingCatch {
    var foeSpecies: Int
    var partyCount: Int
    var speciesCounts: [Int: Int]
    var thrownAt: Date
    /// Lead HP at throw — drop while still wild = broke free (fight resumed).
    var leadHp: Int
    var dexCaught: Int
  }

  /// Poll companion faster while a ball shake is unresolved.
  var wantsFastCompanionPoll: Bool { pendingCatch != nil }

  func reset() {
    previous = nil
    eventAdvice = nil
    eventUntil = .distantPast
    tipCycle = 0
    lastSituationKey = ""
    pinnedSoft = nil
    pinnedSoftUntil = .distantPast
    lastMapEventAt = .distantPast
    pendingQuests = []
    islandSecondaryCount = 0
    welcomeDone = false
    welcomeStartedAt = .distantPast
    welcomeUntil = .distantPast
    welcomeAdvice = nil
    welcomeAnchor = nil
    welcomeConfigId = ""
    lastWildFoeSpecies = 0
    stickySeed = 0xC0FFEE
    pulseQueue.removeAll()
    pendingCatch = nil
    catchTipOverride = nil
    // Keep completedTalkTips across clear() so done quests stay done for the ROM.
  }

  func emitFX(_ kind: SmartIslandFXKind) {
    pulseNonce &+= 1
    pulseQueue.append(SmartIslandFXPulse(kind: kind, nonce: pulseNonce))
  }

  /// Take the next pending pulse (if any) for the HUD to play.
  func consumePulse() -> SmartIslandFXPulse? {
    guard !pulseQueue.isEmpty else { return nil }
    return pulseQueue.removeFirst()
  }

  /// Drain every queued pulse so throw + result published in the same tick both play.
  func consumeAllPulses() -> [SmartIslandFXPulse] {
    let all = pulseQueue
    pulseQueue.removeAll(keepingCapacity: true)
    return all
  }

  /// Advance memory from the previous snap → current; return the tip to show.
  func observe(_ snap: CompanionSnapshot?) -> Gen3BattleCoach.Advice? {
    defer { previous = snap }
    guard let snap else {
      eventAdvice = nil
      pinnedSoft = nil
      welcomeAdvice = nil
      return nil
    }

    loadCompletedTipsIfNeeded(configId: snap.configId)

    catchTipOverride = nil
    // Resolve catch outcome from a prior ball throw (success / fail FX).
    resolvePendingCatch(previous: previous, current: snap)

    // New ROM / config → always re-greet (don’t inherit welcomeDone from last game).
    if snap.configId != welcomeConfigId {
      welcomeConfigId = snap.configId
      welcomeDone = false
      welcomeAdvice = nil
      welcomeAnchor = nil
      welcomeStartedAt = .distantPast
      welcomeUntil = .distantPast
      // Fresh phrase rotation per ROM launch.
      let cfgSeed = snap.configId.utf8.reduce(UInt64(0)) { ($0 &* 17) &+ UInt64($1) }
      stickySeed &+= 0xA5A5_5A5A &+ cfgSeed
    }

    // Title / load screen: greet first — don't dump overworld tips before Play.
    if !welcomeDone {
      if welcomeAdvice == nil {
        let welcome = makeWelcomeAdvice(snap)
        welcomeAdvice = welcome
        welcomeStartedAt = Date()
        welcomeUntil = welcomeStartedAt.addingTimeInterval(Self.welcomeHold)
        welcomeAnchor = (snap.mapGroup, snap.mapNum)
        pinnedSoft = welcome
        pinnedSoftUntil = welcomeUntil
        tipCycle = 0
        // Skip secondary flip on the opening line — show WELCOME clean.
        return welcome
      }

      if shouldEndWelcome(snap) {
        welcomeDone = true
        welcomeAdvice = nil
        // Fall through into normal coaching for this sample.
      } else if let welcome = welcomeAdvice {
        var held = welcome
        let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
        let lead = party.first(where: { $0.hp > 0 }) ?? party.first
        held.allyHpPct = lead.map { Gen3BattleCoach.hpPct($0.hp, $0.maxHp) } ?? held.allyHpPct
        held.partyAlive = party.filter { $0.hp > 0 }.count
        held.partyTotal = party.count
        held.dataChips = Gen3BattleCoach.dataChips(
          from: snap,
          bagBalls: Gen3BattleCoach.BagIndexPublic(snap: snap).ballCount()
        )
        held.itemHint = "Tap island to skip · start the game when ready"
        held.foeName = snap.gameName.isEmpty ? held.foeName : snap.gameName
        held.urgency = "WELCOME"
        pinnedSoft = held
        return held
      }
    }

    if let event = detectEvent(from: previous, to: snap) {
      let hold: TimeInterval
      let tip = event.tipId ?? ""
      if tip.hasPrefix("bat.") || tip == "evt.money"
          || event.urgency == "YOU WIN" || event.urgency == "DEFEAT" {
        hold = Self.battleResultHold
      } else if event.kind == .celebrate {
        hold = Self.celebrateHold
      } else {
        hold = Self.eventHold
      }
      eventAdvice = event
      eventUntil = Date().addingTimeInterval(hold)
      tipCycle = 0
      // Hold the event as the soft pin so composeAdvice can't thrash under it.
      pinnedSoft = event
      pinnedSoftUntil = eventUntil
    }

    // Catch result tip + FX beat money/area chatter from the same transition.
    if let catchTip = catchTipOverride {
      eventAdvice = catchTip
      eventUntil = Date().addingTimeInterval(3.4)
      tipCycle = 0
      pinnedSoft = catchTip
      pinnedSoftUntil = eventUntil
      catchTipOverride = nil
    }

    if snap.inBattle,
       snap.isTrainer != true,
       let foe = snap.battleMons[1], foe.species > 0 {
      lastWildFoeSpecies = foe.species
    }

    let base = Gen3BattleCoach.composeAdvice(
      from: snap,
      lastWildFoeSpecies: lastWildFoeSpecies,
      stickySeed: stickySeed,
      completedTalkTips: completedTalkTips
    )
    guard let fresh = base else { return nil }

    // Urgent coaching always wins (heal / battle calls / catch) — but not over a live celebrate.
    let celebrating = eventAdvice?.kind == .celebrate && Date() < eventUntil
    if Self.isUrgent(fresh), !celebrating {
      pinnedSoft = nil
      eventAdvice = nil
      lastSituationKey = situationKey(fresh)
      return finish(fresh, snap: snap)
    }

    // Active event still running — keep it (refresh HP chips only).
    if let event = eventAdvice, Date() < eventUntil,
       event.kind == .field || event.kind == .celebrate {
      var held = event
      held.allyHpPct = fresh.allyHpPct
      held.partyAlive = fresh.partyAlive
      held.partyTotal = fresh.partyTotal
      held.dataChips = fresh.dataChips
      held.itemHint = fresh.itemHint ?? held.itemHint
      if event.kind == .field { held.foeName = fresh.foeName }
      return finish(held, snap: snap)
    }
    if Date() >= eventUntil {
      eventAdvice = nil
    }

    // Soft tip pin — don't swap talk ↔ partner every sample.
    if let pinned = pinnedSoft, Date() < pinnedSoftUntil, Self.isSoft(pinned) {
      var held = pinned
      held.allyHpPct = fresh.allyHpPct
      held.partyAlive = fresh.partyAlive
      held.partyTotal = fresh.partyTotal
      held.dataChips = fresh.dataChips
      held.itemHint = fresh.itemHint ?? held.itemHint
      // Keep place name fresh when the pin was a talk tip for this area.
      if held.kind == .field { held.foeName = fresh.foeName }
      return finish(held, snap: snap)
    }

    // Time for a new soft tip — rotate sticky seed only here (or on tap).
    stickySeed &+= 0x9E37_79B9
    let rotated = Gen3BattleCoach.composeAdvice(
      from: snap,
      lastWildFoeSpecies: lastWildFoeSpecies,
      stickySeed: stickySeed,
      completedTalkTips: completedTalkTips
    ) ?? fresh
    let chosen = Self.isSoft(rotated) ? rotated : fresh
    pinnedSoft = chosen
    let pinHold: TimeInterval
    if chosen.kind == .celebrate || chosen.kind == .console
        || chosen.tipId == "bat.win" || chosen.tipId == "bat.lose"
        || chosen.urgency == "YOU WIN" || chosen.urgency == "DEFEAT" {
      pinHold = Self.battleResultHold
    } else {
      pinHold = Self.softHold
    }
    pinnedSoftUntil = Date().addingTimeInterval(pinHold)
    tipCycle = 0
    lastSituationKey = situationKey(chosen)
    return finish(chosen, snap: snap)
  }

  private func shouldEndWelcome(_ snap: CompanionSnapshot) -> Bool {
    if snap.inBattle { return true }
    if Date() >= welcomeUntil { return true }
    // Continue / New Game usually changes mapGroup/mapNum — ignore x/y title-screen jitter.
    if Date().timeIntervalSince(welcomeStartedAt) >= Self.welcomeMinBeforeMapDismiss,
       let a = welcomeAnchor,
       snap.mapGroup != a.mapGroup || snap.mapNum != a.mapNum {
      return true
    }
    return false
  }

  private func makeWelcomeAdvice(_ snap: CompanionSnapshot) -> Gen3BattleCoach.Advice {
    let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
    let lead = party.first(where: { $0.hp > 0 }) ?? party.first
    let leadPct = lead.map { Gen3BattleCoach.hpPct($0.hp, $0.maxHp) } ?? 100
    let leadName = lead.map { Gen3Names.species($0.species, tables: snap.tables) } ?? "your team"
    let game = snap.gameName.isEmpty ? "PocketDex" : snap.gameName
    let idSeed = snap.configId.utf8.reduce(UInt64(0)) { ($0 &* 33) &+ UInt64($1) }
    let line = PhraseBank.pick(
      .welcome,
      seed: stickySeed &+ idSeed,
      ["game": game, "lead": leadName]
    )
    return Gen3BattleCoach.Advice(
      foeName: game,
      headline: line.0,
      detail: line.1,
      kind: .field,
      moves: [],
      bestMove: nil,
      allyHpPct: leadPct,
      foeHpPct: nil,
      partyAlive: party.filter { $0.hp > 0 }.count,
      partyTotal: party.count,
      itemHint: "Tap when you're in-game",
      urgency: "WELCOME",
      dataChips: Gen3BattleCoach.dataChips(
        from: snap,
        bagBalls: Gen3BattleCoach.BagIndexPublic(snap: snap).ballCount()
      ),
      tipId: "evt.welcome"
    )
  }

  private func finish(
    _ advice: Gen3BattleCoach.Advice,
    snap: CompanionSnapshot
  ) -> Gen3BattleCoach.Advice {
    noteShownTalkTip(advice, snap: snap)
    return withSecondaries(advice, snap: snap)
  }

  func cycleTip() {
    // Tap during welcome → skip straight into normal coaching.
    if !welcomeDone {
      welcomeDone = true
      welcomeAdvice = nil
      welcomeUntil = .distantPast
      pinnedSoftUntil = .distantPast
      eventUntil = .distantPast
      tipCycle = 0
      stickySeed &+= 0x9E37_79B9
      return
    }
    tipCycle &+= 1
    // After cycling through primary + all secondaries, unlock a fresh soft tip.
    let alts = (pinnedSoft?.secondaryTips.count ?? islandSecondaryCount)
    if tipCycle > 0, tipCycle % (1 + max(alts, 0)) == 0 {
      pinnedSoftUntil = .distantPast
      stickySeed &+= 0x9E37_79B9
    }
  }

  /// Filled when observe attaches secondaries; used so tap-wrap can rotate soft tips.
  private var islandSecondaryCount: Int = 0

  private func withSecondaries(
    _ advice: Gen3BattleCoach.Advice,
    snap: CompanionSnapshot
  ) -> Gen3BattleCoach.Advice {
    var out = advice
    let secondaries = Gen3BattleCoach.secondaryTips(
      from: snap,
      primary: out,
      lastWildFoeSpecies: lastWildFoeSpecies,
      completedTalkTips: completedTalkTips
    )
    islandSecondaryCount = secondaries.count
    if !secondaries.isEmpty {
      out.secondaryTips = secondaries
      // Keep secondaries on the pin so tap-wrap knows the pool size.
      if var pin = pinnedSoft {
        pin.secondaryTips = secondaries
        pinnedSoft = pin
      }
      let idx = tipCycle % (1 + secondaries.count)
      if idx > 0 {
        let alt = secondaries[idx - 1]
        out.headline = alt.headline
        out.detail = alt.detail
        if let u = alt.urgency { out.urgency = u }
        if let h = alt.itemHint { out.itemHint = h }
        noteShownTalkTip(alt, snap: snap)
      }
    }
    return out
  }

  /// Soft overworld color — safe to hold / replace with events.
  private static func isSoft(_ a: Gen3BattleCoach.Advice) -> Bool {
    if a.kind == .celebrate { return true }
    guard a.kind == .field else { return false }
    switch a.urgency {
    case "FIELD", "PARTNER", "TALK", "TRADE", "KEY", "AREA", "COVER", "INFO", "BAG",
         "LEAD", "HEALED", "CURED", "BALL", "GOT IT", "NICE", "WELCOME", nil:
      return true
    default:
      // HEAL UP / PARTY / status labels / CRITICAL break through.
      return false
    }
  }

  private static func isUrgent(_ a: Gen3BattleCoach.Advice) -> Bool {
    !isSoft(a)
  }

  // MARK: - Quest / celebrate

  private func noteShownTalkTip(_ advice: Gen3BattleCoach.Advice, snap: CompanionSnapshot) {
    guard let tipId = advice.tipId, tipId.hasPrefix("talk.") else { return }
    guard !completedTalkTips.contains(tipId) else { return }
    guard !pendingQuests.contains(where: { $0.tipId == tipId }) else { return }
    guard let reward = SmartIslandTalkTips.reward(forTipId: tipId) else { return }
    let label: String
    switch reward {
    case .item(let id):
      let name = Gen3Names.item(id, tables: snap.tables)
      label = name.hasPrefix("Item #") ? "gift" : name
    case .mon(let id):
      label = Gen3Names.species(id, tables: snap.tables)
    case .trade(let get, _):
      label = Gen3Names.species(get, tables: snap.tables)
    }
    pendingQuests.append(PendingQuest(
      tipId: tipId,
      reward: reward,
      label: label,
      mapSec: snap.mapSec,
      configId: snap.configId
    ))
    // Cap pending so long sessions don't grow forever.
    if pendingQuests.count > 24 {
      pendingQuests.removeFirst(pendingQuests.count - 24)
    }
  }

  private func markCompleted(_ tipId: String, configId: String) {
    completedTalkTips.insert(tipId)
    pendingQuests.removeAll { $0.tipId == tipId }
    persistCompletedTips(configId: configId)
  }

  private func loadCompletedTipsIfNeeded(configId: String) {
    guard !configId.isEmpty, configId != completedTipsConfigId else { return }
    completedTipsConfigId = configId
    let key = Self.completedTipsKeyPrefix + configId
    let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
    completedTalkTips = Set(arr)
  }

  private func persistCompletedTips(configId: String) {
    guard !configId.isEmpty else { return }
    let key = Self.completedTipsKeyPrefix + configId
    // Keep the list bounded.
    let trimmed = Array(completedTalkTips.sorted().suffix(400))
    completedTalkTips = Set(trimmed)
    UserDefaults.standard.set(trimmed, forKey: key)
  }

  private func detectQuestComplete(
    from prev: CompanionSnapshot,
    to cur: CompanionSnapshot,
    place: String,
    leadPct: Int,
    alive: Int,
    total: Int,
    chips: [String],
    bagLine: String?
  ) -> Gen3BattleCoach.Advice? {
    guard !cur.inBattle, !pendingQuests.isEmpty else { return nil }
    let prevItems = Gen3BattleCoach.itemQuantities(from: prev)
    let curItems = Gen3BattleCoach.itemQuantities(from: cur)
    let prevSpecies = Gen3BattleCoach.speciesCounts(from: prev)
    let curSpecies = Gen3BattleCoach.speciesCounts(from: cur)

    for quest in pendingQuests {
      guard quest.configId == cur.configId || quest.configId.isEmpty else { continue }
      let matched: Bool
      switch quest.reward {
      case .item(let id):
        matched = (curItems[id] ?? 0) > (prevItems[id] ?? 0)
      case .mon(let id):
        matched = (curSpecies[id] ?? 0) > (prevSpecies[id] ?? 0)
      case .trade(let get, let wants):
        let got = (curSpecies[get] ?? 0) > (prevSpecies[get] ?? 0)
        let gave = (curSpecies[wants] ?? 0) < (prevSpecies[wants] ?? 0)
        matched = got || (got && gave)
      }
      guard matched else { continue }

      markCompleted(quest.tipId, configId: cur.configId)
      let tipSeed = quest.tipId.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
      let line = PhraseBank.pick(
        .questDone,
        seed: stickySeed &+ tipSeed,
        ["what": quest.label, "place": place]
      )
      return Gen3BattleCoach.Advice(
        foeName: place,
        headline: line.0,
        detail: line.1,
        kind: .celebrate,
        moves: [],
        bestMove: nil,
        allyHpPct: leadPct,
        foeHpPct: nil,
        partyAlive: alive,
        partyTotal: total,
        itemHint: bagLine,
        urgency: "GOT IT",
        dataChips: chips,
        tipId: "evt.done.\(quest.tipId)"
      )
    }
    return nil
  }

  // MARK: - Transitions

  private func detectEvent(from prev: CompanionSnapshot?, to cur: CompanionSnapshot) -> Gen3BattleCoach.Advice? {
    guard let prev else { return nil }
    let bag = Gen3BattleCoach.BagIndexPublic(snap: cur)
    let place = Gen3BattleCoach.placeName(cur)
    let party = cur.party.filter { !$0.isEgg && $0.species > 0 }
    let alive = party.filter { $0.hp > 0 }.count
    let total = party.count
    let lead = party.first(where: { $0.hp > 0 }) ?? party.first
    let leadPct = lead.map { Gen3BattleCoach.hpPct($0.hp, $0.maxHp) } ?? 0
    let leadName = lead.map { Gen3Names.species($0.species, tables: cur.tables) } ?? "Lead"
    let chips = Gen3BattleCoach.dataChips(from: cur, bagBalls: bag.ballCount())

    // Talk-tip quest completed (item / mon / trade landed) — celebrate first.
    if let done = detectQuestComplete(
      from: prev, to: cur, place: place, leadPct: leadPct,
      alive: alive, total: total, chips: chips, bagLine: bag.inventoryLine()
    ) {
      return done
    }

    // Entered battle — wild vs trainer openers differ.
    if !prev.inBattle, cur.inBattle {
      let foe = cur.battleMons[1].map { Gen3Names.species($0.species, tables: cur.tables) } ?? "foe"
      let trainer = cur.isTrainer == true
      let kind = trainer ? "Trainer" : "Wild"
      let line = PhraseBank.pick(
        trainer ? .battleStartTrainer : .battleStartWild,
        seed: stickySeed,
        ["foe": foe, "kind": kind, "place": place, "lead": leadName]
      )
      return Gen3BattleCoach.Advice(
        foeName: foe,
        headline: line.0,
        detail: line.1,
        kind: .field,
        moves: [],
        bestMove: nil,
        allyHpPct: leadPct,
        foeHpPct: cur.battleMons[1].map { Gen3BattleCoach.hpPct($0.hp, max(1, $0.maxHp)) },
        partyAlive: alive,
        partyTotal: total,
        itemHint: bag.inventoryLine(),
        urgency: kind.uppercased(),
        dataChips: chips,
        foeLevel: cur.battleMons[1]?.level,
        foeTypes: nil,
        battleKind: kind,
        tipId: trainer ? "evt.battle.trainer" : "evt.battle.wild"
      )
    }

    // Left battle with money gain (handled after win via epilogue too).
    if prev.inBattle, !cur.inBattle {
      if let pm = prev.money, let cm = cur.money, cm > pm {
        let gain = cm - pm
        let line = PhraseBank.pick(
          .moneyGain,
          seed: stickySeed &+ UInt64(gain),
          ["gain": "\(gain)", "money": "\(cm)", "place": place]
        )
        return softEvent(
          headline: line.0, detail: line.1, urgency: "₽+\(gain)",
          place: place, leadPct: leadPct, alive: alive, total: total,
          hint: bag.inventoryLine(), chips: chips, tipId: "evt.money"
        )
      }
    }

    // Map change — prefer “who to talk to” when the new area has PEOPLE / buildings.
    // Town doors fire mapGroup/mapNum constantly; only nudge on cooldown (or mapSec jump).
    if prev.mapGroup != cur.mapGroup || prev.mapNum != cur.mapNum || prev.mapSec != cur.mapSec {
      let mapSecChanged = prev.mapSec != cur.mapSec
      let cooled = Date().timeIntervalSince(lastMapEventAt) >= Self.mapEventCooldown
      if mapSecChanged || cooled {
        lastMapEventAt = Date()
        let seed = stickySeed &+ UInt64(cur.mapGroup &* 64 &+ cur.mapNum)
        if let talk = SmartIslandTalkTips.primaryTip(
             for: cur, stickySeed: seed, excluding: completedTalkTips
           ),
           talk.priority >= 2 || talk.urgency == "TALK" || talk.urgency == "TRADE" || talk.urgency == "KEY" {
          return softEvent(
            headline: talk.headline, detail: talk.detail, urgency: talk.urgency,
            place: place, leadPct: leadPct, alive: alive, total: total,
            hint: bag.inventoryLine(), chips: chips, tipId: talk.tipId
          )
        }
        // Region / mapSec change gets a soft "new area" line; door hops inside a town skip chatter.
        if mapSecChanged {
          let line = PhraseBank.pick(
            .newArea,
            seed: seed,
            ["place": place, "party": "\(alive)/\(total)", "lead": leadName]
          )
          return softEvent(
            headline: line.0, detail: line.1, urgency: "AREA",
            place: place, leadPct: leadPct, alive: alive, total: total,
            hint: bag.inventoryLine(), chips: chips, tipId: "evt.area"
          )
        }
      }
    }

    // Lead species changed (switch on field or after faint).
    let prevLead = prev.party.first(where: { !$0.isEgg && $0.species > 0 && $0.hp > 0 })?.species
      ?? prev.party.first(where: { !$0.isEgg && $0.species > 0 })?.species
    let curLead = lead?.species
    if let prevLead, let curLead, prevLead != curLead, !cur.inBattle {
      let line = PhraseBank.pick(
        .leadSwap,
        seed: stickySeed &+ UInt64(curLead),
        ["lead": leadName, "pct": "\(leadPct)", "place": place]
      )
      return softEvent(
        headline: line.0, detail: line.1, urgency: "LEAD",
        place: place, leadPct: leadPct, alive: alive, total: total,
        hint: bag.inventoryLine(), chips: chips, tipId: "evt.lead"
      )
    }

    // HP healed on party (field) — Nurse Joy vs bag potion.
    if !cur.inBattle {
      var healedWho: [(name: String, pct: Int, hpGain: Int)] = []
      var statusClears = 0
      for (i, mon) in party.enumerated() {
        guard prev.party.indices.contains(i) else { continue }
        let before = prev.party[i]
        guard before.species == mon.species, before.maxHp == mon.maxHp else { continue }
        if mon.hp > before.hp + max(1, before.maxHp / 20) {
          healedWho.append((
            Gen3Names.species(mon.species, tables: cur.tables),
            Gen3BattleCoach.hpPct(mon.hp, mon.maxHp),
            mon.hp - before.hp
          ))
        }
        if before.statusLabel != nil, mon.statusLabel == nil {
          statusClears += 1
        }
      }

      if !healedWho.isEmpty {
        let atCenter = Self.isPokemonCenterPlace(place)
          || Self.isPokemonCenterPlace(cur.mapSecName ?? "")
        let bagHealDrop = Self.restorativeItemQty(prev) > Self.restorativeItemQty(cur)
        // Nurse Joy: Pokémon Center desk, or multi-mon / full-party restore without spending potions.
        let nurseJoy = (atCenter && !bagHealDrop)
          || (!bagHealDrop && healedWho.count >= 2)
          || (!bagHealDrop && healedWho.count >= 1 && statusClears >= 2)

        if nurseJoy {
          let who = healedWho.first?.name ?? leadName
          let pctNow = healedWho.map(\.pct).max() ?? leadPct
          let line = PhraseBank.pick(
            .nurseHeal,
            seed: stickySeed &+ UInt64(healedWho.count &* 17),
            [
              "who": who,
              "pct": "\(pctNow)",
              "place": place,
              "party": "\(alive)/\(total)",
              "count": "\(healedWho.count)",
            ]
          )
          return softEvent(
            headline: line.0, detail: line.1, urgency: "NURSE JOY",
            place: place, leadPct: pctNow, alive: alive, total: total,
            hint: bag.inventoryLine(), chips: chips, tipId: "evt.heal.nurse"
          )
        }

        let first = healedWho[0]
        let line = PhraseBank.pick(
          .healed,
          seed: stickySeed &+ UInt64(first.pct),
          ["who": first.name, "pct": "\(first.pct)", "place": place]
        )
        return softEvent(
          headline: line.0, detail: line.1, urgency: "HEALED",
          place: place, leadPct: first.pct, alive: alive, total: total,
          hint: bag.inventoryLine(), chips: chips, tipId: "evt.heal"
        )
      }

      // Status-only clear (no HP bump this tick).
      for (i, mon) in party.enumerated() {
        guard prev.party.indices.contains(i) else { continue }
        let before = prev.party[i]
        guard before.species == mon.species else { continue }
        if before.statusLabel != nil, mon.statusLabel == nil {
          let who = Gen3Names.species(mon.species, tables: cur.tables)
          let atCenter = Self.isPokemonCenterPlace(place)
            || Self.isPokemonCenterPlace(cur.mapSecName ?? "")
          if atCenter {
            let line = PhraseBank.pick(
              .nurseHeal,
              seed: stickySeed,
              ["who": who, "pct": "\(Gen3BattleCoach.hpPct(mon.hp, mon.maxHp))", "place": place, "party": "\(alive)/\(total)", "count": "1"]
            )
            return softEvent(
              headline: line.0, detail: line.1, urgency: "NURSE JOY",
              place: place, leadPct: Gen3BattleCoach.hpPct(mon.hp, mon.maxHp), alive: alive, total: total,
              hint: bag.inventoryLine(), chips: chips, tipId: "evt.heal.nurse"
            )
          }
          let line = PhraseBank.pick(
            .statusCleared,
            seed: stickySeed,
            ["who": who, "place": place]
          )
          return softEvent(
            headline: line.0, detail: line.1, urgency: "CURED",
            place: place, leadPct: Gen3BattleCoach.hpPct(mon.hp, mon.maxHp), alive: alive, total: total,
            hint: bag.inventoryLine(), chips: chips, tipId: "evt.cure"
          )
        }
      }
    }

    // Balls spent — always fire throw FX (urgent CATCH tips must not swallow it).
    let prevBalls = Gen3BattleCoach.BagIndexPublic(snap: prev).ballCount()
    let curBalls = bag.ballCount()
    if prevBalls > curBalls, curBalls >= 0 {
      // Another throw while a prior attempt was pending ⇒ that prior ball broke free.
      if let prior = pendingCatch {
        finishCatch(success: false, snap: cur, foeSpecies: prior.foeSpecies)
      }
      emitFX(.pokeBallThrow)
      // Wild catch attempt → resolve later (success often leaves battle after a long shake).
      let prevParty = prev.party.filter { !$0.isEgg && $0.species > 0 }.count
      let prevSpecies = Gen3BattleCoach.speciesCounts(from: prev)
      let leadNow = cur.party.first(where: { !$0.isEgg && $0.species > 0 && $0.hp > 0 })
        ?? cur.party.first(where: { !$0.isEgg && $0.species > 0 })
      let grew = total > prevParty || Self.speciesGrew(from: prevSpecies, to: Gen3BattleCoach.speciesCounts(from: cur))
      if grew {
        finishCatch(success: true, snap: cur, foeSpecies: lastWildFoeSpecies)
      } else if cur.inBattle, cur.isTrainer != true {
        let foe = cur.battleMons[1]?.species ?? lastWildFoeSpecies
        pendingCatch = PendingCatch(
          foeSpecies: foe,
          partyCount: prevParty,
          speciesCounts: prevSpecies,
          thrownAt: Date(),
          leadHp: leadNow?.hp ?? 0,
          dexCaught: cur.dex?.caught ?? 0
        )
      } else {
        pendingCatch = nil
      }
      let line = PhraseBank.pick(
        .ballUsed,
        seed: stickySeed &+ UInt64(prevBalls - curBalls),
        ["left": "\(curBalls)", "place": place]
      )
      return softEvent(
        headline: line.0, detail: line.1, urgency: "BALL",
        place: place, leadPct: leadPct, alive: alive, total: total,
        hint: bag.inventoryLine(), chips: chips, tipId: "evt.ball"
      )
    }

    return nil
  }

  /// Catch result rules (no shake-timeout fail — that false-fired during Gotcha):
  /// • Success: party/dex grew, or wild battle ended after the throw
  /// • Fail: lead took damage (fight resumed), or a new ball is thrown (handled in detectEvent)
  private func resolvePendingCatch(previous prev: CompanionSnapshot?, current cur: CompanionSnapshot) {
    guard let pending = pendingCatch else { return }
    let party = cur.party.filter { !$0.isEgg && $0.species > 0 }
    let partyCount = party.count
    let curSpecies = Gen3BattleCoach.speciesCounts(from: cur)
    let dexCaught = cur.dex?.caught ?? pending.dexCaught
    let grew = partyCount > pending.partyCount
      || Self.speciesGrew(from: pending.speciesCounts, to: curSpecies)
      || dexCaught > pending.dexCaught

    if grew {
      finishCatch(success: true, snap: cur, foeSpecies: pending.foeSpecies)
      return
    }

    // Gotcha: battle ends after shakes — treat as success (party RAM can lag).
    // Quick leave (<1.0s) is usually Run — drop quietly.
    if !cur.inBattle {
      let elapsed = Date().timeIntervalSince(pending.thrownAt)
      if elapsed >= 1.0 {
        finishCatch(success: true, snap: cur, foeSpecies: pending.foeSpecies)
      } else {
        pendingCatch = nil
      }
      return
    }

    let lead = party.first(where: { $0.hp > 0 }) ?? party.first
    let leadHp = lead?.hp ?? 0
    let foe = cur.battleMons[1]
    let foeSpecies = foe?.species ?? 0
    let foeAlive = (foe?.hp ?? 0) > 0
    let sameFoe = foeSpecies > 0 && (foeSpecies == pending.foeSpecies || pending.foeSpecies == 0)

    // Broke free only when the fight clearly resumes (our lead got hit).
    // Never timeout-fail while still inBattle — Gen3 Gotcha can take well past 5s.
    if sameFoe, foeAlive, cur.isTrainer != true,
       pending.leadHp > 0, leadHp > 0, leadHp < pending.leadHp {
      finishCatch(success: false, snap: cur, foeSpecies: pending.foeSpecies)
      return
    }

    // Stale pending after a very long fight — drop quietly (no false X).
    if Date().timeIntervalSince(pending.thrownAt) >= 24 {
      pendingCatch = nil
    }
  }

  private func finishCatch(success: Bool, snap: CompanionSnapshot, foeSpecies: Int) {
    emitFX(success ? .catchSuccess : .catchFail)
    catchTipOverride = ashCatchTip(success: success, snap: snap, foeSpecies: foeSpecies)
    pendingCatch = nil
  }

  private func ashCatchTip(success: Bool, snap: CompanionSnapshot, foeSpecies: Int) -> Gen3BattleCoach.Advice {
    let place = Gen3BattleCoach.placeName(snap)
    let party = snap.party.filter { !$0.isEgg && $0.species > 0 }
    let alive = party.filter { $0.hp > 0 }.count
    let lead = party.first(where: { $0.hp > 0 }) ?? party.first
    let leadPct = lead.map { Gen3BattleCoach.hpPct($0.hp, $0.maxHp) } ?? 0
    let foe = foeSpecies > 0
      ? Gen3Names.species(foeSpecies, tables: snap.tables)
      : (lastWildFoeSpecies > 0 ? Gen3Names.species(lastWildFoeSpecies, tables: snap.tables) : "Pokémon")
    let bag = Gen3BattleCoach.BagIndexPublic(snap: snap)
    let chips = Gen3BattleCoach.dataChips(from: snap, bagBalls: bag.ballCount())
    let line = PhraseBank.pick(
      success ? .catchSuccess : .catchFail,
      seed: stickySeed &+ UInt64(foeSpecies),
      ["foe": foe, "place": place, "lead": lead.map { Gen3Names.species($0.species, tables: snap.tables) } ?? "partner"]
    )
    return softEvent(
      headline: line.0,
      detail: line.1,
      urgency: success ? "GOTCHA" : "BROKE FREE",
      place: place,
      leadPct: leadPct,
      alive: alive,
      total: party.count,
      hint: bag.inventoryLine(),
      chips: chips,
      tipId: success ? "evt.catch.ok" : "evt.catch.fail"
    )
  }

  private static func speciesGrew(from prev: [Int: Int], to cur: [Int: Int]) -> Bool {
    for (id, n) in cur {
      if n > (prev[id] ?? 0) { return true }
    }
    return false
  }

  /// Pokémon Center / Nurse Joy desk (excludes Space Center etc.).
  private static func isPokemonCenterPlace(_ raw: String) -> Bool {
    let u = raw.uppercased()
      .replacingOccurrences(of: "É", with: "E")
      .replacingOccurrences(of: "é", with: "E")
    guard u.contains("CENTER") else { return false }
    if u.contains("SPACE") { return false }
    return u.contains("POKE") || u.contains("POKEMON") || u.contains("PKMN") || u.contains("POKECOM")
  }

  /// Rough count of HP-restoring bag items (potions / drinks / berries).
  private static func restorativeItemQty(_ snap: CompanionSnapshot) -> Int {
    var total = 0
    for item in snap.bag where item.itemId > 0 && item.quantity > 0 {
      let name = Gen3Names.item(item.itemId, tables: snap.tables)
        .uppercased()
        .replacingOccurrences(of: "É", with: "E")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
      if name.contains("POTION") || name.contains("RESTORE") || name.contains("FRESHWATER")
          || name.contains("SODAPOP") || name.contains("LEMONADE") || name.contains("MOOMOO")
          || name.contains("BERRYJUICE") || name.contains("ORANBERRY") || name.contains("SITRUSBERRY")
          || name.contains("ENERGYPOWDER") || name.contains("ENERGYROOT")
          || name.contains("REVIVE") || name.contains("HEALPOWDER") {
        total += item.quantity
      }
    }
    return total
  }

  private func softEvent(
    headline: String,
    detail: String,
    urgency: String,
    place: String,
    leadPct: Int,
    alive: Int,
    total: Int,
    hint: String?,
    chips: [String],
    tipId: String
  ) -> Gen3BattleCoach.Advice {
    Gen3BattleCoach.Advice(
      foeName: place,
      headline: headline,
      detail: detail,
      kind: .field,
      moves: [],
      bestMove: nil,
      allyHpPct: leadPct,
      foeHpPct: nil,
      partyAlive: alive,
      partyTotal: total,
      itemHint: hint,
      urgency: urgency,
      dataChips: chips,
      tipId: tipId
    )
  }

  private func situationKey(_ a: Gen3BattleCoach.Advice) -> String {
    "\(a.kind.rawValue)|\(a.urgency ?? "")|\(a.tipId ?? a.headline)"
  }

}

// MARK: - Phrase bank

enum PhraseBank {
  enum Category {
    case fieldIdle
    case personalField
    case personalBattleWild
    case personalBattleTrainer
    case healNudge
    case status
    case catchWindow
    case superEffective
    case resisted
    case switchOutWild
    case switchOutTrainer
    case setupWild
    case setupTrainer
    case winTrainer
    case winWild
    case loseTrainer
    case loseWild
    case criticalHpWild
    case criticalHpTrainer
    case bagEmpty
    case battleStartWild
    case battleStartTrainer
    case moneyGain
    case newArea
    case leadSwap
    case healed
    case nurseHeal
    case statusCleared
    case ballUsed
    case catchSuccess
    case catchFail
    case attackWild
    case attackTrainer
    case revive
    case faintedWild
    case faintedTrainer
    case talkNudge
    case wildChip
    case trainerPace
    case questDone
    case welcome
  }

  static func pick(_ cat: Category, seed: UInt64, _ vars: [String: String]) -> (String, String) {
    let lines = templates(cat)
    guard !lines.isEmpty else { return ("Ready", "I'm with you") }
    let idx = Int(seed % UInt64(lines.count))
    let raw = lines[idx]
    return (fill(raw.0, vars), fill(raw.1, vars))
  }

  /// Personal line for the lead — mixes type voice with the species name.
  static func pickPersonal(
    field: Bool,
    flavor: SmartIslandVoice.Flavor,
    seed: UInt64,
    vars: [String: String],
    trainer: Bool? = nil
  ) -> (String, String) {
    let cat: Category
    if field {
      cat = .personalField
    } else if trainer == true {
      cat = .personalBattleTrainer
    } else {
      cat = .personalBattleWild
    }
    let base = pick(cat, seed: seed, vars)
    let flavored = voiceLine(
      flavor: flavor, field: field, trainer: trainer, seed: seed &+ 17, vars: vars
    )
    return seed % 2 == 0 ? base : flavored
  }

  private static func voiceLine(
    flavor: SmartIslandVoice.Flavor,
    field: Bool,
    trainer: Bool?,
    seed: UInt64,
    vars: [String: String]
  ) -> (String, String) {
    let lines = voiceTemplates(flavor, field: field, trainer: trainer)
    let idx = Int(seed % UInt64(max(1, lines.count)))
    let raw = lines.isEmpty ? ("{lead} has your back", "{place}") : lines[idx]
    return (fill(raw.0, vars), fill(raw.1, vars))
  }

  private static func fill(_ s: String, _ vars: [String: String]) -> String {
    var out = s
    for (k, v) in vars {
      out = out.replacingOccurrences(of: "{\(k)}", with: v)
    }
    return out
  }

  private static func templates(_ cat: Category) -> [(String, String)] {
    switch cat {
    case .fieldIdle:
      return [
        ("{lead} · Lv{level} · {pct}%", "{place} · Party {party}{money}"),
        ("Exploring {place}", "{lead} leading · {pct}% HP · Party {party}"),
        ("All quiet on {place}", "Bag {bag} · {lead} at {pct}%"),
        ("{lead} looks ready", "{place}{money} · Party {party}"),
        ("Keep walking — I've got eyes on HP", "{lead} {pct}% · {place}"),
        ("Party check: {party} healthy", "{lead} up front · {place}"),
        ("Sidekick mode: on", "{place} · ₽ tracking{money}"),
        ("{lead} setting the pace", "Lv{level} · {pct}% · {place}"),
        ("Nothing urgent — enjoy the route", "Party {party} · Bag {bag}"),
        ("I'm watching the bag and the lead", "{lead} · {place}{money}"),
        ("Soft steps through {place}", "{lead} Lv{level} · Party {party}"),
        ("Field coach standing by", "Tap island to flip tips · {place}"),
        ("Scenic route through {place}", "{lead} at {pct}% · Party {party}"),
        ("Steady as she goes", "{place}{money} · bag {bag}"),
        ("Overworld cruise mode", "{lead} Lv{level} · I'm on HP watch"),
        ("No alarms yet", "Enjoy {place} · Party {party}"),
        ("Map crumbs and quiet grass", "{lead} leading · {pct}%"),
        ("Take the long way if you want", "{place} · coach on standby"),
        ("{lead} scanning the path", "Lv{level} · {place}"),
        ("Pocket check complete", "Bag {bag} · Party {party}"),
        ("Still breathing easy on {place}", "{lead} {pct}% · keep exploring"),
        ("Horizon looks clear", "{place}{money}"),
        ("Gotta catch 'em all — someday!", "{place} · {lead} out front"),
        ("A real Trainer never gives up!", "Party {party} · keep walking {place}"),
        ("Adventure time with {lead}!", "Lv{level} · {pct}% · {place}"),
        ("I choose you — every route!", "{lead} leading through {place}"),
        ("Pikachu would love this view", "{place} · Party {party}"),
        ("We're gonna be Pokémon Masters!", "{lead} · {pct}% · bag {bag}"),
      ]
    case .personalField:
      return [
        ("{lead} says hi from the front", "Lv{level} · {pct}% · {place}"),
        ("Partner check — {lead} is locked in", "Ready for whatever {place} throws"),
        ("{lead}'s got that spark today", "Keep them healthy · {pct}% now"),
        ("Walking with {lead} feels right", "{place} · tap for more tips"),
        ("{lead} wants another step forward", "Party lead · Lv{level}"),
        ("Your {lead} looks proud out front", "{pct}% HP · stay sharp"),
        ("Bonded with {lead} — coach online", "{place}"),
        ("{lead} glances back like \"I got you\"", "Overworld mode"),
        ("Sidekick {lead} reporting", "Lv{level} · {place}"),
        ("{lead} sets the vibe for {place}", "I'm watching bags and HP"),
        ("{lead} stretches — ready for more", "{pct}% · {place}"),
        ("Quiet pride from {lead}", "Lead mon energy · Lv{level}"),
        ("{lead} likes this stretch of road", "{place}"),
        ("Front-line buddy: {lead}", "Tap for bag / talk tips"),
        ("{lead} and you · sync'd", "{pct}% HP · Party nearby"),
        ("A little bounce in {lead}'s step", "{place} exploration"),
        ("{lead} trusts the next turn", "Lv{level} · I'm with you"),
        ("Partner cam: {lead}", "Looking solid at {pct}%"),
      ]
    case .personalBattleWild:
      return [
        ("{lead} vs wild {foe}", "Catch lane or KO — your call"),
        ("{lead} spotted {foe} first", "Chip carefully if you're throwing"),
        ("Wild fight — {lead} is ready", "Don't overkill if you want it"),
        ("{lead} can soften {foe} for a ball", "Or go for the KO"),
        ("Partner {lead} on a wild", "{pct}% · stay sharp"),
        ("{lead} thrives in the grass fights", "vs {foe}"),
        ("Wild {foe} — {lead} wants in", "I've got catch + move tips"),
        ("Keep {lead} healthy for the throw", "Wild battle focus"),
      ]
    case .personalBattleTrainer:
      return [
        ("{lead} vs a trainer's {foe}", "This is a full team fight"),
        ("Trainer battle — trust {lead}", "Save heals for the long haul"),
        ("{lead} sets the tone vs {foe}", "Switch if the matchup flips"),
        ("No catching — {lead} finishes trainers", "Play for the whole party"),
        ("{lead} vs {foe} — paced fight", "Watch remaining foes"),
        ("Partner {lead} for the trainer gauntlet", "{pct}% · manage HP"),
        ("{lead} won't flinch at a trainer", "Island has switches + bag"),
        ("Trainer pride — send {lead}", "Clean reads win these"),
      ]
    case .talkNudge:
      return [
        ("Talk to someone here", "{place} has NPCs worth a chat"),
        ("Don't rush past — talk first", "Buildings in {place} hide gifts"),
        ("Knock on doors in {place}", "Trades and gifts hide indoors"),
        ("NPC radar: someone wants a word", "{place}"),
        ("Peek inside before you leave", "Locals in {place} share items"),
        ("Chat check — anyone flagged?", "{place}"),
        ("Houses first, then the route", "Gifts love indoor NPCs"),
        ("Say hi — it pays off", "{place} · talk around"),
      ]
    case .healNudge:
      return [
        ("Heal {who} — {item}×{qty}", "{pct}% HP ({hp}/{max}) · bag has it"),
        ("{who} is hurting — {item}", "{pct}% · use it from the bag"),
        ("Potion time for {who}", "{item}×{qty} · {pct}% left"),
        ("Don't push {who} like this", "{pct}% HP · {item} ready"),
        ("Patch {who} up first", "{item}×{qty} · then keep exploring"),
        ("{who} needs a sip", "{pct}% · {item} in the bag"),
        ("Low HP alert — {who}", "Bag → {item}×{qty}"),
        ("Center or {item} — your call", "{who} at {pct}%"),
      ]
    case .status:
      return [
        ("Cure {who}'s {status}", "Bag → {item}×{qty}"),
        ("{who} is {status} — fix it", "{item} ready in the bag"),
        ("Status check: {status} on {who}", "Use {item}×{qty}"),
        ("Shake off that {status}", "{who} · {item}"),
        ("{status} is slowing {who}", "Bag has {item}×{qty}"),
        ("Cleanse {who}", "{status} · {item}×{qty}"),
      ]
    case .catchWindow:
      return [
        ("Bag → {ball}×{qty}", "Foe {fp}% · {moveBit}"),
        ("Catch window on {foe}!", "{ball}×{qty} · foe {fp}%"),
        ("Throw {ball} — {foe} is weak", "{fp}% HP · {moveBit}"),
        ("This is the moment — {ball}", "Foe {fp}% · don't overkill"),
        ("Ball time!", "{ball}×{qty} · {foe} at {fp}%"),
        ("Chip or catch — {ball} ready", "Foe {fp}% · {moveBit}"),
        ("Go, Poké Ball — get {foe}!", "{ball}×{qty} · foe {fp}%"),
        ("Gotta catch {foe}!", "{ball} ready · {fp}% · {moveBit}"),
        ("This is it, {foe}!", "Throw {ball} — Ash-style catch window"),
      ]
    case .superEffective:
      return [
        ("Use {move}", "{why}"),
        ("Smash with {move}", "{why} · go hard"),
        ("{move} is the call", "{why}"),
        ("Super effective lane — {move}", "{why}"),
        ("Fire {move}!", "{why}"),
        ("Type advantage: {move}", "{why}"),
      ]
    case .resisted:
      return [
        ("Use {move}", "{why} · or switch"),
        ("{move} for now", "{why}"),
        ("Not ideal — {move}", "{why}"),
        ("Chip with {move}", "{why}"),
      ]
    case .switchOutWild:
      return [
        ("Switch to {alt}", "Wild {foe} · {why}"),
        ("Bring in {alt} for this wild", "{why}"),
        ("Better catch lead — {alt}", "{why}"),
        ("Bench and send {alt}", "Wild matchup fix"),
      ]
    case .switchOutTrainer:
      return [
        ("Switch to {alt}", "Trainer {foe} · {why}"),
        ("Bring in {alt} — save the lead", "{why}"),
        ("Matchup fix vs trainer — {alt}", "{why}"),
        ("Don't sack {lead} — send {alt}", "{why}"),
      ]
    case .setupWild:
      return [
        ("Bag → {item}×{qty} then {move}", "Wild setup · {why}"),
        ("Buff once — {item}", "Then chip {foe} · {why}"),
        ("Quick setup on wild — {item}", "Follow with {move}"),
      ]
    case .setupTrainer:
      return [
        ("Bag → {item}×{qty} then {move}", "Trainer fight · invest now · {why}"),
        ("Buff for the gauntlet — {item}", "Then {move} · {why}"),
        ("Setup turn vs trainer — {item}", "Payoff on {foe}"),
      ]
    case .winTrainer:
      return [
        ("That's a wrap — you win!", "{foe}'s team is down · nice call"),
        ("Victory! Read like a book.", "Trainer battle cleared · flex a little"),
        ("Clean KO — you cooked.", "Bag money / XP incoming"),
        ("Trainer down. Style points.", "{foe} never saw it coming"),
        ("You outplayed them.", "Heal if you need · then onward"),
        ("Clutch finish!", "{foe} folded · proud of that"),
        ("Textbook battle.", "XP and cash — enjoy it"),
        ("They brought a team. You brought answers.", "Win locked in"),
        ("Another badge of bragging rights.", "{foe} defeated"),
        ("Sharp reads all fight.", "You looked unstoppable"),
        ("We did it! You guys were awesome!", "Trainer {foe} down — Ash-approved"),
        ("That's what being a Trainer is about!", "Never give up · you won"),
      ]
    case .winWild:
      return [
        ("Down goes {foe}!", "Wild KO · catch window or walk tall"),
        ("That's how it's done!", "{foe} fainted · your call next"),
        ("Boom — {foe} is out!", "Clutch hit · enjoy the win"),
        ("Wild {foe} couldn't hang.", "Nice timing"),
        ("One-and-done.", "{foe} is history"),
        ("Smooth KO on {foe}.", "Keep the momentum"),
        ("Field cleared.", "{foe} down · bag check?"),
        ("You made that look easy.", "Wild win · onward"),
        ("{foe} learned respect.", "KO secured"),
        ("Snap — battle over.", "{foe} fainted"),
        ("Pikachu — thunder… wait, you won!", "{foe} fainted · nice one"),
        ("Yeah! We won't lose!", "Wild {foe} down"),
      ]
    case .loseTrainer:
      return [
        ("Oof — blacked out.", "Shake it off · heal up and run it back"),
        ("They got you this time.", "{foe} won the exchange · next one's yours"),
        ("Tough loss — still proud.", "Party wiped · visit a Pokémon Center"),
        ("Not your fight today.", "Center up · rewrite the script"),
        ("Down, but the rivalry's open.", "{foe} got lucky · rematch soon"),
        ("Lesson paid in fainted mons.", "Heal · adjust · return"),
        ("Wipe. Breathe. Retry.", "You've got this next time"),
        ("They earned that one.", "Pokémon Center → comeback arc"),
      ]
    case .loseWild:
      return [
        ("Down… but not done.", "Wild {foe} won · heal and rematch"),
        ("Rough beat — walk it off.", "You'll get {foe} next time"),
        ("Fainted to {foe}.", "Center up · that rivalry isn't over"),
        ("Wild card went their way.", "{foe} · respect · revenge later"),
        ("Oops. Nature won that round.", "Heal up · find {foe} again"),
        ("Temporary setback.", "{foe} got the last hit"),
      ]
    case .criticalHpWild:
      return [
        ("Bag → {item}×{qty}", "Wild fight · {hpBit}{foeBit}"),
        ("Heal before the wild hits!", "{item} · {hpBit}"),
        ("Stay up for a catch — {item}", "{hpBit}{foeBit}"),
        ("Critical in grass — {item}", "Survive, then chip or throw"),
      ]
    case .criticalHpTrainer:
      return [
        ("Bag → {item}×{qty}", "Trainer fight · {hpBit}{foeBit}"),
        ("Heal now — more mons coming", "{item} · {hpBit}"),
        ("Don't black out here — {item}", "Trainer gauntlet · {hpBit}"),
        ("Emergency heal vs trainer", "{item} · {hpBit}{foeBit}"),
      ]
    case .bagEmpty:
      return [
        ("Stock Poké Balls", "Bag is empty · grab balls before wilds"),
        ("Ball drawer is bare", "Mart run before the next wild"),
        ("No balls — awkward", "Buy some before a shiny moment"),
        ("Catching disabled until restock", "Poké Balls · please"),
      ]
    case .battleStartWild:
      return [
        ("Wild {foe}!", "Catch or KO — I'll coach both"),
        ("A wild {foe} appeared!", "Chip carefully if you want it"),
        ("Grass fight — {foe}", "Balls ready? Tap for tips"),
        ("Wild encounter: {foe}", "{lead} is up · stay sharp"),
        ("{foe} jumped you!", "Wild battle · catch window later"),
        ("Wild {foe}! I choose you, {lead}!", "Gotta catch it — or battle hard"),
        ("It's a wild {foe}!", "Ash mode: balls ready?"),
      ]
    case .battleStartTrainer:
      return [
        ("Trainer battle — {foe}!", "Full team fight · pace yourself"),
        ("Challenged! Lead is {foe}", "No catching — play the party"),
        ("Trainer wants smoke — {foe}", "Switches and bag matter"),
        ("Vs trainer's {foe}", "Save heals for later mons"),
        ("Trainer battle on!", "{foe} first · more may come"),
        ("A Trainer battle! Let's go!", "{foe} lead · never give up"),
        ("I won't lose to you!", "Vs {foe} · full party fight"),
      ]
    case .wildChip:
      return [
        ("Chip {foe} — don't overkill", "Save HP for a cleaner catch"),
        ("Soften {foe} first", "Then Bag → ball"),
        ("False swipe energy — chip only", "Wild {foe} · {fp}%"),
      ]
    case .trainerPace:
      return [
        ("Pace the trainer fight", "Party {party} · don't burn everything"),
        ("More mons may be coming", "Manage HP vs {foe}"),
        ("Trainer gauntlet mode", "Switch early if matchup is bad"),
      ]
    case .moneyGain:
      return [
        ("₽+{gain} — nice payout", "Wallet {money} · {place}"),
        ("Cash secured (+{gain})", "Now at ₽{money}"),
        ("Trainer tax collected", "+{gain} · ₽{money} total"),
        ("Pocket heavier by {gain}", "{place} · ₽{money}"),
      ]
    case .newArea:
      return [
        ("New area: {place}", "Party {party} · {lead} leading"),
        ("Welcome to {place}", "I've got your back · Party {party}"),
        ("Map update — {place}", "{lead} out front"),
        ("Fresh scenery: {place}", "Party {party} · stay stocked"),
        ("{place} unlocked on the HUD", "Lead {lead} · Party {party}"),
        ("Feet on new ground — {place}", "{lead} · Party {party}"),
        ("Region ping: {place}", "Look around · talk to locals"),
        ("Arrived: {place}", "Bag check when you can"),
        ("Crossing into {place}", "{lead} takes point"),
        ("New pin on the map — {place}", "Party {party}"),
      ]
    case .leadSwap:
      return [
        ("Lead swapped to {lead}", "{pct}% HP · {place}"),
        ("{lead} takes point", "Looking {pct}% · let's go"),
        ("New face up front — {lead}", "{place}"),
        ("Sending {lead}", "Party lead · {pct}%"),
      ]
    case .healed:
      return [
        ("Nice heal — {who} back to {pct}%", "{place}"),
        ("{who} topped up ({pct}%)", "Looking healthier"),
        ("Potion well spent on {who}", "Now {pct}%"),
        ("{who} refreshed", "{pct}% · good call"),
      ]
    case .nurseHeal:
      return [
        ("Nurse Joy patched everyone up!", "We hope to see you again!"),
        ("Your Pokémon are fully healed!", "Thanks, Nurse Joy · {place}"),
        ("Pokémon Center magic ✨", "Party {party} · good as new"),
        ("Nurse Joy says hi — all better!", "{count} healed · {place}"),
        ("Channeling channel… channeling… done!", "Party restored · {place}"),
        ("Joy's care lands — {who} sparkling", "Full restore · party {party}"),
        ("Take care of your Pokémon!", "Nurse Joy · {place}"),
        ("Fresh from the Center desk", "Party {party} · ready to adventure"),
      ]
    case .statusCleared:
      return [
        ("{who} is cured — clean", "{place}"),
        ("Status gone from {who}", "Back to business"),
        ("{who} shaking it off", "Cure landed"),
      ]
    case .ballUsed:
      return [
        ("Ball thrown — {left} left", "{place}"),
        ("Catch attempt logged", "{left} balls remaining"),
        ("One ball down · {left} ready", "Fingers crossed"),
        ("Poké Ball — go!", "{left} left · shake for it!"),
        ("I choose… that catch!", "Ball in the air · {left} ready"),
        ("Gotta catch this one!", "Watch the shakes · {left} left"),
      ]
    case .catchSuccess:
      return [
        ("Gotcha! {foe} was caught!", "You're a real Trainer now"),
        ("Yes! {foe} is ours!", "Gotta catch 'em all — progress!"),
        ("We did it! {foe}!", "Ash would high-five you for that"),
        ("Alright! {foe} joined the party!", "That's how Champions catch"),
        ("Poké Ball click — {foe} secured!", "Never give up pays off"),
        ("You caught {foe}!", "I knew we had that one"),
        ("Gotcha! Welcome, {foe}!", "{place} · party growing strong"),
        ("{foe} is gonna be awesome!", "Catch locked in — let's go!"),
      ]
    case .catchFail:
      return [
        ("Aww — {foe} broke free!", "It's okay · throw again!"),
        ("Not this time… {foe} escaped!", "A real Trainer never gives up"),
        ("So close on {foe}!", "Chip a little · then another ball"),
        ("Ugh — broke out!", "{foe} is tough · we got this"),
        ("Shake… and nope!", "Try again — gotta catch {foe}!"),
        ("{foe} isn't done yet!", "Next ball's the one — believe it"),
      ]
    case .questDone:
      return [
        ("You got it — {what}!", "Nice find · I won't nag about that again"),
        ("Nailed it — {what} secured", "{place} · quest cleared"),
        ("Told you · {what} is yours", "Tip retired · on to the next"),
        ("{what} acquired!", "That's the one I flagged"),
        ("Mission complete — {what}", "Smart Island high-five"),
        ("Got the goods — {what}", "I saw that · well done"),
      ]
    case .welcome:
      return [
        ("Let's play — {game}", "Hit Continue / New Game · I'll coach once you're in"),
        ("Welcome to {game}", "Smart Island standing by · press Play when ready"),
        ("Ready when you are", "{game} · tips wait until you're in the overworld"),
        ("Hey — let's go!", "{game} loaded · start the game and I'll jump in"),
        ("PocketDex is with you", "{game} · tap the island anytime after you start"),
        ("Booting up {game}", "No spoilers yet · enter the world first"),
        ("{lead} is on deck", "Start {game} · then I'll call the plays"),
        ("Let's play!", "Load in · walk around · I'll take it from there"),
        ("Adventure locked and loaded", "{game} · Continue when you're ready"),
        ("Good to see you trainer", "Smart Island online for {game}"),
        ("New session — {game}", "I'll watch HP, bag, and battles once you start"),
        ("Press start when you're set", "{game} · coaching holds for the title screen"),
        ("Let's run it back", "{game} is ready · jump in whenever"),
        ("Sidekick reporting for duty", "Tap to skip · or just hit Continue"),
        ("{game} time", "Welcome message · real tips after you're in-world"),
        ("Gloves on — {game}", "Start the adventure and I'll keep pace"),
        ("Save the spoilers for later", "I'm quiet until you leave the title screen"),
        ("Your pocket coach is here", "{game} · {lead} waiting in the wings"),
        ("Fresh boot · fresh vibes", "Let's play {game}"),
        ("Title screen chill mode", "Start {game} and the island gets talkative"),
        ("Hey trainer — {game} awaits", "Continue / New Game · then I coach"),
        ("We're live on PocketDex", "{game} loaded · make your move"),
        ("No rush — enjoy the boot", "I'll greet you properly in the overworld"),
        ("Smart Island says hi", "Let's play {game} when you're ready"),
        ("Cue the adventure music", "{game} · press Play and stick with me"),
        ("One more journey", "{lead} and I are ready for {game}"),
        ("Boot complete", "Welcome · start {game} to unlock field tips"),
        ("Waiting on you, champ", "{game} · Continue unlocks the coach"),
        ("Quiet for now", "Title screen · tips kick in after you play"),
        ("Let's make this run count", "{game} · I'm with you the whole way"),
        ("PocketDex · game on", "Welcome to {game}"),
        ("Stretch break over?", "Hit Continue · {game} won't play itself"),
        ("Island online", "Let's play — start {game} anytime"),
        ("Friendly reminder: have fun", "{game} · I'll call heals and matchups later"),
        ("ROM recognized — {game}", "Start playing and Smart Island follows"),
        ("All systems go", "Welcome · {lead} ready when you are"),
        ("Don't mind me on the island", "Start {game} · then talk tips, battles, bag checks"),
        ("First things first: play", "Continue into {game} · coaching follows"),
        ("A new page turns", "Let's play {game}"),
        ("Trainer, the world is waiting", "{game} · step in when ready"),
        // Ash Ketchum energy
        ("I wanna be the very best!", "{game} · let's catch 'em all"),
        ("Ash reporting for adventure!", "Hit Continue · {game} awaits"),
        ("Pikachu — I mean, let's go!", "{game} · never give up out there"),
        ("A journey's about to begin!", "{game} · Smart Island's your Brock"),
        ("Gotta catch 'em all starts now!", "Press Play on {game}"),
        ("Hey! I'm Ash — kinda.", "Coach mode for {game} · you choose 'em"),
      ]
    case .attackWild:
      return [
        ("Use {move}", "Wild · {why}"),
        ("Go {move} on wild {foe}", "{why}"),
        ("{move} — chip or KO", "{why}"),
        ("Best wild shot: {move}", "{why}"),
        ("Hit {foe} with {move}", "Leave room for a ball if you want"),
      ]
    case .attackTrainer:
      return [
        ("Use {move}", "Trainer · {why}"),
        ("Go {move} vs {foe}", "{why}"),
        ("{move} is the call", "Trainer fight · {why}"),
        ("Best shot: {move}", "Keep pressure on their team"),
        ("Hit hard with {move}", "No catch — finish clean"),
      ]
    case .revive:
      return [
        ("Revive {who} — {item}×{qty}", "{count} fainted · bag has {item}"),
        ("Bag → {item}×{qty}", "{who} is down · bring them back"),
        ("{who} needs {item}", "Fainted · {item}×{qty} ready"),
      ]
    case .faintedWild:
      return [
        ("Switch — stay in the wild fight!", "{alive} left · no revive"),
        ("Lead down to a wild — switch!", "{alive} still fighting"),
        ("Send the next mon", "Wild battle · keep pressure"),
      ]
    case .faintedTrainer:
      return [
        ("Switch — trainer still has mons!", "{alive} left · no revive"),
        ("Lead down — send the next!", "Trainer gauntlet · {alive} ready"),
        ("Stay in it — switch now", "{alive} remaining vs their team"),
      ]
    }
  }

  private static func voiceTemplates(
    _ flavor: SmartIslandVoice.Flavor,
    field: Bool,
    trainer: Bool?
  ) -> [(String, String)] {
    if field {
      switch flavor {
      case .fire:
        return [
          ("{lead}'s still smoldering — good", "Warm lead for {place}"),
          ("Keep {lead}'s flame fed", "Potions before the next spark"),
          ("{lead} likes this heat", "{place} · stay bold"),
        ]
      case .water:
        return [
          ("{lead} rides the current", "Smooth steps through {place}"),
          ("{lead}'s calm — like water", "I've got the bag watch"),
          ("Float on, {lead}", "Lv{level} · {pct}%"),
        ]
      case .grass:
        return [
          ("{lead} soaking up the route", "{place} feels green"),
          ("{lead} wants sun and safe HP", "{pct}% · tend the garden"),
          ("Rooted with {lead} out front", "Steady exploration"),
        ]
      case .electric:
        return [
          ("{lead} is charged", "Don't waste that buzz · {place}"),
          ("Sparks from {lead} — love it", "Keep them topped up"),
          ("{lead} crackles with go-energy", "Lv{level}"),
        ]
      case .psychic:
        return [
          ("{lead} already knows the path", "Trust the read · {place}"),
          ("Quiet focus from {lead}", "I'll call the items"),
          ("{lead}'s mind is on the next door", "Talk to people indoors"),
        ]
      case .fighting:
        return [
          ("{lead} wants a challenge", "Trainers ahead? We're ready"),
          ("Fist-bump energy from {lead}", "{pct}% · keep training"),
          ("{lead} walks like a champ", "{place}"),
        ]
      case .ghost, .dark:
        return [
          ("{lead} slips through {place}", "Quiet coach mode"),
          ("Shadow partner {lead} online", "Watch the corners"),
          ("{lead} likes the eerie bits", "Stay sharp"),
        ]
      case .dragon:
        return [
          ("{lead} owns the skyline", "Big energy · {place}"),
          ("Dragon pace — {lead} leads", "Don't rush the bag"),
          ("{lead} expects greatness", "Lv{level} and climbing"),
        ]
      case .fairy:
        return [
          ("{lead} sparkles on route", "Cute AND dangerous"),
          ("{lead} charms {place}", "I'm still watching HP"),
          ("Fairy lead {lead} — soft steps", "{pct}%"),
        ]
      case .steel, .rock, .ground:
        return [
          ("{lead} is a wall out front", "Solid for {place}"),
          ("Heavy steps — {lead} holding line", "Bag ready"),
          ("{lead} doesn't flinch easy", "Lv{level}"),
        ]
      case .flying:
        return [
          ("{lead} scouting ahead", "Eyes on {place}"),
          ("Wind at {lead}'s back", "Keep moving"),
          ("{lead} wants altitude", "I'll handle the bag"),
        ]
      case .bug, .poison, .ice, .normal, .mystery:
        return [
          ("{lead} vibing with {place}", "Personal coach locked"),
          ("Just you, me, and {lead}", "{pct}% · looking good"),
          ("{lead} makes this feel like a team", "Tap for talk tips"),
        ]
      }
    } else if trainer == true {
      switch flavor {
      case .fire:
        return [
          ("{lead} — burn through their team", "Trainer fight · pace the flame"),
          ("Flame vs trainer's {foe}", "More mons may follow"),
          ("{lead} sparks the gauntlet", "Save potions for later"),
        ]
      case .water:
        return [
          ("{lead} wash their lead away", "Trainer pace · stay composed"),
          ("Tide vs {foe} — then the rest", "Manage HP across their party"),
          ("{lead} flows through trainers", "Island has switches"),
        ]
      case .grass:
        return [
          ("{lead} outlast their team", "Trainer endurance"),
          ("Root in vs {foe}", "Don't over-spend HP early"),
          ("{lead} grows into the fight", "Gauntlet mode"),
        ]
      case .electric:
        return [
          ("{lead} shock their opener", "Trainer · keep the tempo"),
          ("Zap {foe} — stay charged", "More challengers coming"),
          ("{lead} lights up the trainer", "Clean and fast"),
        ]
      case .psychic:
        return [
          ("{lead} already mapped their party", "Trainer reads locked"),
          ("Mind games vs {foe}", "Plan the switches"),
          ("{lead} sees the whole fight", "Trust the chart"),
        ]
      case .fighting:
        return [
          ("{lead} came for the trainer", "No mercy · clean hits"),
          ("Champ energy vs {foe}", "Press their whole team"),
          ("{lead} sparring for keeps", "Gauntlet ready"),
        ]
      case .ghost, .dark:
        return [
          ("{lead} haunt their lineup", "Trainer fight · mean lanes"),
          ("Shadow through {foe}", "Then the next one"),
          ("{lead} thrives in rivalries", "Stay cold"),
        ]
      case .dragon:
        return [
          ("{lead} dominates trainers", "Pride on the line"),
          ("Dragon vs {foe} — then more", "Don't get greedy"),
          ("{lead} refuses a wipe", "Play the long fight"),
        ]
      case .fairy:
        return [
          ("{lead} — cute KO, serious fight", "Trainer gauntlet"),
          ("Fairy force vs {foe}", "Save heals for later"),
          ("{lead} sparkles mid-gauntlet", "Stay sharp"),
        ]
      case .steel, .rock, .ground:
        return [
          ("{lead} walls their opener", "Trainer · then punish"),
          ("Hard soak vs {foe}", "Wear the team down"),
          ("{lead} is built for long fights", "Island call ready"),
        ]
      case .flying:
        return [
          ("{lead} dive their lead", "Trainer · stay mobile"),
          ("Air control vs {foe}", "Keep tempo for the rest"),
          ("{lead} wings through trainers", "Finish clean"),
        ]
      case .bug, .poison, .ice, .normal, .mystery:
        return [
          ("{lead} vs a trainer — lock in", "Party fight"),
          ("Partner {lead} for the gauntlet", "Follow the island"),
          ("{lead} vs {foe} — then whoever's next", "Best move highlighted"),
        ]
      }
    } else {
      switch flavor {
      case .fire:
        return [
          ("{lead} — burn wild {foe}", "Catch or KO"),
          ("Flame on a wild", "Chip if you're throwing"),
          ("{lead} sparks the encounter", "Don't overkill for a ball"),
        ]
      case .water:
        return [
          ("{lead} wash wild {foe}", "Soft hits for a catch"),
          ("Tide on the wild", "Pick chip or KO"),
          ("{lead} vs wild {foe}", "Ball window later"),
        ]
      case .grass:
        return [
          ("{lead} tangle wild {foe}", "Patience for a catch"),
          ("Root the wild", "Leave HP for a throw"),
          ("{lead} blooming on a wild", "vs {foe}"),
        ]
      case .electric:
        return [
          ("{lead} — zap the wild", "Fast fight · or soft chip"),
          ("Shock wild {foe}", "Catch lane open soon"),
          ("{lead} charged on a wild", "Go"),
        ]
      case .psychic:
        return [
          ("{lead} already read this wild", "Catch or KO"),
          ("Mind on wild {foe}", "I've got ball tips"),
          ("{lead} sees the catch path", "vs {foe}"),
        ]
      case .fighting:
        return [
          ("{lead} — clean hit on wild {foe}", "Or chip for a ball"),
          ("Wild scrap — {lead}", "Your call: KO or catch"),
          ("{lead} came to fight the wild", "Stay precise"),
        ]
      case .ghost, .dark:
        return [
          ("{lead} haunt the wild", "Mean and careful"),
          ("Shadow on wild {foe}", "Catch if you want"),
          ("{lead} owns this encounter", "vs {foe}"),
        ]
      case .dragon:
        return [
          ("{lead} — don't overkill the wild", "Unless you want the KO"),
          ("Dragon vs wild {foe}", "Power with control"),
          ("{lead} rules the encounter", "Catch window possible"),
        ]
      case .fairy:
        return [
          ("{lead} — cute catch or KO", "Wild {foe}"),
          ("Fairy on a wild", "Soft hits help balls"),
          ("{lead} sparkles at {foe}", "Your call"),
        ]
      case .steel, .rock, .ground:
        return [
          ("{lead} tank the wild, then chip", "Catch lane"),
          ("Hard hit — leave some HP", "Wild {foe}"),
          ("{lead} vs wild — controlled power", "Island ready"),
        ]
      case .flying:
        return [
          ("{lead} dive the wild", "Chip or KO"),
          ("Air edge vs wild {foe}", "Ball after soften"),
          ("{lead} wings on the encounter", "Finish clean"),
        ]
      case .bug, .poison, .ice, .normal, .mystery:
        return [
          ("{lead} vs wild {foe}", "Catch or KO — I'm with you"),
          ("Partner {lead} on the wild", "Follow the island"),
          ("{lead} makes this encounter personal", "Best move highlighted"),
        ]
      }
    }
  }
}
