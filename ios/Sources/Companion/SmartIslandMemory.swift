import Foundation

/// Session memory for Smart Island — notices what you just did and holds short-lived event tips.
@MainActor
final class SmartIslandMemory {
  static let shared = SmartIslandMemory()

  /// Seconds an event tip stays pinned over idle field coaching.
  private static let eventHold: TimeInterval = 5.0

  private var previous: CompanionSnapshot?
  private var eventAdvice: Gen3BattleCoach.Advice?
  private var eventUntil: Date = .distantPast
  private var tipCycle: Int = 0
  private var lastSituationKey: String = ""
  /// Last wild foe species (for soft field coverage hints).
  private(set) var lastWildFoeSpecies: Int = 0
  private var stickySeed: UInt64 = 0xC0FFEE

  func reset() {
    previous = nil
    eventAdvice = nil
    eventUntil = .distantPast
    tipCycle = 0
    lastSituationKey = ""
    lastWildFoeSpecies = 0
    stickySeed = 0xC0FFEE
  }

  /// Advance memory from the previous snap → current; return the tip to show.
  func observe(_ snap: CompanionSnapshot?) -> Gen3BattleCoach.Advice? {
    defer { previous = snap }
    guard let snap else {
      eventAdvice = nil
      return nil
    }

    if let event = detectEvent(from: previous, to: snap) {
      eventAdvice = event
      eventUntil = Date().addingTimeInterval(Self.eventHold)
      tipCycle = 0
    }

    if snap.inBattle,
       snap.isTrainer != true,
       let foe = snap.battleMons[1], foe.species > 0 {
      lastWildFoeSpecies = foe.species
    }

    let base = Gen3BattleCoach.composeAdvice(
      from: snap,
      lastWildFoeSpecies: lastWildFoeSpecies,
      stickySeed: stickySeed
    )
    guard var advice = base else { return nil }

    let key = situationKey(advice)
    if key != lastSituationKey {
      lastSituationKey = key
      tipCycle = 0
      stickySeed &+= 0x9E37_79B9
    }

    // Short-lived event tips only override soft field idle — never bury battle / heal alerts.
    if let event = eventAdvice, Date() < eventUntil, advice.kind == .field, advice.urgency == "FIELD" {
      advice = event
    } else if Date() >= eventUntil {
      eventAdvice = nil
    }

    let secondaries = Gen3BattleCoach.secondaryTips(
      from: snap,
      primary: advice,
      lastWildFoeSpecies: lastWildFoeSpecies
    )
    if !secondaries.isEmpty {
      advice.secondaryTips = secondaries
      let idx = tipCycle % (1 + secondaries.count)
      if idx > 0 {
        let alt = secondaries[idx - 1]
        advice.headline = alt.headline
        advice.detail = alt.detail
        if let u = alt.urgency { advice.urgency = u }
        if let h = alt.itemHint { advice.itemHint = h }
      }
    }
    return advice
  }

  func cycleTip() {
    tipCycle &+= 1
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

    // Entered battle.
    if !prev.inBattle, cur.inBattle {
      let foe = cur.battleMons[1].map { Gen3Names.species($0.species, tables: cur.tables) } ?? "foe"
      let kind = cur.isTrainer == true ? "Trainer" : "Wild"
      let line = PhraseBank.pick(
        .battleStart,
        seed: stickySeed,
        ["foe": foe, "kind": kind, "place": place]
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
        tipId: "evt.battle.start"
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

    // Map change.
    if prev.mapGroup != cur.mapGroup || prev.mapNum != cur.mapNum || prev.mapSec != cur.mapSec {
      let line = PhraseBank.pick(
        .newArea,
        seed: stickySeed &+ UInt64(cur.mapGroup &* 64 &+ cur.mapNum),
        ["place": place, "party": "\(alive)/\(total)", "lead": leadName]
      )
      return softEvent(
        headline: line.0, detail: line.1, urgency: "AREA",
        place: place, leadPct: leadPct, alive: alive, total: total,
        hint: bag.inventoryLine(), chips: chips, tipId: "evt.area"
      )
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

    // HP healed on any party mon (field).
    if !cur.inBattle {
      for (i, mon) in party.enumerated() {
        guard prev.party.indices.contains(i) else { continue }
        let before = prev.party[i]
        guard before.species == mon.species, before.maxHp == mon.maxHp else { continue }
        if mon.hp > before.hp + max(1, before.maxHp / 20) {
          let who = Gen3Names.species(mon.species, tables: cur.tables)
          let pctNow = Gen3BattleCoach.hpPct(mon.hp, mon.maxHp)
          let line = PhraseBank.pick(
            .healed,
            seed: stickySeed &+ UInt64(mon.hp),
            ["who": who, "pct": "\(pctNow)", "place": place]
          )
          return softEvent(
            headline: line.0, detail: line.1, urgency: "HEALED",
            place: place, leadPct: pctNow, alive: alive, total: total,
            hint: bag.inventoryLine(), chips: chips, tipId: "evt.heal"
          )
        }
        // Status cleared.
        if before.statusLabel != nil, mon.statusLabel == nil {
          let who = Gen3Names.species(mon.species, tables: cur.tables)
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

    // Balls spent (wild catch attempt).
    let prevBalls = Gen3BattleCoach.BagIndexPublic(snap: prev).ballCount()
    let curBalls = bag.ballCount()
    if prevBalls > curBalls, curBalls >= 0 {
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
    case healNudge
    case status
    case catchWindow
    case superEffective
    case resisted
    case switchOut
    case setup
    case winTrainer
    case winWild
    case loseTrainer
    case loseWild
    case criticalHp
    case bagEmpty
    case battleStart
    case moneyGain
    case newArea
    case leadSwap
    case healed
    case statusCleared
    case ballUsed
    case attack
    case revive
    case fainted
  }

  static func pick(_ cat: Category, seed: UInt64, _ vars: [String: String]) -> (String, String) {
    let lines = templates(cat)
    guard !lines.isEmpty else { return ("Ready", "I'm with you") }
    let idx = Int(seed % UInt64(lines.count))
    let raw = lines[idx]
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
    case .switchOut:
      return [
        ("Switch to {alt}", "{why}"),
        ("Bring in {alt}", "{why}"),
        ("Matchup fix — {alt}", "{why}"),
        ("Bench the lead · send {alt}", "{why}"),
        ("{alt} handles this better", "{why}"),
      ]
    case .setup:
      return [
        ("Bag → {item}×{qty} then {move}", "{why}"),
        ("Buff first — {item}", "Then {move} · {why}"),
        ("Setup turn: {item}", "{move} afterward · {why}"),
        ("X-item window — {item}", "Follow with {move}"),
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
    case .criticalHp:
      return [
        ("Bag → {item}×{qty}", "{hpBit}{foeBit} · heal before you swing"),
        ("Critical — use {item}!", "{hpBit} · don't get cute"),
        ("Emergency heal — {item}", "{hpBit}{foeBit}"),
        ("Open bag — {item} now", "{hpBit} · survive first"),
        ("{item} or you drop", "{hpBit}{foeBit}"),
      ]
    case .bagEmpty:
      return [
        ("Stock Poké Balls", "Bag is empty · grab balls before wilds"),
        ("Ball drawer is bare", "Mart run before the next wild"),
        ("No balls — awkward", "Buy some before a shiny moment"),
        ("Catching disabled until restock", "Poké Balls · please"),
      ]
    case .battleStart:
      return [
        ("{kind} battle — {foe}!", "I've got moves and bag tips ready"),
        ("Here we go vs {foe}", "{kind} · stay sharp"),
        ("Engaged: {foe}", "{kind} fight · I'll coach"),
        ("{foe} stepped up", "{kind} · type chart locked in"),
        ("Battle start!", "{kind} {foe} · let's cook"),
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
      ]
    case .attack:
      return [
        ("Use {move}", "{why}"),
        ("Go {move}", "{why}"),
        ("{move} is clean", "{why}"),
        ("Best shot: {move}", "{why}"),
        ("Hit with {move}", "{why}"),
      ]
    case .revive:
      return [
        ("Revive {who} — {item}×{qty}", "{count} fainted · bag has {item}"),
        ("Bag → {item}×{qty}", "{who} is down · bring them back"),
        ("{who} needs {item}", "Fainted · {item}×{qty} ready"),
      ]
    case .fainted:
      return [
        ("Switch Pokémon — stay in it!", "{alive} left · no revive in bag"),
        ("Lead is down — switch!", "{alive} still fighting"),
        ("Send the next mon", "{alive} remaining · keep pressure"),
      ]
    }
  }
}
