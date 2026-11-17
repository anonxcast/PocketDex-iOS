import Foundation

/// Live Gen 1 companion reads over the GB bus (WRAM C000–DFFF). Port of PokeDaisy `readGen1Telemetry`.
final class Gen1Sampler: CompanionSampling, @unchecked Sendable {
  let config: Gen1Config

  init(config: Gen1Config) {
    self.config = config
  }

  private func read(_ addr: UInt32, _ len: Int) -> [UInt8]? {
    guard len > 0 else { return [] }
    var ok = false
    let bytes = [UInt8](unsafeUninitializedCapacity: len) { buf, count in
      ok = pk_ios_read_into(addr, buf.baseAddress, Int32(len))
      count = ok ? len : 0
    }
    return ok ? bytes : nil
  }

  private func readU8(_ addr: UInt32) -> UInt8? { read(addr, 1)?.first }

  private static func be16(_ b: [UInt8], _ o: Int) -> Int {
    (Int(b[o]) << 8) | Int(b[o + 1])
  }

  private static func bcd(_ b: [UInt8]) -> Int {
    b.reduce(0) { acc, x in
      acc * 100 + Int((x >> 4) & 0xF) * 10 + Int(x & 0xF)
    }
  }

  /// Minimal English Gen 1 charmap (A–Z / a–z / 0–9 / space).
  private static func nickname(_ raw: [UInt8], off: Int) -> String? {
    guard off + Gen1ConfigStore.nameLen <= raw.count else { return nil }
    var s = ""
    for i in 0..<Gen1ConfigStore.nameLen {
      let c = Int(raw[off + i])
      if c == 0 || c == 0x50 { break }
      switch c {
      case 0x80...0x99: s.append(Character(UnicodeScalar(c - 0x80 + 65)!))
      case 0xA0...0xB9: s.append(Character(UnicodeScalar(c - 0xA0 + 97)!))
      case 0xF6...0xFF: s.append(Character(UnicodeScalar(c - 0xF6 + 48)!))
      case 0x7F: s.append(" ")
      default: break
      }
    }
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
  }

  private func decodePartyMon(_ raw: [UInt8], off: Int) -> Mon? {
    let species = config.dex(Int(raw[off]))
    guard species > 0 else { return nil }
    let level = Int(raw[off + 33])
    guard (1...100).contains(level) else { return nil }
    let exp = (UInt32(raw[off + 14]) << 16) | (UInt32(raw[off + 15]) << 8) | UInt32(raw[off + 16])
    return Mon(
      species: species,
      level: level,
      hp: Self.be16(raw, off + 1),
      maxHp: Self.be16(raw, off + 34),
      status: UInt32(raw[off + 4]),
      moves: (0..<4).map { Int(raw[off + 8 + $0]) },
      pp: (0..<4).map { Int(raw[off + 29 + $0]) & 0x3F },
      exp: exp,
      personality: 0,
      otId: 0,
      stats: nil,
      heldItem: 0,
      nickname: nil,
      shiny: false,
      isEgg: false
    )
  }

  private func decodeBattleMon(_ raw: [UInt8]) -> BattleMon? {
    guard raw.count >= Gen1ConfigStore.battleMonSize else { return nil }
    let species = config.dex(Int(raw[0]))
    guard species > 0 else { return nil }
    return BattleMon(
      species: species,
      level: Int(raw[14]),
      hp: Self.be16(raw, 1),
      maxHp: Self.be16(raw, 15),
      moves: (0..<4).map { Int(raw[8 + $0]) },
      pp: (0..<4).map { Int(raw[25 + $0]) & 0x3F },
      item: 0,
      status1: UInt32(raw[4]),
      shiny: false
    )
  }

  func sample() -> CompanionSnapshot? {
    let c = config
    guard let countByte = readU8(c.partyCount) else { return nil }
    let count = min(Int(countByte), 6)

    // Yellow / Gen 1 type ids + chart (Ghost vs Psychic immune, Gust = Normal).
    var snap = CompanionSnapshot(gameName: c.displayName, tables: .yellow, configId: c.id)

    if count > 0, let raw = read(c.partyMons, count * Gen1ConfigStore.partyMonSize) {
      let nicks = read(c.partyMons + UInt32(Gen1ConfigStore.nicknamesAfterMons), 6 * Gen1ConfigStore.nameLen)
      for i in 0..<count {
        if var mon = decodePartyMon(raw, off: i * Gen1ConfigStore.partyMonSize) {
          mon.slot = i
          if let nicks {
            mon.nickname = Self.nickname(nicks, off: i * Gen1ConfigStore.nameLen)
          }
          snap.party.append(mon)
        }
      }
    }

    let battle = Int(readU8(c.isInBattle) ?? 0)
    snap.inBattle = battle == 1 || battle == 2
    snap.isTrainer = battle == 2
    if snap.inBattle {
      var slots: [BattleMon?] = [nil, nil, nil, nil]
      if let raw = read(c.battleMon, Gen1ConfigStore.battleMonSize) {
        slots[0] = decodeBattleMon(raw)
      }
      if let raw = read(c.enemyMon, Gen1ConfigStore.battleMonSize) {
        slots[1] = decodeBattleMon(raw)
      }
      snap.battleMons = slots
      if battle == 2, let n = readU8(c.enemyPartyCount) {
        let ec = min(Int(n), 6)
        if ec > 0, let raw = read(c.enemyMons, ec * Gen1ConfigStore.partyMonSize) {
          for i in 0..<ec {
            if var mon = decodePartyMon(raw, off: i * Gen1ConfigStore.partyMonSize) {
              mon.slot = i
              snap.foeParty.append(mon)
            }
          }
        }
      }
    }

    snap.mapNum = Int(readU8(c.curMap) ?? 0)
    snap.mapSec = snap.mapNum
    snap.mapSecName = "Map \(snap.mapNum)"
    snap.x = Int(readU8(c.xCoord) ?? 0)
    snap.y = Int(readU8(c.yCoord) ?? 0)

    if let m = read(c.money, 3) {
      snap.money = Self.bcd(m)
    }

    let bagN = min(Int(readU8(c.bagCount) ?? 0), c.bagSlots)
    if bagN > 0, let bagRaw = read(c.bagCount + 1, c.bagSlots * 2) {
      for i in 0..<bagN {
        let id = Int(bagRaw[2 * i])
        let qty = Int(bagRaw[2 * i + 1])
        if id == 0xFF { break }
        if id > 0, qty > 0 {
          snap.bag.append(BagItem(itemId: id, quantity: qty, pocket: Gen3Pocket.items, index: i))
        }
      }
    }

    snap.dex = readDex()
    return snap
  }

  /// wPokedexOwned / wPokedexSeen — bit n-1 = National Dex No. n (19 bytes for 151).
  private func readDex() -> DexSummary? {
    let bytes = (config.dexCount + 7) / 8
    guard let ownedB = read(config.dexOwned, bytes),
          let seenB = read(config.dexSeen, bytes) else { return nil }
    var seen = Set<Int>()
    var caught = Set<Int>()
    for n in 1...config.dexCount {
      let bit = (n - 1) % 8
      let byte = (n - 1) / 8
      if (Int(seenB[byte]) >> bit) & 1 != 0 { seen.insert(n) }
      if (Int(ownedB[byte]) >> bit) & 1 != 0 { caught.insert(n) }
    }
    seen.formUnion(caught)
    return DexSummary(
      seen: seen.count,
      caught: caught.count,
      seenSet: seen,
      caughtSet: caught,
      total: config.dexCount,
      nationalUnlocked: true
    )
  }
}
