import Foundation

// Gen 3 struct Pokemon / BattlePokemon decoding. Port of Gen3Mon.kt (vanilla layout only).

@inline(__always) func gen3U16(_ b: [UInt8], _ off: Int) -> Int {
  Int(b[off]) | (Int(b[off + 1]) << 8)
}

@inline(__always) func gen3U32(_ b: [UInt8], _ off: Int) -> UInt32 {
  UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
}

enum Gen3Decode {
  /// gen3SubstructOrder[personality % 24][physicalSlot] = logical substruct (0=Growth, 1=Attacks, 2=EVs, 3=Misc).
  static let substructOrder: [[Int]] = [
    [0, 1, 2, 3], [0, 1, 3, 2], [0, 2, 1, 3], [0, 2, 3, 1], [0, 3, 1, 2], [0, 3, 2, 1],
    [1, 0, 2, 3], [1, 0, 3, 2], [1, 2, 0, 3], [1, 2, 3, 0], [1, 3, 0, 2], [1, 3, 2, 0],
    [2, 0, 1, 3], [2, 0, 3, 1], [2, 1, 0, 3], [2, 1, 3, 0], [2, 3, 0, 1], [2, 3, 1, 0],
    [3, 0, 1, 2], [3, 0, 2, 1], [3, 1, 0, 2], [3, 1, 2, 0], [3, 2, 0, 1], [3, 2, 1, 0],
  ]

  struct Substructs {
    var species: Int
    var exp: UInt32
    var moves: [Int]
    var pp: [Int]
    var evs: [Int]
    var ivWord: UInt32
    var heldItem: Int
  }

  /// Gen 3's shiny value: OT ID halves XOR PID halves.
  static func shinyValue(personality: UInt32, otId: UInt32) -> Int {
    Int((otId >> 16) ^ (otId & 0xFFFF) ^ (personality >> 16) ^ (personality & 0xFFFF))
  }

  /// Decrypts the 48-byte substruct block (key = PID ^ OTID, ordered by PID % 24), gated on the stored
  /// checksum (u16 at +28). Returns nil when the checksum fails (plaintext hack / empty / bad egg).
  static func decryptSubstructs(_ raw: [UInt8], off: Int) -> Substructs? {
    guard raw.count >= off + 0x20 + 48 else { return nil }
    let personality = gen3U32(raw, off)
    let otId = gen3U32(raw, off + 4)
    let storedChecksum = gen3U16(raw, off + 28)
    let key = personality ^ otId

    var block = [UInt8](repeating: 0, count: 48)
    var sum = 0
    for i in 0..<12 {
      let w = gen3U32(raw, off + 0x20 + i * 4) ^ key
      block[i * 4] = UInt8(w & 0xFF)
      block[i * 4 + 1] = UInt8((w >> 8) & 0xFF)
      block[i * 4 + 2] = UInt8((w >> 16) & 0xFF)
      block[i * 4 + 3] = UInt8((w >> 24) & 0xFF)
      sum = (sum + Int(w & 0xFFFF) + Int(w >> 16)) & 0xFFFF
    }
    if sum != storedChecksum || storedChecksum == 0 { return nil }

    let order = substructOrder[Int(personality % 24)]
    var growthOff = 0, attacksOff = 0, evsOff = 0, miscOff = 0
    for slot in 0..<4 {
      switch order[slot] {
      case 0: growthOff = slot * 12
      case 1: attacksOff = slot * 12
      case 2: evsOff = slot * 12
      default: miscOff = slot * 12
      }
    }
    return Substructs(
      species: gen3U16(block, growthOff),
      exp: gen3U32(block, growthOff + 4),
      moves: (0..<4).map { gen3U16(block, attacksOff + $0 * 2) },
      pp: (0..<4).map { Int(block[attacksOff + 8 + $0]) },
      evs: (0..<6).map { Int(block[evsOff + $0]) },
      ivWord: gen3U32(block, miscOff + 4),
      heldItem: gen3U16(block, growthOff + 2)
    )
  }

  /// Plaintext box (Unbound-style fallback): substructs in G-A-E-M order from +0x20, no checksum.
  static func plainSubstructs(_ raw: [UInt8], off: Int) -> Substructs? {
    let box = off + 0x20
    guard raw.count >= box + 0x2C else { return nil }
    let species = gen3U16(raw, box)
    if species == 0 || species > 4000 { return nil }
    return Substructs(
      species: species,
      exp: gen3U32(raw, box + 4),
      moves: (0..<4).map { gen3U16(raw, box + 0x0C + $0 * 2) },
      pp: (0..<4).map { Int(raw[box + 0x0C + 8 + $0]) },
      evs: (0..<6).map { Int(raw[box + 0x18 + $0]) },
      ivWord: gen3U32(raw, box + 0x28),
      heldItem: gen3U16(raw, box + 2)
    )
  }

  /// Nickname at +8 (10 bytes). Nil when empty / not Western text (Japanese language byte, unknown glyph).
  static func nickname(_ raw: [UInt8], off: Int) -> String? {
    // Language byte at +0x12: 1 = Japanese, whose kana share bytes with Western letters.
    if raw[off + 0x12] == 1 { return nil }
    let s = Gen3Text.decode(raw, off: off + 0x08, max: 10).trimmingCharacters(in: .whitespaces)
    if s.isEmpty || s.contains(Gen3Text.unknown) { return nil }
    return s
  }

  /// Party-struct stats: IVs (5 bits each, HP first), EVs, nature, and the computed stats at +0x58.
  static func monStats(_ raw: [UInt8], off: Int, evs: [Int], ivWord: UInt32) -> MonStats {
    let pid = gen3U32(raw, off)
    let pidNature = Int(pid % 25)
    // pokeemerald-expansion's Mints XOR a nature in above the 3 language bits (0 in vanilla / CFRU).
    let mint = Int(raw[off + 0x12]) >> 3
    let nature = (pidNature ^ mint) < 25 ? (pidNature ^ mint) : pidNature
    return MonStats(
      ivs: (0..<6).map { Int((ivWord >> UInt32(5 * $0)) & 0x1F) },
      evs: evs,
      nature: nature,
      stats: (0..<6).map { gen3U16(raw, off + 0x58 + 2 * $0) }
    )
  }

  /// Decodes one struct Pokemon at `off`. Encrypted retail GAEM first, plaintext fallback after.
  /// Returns nil for an empty slot.
  static func decodePartyMon(
    _ raw: [UInt8],
    off: Int,
    shinyBelow: Int = Gen3Const.shinyBelow,
    kind: PartyMonKind = .vanilla,
    speciesMask: Int = 0xFFFF,
    moveMask: Int = 0xFFFF,
    ppMask: Int = 0xFF,
    monStride: Int = Gen3Const.monStructSize
  ) -> Mon? {
    switch kind {
    case .rowe:
      return decodeRowePartyMon(raw, off: off, shinyBelow: shinyBelow)
    case .soulGold(let packed):
      return decodeSoulGoldPartyMon(
        raw, off: off, shinyBelow: shinyBelow, packedAttacks: packed,
        speciesMask: speciesMask, moveMask: moveMask, ppMask: ppMask
      )
    case .vanilla:
      break
    }
    guard raw.count >= off + monStride else { return nil }

    let dec: Substructs
    if let d = decryptSubstructs(raw, off: off) {
      dec = d
    } else if let p = plainSubstructs(raw, off: off) {
      dec = p
    } else {
      return nil
    }
    let species = dec.species & speciesMask
    if species == 0 { return nil }

    let personality = gen3U32(raw, off)
    let otId = gen3U32(raw, off + 4)
    let isEgg = (dec.ivWord >> 30) & 1 == 1
    return Mon(
      species: species,
      level: Int(raw[off + 0x54]),
      hp: gen3U16(raw, off + 0x56),
      maxHp: gen3U16(raw, off + 0x58),
      status: gen3U32(raw, off + 0x50),
      moves: dec.moves.map { $0 & moveMask },
      pp: dec.pp.map { $0 & ppMask },
      exp: dec.exp,
      personality: personality,
      otId: otId,
      stats: monStats(raw, off: off, evs: dec.evs, ivWord: dec.ivWord),
      heldItem: dec.heldItem,
      nickname: nickname(raw, off: off),
      shiny: shinyBelow > 0 && shinyValue(personality: personality, otId: otId) < shinyBelow,
      isEgg: isEgg
    )
  }

  /// SoulGold GBA: 96-byte plaintext party (box from +0x20; stats at expansion offsets).
  private static func decodeSoulGoldPartyMon(
    _ raw: [UInt8],
    off: Int,
    shinyBelow: Int,
    packedAttacks: Bool,
    speciesMask: Int,
    moveMask: Int,
    ppMask: Int
  ) -> Mon? {
    let size = 96
    guard raw.count >= off + size else { return nil }
    let box = off + 0x20
    let species = gen3U16(raw, box) & speciesMask
    if species == 0 || species > 4000 { return nil }
    let heldItem = gen3U16(raw, box + 2) & 0x03FF
    let moves: [Int]
    let pp: [Int]
    if packedAttacks {
      let w = (0..<4).map { gen3U16(raw, box + 0x0C + $0 * 2) }
      moves = [
        w[0] & 0x7FF, w[1] & 0x7FF, w[2] & 0x7FF,
        ((w[2] >> 11) | (w[3] << 5)) & 0x7FF
      ].map { $0 & moveMask }
      let ppWord = gen3U32(raw, box + 0x0C + 8)
      pp = (0..<4).map { Int((ppWord >> (7 * $0)) & 0x7F) & ppMask }
    } else {
      moves = (0..<4).map { gen3U16(raw, box + 0x0C + $0 * 2) & moveMask }
      pp = (0..<4).map { Int(raw[box + 0x0C + 8 + $0]) & ppMask }
    }
    let personality = gen3U32(raw, off)
    let otId = gen3U32(raw, off + 4)
    let ivWord = gen3U32(raw, box + 0x28)
    let isEgg = (Int(raw[off + 0x15]) & 0x80) != 0 || ((ivWord >> 30) & 1) == 1
    return Mon(
      species: species,
      level: Int(raw[off + 0x50]),
      hp: gen3U16(raw, off + 0x52),
      maxHp: gen3U16(raw, off + 0x54),
      status: gen3U32(raw, off + 0x4C),
      moves: moves,
      pp: pp,
      exp: gen3U32(raw, box + 4),
      personality: personality,
      otId: otId,
      stats: monStats(
        raw, off: off,
        evs: (0..<6).map { Int(raw[box + 0x18 + $0]) },
        ivWord: ivWord
      ),
      heldItem: heldItem,
      nickname: nickname(raw, off: off),
      shiny: shinyBelow > 0 && shinyValue(personality: personality, otId: otId) < shinyBelow,
      isEgg: isEgg
    )
  }

  /// R.O.W.E. 0x4C-byte bit-packed party mon.
  private static func decodeRowePartyMon(
    _ raw: [UInt8], off: Int, shinyBelow: Int
  ) -> Mon? {
    let size = 0x4C
    guard raw.count >= off + size else { return nil }
    let w14 = gen3U32(raw, off + 0x14)
    let w18 = gen3U32(raw, off + 0x18)
    let species = Int(gen3U32(raw, off + 0x1C) & 0xFFF)
    if species == 0 { return nil }
    let personality = gen3U32(raw, off)
    let move4 = (gen3U16(raw, off + 0x1E) >> 1) & 0x3FF
    return Mon(
      species: species,
      level: Int(raw[off + 0x3C]),
      hp: gen3U16(raw, off + 0x3E),
      maxHp: gen3U16(raw, off + 0x40),
      status: gen3U32(raw, off + 0x38),
      moves: [
        Int(w14 & 0x3FF), Int(w18 & 0x3FF), Int((w18 >> 10) & 0x3FF), move4
      ],
      pp: (0..<4).map { Int(raw[off + 0x34 + $0]) },
      exp: w14 >> 10 & 0x1F_FFFF,
      personality: personality,
      otId: gen3U32(raw, off + 4),
      stats: MonStats(
        ivs: Array(repeating: 0, count: 6),
        evs: (0..<6).map { Int(raw[off + 0x20 + $0]) },
        nature: (Int(raw[off + 0x27]) >> 2) & 0x1F,
        stats: (0..<6).map { gen3U16(raw, off + 0x40 + 2 * $0) }
      ),
      heldItem: 0,
      nickname: nickname(raw, off: off),
      shiny: shinyBelow > 0 && (Int(raw[off + 0x29]) & 0x80) != 0,
      isEgg: (Int(raw[off + 0x27]) & 0x80) != 0
    )
  }

  /// Decodes one `struct BattlePokemon` using the game’s layout (vanilla 0x58 or expansion 0x60).
  static func decodeBattleMon(
    _ raw: [UInt8],
    off: Int,
    layout: BattleMonLayout = .vanilla,
    shinyBelow: Int = Gen3Const.shinyBelow,
    speciesMask: Int = 0xFFFF,
    moveMask: Int = 0xFFFF,
    ppMask: Int = 0xFF
  ) -> BattleMon? {
    guard raw.count >= off + layout.size else { return nil }
    let species = gen3U16(raw, off + layout.species) & speciesMask
    if species == 0 { return nil }
    let pid = layout.personality >= 0 ? gen3U32(raw, off + layout.personality) : 0
    let ot = layout.otId >= 0 ? gen3U32(raw, off + layout.otId) : 0
    return BattleMon(
      species: species,
      level: Int(raw[off + layout.level]),
      hp: gen3U16(raw, off + layout.hp),
      maxHp: gen3U16(raw, off + layout.maxHp),
      moves: (0..<4).map { gen3U16(raw, off + layout.moves + $0 * 2) & moveMask },
      pp: (0..<4).map { Int(raw[off + layout.pp + $0]) & ppMask },
      item: gen3U16(raw, off + layout.item),
      status1: gen3U32(raw, off + layout.status1),
      shiny: shinyBelow > 0
        && layout.personality >= 0
        && layout.otId >= 0
        && shinyValue(personality: pid, otId: ot) < shinyBelow
    )
  }
}
