import Foundation

struct Gen45MonError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

/// One Gen 4 (PK4) or Gen 5 (PK5) party Pokémon, held decrypted. The two share the layouts this editor touches:
///
///     0x00 PID u32      0x04 u16 flags      0x06 u16 checksum
///     A 0x08 species u16 · 0x0A held item · 0x0C TID · 0x0E SID · 0x10 exp u32 · 0x14 friendship · 0x15 ability
///       0x17 language · 0x18 EVs (HP Atk Def Spe SpA SpD)
///     B 0x28 moves (4 u16) · 0x30 PP (4) · 0x34 PP Ups (4) · 0x38 IV word (5 bits x6, bit 30 egg, bit 31 nicknamed)
///       0x40 gender / forme · 0x41 nature
///     C 0x48 nickname (11 x u16)      D 0x68 OT name (8 x u16)
///     party tail: 0x88 status · 0x8C level · 0x8E HP · 0x90 max HP · 0x92 Atk · 0x94 Def · 0x96 Spe · 0x98 SpA · 0x9A SpD
///
/// `encrypted()` refreshes the checksum and puts it back the way the game stores it.
struct Gen45Mon {
  static let maxLevel = 100
  static let nameChars = 10
  static let nicknameSlotChars = 11

  let gen5: Bool
  private(set) var d: [UInt8]

  /// A readable record: the checksum of the decrypted data matches and the species is one the game has.
  /// nil for an empty slot or garbage.
  init?(encrypted raw: [UInt8], gen5: Bool) {
    guard raw.count == (gen5 ? PokeCrypto.size5Party : PokeCrypto.size4Party) else { return nil }
    let plain = PokeCrypto.decrypt45(raw)
    guard PokeCrypto.checksumValid(decrypted: plain) else { return nil }
    self.gen5 = gen5
    self.d = plain
    guard (1...maxSpecies).contains(species) else { return nil }
  }

  var maxSpecies: Int { gen5 ? Gen45Personal.gen5MaxSpecies : Gen45Personal.gen4MaxSpecies }
  var maxMove: Int { gen5 ? Gen45Personal.gen5MaxMove : Gen45Personal.gen4MaxMove }

  // MARK: Reads

  var pid: Int { saveU32(d, 0) }
  var species: Int { saveU16(d, 0x08) }
  var heldItem: Int { saveU16(d, 0x0A) }
  var tid: Int { saveU16(d, 0x0C) }
  var sid: Int { saveU16(d, 0x0E) }
  var exp: Int { saveU32(d, 0x10) }
  var friendship: Int { Int(d[0x14]) }
  var ability: Int { Int(d[0x15]) }
  var language: Int { Int(d[0x17]) }
  var evs: [Int] { (0..<6).map { Int(d[0x18 + $0]) } }
  var moves: [Int] { (0..<4).map { saveU16(d, 0x28 + $0 * 2) } }
  var pp: [Int] { (0..<4).map { Int(d[0x30 + $0]) } }
  var ppUps: [Int] { (0..<4).map { Int(d[0x34 + $0]) & 3 } }
  private var ivWord: Int { saveU32(d, 0x38) }
  var ivs: [Int] { (0..<6).map { (ivWord >> ($0 * 5)) & 0x1F } }
  var isEgg: Bool { (ivWord >> 30) & 1 == 1 }
  var isNicknamed: Bool { (ivWord >> 31) & 1 == 1 }
  /// Gen 5 stores nature at 0x41; Gen 4 derives it from PID % 25.
  var nature: Int {
    if gen5 {
      let n = Int(d[0x41])
      return n < 25 ? n : pid % 25
    }
    return ((pid % 25) + 25) % 25
  }
  var level: Int { Int(d[0x8C]) }
  var hp: Int { saveU16(d, 0x8E) }
  var maxHP: Int { saveU16(d, 0x90) }
  /// [HP, Atk, Def, Spe, SpA, SpD]
  var stats: [Int] { [saveU16(d, 0x90)] + (0..<5).map { saveU16(d, 0x92 + $0 * 2) } }
  var isShiny: Bool { (tid ^ sid ^ (pid >> 16) ^ (pid & 0xFFFF)) < 8 }
  var nickname: String { Gen45Text.decode(d, off: 0x48, maxChars: Gen45Mon.nicknameSlotChars, gen5: gen5) }
  /// National-dex gender ratios (Gen 4 / 5 species ids align with `.national`).
  var gender: Gen3MonGender {
    Gen3Gender.gender(species: species, personality: pid, tables: .national)
  }

  var growthRate: Int { Gen45Personal.entry(species: species, gen5: gen5)?.growth ?? 0 }

  func saveMon(id: String) -> SaveMon {
    SaveMon(
      id: id, species: species, level: level, heldItem: heldItem, friendship: friendship,
      moves: moves, pp: pp, evs: evs, ivs: ivs, nickname: nickname, shiny: isShiny, gender: gender, isEgg: isEgg,
      exp: exp, nature: nature)
  }

  // MARK: Edits (all validate before touching a byte)

  /// Experience for `level` on this mon's growth rate.
  func expFor(level: Int) -> Int { Gen3BoxMon.expForLevel(level, rate: growthRate) }

  mutating func setSpecies(_ s: Int) throws {
    guard (1...maxSpecies).contains(s) else { throw Gen45MonError("species \(s)") }
    let wasNamed = isNicknamed
    savePutU16(&d, 0x08, s)
    // An un-nicknamed mon shows its species name: keep the stored name in step (English names only).
    if !wasNamed, language == 2, let name = Gen3Names.speciesNational[s] {
      Gen45Text.encode(name, into: &d, off: 0x48, maxChars: Gen45Mon.nameChars,
                       slotChars: Gen45Mon.nicknameSlotChars, gen5: gen5)
    }
  }

  /// Sets the level byte and the EXP of that level's threshold. Stats are separate (`recomputeStats`).
  mutating func setLevel(_ l: Int) throws {
    guard (1...Gen45Mon.maxLevel).contains(l) else { throw Gen45MonError("level \(l)") }
    d[0x8C] = UInt8(l)
    savePutU32(&d, 0x10, expFor(level: l))
  }

  mutating func setHeldItem(_ item: Int, maxItem: Int) throws {
    guard (0...maxItem).contains(item) else { throw Gen45MonError("item \(item)") }
    savePutU16(&d, 0x0A, item)
  }

  /// 1-4 different moves (further slots empty). A move the mon already knows keeps its PP and PP Ups; a new one
  /// gets full base PP and no Ups.
  mutating func setMoves(_ new: [Int]) throws {
    guard (1...4).contains(new.count), new.allSatisfy({ (1...maxMove).contains($0) }), Set(new).count == new.count
    else { throw Gen45MonError("moves \(new)") }
    let known = moves, knownPP = pp, knownUps = ppUps
    for i in 0..<4 {
      if i < new.count {
        let m = new[i]
        let base = Gen45Personal.basePP(move: m, gen5: gen5)
        var ups = 0
        var cur = base
        if let was = known.firstIndex(of: m) {
          ups = knownUps[was]
          cur = min(knownPP[was], base + base / 5 * ups)
        }
        savePutU16(&d, 0x28 + i * 2, m)
        d[0x30 + i] = UInt8(cur)
        d[0x34 + i] = UInt8(ups)
      } else {
        savePutU16(&d, 0x28 + i * 2, 0)
        d[0x30 + i] = 0
        d[0x34 + i] = 0
      }
    }
  }

  mutating func setEVs(_ e: [Int]) throws {
    guard e.count == 6, e.allSatisfy({ (0...255).contains($0) }) else { throw Gen45MonError("EVs \(e)") }
    for i in 0..<6 { d[0x18 + i] = UInt8(e[i]) }
  }

  mutating func setIVs(_ v: [Int]) throws {
    guard v.count == 6, v.allSatisfy({ (0...31).contains($0) }) else { throw Gen45MonError("IVs \(v)") }
    var word = ivWord & ~0x3FFF_FFFF
    for i in 0..<6 { word |= v[i] << (i * 5) }
    savePutU32(&d, 0x38, word)
  }

  mutating func setNickname(_ s: String) {
    Gen45Text.encode(s, into: &d, off: 0x48, maxChars: Gen45Mon.nameChars,
                     slotChars: Gen45Mon.nicknameSlotChars, gen5: gen5)
    savePutU32(&d, 0x38, ivWord | (1 << 31))
  }

  /// Gen 5: write nature byte. Gen 4: rebuild PID (% 25) while keeping gender + shiny.
  mutating func setNature(_ n: Int) throws {
    guard (0..<25).contains(n) else { throw Gen45MonError("nature \(n)") }
    if nature == n { return }
    if gen5 {
      d[0x41] = UInt8(n)
    } else {
      let newPid = Self.matchingPersonality(
        tid: tid, sid: sid, shiny: isShiny, nature: n, gender: gender, species: species
      )
      savePutU32(&d, 0, newPid & 0xFFFF_FFFF)
    }
  }

  /// Rebuild PID for the requested gender (nature + shiny preserved when possible).
  mutating func setGender(_ g: Gen3MonGender) throws {
    let options = Gen3Gender.options(species: species, tables: .national)
    guard options.contains(g) else {
      throw Gen45MonError("\(Gen3Names.speciesNational[species] ?? "Species") can't be \(g.label.lowercased())")
    }
    if gender == g { return }
    let newPid = Self.matchingPersonality(
      tid: tid, sid: sid, shiny: isShiny, nature: nature, gender: g, species: species
    )
    savePutU32(&d, 0, newPid & 0xFFFF_FFFF)
  }

  /// PID matching shiny, nature (% 25), and gender (low byte vs national gender ratio).
  static func matchingPersonality(
    tid: Int, sid: Int, shiny: Bool, nature: Int, gender: Gen3MonGender, species: Int
  ) -> Int {
    let wantNature = ((nature % 25) + 25) % 25
    let genderByte = Gen3Gender.personalityByte(for: gender, species: species, tables: .national)
    var pid = Int.random(in: 0...0x7FFF_FFFF)
    for _ in 0..<400_000 {
      let candidate = (pid & ~0xFF) | genderByte
      let sv = (tid ^ sid ^ (candidate >> 16) ^ (candidate & 0xFFFF)) & 0xFFFF
      if (sv < 8) == shiny && candidate % 25 == wantNature {
        return candidate
      }
      pid = (pid &+ 0x100) & 0x7FFF_FFFF
    }
    if shiny {
      var p1 = Int.random(in: 0...0xFFFF)
      for _ in 0..<10_000 {
        let p2 = ((tid ^ sid ^ p1) & 0xFFF8) | (genderByte & 0x7)
        let candidate = (p1 << 16) | (p2 & 0xFF00) | genderByte
        let sv = (tid ^ sid ^ (candidate >> 16) ^ (candidate & 0xFFFF)) & 0xFFFF
        if sv < 8 { return candidate }
        p1 = (p1 &+ 1) & 0xFFFF
      }
    }
    return (wantNature &* 0x100) | genderByte
  }

  mutating func setHP(_ v: Int) throws {
    guard (0...maxHP).contains(v) else { throw Gen45MonError("HP \(v)") }
    savePutU16(&d, 0x8E, v)
  }

  /// Max HP and the five stats from base stats, IVs, EVs, level and nature (the game's formula).
  /// HP is clamped to the new max, or set to it with `healFully`. Skips (returns false) if there's no base-stat entry.
  @discardableResult
  mutating func recomputeStats(healFully: Bool = false) -> Bool {
    guard let e = Gen45Personal.entry(species: species, gen5: gen5) else { return false }
    let l = level, iv = ivs, ev = evs, nat = nature
    var out = [Int](repeating: 0, count: 6)
    if species == 292 {   // Shedinja
      out[0] = 1
    } else {
      out[0] = (2 * e.base[0] + iv[0] + ev[0] / 4) * l / 100 + l + 10
    }
    // Nature: +stat = nat / 5, -stat = nat % 5 over Atk, Def, Spe, SpA, SpD
    let up = nat / 5, down = nat % 5
    for s in 1...5 {
      var v = (2 * e.base[s] + iv[s] + ev[s] / 4) * l / 100 + 5
      if up != down {
        if s - 1 == up { v = v * 110 / 100 }
        if s - 1 == down { v = v * 90 / 100 }
      }
      out[s] = v
    }
    savePutU16(&d, 0x90, out[0])
    for s in 1...5 { savePutU16(&d, 0x92 + (s - 1) * 2, out[s]) }
    savePutU16(&d, 0x8E, healFully ? out[0] : min(hp, out[0]))
    return true
  }

  /// The record as the game stores it: checksum refreshed, shuffled, encrypted.
  func encrypted() -> [UInt8] {
    var p = d
    PokeCrypto.refreshChecksum(&p)
    return PokeCrypto.encrypt45(p)
  }
}
