import Foundation

/// Gen 1 (Red / Blue / Yellow, international) battery-save editor.
///
/// Layout follows PKHeX `SAV1` / Bulbapedia "Save data structure (Generation I)":
///
///     0x2598 player name (11)       0x25A3 dex owned (19)    0x25B6 dex seen (19)
///     0x25C9 bag (count, 20×id/qty, 0xFF)                    0x25F3 money (3-byte BCD)
///     0x25F6 rival name (11)        0x2601 options           0x2602 badges
///     0x2605 trainer ID (u16 BE)    0x2850 coins (2-byte BCD)
///     0x2CED play time (h, 0, m, s, frames)
///     0x2F2C party count, 0x2F2D species list (6 + 0xFF), 0x2F34 party (6×44),
///     0x303C party OT names (6×11), 0x307E party nicknames (6×11)
///     0x3523 checksum = ~sum(bytes 0x2598..<0x3523)
///
/// Party mon (44 bytes): 0 species(internal) · 1-2 HP · 3 box level · 4 status · 5-6 types · 7 catch rate ·
/// 8-11 moves · 12-13 OT ID · 14-16 exp · 17-26 stat exp (HP/Atk/Def/Spd/Spc, u16 BE each) ·
/// 27-28 DVs · 29-32 PP · 33 level · 34-35 max HP · 36-43 Atk/Def/Spd/Spc (u16 BE each).
///
/// `SaveMon.species` is the National Dex number; the internal Gen 1 index is converted on read/write.
/// `SaveMon.ivs` carries DVs (0…15) and `SaveMon.evs` carries stat exp (0…65535), both as
/// [HP, Atk, Def, Spe, SpA, SpD] with SpA == SpD == Special.
struct Gen1Save {
  enum Offsets {
    static let playerName = 0x2598
    static let dexOwned = 0x25A3
    static let dexSeen = 0x25B6
    static let bagCount = 0x25C9
    static let money = 0x25F3
    static let rivalName = 0x25F6
    static let options = 0x2601
    static let badges = 0x2602
    static let trainerId = 0x2605
    static let coins = 0x2850
    static let playTime = 0x2CED
    static let partyCount = 0x2F2C
    static let partySpecies = 0x2F2D
    static let party = 0x2F34
    static let partyOT = 0x303C
    static let partyNick = 0x307E
    /// Current box payload (20×33 + species list); box index nibble at 0x284C.
    static let currentBoxIndex = 0x284C
    static let currentBoxCount = 0x30C0
    static let currentBoxSpecies = 0x30C1
    static let currentBoxData = 0x30D6
    static let currentBoxOT = 0x336A
    static let currentBoxNick = 0x3446
    static let boxMonSize = 33
    static let boxSlots = 20
    static let checksumStart = 0x2598
    static let checksumEnd = 0x3523   // exclusive; checksum byte lives here
  }

  static let saveSize = 0x8000
  static let partyMonSize = 44
  static let maxParty = 6
  static let bagCapacity = 20
  static let maxMoney = 999_999
  static let maxCoins = 9_999
  static let maxDex = 151

  /// Gen 1 internal species index → National Dex number (0 = MissingNo / unused).
  static let internalToDex: [Int] = [
    0,
    112, 115, 32, 35, 21, 100, 34, 80, 2, 103,
    108, 102, 88, 94, 29, 31, 104, 111, 131, 59,
    151, 130, 90, 72, 92, 123, 120, 9, 127, 114,
    0, 0, 58, 95, 22, 16, 79, 64, 75, 113,
    67, 122, 106, 107, 24, 47, 54, 96, 76, 0,
    126, 0, 125, 82, 109, 0, 56, 86, 50, 128,
    0, 0, 0, 83, 48, 149, 0, 0, 0, 84,
    60, 124, 146, 144, 145, 132, 52, 98, 0, 0,
    0, 37, 38, 25, 26, 0, 0, 147, 148, 140,
    141, 116, 117, 0, 0, 27, 28, 138, 139, 39,
    40, 133, 136, 135, 134, 66, 41, 23, 46, 61,
    62, 13, 14, 15, 0, 85, 57, 51, 49, 87,
    0, 0, 10, 11, 12, 68, 0, 55, 97, 42,
    150, 143, 129, 0, 0, 89, 0, 99, 91, 0,
    101, 36, 110, 53, 105, 0, 93, 63, 65, 17,
    18, 121, 1, 3, 73, 0, 118, 119, 0, 0,
    0, 0, 77, 78, 19, 20, 33, 30, 74, 137,
    142, 0, 81, 0, 0, 4, 7, 5, 8, 6,
    0, 0, 0, 0, 43, 44, 45, 69, 70, 71,
  ]

  static let dexToInternal: [Int: Int] = {
    var d: [Int: Int] = [:]
    for (i, dex) in internalToDex.enumerated() where dex > 0 { d[dex] = i }
    return d
  }()

  static func dexNumber(internal idx: Int) -> Int {
    (0..<internalToDex.count).contains(idx) ? internalToDex[idx] : 0
  }

  private(set) var bytes: [UInt8]

  // MARK: Parse

  static func parse(_ data: Data) throws -> Gen1Save {
    guard data.count >= saveSize else {
      throw Gen12SaveError("Gen 1 save too small (\(data.count) bytes, expected \(saveSize))")
    }
    let b = [UInt8](data)
    let count = Int(b[Offsets.partyCount])
    guard count <= maxParty else {
      throw Gen12SaveError("Gen 1 save: invalid party count \(count)")
    }
    guard b[Offsets.partySpecies + count] == 0xFF else {
      throw Gen12SaveError("Gen 1 save: party species list is not 0xFF-terminated")
    }
    return Gen1Save(bytes: b)
  }

  private init(bytes: [UInt8]) { self.bytes = bytes }

  // MARK: Checksum

  var computedChecksum: UInt8 {
    ~Gen12Codec.sum8(bytes, from: Offsets.checksumStart, to: Offsets.checksumEnd)
  }

  var storedChecksum: UInt8 { bytes[Offsets.checksumEnd] }
  var checksumIsValid: Bool { computedChecksum == storedChecksum }

  mutating func rewriteChecksum() {
    bytes[Offsets.checksumEnd] = computedChecksum
  }

  /// The full save with the checksum fixed.
  func build() -> Data {
    var copy = self
    copy.rewriteChecksum()
    return Data(copy.bytes)
  }

  // MARK: Reads

  var partyCount: Int { min(Int(bytes[Offsets.partyCount]), Self.maxParty) }

  func party() -> [SaveMon] {
    (0..<partyCount).compactMap { partyMon(at: $0) }
  }

  func partyMon(at slot: Int) -> SaveMon? {
    guard (0..<partyCount).contains(slot) else { return nil }
    let o = Offsets.party + slot * Self.partyMonSize
    let internalId = Int(bytes[o])
    let dex = Self.dexNumber(internal: internalId)
    let dvAD = bytes[o + 27], dvSS = bytes[o + 28]
    let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
    let hpDV = Gen12Stats.hpDV(atk: atk, def: def, spe: spe, spc: spc)
    let se = (0..<5).map { Gen12Codec.be16(bytes, o + 17 + $0 * 2) }
    let nick = Gen12Text.decode(bytes, off: Offsets.partyNick + slot * Gen12Text.nameLength)
    return SaveMon(
      id: "party-\(slot)",
      species: dex,
      level: Int(bytes[o + 33]),
      heldItem: 0,
      friendship: 0,
      moves: (0..<4).map { Int(bytes[o + 8 + $0]) },
      pp: (0..<4).map { Int(bytes[o + 29 + $0]) & 0x3F },
      evs: [se[0], se[1], se[2], se[3], se[4], se[4]],
      ivs: [hpDV, atk, def, spe, spc, spc],
      nickname: nick,
      shiny: false,
      gender: nil,
      isEgg: false,
      exp: Gen12Codec.be24(bytes, o + 14),
      nature: nil
    )
  }

  func trainer() -> SaveTrainer {
    SaveTrainer(
      name: Gen12Text.decode(bytes, off: Offsets.playerName),
      money: Gen12Codec.bcd(bytes, off: Offsets.money, len: 3),
      coins: Gen12Codec.bcd(bytes, off: Offsets.coins, len: 2),
      trainerId: Gen12Codec.be16(bytes, Offsets.trainerId),
      secretId: 0,
      isFemale: false,
      playTime: String(format: "%d:%02d", Int(bytes[Offsets.playTime]), Int(bytes[Offsets.playTime + 2]))
    )
  }

  func bag() -> [SaveItemStack] {
    let n = min(Int(bytes[Offsets.bagCount]), Self.bagCapacity)
    var out: [SaveItemStack] = []
    for i in 0..<n {
      let id = Int(bytes[Offsets.bagCount + 1 + i * 2])
      let qty = Int(bytes[Offsets.bagCount + 2 + i * 2])
      if id == 0xFF { break }
      if id > 0, qty > 0 { out.append(SaveItemStack(item: id, quantity: qty, pocket: 0)) }
    }
    return out
  }

  func dexSummary() -> SaveDexSummary {
    SaveDexSummary(
      owned: Self.countBits(bytes, off: Offsets.dexOwned, species: Self.maxDex),
      seen: Self.countBits(bytes, off: Offsets.dexSeen, species: Self.maxDex),
      max: Self.maxDex,
      nationalEnabled: nil
    )
  }

  /// The open PC box only (other boxes live in banked SRAM and aren't remapped here).
  func currentBox() -> [SaveBox] {
    let idx = Int(bytes[Offsets.currentBoxIndex] & 0x0F)
    let count = min(Int(bytes[Offsets.currentBoxCount]), Offsets.boxSlots)
    var mons: [SaveMon] = []
    for slot in 0..<count {
      let internalId = Int(bytes[Offsets.currentBoxSpecies + slot])
      if internalId == 0 || internalId == 0xFF { continue }
      let o = Offsets.currentBoxData + slot * Offsets.boxMonSize
      let dex = Self.dexNumber(internal: internalId)
      let dvAD = bytes[o + 0x1B], dvSS = bytes[o + 0x1C]
      let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
      let level = Int(bytes[o + 3]) // box level byte
      mons.append(SaveMon(
        id: "box-\(idx)-\(slot)",
        species: dex,
        level: level,
        heldItem: 0,
        friendship: 0,
        moves: (0..<4).map { Int(bytes[o + 8 + $0]) },
        pp: (0..<4).map { Int(bytes[o + 0x1D + $0]) & 0x3F },
        evs: [0, 0, 0, 0, 0, 0],
        ivs: [Gen12Stats.hpDV(atk: atk, def: def, spe: spe, spc: spc), atk, def, spe, spc, spc],
        nickname: Gen12Text.decode(bytes, off: Offsets.currentBoxNick + slot * Gen12Text.nameLength),
        shiny: false,
        gender: nil,
        isEgg: false,
        exp: Gen12Codec.be24(bytes, o + 0x0E),
        nature: nil
      ))
    }
    return [SaveBox(index: idx, name: "Box \(idx + 1)", mons: mons)]
  }

  private static func countBits(_ b: [UInt8], off: Int, species: Int) -> Int {
    var n = 0
    for i in 0..<species {
      if (b[off + i / 8] >> (i % 8)) & 1 != 0 { n += 1 }
    }
    return n
  }

  // MARK: Writes

  mutating func setMoney(_ value: Int) {
    Gen12Codec.putBCD(&bytes, off: Offsets.money, len: 3, Gen12Codec.clamp(value, 0, Self.maxMoney))
  }

  mutating func setCoins(_ value: Int) {
    Gen12Codec.putBCD(&bytes, off: Offsets.coins, len: 2, Gen12Codec.clamp(value, 0, Self.maxCoins))
  }

  /// Replaces the bag (max 20 distinct stacks, qty 1…99).
  mutating func setBag(_ items: [SaveItemStack]) throws {
    let stacks = items.filter { $0.quantity > 0 }
    guard stacks.count <= Self.bagCapacity else {
      throw Gen12SaveError("Gen 1 bag holds at most \(Self.bagCapacity) stacks")
    }
    for s in stacks where !(1...0xFE).contains(s.item) {
      throw Gen12SaveError("Gen 1 item id out of range: \(s.item)")
    }
    let base = Offsets.bagCount
    bytes[base] = UInt8(stacks.count)
    for i in 0..<Self.bagCapacity {
      if i < stacks.count {
        bytes[base + 1 + i * 2] = UInt8(stacks[i].item)
        bytes[base + 2 + i * 2] = UInt8(Gen12Codec.clamp(stacks[i].quantity, 1, 99))
      } else {
        bytes[base + 1 + i * 2] = i == stacks.count ? 0xFF : 0
        bytes[base + 2 + i * 2] = 0
      }
    }
    bytes[base + 1 + Self.bagCapacity * 2] = 0xFF
  }

  /// Edits one party slot. Only the non-nil fields are touched.
  /// - `species` is a National Dex number (1…151). Types (`types`) are NOT derived from species —
  ///   pass them (Gen 1 type ids) when changing species or battle types will be stale.
  /// - Changing `level` does not recompute `exp` or stats; pass `exp` / call `recomputeStats` as needed.
  mutating func setPartyMon(
    slot: Int,
    species: Int? = nil,
    level: Int? = nil,
    moves: [Int]? = nil,
    pp: [Int]? = nil,
    hp: Int? = nil,
    maxHP: Int? = nil,
    exp: Int? = nil,
    nickname: String? = nil,
    types: (Int, Int)? = nil
  ) throws {
    guard (0..<partyCount).contains(slot) else {
      throw Gen12SaveError("Gen 1 party slot \(slot) out of range")
    }
    let o = Offsets.party + slot * Self.partyMonSize

    if let species {
      guard let idx = Self.dexToInternal[species] else {
        throw Gen12SaveError("Gen 1 has no species #\(species)")
      }
      bytes[o] = UInt8(idx)
      bytes[Offsets.partySpecies + slot] = UInt8(idx)
    }
    if let types {
      bytes[o + 5] = UInt8(truncatingIfNeeded: types.0)
      bytes[o + 6] = UInt8(truncatingIfNeeded: types.1)
    }
    if let level {
      guard (1...100).contains(level) else { throw Gen12SaveError("Level must be 1…100") }
      bytes[o + 3] = UInt8(level)
      bytes[o + 33] = UInt8(level)
    }
    if let moves {
      guard moves.count == 4, moves.allSatisfy({ (0...255).contains($0) }) else {
        throw Gen12SaveError("Need 4 move ids (0…255)")
      }
      for i in 0..<4 { bytes[o + 8 + i] = UInt8(moves[i]) }
    }
    if let pp {
      guard pp.count == 4, pp.allSatisfy({ (0...63).contains($0) }) else {
        throw Gen12SaveError("Need 4 PP values (0…63)")
      }
      // Keep the PP-Up bits (top 2 of each byte).
      for i in 0..<4 { bytes[o + 29 + i] = (bytes[o + 29 + i] & 0xC0) | UInt8(pp[i]) }
    }
    if let exp {
      Gen12Codec.putBE24(&bytes, o + 14, Gen12Codec.clamp(exp, 0, 0xFFFFFF))
    }
    if let maxHP {
      Gen12Codec.putBE16(&bytes, o + 34, Gen12Codec.clamp(maxHP, 1, 999))
    }
    if let hp {
      let cap = Gen12Codec.be16(bytes, o + 34)
      Gen12Codec.putBE16(&bytes, o + 1, Gen12Codec.clamp(hp, 0, max(cap, 1)))
    } else if maxHP != nil {
      let cur = Gen12Codec.be16(bytes, o + 1)
      Gen12Codec.putBE16(&bytes, o + 1, min(cur, Gen12Codec.be16(bytes, o + 34)))
    }
    if let nickname {
      let enc = Gen12Text.encode(nickname)
      let no = Offsets.partyNick + slot * Gen12Text.nameLength
      for i in 0..<Gen12Text.nameLength { bytes[no + i] = enc[i] }
    }
  }

  /// Recomputes max HP and the four stats from DVs / stat exp / level using caller-supplied base stats
  /// `[HP, Atk, Def, Spd, Spc]`, and tops up HP to the new max when `healFully` is true.
  mutating func recomputeStats(slot: Int, baseStats: [Int], healFully: Bool = false) throws {
    guard (0..<partyCount).contains(slot) else {
      throw Gen12SaveError("Gen 1 party slot \(slot) out of range")
    }
    guard baseStats.count == 5 else { throw Gen12SaveError("Need 5 base stats [HP, Atk, Def, Spd, Spc]") }
    let o = Offsets.party + slot * Self.partyMonSize
    let level = Int(bytes[o + 33])
    let dvAD = bytes[o + 27], dvSS = bytes[o + 28]
    let atk = Int(dvAD >> 4), def = Int(dvAD & 0xF), spe = Int(dvSS >> 4), spc = Int(dvSS & 0xF)
    let dvs = [Gen12Stats.hpDV(atk: atk, def: def, spe: spe, spc: spc), atk, def, spe, spc]
    var out: [Int] = []
    for i in 0..<5 {
      let se = Gen12Codec.be16(bytes, o + 17 + i * 2)
      out.append(Gen12Stats.calc(base: baseStats[i], dv: dvs[i], statExp: se, level: level, isHP: i == 0))
    }
    for i in 0..<5 { Gen12Codec.putBE16(&bytes, o + 34 + i * 2, out[i]) }
    let cur = Gen12Codec.be16(bytes, o + 1)
    Gen12Codec.putBE16(&bytes, o + 1, healFully ? out[0] : min(cur, out[0]))
  }
}
