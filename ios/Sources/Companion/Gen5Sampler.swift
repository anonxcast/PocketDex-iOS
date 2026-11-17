import Foundation

/// Live Gen 5 companion over melonDS main RAM (PokeDaisy `readGen5Telemetry` / battle).
final class Gen5Sampler: CompanionSampling, @unchecked Sendable {
  let config: Gen5Config
  private var lastGoodParty: [Mon?] = Array(repeating: nil, count: 6)
  /// When the companion drawer is closed, skip bag/dex RAM walks (Black 2 stutter).
  var lightSample = true

  init(config: Gen5Config) {
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
  private static let monSize = 0xDC
  private static let battleMonBytes = 0x140
  private static let dexMagic: UInt32 = 0xBEEF_CAFE

  private static func inMain(_ p: UInt32) -> Bool {
    p >= mainRam && p < mainRamEnd
  }

  func sample() -> CompanionSnapshot? {
    var snap = CompanionSnapshot(gameName: config.displayName, tables: .national, configId: config.id)
    guard let img = saveImage() else { return snap }
    snap.party = readParty(img: img)
    snap.money = readMoney(img: img)
    if !lightSample {
      snap.bag = readBag(img: img)
    }
    if let loc = readLocation(img: img) {
      snap.mapNum = loc.zone
      snap.mapSec = loc.zone
      snap.x = loc.x
      snap.y = loc.z
      snap.mapSecName = Gen5Maps.placeName(gameId: config.id, zone: loc.zone)
        ?? "Zone \(loc.zone)"
    }
    if !lightSample {
      snap.dex = readDex(img: img)
    }
    if let battle = readBattle() {
      snap.inBattle = true
      snap.isTrainer = battle.trainer
      snap.isDouble = battle.doubles
      snap.battleMons = battle.mons
    }
    return snap
  }

  // MARK: - Save image

  private func saveImage() -> UInt32? {
    guard let scRaw = read(config.saveControlPtr, 4) else { return nil }
    let sc = Self.u32(scRaw, 0)
    guard Self.inMain(sc), let bsRaw = read(sc &+ UInt32(config.offBackupSystem), 4) else { return nil }
    let bs = Self.u32(bsRaw, 0)
    guard Self.inMain(bs), let imgRaw = read(bs &+ UInt32(config.offImage), 4) else { return nil }
    let img = Self.u32(imgRaw, 0)
    guard Self.inMain(img), img < Self.mainRamEnd &- UInt32(config.imageSize) else { return nil }
    return img
  }

  // MARK: - Party

  private func readParty(img: UInt32) -> [Mon] {
    let base = img &+ UInt32(config.partyOff)
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
      if steady, var mon = Gen4Sampler.decodePartyMon(
        raw1, off: off, maxSpecies: config.maxSpecies, monSize: Self.monSize
      ) {
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

  // MARK: - Money / location / bag / dex

  private func readMoney(img: UInt32) -> Int? {
    guard let t = read(img &+ UInt32(config.moneyOff), 4) else { return nil }
    let money = Int(Self.u32(t, 0))
    return (0...999_999).contains(money) ? money : nil
  }

  private struct Loc { var zone: Int; var x: Int; var z: Int }

  private func readLocation(img: UInt32) -> Loc? {
    // Prefer live GameData zone / position when GameSystem is up.
    if config.gameSystemPtr != 0,
       let gsRaw = read(config.gameSystemPtr, 4) {
      let gs = Self.u32(gsRaw, 0)
      if Self.inMain(gs),
         let gdRaw = read(gs &+ UInt32(config.offGameData), 4) {
        let gd = Self.u32(gdRaw, 0)
        if Self.inMain(gd), let live = read(gd &+ UInt32(config.offZone), 0x10) {
          let zone = Self.u16(live, 0)
          // fx32 x at +4, z at +0xC (y unused for HUD).
          let x = Int(Self.u32(live, 4)) >> 12
          let z = Int(Self.u32(live, 12)) >> 12
          if zone > 0 { return Loc(zone: zone, x: x, z: z) }
        }
      }
    }
    guard let loc = read(img &+ UInt32(config.locationOff), 0x14) else { return nil }
    return Loc(
      zone: Self.u16(loc, 4),
      x: Int(Self.u32(loc, 8)) >> 12,
      z: Int(Self.u32(loc, 12)) >> 12
    )
  }

  private func readBag(img: UInt32) -> [BagItem] {
    var items: [BagItem] = []
    var offset = 0
    for (pi, size) in config.pocketSizes.enumerated() {
      let pocket = pi < config.savePockets.count ? config.savePockets[pi] : Gen3Pocket.items
      guard let raw = read(img &+ UInt32(config.bagOff + offset), size * 4) else { break }
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

  private func readDex(img: UInt32) -> DexSummary? {
    let setBytes = ((config.maxSpecies + 7) / 8 + 3) & ~3  // 0x54 for 649
    let need = 8 + setBytes * 5
    guard let d = read(img &+ UInt32(config.pokedexOff), need) else { return nil }
    guard Self.u32(d, 0) == Self.dexMagic else { return nil }
    func bit(_ base: Int, _ n: Int) -> Bool {
      let idx = base + (n - 1) / 8
      guard idx < d.count else { return false }
      return ((Int(d[idx]) >> ((n - 1) % 8)) & 1) != 0
    }
    var seen = Set<Int>()
    var caught = Set<Int>()
    let caughtBase = 8
    for n in 1...config.maxSpecies {
      if bit(caughtBase, n) { caught.insert(n); seen.insert(n) }
      for s in 1...4 where bit(caughtBase + setBytes * s, n) {
        seen.insert(n)
      }
    }
    // National if anything outside Unova (494…649) is seen — BW; sequels include older regionals.
    let national = seen.contains(where: { $0 < 494 })
    return DexSummary(
      seen: seen.count,
      caught: caught.count,
      seenSet: seen,
      caughtSet: caught,
      total: config.maxSpecies,
      nationalUnlocked: national
    )
  }

  // MARK: - Battle

  private struct BattleRead {
    var mons: [BattleMon?]
    var trainer: Bool
    var doubles: Bool
  }

  private func readBattle() -> BattleRead? {
    let b = config.battle
    guard let gsRaw = read(b.gameSystemPtr, 4) else { return nil }
    let gs = Self.u32(gsRaw, 0)
    guard Self.inMain(gs), let psRaw = read(gs &+ UInt32(b.offProcSys), 4) else { return nil }
    let ps = Self.u32(psRaw, 0)
    guard Self.inMain(ps), let procRaw = read(ps &+ UInt32(b.offCurrentProc), 4) else { return nil }
    let proc = Self.u32(procRaw, 0)
    guard Self.inMain(proc),
          let ovRaw = read(proc &+ UInt32(b.offProcOverlay), 4),
          Int(Self.u32(ovRaw, 0)) == b.battleOverlay else { return nil }
    guard let paramRaw = read(proc &+ UInt32(b.offProcParam), 4),
          let mainRaw = read(proc &+ UInt32(b.offProcWork), 4) else { return nil }
    let param = Self.u32(paramRaw, 0)
    let main = Self.u32(mainRaw, 0)
    guard Self.inMain(param), Self.inMain(main) else { return nil }
    let headNeed = max(b.offFoeParty + 4, b.offRule + 4)
    guard let head = read(param, headNeed) else { return nil }
    let competitor = Self.u32(head, b.offCompetitor)
    let rule = Self.u32(head, b.offRule)
    let doubles = rule == 1
    guard let parties = read(main &+ UInt32(b.offParties), b.partyStride * 2) else { return nil }
    func member(_ client: Int, _ i: Int) -> UInt32? {
      let p = Self.u32(parties, client * b.partyStride + i * 4)
      return Self.inMain(p) ? p : nil
    }
    func mon(_ addr: UInt32?) -> BattleMon? {
      guard let addr, let raw = read(addr, Self.battleMonBytes) else { return nil }
      return decodeBattleMon(raw, off: 0)
    }
    var slots: [BattleMon?] = [
      mon(member(0, 0)),
      mon(member(1, 0)),
      doubles ? mon(member(0, 1)) : nil,
      doubles ? mon(member(1, 1)) : nil
    ]
    // Ensure 4 slots for liveSuggestions (foe at [1]).
    while slots.count < 4 { slots.append(nil) }
    return BattleRead(mons: slots, trainer: competitor != 0, doubles: doubles)
  }

  private func decodeBattleMon(_ raw: [UInt8], off: Int) -> BattleMon? {
    guard off + Self.battleMonBytes <= raw.count else { return nil }
    let species = Self.u16(raw, off + 0x0C)
    guard (1...config.maxSpecies).contains(species) else { return nil }
    let maxHp = Self.u16(raw, off + 0x0E)
    let hp = Self.u16(raw, off + 0x10)
    guard (1...999).contains(maxHp), hp <= maxHp else { return nil }
    return BattleMon(
      species: species,
      level: Self.u8(raw, off + 0x18),
      hp: hp,
      maxHp: maxHp,
      moves: (0..<4).map { Self.u16(raw, off + 0x104 + $0 * 14) },
      pp: (0..<4).map { Self.u8(raw, off + 0x104 + $0 * 14 + 2) },
      item: Self.u16(raw, off + 0x12),
      status1: 0,
      shiny: false
    )
  }
}
