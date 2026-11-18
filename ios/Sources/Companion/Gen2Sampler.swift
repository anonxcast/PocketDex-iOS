import Foundation

/// Live Gen 2 companion reads over the GBC bus. Port of PokeDaisy `readGen2Telemetry`.
final class Gen2Sampler: CompanionSampling, @unchecked Sendable {
  let config: Gen2Config

  init(config: Gen2Config) {
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

  private static func nickname(_ raw: [UInt8], off: Int, polished: Bool) -> String? {
    guard off + Gen2ConfigStore.nameLen <= raw.count else { return nil }
    var s = ""
    for i in 0..<Gen2ConfigStore.nameLen {
      let c = Int(raw[off + i])
      if c == 0 || c == 0x50 { break }
      if polished, c == 0x52 || c == 0x53 { break }
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

  private func decodePartyMon(_ raw: [UInt8], off: Int, egg: Bool) -> Mon? {
    if config.polished {
      return decodePolishedPartyMon(raw, off: off)
    }
    let species = Int(raw[off])
    guard (1...config.speciesCount).contains(species) else { return nil }
    let level = Int(raw[off + 31])
    guard (1...100).contains(level) else { return nil }
    let exp = (UInt32(raw[off + 8]) << 16) | (UInt32(raw[off + 9]) << 8) | UInt32(raw[off + 10])
    return Mon(
      species: egg ? Gen2ConfigStore.eggSpecies : species,
      level: level,
      hp: Self.be16(raw, off + 34),
      maxHp: Self.be16(raw, off + 36),
      status: UInt32(raw[off + 32]),
      moves: (0..<4).map { Int(raw[off + 2 + $0]) },
      pp: (0..<4).map { Int(raw[off + 23 + $0]) & 0x3F },
      exp: exp,
      personality: 0,
      otId: 0,
      stats: nil,
      heldItem: Int(raw[off + 1]),
      nickname: nil,
      shiny: false,
      isEgg: egg
    )
  }

  private func decodePolishedPartyMon(_ raw: [UInt8], off: Int) -> Mon? {
    guard off + Gen2ConfigStore.partyMonSize <= raw.count else { return nil }
    let species = Int(raw[off])
    guard species != 0, species != 0xFF else { return nil }
    let form = Int(raw[off + 21])
    let id = Gen2Polished.speciesId(species: species, form: form)
    let level = Int(raw[off + 31])
    guard (1...100).contains(level) else { return nil }
    let egg = (form & 0x40) != 0
    let exp = (UInt32(raw[off + 8]) << 16) | (UInt32(raw[off + 9]) << 8) | UInt32(raw[off + 10])
    return Mon(
      species: egg ? Gen2Polished.eggSpecies : id,
      level: level,
      hp: Self.be16(raw, off + 34),
      maxHp: Self.be16(raw, off + 36),
      status: UInt32(raw[off + 32]),
      moves: (0..<4).map { Int(raw[off + 2 + $0]) },
      pp: (0..<4).map { Int(raw[off + 22 + $0]) & 0x3F },
      exp: exp,
      personality: 0,
      otId: 0,
      stats: nil,
      heldItem: Int(raw[off + 1]),
      nickname: nil,
      shiny: false,
      isEgg: egg
    )
  }

  private func decodeBattleMon(_ raw: [UInt8]) -> BattleMon? {
    if config.polished {
      return decodePolishedBattleMon(raw)
    }
    guard raw.count >= Gen2ConfigStore.battleMonSize else { return nil }
    let species = Int(raw[0])
    guard (1...config.speciesCount).contains(species) else { return nil }
    return BattleMon(
      species: species,
      level: Int(raw[13]),
      hp: Self.be16(raw, 16),
      maxHp: Self.be16(raw, 18),
      moves: (0..<4).map { Int(raw[2 + $0]) },
      pp: (0..<4).map { Int(raw[8 + $0]) & 0x3F },
      item: Int(raw[1]),
      status1: UInt32(raw[14]),
      shiny: false
    )
  }

  private func decodePolishedBattleMon(_ raw: [UInt8]) -> BattleMon? {
    guard raw.count >= Gen2Polished.battleMonSize else { return nil }
    let species = Int(raw[0])
    guard species != 0, species != 0xFF else { return nil }
    let level = Int(raw[16])
    guard (1...100).contains(level) else { return nil }
    return BattleMon(
      species: Gen2Polished.speciesId(species: species, form: Int(raw[10])),
      level: level,
      hp: Self.be16(raw, 19),
      maxHp: Self.be16(raw, 21),
      moves: (0..<4).map { Int(raw[2 + $0]) },
      pp: (0..<4).map { Int(raw[11 + $0]) & 0x3F },
      item: Int(raw[1]),
      status1: UInt32(raw[17]),
      shiny: false
    )
  }

  private func readPairPocket(addr: UInt32, max: Int, pocket: Int) -> [BagItem]? {
    guard let raw = read(addr, 2 + 2 * max) else { return nil }
    let n = Int(raw[0])
    guard n <= max, Int(raw[1 + 2 * n]) == 0xFF else { return nil }
    return (0..<n).compactMap { i in
      let id = Int(raw[1 + 2 * i])
      let qty = Int(raw[2 + 2 * i])
      guard id > 0, id < 0xFF, qty > 0 else { return nil }
      return BagItem(itemId: id, quantity: qty, pocket: pocket, index: i)
    }
  }

  private func readBag() -> [BagItem] {
    let c = config
    // Polished's bag layout (medicine / berries / TM bits) differs; skip rather than mis-read.
    if c.polished { return [] }
    guard
      let items = readPairPocket(addr: c.numItems, max: c.itemsMax, pocket: Gen3Pocket.items),
      let balls = readPairPocket(addr: c.numBalls, max: c.ballsMax, pocket: Gen3Pocket.pokeBalls),
      let keyRaw = read(c.numKeyItems, 2 + c.keyItemsMax)
    else { return [] }
    let nKeys = Int(keyRaw[0])
    guard nKeys <= c.keyItemsMax, Int(keyRaw[1 + nKeys]) == 0xFF else { return [] }
    let keys = (0..<nKeys).compactMap { i -> BagItem? in
      let id = Int(keyRaw[1 + i])
      guard id > 0 else { return nil }
      return BagItem(itemId: id, quantity: 1, pocket: Gen3Pocket.keyItems, index: i)
    }
    let tms: [BagItem]
    if c.tmBits {
      let byteCount = (c.tmItems.count + 7) / 8
      guard let bits = read(c.tmsHms, byteCount) else { return [] }
      tms = c.tmItems.indices.compactMap { i -> BagItem? in
        guard (Int(bits[i / 8]) >> (i % 8)) & 1 != 0 else { return nil }
        return BagItem(itemId: c.tmItems[i], quantity: 1, pocket: Gen3Pocket.tmHm, index: i)
      }
    } else {
      guard let tmRaw = read(c.tmsHms, Gen2ConfigStore.tmsHmsCount) else { return [] }
      if (0..<Gen2ConfigStore.tmsHmsCount).contains(where: { Int(tmRaw[$0]) > 99 }) { return [] }
      tms = (0..<min(Gen2ConfigStore.tmsHmsCount, c.tmItems.count)).compactMap { i -> BagItem? in
        let qty = Int(tmRaw[i])
        guard qty > 0 else { return nil }
        return BagItem(itemId: c.tmItems[i], quantity: qty, pocket: Gen3Pocket.tmHm, index: i)
      }
    }
    return items + balls + keys + tms
  }

  private func readDex() -> DexSummary? {
    let bytes = (config.speciesCount + 7) / 8
    guard let seenB = read(config.dexSeen, bytes), let caughtB = read(config.dexCaught, bytes) else { return nil }
    var seen = Set<Int>()
    var caught = Set<Int>()
    for n in 1...config.speciesCount {
      let bit = (n - 1) % 8
      let byte = (n - 1) / 8
      if (Int(seenB[byte]) >> bit) & 1 != 0 { seen.insert(n) }
      if (Int(caughtB[byte]) >> bit) & 1 != 0 { caught.insert(n) }
    }
    seen.formUnion(caught)
    return DexSummary(
      seen: seen.count,
      caught: caught.count,
      seenSet: seen,
      caughtSet: caught,
      total: config.speciesCount,
      nationalUnlocked: true
    )
  }

  func sample() -> CompanionSnapshot? {
    let c = config
    guard let countRaw = read(c.partyCount, 1 + 6) else { return nil }
    let countByte = Int(countRaw[0])
    let count: Int
    if countByte <= 6, c.polished || countByte == 6 || Int(countRaw[1 + countByte]) == 0xFF {
      count = countByte
    } else {
      count = 0
    }

    var snap = CompanionSnapshot(gameName: c.displayName, tables: c.tables, configId: c.id)

    if count > 0, let raw = read(c.partyMons, 6 * Gen2ConfigStore.partyMonSize) {
      let nicks = read(c.partyMons + UInt32(Gen2ConfigStore.nicknamesAfterMons), 6 * Gen2ConfigStore.nameLen)
      for i in 0..<count {
        let egg = !c.polished && Int(countRaw[1 + i]) == Gen2ConfigStore.eggSpecies
        if var mon = decodePartyMon(raw, off: i * Gen2ConfigStore.partyMonSize, egg: egg) {
          mon.slot = i
          if let nicks { mon.nickname = Self.nickname(nicks, off: i * Gen2ConfigStore.nameLen, polished: c.polished) }
          snap.party.append(mon)
        }
      }
    }

    let battle = Int(readU8(c.battleMode) ?? 0)
    snap.inBattle = battle == 1 || battle == 2
    snap.isTrainer = battle == 2
    if snap.inBattle {
      var slots: [BattleMon?] = [nil, nil, nil, nil]
      if let raw = read(c.battleMon, c.battleMonSize) { slots[0] = decodeBattleMon(raw) }
      if let raw = read(c.enemyMon, c.battleMonSize) { slots[1] = decodeBattleMon(raw) }
      snap.battleMons = slots
      if battle == 2, let ot = read(c.otPartyCount, 1 + 6) {
        let n = min(Int(ot[0]), 6)
        if n > 0, let raw = read(c.otPartyMons, 6 * Gen2ConfigStore.partyMonSize) {
          for i in 0..<n {
            if var mon = decodePartyMon(raw, off: i * Gen2ConfigStore.partyMonSize, egg: false) {
              mon.slot = i
              snap.foeParty.append(mon)
            }
          }
        }
      }
    }

    if let map = read(c.mapGroup, 4) {
      snap.mapGroup = Int(map[0])
      snap.mapNum = Int(map[1])
      snap.y = Int(map[2])
      snap.x = Int(map[3])
      let backup = read(c.backupMapGroup, 2)
      let bg = Int(backup?[0] ?? 0)
      let bn = Int(backup?[1] ?? 0)
      let landmark = Gen2Maps.landmarkId(
        gameId: c.id,
        group: snap.mapGroup,
        num: snap.mapNum,
        backupGroup: bg,
        backupNum: bn
      )
      // Guide talk tips key Gen2 by landmark id (same as Android areaSection).
      snap.mapSec = landmark
      snap.mapSecName = Gen2Maps.placeName(gameId: c.id, landmark: landmark)
        ?? Gen2Maps.resolve(
          gameId: c.id,
          group: snap.mapGroup,
          num: snap.mapNum,
          backupGroup: bg,
          backupNum: bn
        )
    }

    if let m = read(c.money, 3) {
      snap.money = (Int(m[0]) << 16) | (Int(m[1]) << 8) | Int(m[2])
    }

    snap.bag = readBag()
    snap.dex = readDex()
    return snap
  }
}
