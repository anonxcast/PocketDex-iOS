import Foundation

/// Gen 2 (Gold / Silver / Crystal, international) battery-save editor.
///
/// File offsets are SRAM bank offsets (0xA000 → 0x2000). They were cross-checked against the
/// pokecrystal / pokegold WRAM symbols (file = wram − 0xB472 for Crystal, − 0xB198 for G/S):
///
///                       Crystal   Gold/Silver
///     trainer ID (BE)   0x2009    0x2009
///     player name (11)  0x200B    0x200B
///     money (3-byte BE) 0x23DC    0x23DB
///     coins (u16 BE)    0x23E3    0x23E2
///     numItems          0x2420    0x241F      (items 20×id/qty, key items 25×id, balls 12×id/qty)
///     party count       0x2865    0x288A      (then 7-byte species list, 6×48 party, 6×11 OT, 6×11 nick)
///     gender            0x3E3D    —           (Crystal only, 0 = male, 1 = female)
///
/// Checksums are 16-bit additive sums stored little-endian:
///   Crystal: 0x2009…0x2B82 → 0x2D0D, backup copy 0x1209…0x1D82 → 0x1F0D
///   G/S:     0x2009…0x2D68 → 0x2D69 (backup region not touched; the game only falls back to it
///            when the primary checksum fails)
///
/// Party mon (48 bytes): 0 species · 1 held item · 2-5 moves · 6-7 OT ID · 8-10 exp ·
/// 11-20 stat exp (HP/Atk/Def/Spd/Spc u16 BE) · 21-22 DVs · 23-26 PP · 27 friendship · 28 pokérus ·
/// 29-30 caught data · 31 level · 32 status · 34-35 HP · 36-37 max HP · 38-47 Atk/Def/Spd/SpA/SpD (u16 BE).
///
/// `SaveMon.ivs` carries DVs (0…15) and `SaveMon.evs` stat exp (0…65535) as [HP, Atk, Def, Spe, SpA, SpD]
/// with SpA == SpD == Special. Species ids are National Dex numbers.
///
/// Polished Crystal and other hacks use a different map. They are not detected; if neither layout's party
/// validates, `parse` throws so the caller can mark the save unsupported.
struct Gen2Save {
  enum Variant: Equatable { case crystal, goldSilver }

  struct Layout {
    let variant: Variant
    let money: Int
    let coins: Int
    let numItems: Int
    let partyCount: Int
    let mainStart: Int
    let mainEnd: Int        // inclusive
    let mainChecksum: Int
    let backupStart: Int?   // same length as main; mirrored on rewrite when valid at parse
    let backupChecksum: Int?
    let gender: Int?

    var partySpecies: Int { partyCount + 1 }
    var party: Int { partyCount + 8 }
    var partyOT: Int { party + 6 * Gen2Save.partyMonSize }
    var partyNick: Int { partyOT + 6 * Gen12Text.nameLength }
    var keyItemsCount: Int { numItems + 42 }
    var ballsCount: Int { numItems + 69 }

    static let crystal = Layout(
      variant: .crystal, money: 0x23DC, coins: 0x23E3, numItems: 0x2420, partyCount: 0x2865,
      mainStart: 0x2009, mainEnd: 0x2B82, mainChecksum: 0x2D0D,
      backupStart: 0x1209, backupChecksum: 0x1F0D, gender: 0x3E3D)

    static let goldSilver = Layout(
      variant: .goldSilver, money: 0x23DB, coins: 0x23E2, numItems: 0x241F, partyCount: 0x288A,
      mainStart: 0x2009, mainEnd: 0x2D68, mainChecksum: 0x2D69,
      backupStart: nil, backupChecksum: nil, gender: nil)
  }

  enum Pocket { static let items = 0, keyItems = 1, balls = 2 }

  static let saveSize = 0x8000
  static let partyMonSize = 48
  static let maxParty = 6
  static let eggSpecies = 0xFD
  static let trainerIdOff = 0x2009
  static let playerNameOff = 0x200B
  static let playTimeOff = 0x2053     // hours u16 BE, minutes, seconds
  static let itemCapacity = 20
  static let keyItemCapacity = 25
  static let ballCapacity = 12
  static let maxMoney = 999_999
  static let maxCoins = 9_999
  static let maxDex = 251

  private(set) var bytes: [UInt8]
  let layout: Layout
  /// True when the Crystal backup block validated at parse, so `rewriteChecksums` may mirror into it.
  private let backupWasValid: Bool

  var variant: Variant { layout.variant }
  /// Anything other than a plain 32 KB image (e.g. RTC footer, Polished Crystal's larger SRAM).
  let hasNonStandardSize: Bool

  // MARK: Parse

  static func parse(_ data: Data) throws -> Gen2Save {
    guard data.count >= saveSize else {
      throw Gen12SaveError("Gen 2 save too small (\(data.count) bytes, expected \(saveSize))")
    }
    let b = [UInt8](data)
    // Prefer Crystal when both validate equally (it is the more common target here).
    let candidates: [Layout] = [.crystal, .goldSilver]
    var best: (layout: Layout, score: Int)?
    for l in candidates {
      guard partyLooksValid(b, l) else { continue }
      var score = 1
      if Int(b[l.partyCount]) > 0 { score += 2 }
      if checksumMatches(b, start: l.mainStart, end: l.mainEnd, at: l.mainChecksum) { score += 4 }
      if best == nil || score > best!.score { best = (l, score) }
    }
    guard let pick = best else {
      throw Gen12SaveError("Gen 2 save: neither Crystal nor Gold/Silver party layout validates (unsupported or hacked save)")
    }
    return Gen2Save(bytes: b, layout: pick.layout, nonStandard: data.count != saveSize)
  }

  private init(bytes: [UInt8], layout: Layout, nonStandard: Bool) {
    self.bytes = bytes
    self.layout = layout
    self.hasNonStandardSize = nonStandard
    if let bs = layout.backupStart, let bc = layout.backupChecksum {
      let len = layout.mainEnd - layout.mainStart
      self.backupWasValid = Self.checksumMatches(bytes, start: bs, end: bs + len, at: bc)
    } else {
      self.backupWasValid = false
    }
  }

  private static func checksumMatches(_ b: [UInt8], start: Int, end: Int, at chk: Int) -> Bool {
    guard end < b.count, chk + 1 < b.count else { return false }
    return Gen12Codec.sum16(b, from: start, through: end) == saveU16(b, chk)
  }

  private static func partyLooksValid(_ b: [UInt8], _ l: Layout) -> Bool {
    guard l.partyOT + 6 * Gen12Text.nameLength <= b.count else { return false }
    let count = Int(b[l.partyCount])
    guard count <= maxParty, b[l.partySpecies + count] == 0xFF else { return false }
    for i in 0..<count {
      let listed = Int(b[l.partySpecies + i])
      let o = l.party + i * partyMonSize
      let own = Int(b[o])
      let level = Int(b[o + 31])
      guard (1...maxDex).contains(own), (1...100).contains(level) else { return false }
      guard listed == own || listed == eggSpecies else { return false }
    }
    return true
  }

  // MARK: Checksums

  var mainChecksumIsValid: Bool {
    Self.checksumMatches(bytes, start: layout.mainStart, end: layout.mainEnd, at: layout.mainChecksum)
  }

  var backupChecksumIsValid: Bool? {
    guard let bs = layout.backupStart, let bc = layout.backupChecksum else { return nil }
    return Self.checksumMatches(bytes, start: bs, end: bs + (layout.mainEnd - layout.mainStart), at: bc)
  }

  mutating func rewriteChecksums() {
    let l = layout
    savePutU16(&bytes, l.mainChecksum, Gen12Codec.sum16(bytes, from: l.mainStart, through: l.mainEnd))
    if backupWasValid, let bs = l.backupStart, let bc = l.backupChecksum {
      let len = l.mainEnd - l.mainStart + 1
      bytes.replaceSubrange(bs..<(bs + len), with: bytes[l.mainStart..<(l.mainStart + len)])
      savePutU16(&bytes, bc, Gen12Codec.sum16(bytes, from: bs, through: bs + len - 1))
    }
  }

  /// The full save with checksums fixed.
  func build() -> Data {
    var copy = self
    copy.rewriteChecksums()
    return Data(copy.bytes)
  }

  // MARK: Reads

  var partyCount: Int { min(Int(bytes[layout.partyCount]), Self.maxParty) }

  func party() -> [SaveMon] {
    (0..<partyCount).compactMap { partyMon(at: $0) }
  }

  func partyMon(at slot: Int) -> SaveMon? {
    guard (0..<partyCount).contains(slot) else { return nil }
    let o = layout.party + slot * Self.partyMonSize
    let dvAD = bytes[o + 21], dvSS = bytes[o + 22]
    let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
    let hpDV = Gen12Stats.hpDV(atk: atk, def: def, spe: spe, spc: spc)
    let se = (0..<5).map { Gen12Codec.be16(bytes, o + 11 + $0 * 2) }
    let shiny = def == 10 && spe == 10 && spc == 10 && [2, 3, 6, 7, 10, 11, 14, 15].contains(atk)
    let isEgg = Int(bytes[layout.partySpecies + slot]) == Self.eggSpecies
    let species = Int(bytes[o])
    return SaveMon(
      id: "party-\(slot)",
      species: species,
      level: Int(bytes[o + 31]),
      heldItem: Int(bytes[o + 1]),
      friendship: Int(bytes[o + 27]),
      moves: (0..<4).map { Int(bytes[o + 2 + $0]) },
      pp: (0..<4).map { Int(bytes[o + 23 + $0]) & 0x3F },
      evs: [se[0], se[1], se[2], se[3], se[4], se[4]],
      ivs: [hpDV, atk, def, spe, spc, spc],
      nickname: Gen12Text.decode(bytes, off: layout.partyNick + slot * Gen12Text.nameLength),
      shiny: shiny,
      gender: Gen2Gender.gender(species: species, atkDV: atk),
      isEgg: isEgg,
      exp: Gen12Codec.be24(bytes, o + 8),
      nature: nil
    )
  }

  func trainer() -> SaveTrainer {
    let t = Self.playTimeOff
    let hours = Gen12Codec.be16(bytes, t)
    return SaveTrainer(
      name: Gen12Text.decode(bytes, off: Self.playerNameOff),
      money: Gen12Codec.be24(bytes, layout.money),
      coins: Gen12Codec.be16(bytes, layout.coins),
      trainerId: Gen12Codec.be16(bytes, Self.trainerIdOff),
      secretId: 0,
      isFemale: layout.gender.map { bytes[$0] == 1 } ?? false,
      playTime: String(format: "%d:%02d", hours, Int(bytes[t + 2]))
    )
  }

  /// Items (pocket 0), key items (pocket 1, qty 1) and balls (pocket 2).
  func bag() -> [SaveItemStack] {
    var out: [SaveItemStack] = []
    out += readPairs(at: layout.numItems, capacity: Self.itemCapacity, pocket: Pocket.items)
    let kn = min(Int(bytes[layout.keyItemsCount]), Self.keyItemCapacity)
    for i in 0..<kn {
      let id = Int(bytes[layout.keyItemsCount + 1 + i])
      if id == 0xFF { break }
      if id > 0 { out.append(SaveItemStack(item: id, quantity: 1, pocket: Pocket.keyItems)) }
    }
    out += readPairs(at: layout.ballsCount, capacity: Self.ballCapacity, pocket: Pocket.balls)
    return out
  }

  /// Crystal: owned @ 0x2A27 / seen @ 0x2A47; G/S: owned @ 0x2A4C / seen @ 0x2A6C (32 bytes each for 251 bits).
  func dexSummary() -> SaveDexSummary {
    let ownedOff = layout.variant == .crystal ? 0x2A27 : 0x2A4C
    let seenOff = layout.variant == .crystal ? 0x2A47 : 0x2A6C
    return SaveDexSummary(
      owned: Self.countBits(bytes, off: ownedOff, species: Self.maxDex),
      seen: Self.countBits(bytes, off: seenOff, species: Self.maxDex),
      max: Self.maxDex,
      nationalEnabled: nil
    )
  }

  private static func countBits(_ b: [UInt8], off: Int, species: Int) -> Int {
    guard off + (species + 7) / 8 <= b.count else { return 0 }
    var n = 0
    for i in 0..<species {
      if (b[off + i / 8] >> (i % 8)) & 1 != 0 { n += 1 }
    }
    return n
  }

  private func readPairs(at base: Int, capacity: Int, pocket: Int) -> [SaveItemStack] {
    let n = min(Int(bytes[base]), capacity)
    var out: [SaveItemStack] = []
    for i in 0..<n {
      let id = Int(bytes[base + 1 + i * 2])
      let qty = Int(bytes[base + 2 + i * 2])
      if id == 0xFF { break }
      if id > 0, qty > 0 { out.append(SaveItemStack(item: id, quantity: qty, pocket: pocket)) }
    }
    return out
  }

  // MARK: Writes

  mutating func setMoney(_ value: Int) {
    Gen12Codec.putBE24(&bytes, layout.money, Gen12Codec.clamp(value, 0, Self.maxMoney))
  }

  mutating func setCoins(_ value: Int) {
    Gen12Codec.putBE16(&bytes, layout.coins, Gen12Codec.clamp(value, 0, Self.maxCoins))
  }

  /// Replaces the Items pocket (max 20 stacks, qty 1…99). Other pockets are untouched.
  mutating func setItems(_ items: [SaveItemStack]) throws {
    try writePairs(at: layout.numItems, capacity: Self.itemCapacity, items.filter { $0.quantity > 0 }, name: "Items")
  }

  /// Replaces the Balls pocket (max 12 stacks, qty 1…99).
  mutating func setBalls(_ items: [SaveItemStack]) throws {
    try writePairs(at: layout.ballsCount, capacity: Self.ballCapacity, items.filter { $0.quantity > 0 }, name: "Balls")
  }

  private mutating func writePairs(at base: Int, capacity: Int, _ stacks: [SaveItemStack], name: String) throws {
    guard stacks.count <= capacity else {
      throw Gen12SaveError("Gen 2 \(name) pocket holds at most \(capacity) stacks")
    }
    for s in stacks where !(1...0xFE).contains(s.item) {
      throw Gen12SaveError("Gen 2 item id out of range: \(s.item)")
    }
    bytes[base] = UInt8(stacks.count)
    for i in 0..<capacity {
      if i < stacks.count {
        bytes[base + 1 + i * 2] = UInt8(stacks[i].item)
        bytes[base + 2 + i * 2] = UInt8(Gen12Codec.clamp(stacks[i].quantity, 1, 99))
      } else {
        bytes[base + 1 + i * 2] = i == stacks.count ? 0xFF : 0
        bytes[base + 2 + i * 2] = 0
      }
    }
    bytes[base + 1 + capacity * 2] = 0xFF
  }

  /// Edits one party slot. Only the non-nil fields are touched.
  /// Changing `level` does not recompute `exp` or stats; pass `exp` / call `recomputeStats` as needed.
  /// Eggs keep their egg marker in the species list when `species` changes.
  mutating func setPartyMon(
    slot: Int,
    species: Int? = nil,
    level: Int? = nil,
    moves: [Int]? = nil,
    pp: [Int]? = nil,
    hp: Int? = nil,
    maxHP: Int? = nil,
    heldItem: Int? = nil,
    exp: Int? = nil,
    nickname: String? = nil,
    gender: Gen3MonGender? = nil
  ) throws {
    guard (0..<partyCount).contains(slot) else {
      throw Gen12SaveError("Gen 2 party slot \(slot) out of range")
    }
    let o = layout.party + slot * Self.partyMonSize

    if let species {
      guard (1...Self.maxDex).contains(species) else {
        throw Gen12SaveError("Gen 2 species must be 1…\(Self.maxDex)")
      }
      bytes[o] = UInt8(species)
      if Int(bytes[layout.partySpecies + slot]) != Self.eggSpecies {
        bytes[layout.partySpecies + slot] = UInt8(species)
      }
    }
    var genderTouched = false
    if let gender {
      let sp = species ?? Int(bytes[o])
      let opts = Gen2Gender.options(species: sp)
      guard opts.contains(gender) else {
        throw Gen12SaveError("That species can't be \(gender.label.lowercased())")
      }
      let dvAD = bytes[o + 21], dvSS = bytes[o + 22]
      let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
      let shiny = def == 10 && spe == 10 && spc == 10 && [2, 3, 6, 7, 10, 11, 14, 15].contains(atk)
      let newAtk = Gen2Gender.atkDV(for: gender, species: sp, preferShiny: shiny, current: atk)
      bytes[o + 21] = UInt8(((newAtk & 0xF) << 4) | (def & 0xF))
      genderTouched = true
    }
    if let level {
      guard (1...100).contains(level) else { throw Gen12SaveError("Level must be 1…100") }
      bytes[o + 31] = UInt8(level)
    }
    if let moves {
      guard moves.count == 4, moves.allSatisfy({ (0...255).contains($0) }) else {
        throw Gen12SaveError("Need 4 move ids (0…255)")
      }
      for i in 0..<4 { bytes[o + 2 + i] = UInt8(moves[i]) }
    }
    if let pp {
      guard pp.count == 4, pp.allSatisfy({ (0...63).contains($0) }) else {
        throw Gen12SaveError("Need 4 PP values (0…63)")
      }
      for i in 0..<4 { bytes[o + 23 + i] = (bytes[o + 23 + i] & 0xC0) | UInt8(pp[i]) }
    }
    if let heldItem {
      guard (0...255).contains(heldItem) else { throw Gen12SaveError("Held item must be 0…255") }
      bytes[o + 1] = UInt8(heldItem)
    }
    if let exp {
      Gen12Codec.putBE24(&bytes, o + 8, Gen12Codec.clamp(exp, 0, 0xFFFFFF))
    }
    if let maxHP {
      Gen12Codec.putBE16(&bytes, o + 36, Gen12Codec.clamp(maxHP, 1, 999))
    }
    if let hp {
      let cap = Gen12Codec.be16(bytes, o + 36)
      Gen12Codec.putBE16(&bytes, o + 34, Gen12Codec.clamp(hp, 0, Swift.max(cap, 1)))
    } else if maxHP != nil {
      let cur = Gen12Codec.be16(bytes, o + 34)
      Gen12Codec.putBE16(&bytes, o + 34, Swift.min(cur, Gen12Codec.be16(bytes, o + 36)))
    }
    if let nickname {
      let enc = Gen12Text.encode(nickname)
      let no = layout.partyNick + slot * Gen12Text.nameLength
      for i in 0..<Gen12Text.nameLength { bytes[no + i] = enc[i] }
    }
    if genderTouched {
      let sp = Int(bytes[o])
      let base = Gen3BaseStats.stats(species: sp, tables: .crystal)
      try? recomputeStats(slot: slot, baseStats: base, healFully: false)
    }
  }

  /// Recomputes max HP and stats from DVs / stat exp / level using caller-supplied base stats
  /// `[HP, Atk, Def, Spe, SpA, SpD]`. HP is clamped to the new max, or set to it when `healFully`.
  mutating func recomputeStats(slot: Int, baseStats: [Int], healFully: Bool = false) throws {
    guard (0..<partyCount).contains(slot) else {
      throw Gen12SaveError("Gen 2 party slot \(slot) out of range")
    }
    guard baseStats.count == 6 else {
      throw Gen12SaveError("Need 6 base stats [HP, Atk, Def, Spe, SpA, SpD]")
    }
    let o = layout.party + slot * Self.partyMonSize
    let level = Int(bytes[o + 31])
    let dvAD = bytes[o + 21], dvSS = bytes[o + 22]
    let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
    let dvs = [Gen12Stats.hpDV(atk: atk, def: def, spe: spe, spc: spc), atk, def, spe, spc, spc]
    // Stat exp order in the struct: HP, Atk, Def, Spe, Spc (Spc feeds both SpA and SpD).
    let se = (0..<5).map { Gen12Codec.be16(bytes, o + 11 + $0 * 2) }
    let statExp = [se[0], se[1], se[2], se[3], se[4], se[4]]
    var out: [Int] = []
    for i in 0..<6 {
      out.append(Gen12Stats.calc(base: baseStats[i], dv: dvs[i], statExp: statExp[i], level: level, isHP: i == 0))
    }
    for i in 0..<6 { Gen12Codec.putBE16(&bytes, o + 36 + i * 2, out[i]) }
    let cur = Gen12Codec.be16(bytes, o + 34)
    Gen12Codec.putBE16(&bytes, o + 34, healFully ? out[0] : Swift.min(cur, out[0]))
  }
}

/// Gen 2 gender from Attack DV vs species threshold (Crystal / Gold / Silver / Polished).
enum Gen2Gender {
  static func options(species: Int) -> [Gen3MonGender] {
    Gen3Gender.options(species: species, tables: .crystal)
  }

  static func gender(species: Int, atkDV: Int) -> Gen3MonGender {
    let r = Gen3Gender.ratio(species: species, tables: .crystal)
    if r == 255 { return .genderless }
    if r == 0 { return .male }
    if r == 254 { return .female }
    let thresh = atkThreshold(ratio: r)
    return atkDV < thresh ? .female : .male
  }

  /// ATK DV that yields `gender`, preferring a shiny-legal nibble when `preferShiny`.
  static func atkDV(for gender: Gen3MonGender, species: Int, preferShiny: Bool, current: Int) -> Int {
    let r = Gen3Gender.ratio(species: species, tables: .crystal)
    if r == 255 || r == 0 || r == 254 { return current & 0xF }
    let thresh = atkThreshold(ratio: r)
    let wantFemale = gender == .female
    let shinyPool = [2, 3, 6, 7, 10, 11, 14, 15]
    if preferShiny {
      let hits = shinyPool.filter { wantFemale ? $0 < thresh : $0 >= thresh }
      if let hit = hits.first { return hit }
    }
    if wantFemale {
      return max(0, min(15, thresh - 1))
    }
    return max(0, min(15, thresh))
  }

  /// Gen 2 Attack-DV thresholds for the standard female percentages.
  private static func atkThreshold(ratio: Int) -> Int {
    switch ratio {
    case ...31: return 2    // 12.5% ♀
    case ...63: return 4    // 25% ♀
    case ...127: return 8   // 50% ♀
    case ...191: return 12  // 75% ♀
    default: return 14      // 87.5% ♀
    }
  }
}
