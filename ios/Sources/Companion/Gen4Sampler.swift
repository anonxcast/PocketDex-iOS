import Foundation

/// Live Gen 4 companion over melonDS main RAM (PokeDaisy `readGen4Telemetry` / battle / dex).
final class Gen4Sampler: CompanionSampling, @unchecked Sendable {
  let config: Gen4Config
  /// Last good party slot (mid-frame decrypt flicker).
  private var lastGoodParty: [Mon?] = Array(repeating: nil, count: 6)

  init(config: Gen4Config) {
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

  private static func u8(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) }
  private static func u16(_ b: [UInt8], _ o: Int) -> Int {
    Int(b[o]) | (Int(b[o + 1]) << 8)
  }
  private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
  }

  private static let mainRam: UInt32 = 0x02000000
  private static let mainRamEnd: UInt32 = 0x02400000
  private static let monSize = 0xEC
  private static let boxSize = 0x88
  private static let battleTrainer: UInt32 = 1
  private static let battleDoubles: UInt32 = 2
  private static let dexMagic: UInt32 = 0xBEEF_CAFE

  private static let blockOrders: [String] = [
    "ABCD", "ABDC", "ACBD", "ACDB", "ADBC", "ADCB", "BACD", "BADC", "BCAD", "BCDA", "BDAC", "BDCA",
    "CABD", "CADB", "CBAD", "CBDA", "CDAB", "CDBA", "DABC", "DACB", "DBAC", "DBCA", "DCAB", "DCBA"
  ]

  private static func inMain(_ p: UInt32) -> Bool {
    p >= mainRam && p < mainRamEnd
  }

  func sample() -> CompanionSnapshot? {
    var snap = CompanionSnapshot(gameName: config.displayName, tables: .national, configId: config.id)
    if let body = saveBody() {
      snap.party = readParty(body: body)
      snap.money = readMoney(body: body)
      snap.bag = readBag(body: body)
      if let loc = readLocation(body: body) {
        snap.mapNum = loc.mapId
        snap.mapSec = loc.mapId
        snap.x = loc.x
        snap.y = loc.z
        snap.mapSecName = Gen4Maps.placeName(gameId: config.id, header: loc.mapId)
          ?? "Map \(loc.mapId)"
      }
      snap.dex = readDex(body: body)
    }
    if let battle = readBattle() {
      snap.inBattle = true
      snap.isTrainer = battle.trainer
      snap.isDouble = battle.doubles
      snap.battleMons = battle.mons
    }
    return snap
  }

  // MARK: - Save body

  private func saveBody() -> UInt32? {
    guard let ptrRaw = read(config.saveDataPtr, 4) else { return nil }
    let ptr = Self.u32(ptrRaw, 0)
    guard Self.inMain(ptr), ptr < Self.mainRamEnd &- 0x20000 else { return nil }
    return ptr &+ UInt32(config.bodyOff)
  }

  // MARK: - Party

  private func readParty(body: UInt32) -> [Mon] {
    let base = body &+ UInt32(config.partyOff)
    guard let head = read(base, 8) else { return [] }
    let count = min(Int(Self.u32(head, 4)), 6)
    guard count > 0 else { return [] }
    let bytes = count * Self.monSize
    guard let raw1 = read(base &+ 8, bytes),
          let raw2 = read(base &+ 8, bytes) else { return [] }
    var out: [Mon] = []
    for i in 0..<count {
      let off = i * Self.monSize
      let steady = (0..<Self.monSize).allSatisfy { raw1[off + $0] == raw2[off + $0] }
      if steady, var mon = Self.decodePartyMon(raw1, off: off, maxSpecies: config.maxSpecies) {
        mon.slot = i
        lastGoodParty[i] = mon
        out.append(mon)
      } else if var kept = lastGoodParty[i] {
        kept.slot = i
        out.append(kept)
      }
    }
    return out
  }

  private static func gen4Crypt(_ raw: [UInt8], off: Int, len: Int, seed: UInt32) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: len)
    var s = seed
    var i = 0
    while i + 1 < len {
      s = s &* 0x41C6_4E6D &+ 0x6073
      let key = Int(s >> 16) & 0xFFFF
      let w = (u16(raw, off + i) ^ key) & 0xFFFF
      out[i] = UInt8(w & 0xFF)
      out[i + 1] = UInt8((w >> 8) & 0xFF)
      i += 2
    }
    return out
  }

  private static func sums(_ blocks: [UInt8], checksum: Int) -> Bool {
    guard blocks.count >= 0x80 else { return false }
    var sum = 0
    for i in stride(from: 0, to: 0x80, by: 2) {
      sum += u16(blocks, i)
    }
    return (sum & 0xFFFF) == checksum
  }

  private static func saneParty(_ p: [UInt8]) -> Bool {
    guard p.count >= 10 else { return false }
    let level = u8(p, 4)
    let hp = u16(p, 6)
    let maxHp = u16(p, 8)
    return (1...100).contains(level) && (1...999).contains(maxHp) && hp <= maxHp
  }

  /// Gen 4 party is 0xEC; Gen 5 reuses the same box crypto with a 0xDC record.
  static func decodePartyMon(_ raw: [UInt8], off: Int, maxSpecies: Int, monSize: Int = 0xEC) -> Mon? {
    guard off + monSize <= raw.count, monSize >= boxSize + 10 else { return nil }
    let personality = u32(raw, off)
    let decrypted = u16(raw, off + 4)
    let checksum = u16(raw, off + 6)
    let plain = Array(raw[(off + 8)..<(off + 8 + 0x80)])
    let blocks: [UInt8]? = {
      if decrypted & 2 != 0 {
        return sums(plain, checksum: checksum) ? plain : nil
      }
      let crypt = gen4Crypt(raw, off: off + 8, len: 0x80, seed: UInt32(checksum))
      if sums(crypt, checksum: checksum) { return crypt }
      return sums(plain, checksum: checksum) ? plain : nil
    }()
    guard let blocks else { return nil }
    let orderIdx = Int(((personality >> 13) & 0x1F) % 24)
    let order = blockOrders[orderIdx]
    func block(_ c: Character) -> Int {
      guard let idx = order.firstIndex(of: c) else { return 0 }
      return order.distance(from: order.startIndex, to: idx) * 32
    }
    let a = block("A")
    let b = block("B")
    let species = u16(blocks, a)
    guard (1...maxSpecies).contains(species) else { return nil }
    let ivWord = u32(blocks, b + 0x10)
    let isEgg = ((ivWord >> 30) & 1) != 0
    let plainParty = Array(raw[(off + boxSize)..<(off + monSize)])
    let party: [UInt8]? = {
      if decrypted & 1 != 0 {
        return saneParty(plainParty) ? plainParty : nil
      }
      let crypt = gen4Crypt(raw, off: off + boxSize, len: monSize - boxSize, seed: personality)
      if saneParty(crypt) { return crypt }
      return saneParty(plainParty) ? plainParty : nil
    }()
    guard let party else { return nil }
    return Mon(
      species: species,
      level: u8(party, 4),
      hp: u16(party, 6),
      maxHp: u16(party, 8),
      status: u32(party, 0),
      moves: (0..<4).map { u16(blocks, b + $0 * 2) },
      pp: (0..<4).map { u8(blocks, b + 8 + $0) },
      exp: u32(blocks, a + 8),
      personality: personality,
      otId: 0,
      stats: nil,
      heldItem: u16(blocks, a + 2),
      nickname: nil,
      shiny: false,
      isEgg: isEgg
    )
  }

  // MARK: - Money / location / bag / dex

  private func readMoney(body: UInt32) -> Int? {
    guard let t = read(body &+ UInt32(config.trainerOff), 0x1C) else { return nil }
    let money = Int(Self.u32(t, 0x14))
    return (0...999_999).contains(money) ? money : nil
  }

  private struct Loc { var mapId: Int; var x: Int; var z: Int }

  private func readLocation(body: UInt32) -> Loc? {
    guard let loc = read(body &+ UInt32(config.locationOff), 0x14) else { return nil }
    return Loc(
      mapId: Int(Self.u32(loc, 0)),
      x: Int(Self.u32(loc, 8)),
      z: Int(Self.u32(loc, 12))
    )
  }

  private func readBag(body: UInt32) -> [BagItem] {
    var items: [BagItem] = []
    var offset = 0
    for (pi, size) in config.pocketSizes.enumerated() {
      let pocket = pi < config.savePockets.count ? config.savePockets[pi] : Gen3Pocket.items
      guard let raw = read(body &+ UInt32(config.bagOff + offset), size * 4) else { break }
      for i in 0..<size {
        let id = Self.u16(raw, i * 4)
        let qty = Self.u16(raw, i * 4 + 2)
        if id > 0, qty > 0 {
          items.append(BagItem(itemId: id, quantity: qty, pocket: pocket, index: items.count))
        }
      }
      offset += size * 4
    }
    return items
  }

  private func readDex(body: UInt32) -> DexSummary? {
    let flagBytes = config.dexFlagBytes
    let need = max(4 + 4 * flagBytes + 0x50, 0x340)
    guard let d = read(body &+ UInt32(config.pokedexOff), need) else { return nil }
    guard Self.u32(d, 0) == Self.dexMagic else { return nil }
    let total = config.maxSpecies
    var seen = Set<Int>()
    var caught = Set<Int>()
    func bit(_ base: Int, _ n: Int) -> Bool {
      let idx = base + (n - 1) / 8
      guard idx < d.count else { return false }
      return ((Int(d[idx]) >> ((n - 1) % 8)) & 1) != 0
    }
    let caughtBase = 4
    let seenBase = 4 + flagBytes
    for n in 1...total {
      if bit(seenBase, n) { seen.insert(n) }
      if bit(caughtBase, n), seen.contains(n) { caught.insert(n) }
    }
    let national: Bool = {
      guard config.nationalDexOff < d.count else { return false }
      return d[config.nationalDexOff] != 0
    }()
    return DexSummary(
      seen: seen.count,
      caught: caught.count,
      seenSet: seen,
      caughtSet: caught,
      total: total,
      nationalUnlocked: national
    )
  }

  // MARK: - Battle

  private struct BattleRead {
    var mons: [BattleMon?]
    var trainer: Bool
    var doubles: Bool
  }

  private func battleSystem() -> UInt32? {
    let b = config.battle
    guard let fsRaw = read(b.fieldSystemPtr, 4) else { return nil }
    let fs = Self.u32(fsRaw, 0)
    guard Self.inMain(fs), let pmRaw = read(fs, 4) else { return nil }
    let pm = Self.u32(pmRaw, 0)
    guard Self.inMain(pm), let childRaw = read(pm + UInt32(b.offChild), 4) else { return nil }
    let child = Self.u32(childRaw, 0)
    guard Self.inMain(child) else { return nil }
    guard let childHead = read(child, 4), let tmplHead = read(b.battleTemplate, 4) else { return nil }
    guard Self.u32(childHead, 0) == Self.u32(tmplHead, 0) else { return nil }
    guard let appRaw = read(child + UInt32(b.offAppData), 4) else { return nil }
    let bs = Self.u32(appRaw, 0)
    return Self.inMain(bs) ? bs : nil
  }

  private func readBattle() -> BattleRead? {
    let b = config.battle
    guard let bs = battleSystem() else { return nil }
    let headLen = b.offBattleCtx - b.offBattleType + 4
    guard headLen > 0, let head = read(bs + UInt32(b.offBattleType), headLen) else { return nil }
    let type = Self.u32(head, 0)
    let ctx = Self.u32(head, b.offBattleCtx - b.offBattleType)
    guard Self.inMain(ctx) else { return nil }
    let stride = b.battleMonSize
    guard let raw = read(ctx + UInt32(b.offBattleMons), 4 * stride) else { return nil }
    var slots: [BattleMon?] = [nil, nil, nil, nil]
    for i in 0..<4 {
      slots[i] = decodeBattleMon(raw, off: i * stride)
    }
    return BattleRead(
      mons: slots,
      trainer: (type & Self.battleTrainer) != 0,
      doubles: (type & Self.battleDoubles) != 0
    )
  }

  private func decodeBattleMon(_ raw: [UInt8], off: Int) -> BattleMon? {
    guard off + config.battle.battleMonSize <= raw.count else { return nil }
    let species = Self.u16(raw, off)
    guard (1...config.maxSpecies).contains(species) else { return nil }
    return BattleMon(
      species: species,
      level: Self.u8(raw, off + 0x34),
      hp: Int(Self.u32(raw, off + 0x4C)),
      maxHp: Int(Self.u32(raw, off + 0x50)),
      moves: (0..<4).map { Self.u16(raw, off + 0x0C + $0 * 2) },
      pp: (0..<4).map { Self.u8(raw, off + 0x2C + $0) },
      item: Self.u16(raw, off + 0x78),
      status1: Self.u32(raw, off + 0x6C),
      shiny: false
    )
  }
}
