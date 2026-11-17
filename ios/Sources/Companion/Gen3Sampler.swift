import Foundation

/// Reads a running Gen 3 game's RAM through `pk_ios_read_into` and rebuilds a `CompanionSnapshot`.
/// Port of `readNativeTelemetry` (NativeReader.kt). Not thread-safe by itself: call from the emulator queue.
final class Gen3Sampler: CompanionSampling, @unchecked Sendable {
  let config: NativeConfig

  private static let ewram: Range<UInt32> = 0x0200_0000..<0x0400_0000
  private static let bagPocketStride = 8
  private static let bagPocketSlots = 255
  private static let bagMaxItems = 300
  private static let maxMoney: UInt32 = 999_999

  private var tick = 0
  private var lastBag: [BagItem] = []
  private var bagValid = false
  private var lastDex: DexSummary?
  private var dexValid = false

  /// Bag every N samples, dex every M (both change slowly; party / battle / map every sample).
  private let bagEvery = 3
  private let dexEvery = 3

  init(config: NativeConfig) {
    self.config = config
  }

  // MARK: - Memory helpers

  private func read(_ addr: UInt32, _ len: Int) -> [UInt8]? {
    guard len > 0 else { return [] }
    var ok = false
    let bytes = [UInt8](unsafeUninitializedCapacity: len) { buf, count in
      ok = pk_ios_read_into(addr, buf.baseAddress, Int32(len))
      count = ok ? len : 0
    }
    return ok ? bytes : nil
  }

  private func readU32(_ addr: UInt32) -> UInt32? {
    guard let b = read(addr, 4) else { return nil }
    return gen3U32(b, 0)
  }

  private func readU8(_ addr: UInt32) -> UInt8? {
    read(addr, 1)?.first
  }

  private func saveBlock1() -> UInt32? {
    if config.staticSaveBlocks {
      return Self.ewram.contains(config.saveBlock1Ptr) ? config.saveBlock1Ptr : nil
    }
    guard let p = readU32(config.saveBlock1Ptr), Self.ewram.contains(p) else { return nil }
    return p
  }

  private func saveBlock2() -> UInt32? {
    if config.staticSaveBlocks {
      return Self.ewram.contains(config.saveBlock2Ptr) ? config.saveBlock2Ptr : nil
    }
    guard let p = readU32(config.saveBlock2Ptr), Self.ewram.contains(p) else { return nil }
    return p
  }

  // MARK: - Sample

  func sample() -> CompanionSnapshot? {
    let c = config
    // No core / unreadable first byte -> nothing to show.
    guard let countByte = readU8(c.playerPartyCount) else { return nil }
    tick += 1

    var snap = CompanionSnapshot(gameName: c.displayName, tables: c.tables, configId: c.id)

    // --- party ---
    let count = min(Int(countByte), Gen3Const.partySize)
    let stride = max(1, c.monStride)
    if count > 0, let raw = read(c.playerParty, count * stride) {
      for i in 0..<count {
        if var mon = Gen3Decode.decodePartyMon(
          raw, off: i * stride, shinyBelow: c.shinyBelow,
          kind: c.partyMonKind, speciesMask: c.speciesMask,
          moveMask: c.moveMask, ppMask: c.ppMask, monStride: stride
        ) {
          mon.slot = i
          snap.party.append(mon)
        }
      }
    }

    // --- battle --- (gMain.inBattle is bit 1 of the byte at gMain + 0x439)
    let inBattle = ((readU8(c.gMain + c.inBattleOff) ?? 0) & 0x02) != 0
    snap.inBattle = inBattle
    if inBattle {
      readBattle(into: &snap)
    }

    // --- location ---
    if let sb1 = saveBlock1(), let b = read(sb1 + c.saveBlock1PosOff, 6) {
      snap.x = gen3U16(b, 0)
      snap.y = gen3U16(b, 2)
      snap.mapGroup = Int(b[4])
      snap.mapNum = Int(b[5])
    }
    if c.mapSecWide {
      if let b = read(c.mapHeader + 0x14, 2) {
        let sec = Int(gen3U16(b, 0))
        snap.mapSec = sec
        snap.mapSecName = Gen3Names.mapSec(sec, game: c.game, tables: c.tables, configId: c.id)
      }
    } else if let sec = readU8(c.mapHeader + 0x14) {
      snap.mapSec = Int(sec)
      snap.mapSecName = Gen3Names.mapSec(Int(sec), game: c.game, tables: c.tables, configId: c.id)
    }

    // --- money ---
    snap.money = readMoney()

    // --- bag (throttled) ---
    if !bagValid || tick % bagEvery == 0 {
      if let bag = readBag() {
        lastBag = bag
        bagValid = true
      }
    }
    snap.bag = lastBag

    // --- dex (throttled) ---
    if c.dexEnabled {
      if !dexValid || tick % dexEvery == 0 {
        lastDex = readDex()
        dexValid = lastDex != nil
      }
      snap.dex = lastDex
    }

    return snap
  }

  // MARK: - Battle

  private func readBattle(into snap: inout CompanionSnapshot) {
    let c = config
    // Unknown / disabled battle globals (emerald_hack placeholder).
    guard c.battleMons != 0, c.battleTypeFlags != 0 else { return }
    if let flags = read(c.battleTypeFlags, 4) {
      let f = gen3U32(flags, 0)
      snap.isDouble = f & 0x0001 != 0
      snap.isTrainer = f & 0x0008 != 0
    }
    let layout = c.battleMonLayout
    let size = layout.size
    let n: Int = {
      if c.battlersCount != 0, let v = readU8(c.battlersCount), (1...4).contains(Int(v)) { return Int(v) }
      return 4
    }()
    let pos = c.battlerPositions != 0 ? read(c.battlerPositions, 4) : nil
    if let raw = read(c.battleMons, 4 * size) {
      for battler in 0..<n {
        var p = battler
        if let pos, Int(pos[battler]) < 4 { p = Int(pos[battler]) }
        if let mon = Gen3Decode.decodeBattleMon(
          raw, off: battler * size, layout: layout, shinyBelow: c.shinyBelow,
          speciesMask: c.speciesMask, moveMask: c.moveMask, ppMask: c.ppMask
        ) {
          snap.battleMons[p] = mon
        }
      }
    }
    // gEnemyParty: trainer's whole party, or the wild foe(s).
    let stride = max(1, c.monStride)
    if c.enemyParty != 0,
       let raw = read(c.enemyParty, Gen3Const.partySize * stride) {
      for i in 0..<Gen3Const.partySize {
        if var mon = Gen3Decode.decodePartyMon(
          raw, off: i * stride, shinyBelow: c.shinyBelow,
          kind: c.partyMonKind, speciesMask: c.speciesMask,
          moveMask: c.moveMask, ppMask: c.ppMask, monStride: stride
        ), mon.species != 0 {
          mon.slot = i
          snap.foeParty.append(mon)
        }
      }
    }
  }

  // MARK: - Money / bag

  /// SaveBlock1.money XOR SaveBlock2.encryptionKey (plain on Ruby/Sapphire).
  private func readMoney() -> Int? {
    guard let sb1 = saveBlock1(), let raw = readU32(sb1 + config.moneyOff) else { return nil }
    let key: UInt32
    if let off = config.encryptionKeyOff, let sb2 = saveBlock2(), let k = readU32(sb2 + off) {
      key = k
    } else {
      key = 0
    }
    let money = raw ^ key
    return money <= Self.maxMoney ? Int(money) : nil
  }

  /// gBagPockets[]: { u32 slotsPtr; u8 capacity } stride 8; slots are { u16 itemId; u16 quantity ^ key }.
  private func readBag() -> [BagItem]? {
    let c = config
    var key: UInt16 = 0
    if let off = c.encryptionKeyOff, let sb2 = saveBlock2(), let k = readU32(sb2 + off) {
      key = UInt16(k & 0xFFFF)
    }
    guard let pockets = read(c.bagPockets, c.bagPocketCount * Self.bagPocketStride) else { return nil }
    var out: [BagItem] = []
    for p in 0..<c.bagPocketCount {
      let ptr = gen3U32(pockets, p * Self.bagPocketStride)
      let capacity = Int(pockets[p * Self.bagPocketStride + 4])
      // Slot arrays live in EWRAM (or static save); pocket descriptors may be ROM on R/S.
      guard (Self.ewram.contains(ptr) || (0x0200_0000..<0x0300_8000).contains(ptr)), capacity > 0 else { continue }
      let slots = min(capacity, Self.bagPocketSlots)
      guard let raw = read(ptr, slots * 4) else { continue }
      let pocket = p < c.bagPocketOrder.count ? c.bagPocketOrder[p] : Gen3Pocket.items
      var i = 0
      while i < slots && out.count < Self.bagMaxItems {
        let id = gen3U16(raw, i * 4)
        if id != 0 {
          let qty = UInt16(gen3U16(raw, i * 4 + 2)) ^ key
          out.append(BagItem(itemId: id, quantity: Int(qty), pocket: pocket, index: out.count))
        }
        i += 1
      }
    }
    return out
  }

  // MARK: - Pokédex

  /// Seen / caught bit arrays, indexed by National Dex number (bit n-1).
  /// Retail Emerald/FR keep them in SaveBlock2; Seaglass / Unbound / CFRU / expansion use SaveBlock1;
  /// Gaia uses fixed EWRAM addresses.
  private func readDex() -> DexSummary? {
    let c = config
    let seenBits: [UInt8]
    let caughtBits: [UInt8]
    switch c.dexFlagBlock {
    case .saveBlock2:
      guard let sb2 = saveBlock2(),
            let s = read(sb2 + c.dexSeenOff, c.dexBytes),
            let k = read(sb2 + c.dexCaughtOff, c.dexBytes) else { return nil }
      seenBits = s
      caughtBits = k
    case .saveBlock1:
      guard let sb1 = saveBlock1(),
            let s = read(sb1 + c.dexSeenOff, c.dexBytes),
            let k = read(sb1 + c.dexCaughtOff, c.dexBytes) else { return nil }
      seenBits = s
      caughtBits = k
    case .fixed:
      guard let s = read(c.dexSeenOff, c.dexBytes),
            let k = read(c.dexCaughtOff, c.dexBytes) else { return nil }
      seenBits = s
      caughtBits = k
    }
    // SaveBlock1 anti-cheat copies are optional live: they often lag SaveBlock2 mid-session.
    var copies: [[UInt8]] = []
    if c.dexFlagBlock == .saveBlock2, let sb1 = saveBlock1() {
      for off in c.dexSeenCopies {
        if let b = read(sb1 + off, c.dexBytes) { copies.append(b) }
      }
    }
    func bit(_ b: [UInt8], _ n: Int) -> Bool {
      let i = n - 1
      return i >= 0 && i / 8 < b.count && (b[i / 8] >> UInt8(i % 8)) & 1 != 0
    }
    var seen = Set<Int>()
    var caught = Set<Int>()
    for n in 1...c.dexNationalCount {
      let s = bit(seenBits, n) || copies.contains(where: { bit($0, n) })
      let k = bit(caughtBits, n)
      if k {
        caught.insert(n)
        seen.insert(n)
      } else if s {
        seen.insert(n)
      }
    }
    // National Dex unlock lives in SaveBlock2's Pokedex header (even when flags are in SB1).
    var unlocked = true
    if c.dexNationalMagicOff >= 0, let sb2 = saveBlock2(),
       let m = readU8(sb2 + c.sb2DexOff + UInt32(c.dexNationalMagicOff)) {
      unlocked = m == c.dexNationalMagic
    }
    return DexSummary(
      seen: seen.count,
      caught: caught.count,
      seenSet: seen,
      caughtSet: caught,
      total: c.dexNationalCount,
      nationalUnlocked: unlocked
    )
  }
}
