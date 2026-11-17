import Foundation

/// A bag's pockets; `id` is the generated tables' pocket number (KEY's 5 isn't in them, never edited).
enum BagPocket: Int, CaseIterable, Identifiable {
  case items = 1, balls = 2, tmhm = 3, berries = 4, key = 5
  var id: Int { rawValue }

  /// Pockets the save editor can add stacks into (not Key Items).
  static var editableCases: [BagPocket] { [.items, .balls, .tmhm, .berries] }

  var title: String {
    switch self {
    case .items: return "Items"
    case .balls: return "Poké Balls"
    case .tmhm: return "TMs & HMs"
    case .berries: return "Berries"
    case .key: return "Key Items"
    }
  }

  var symbol: String {
    switch self {
    case .items: return "bag.fill"
    case .balls: return "circle.circle.fill"
    case .tmhm: return "opticaldisc.fill"
    case .berries: return "leaf.fill"
    case .key: return "key.fill"
    }
  }
}

/// A pocket's ItemSlot array ({u16 itemId; u16 quantity}) in SaveBlock1.
struct PocketLayout {
  let pocket: BagPocket
  let off: Int
  let slots: Int
}

/// global.h's bagPocket_Items, _KeyItems, _PokeBalls, _TMHM, _Berries: back to back from `start`, 4 bytes a slot.
private func gen3Pockets(start: Int, items: Int, key: Int, balls: Int, tmhm: Int, berries: Int) -> [PocketLayout] {
  var off = start
  return [(BagPocket.items, items), (.key, key), (.balls, balls), (.tmhm, tmhm), (.berries, berries)].map { p, n in
    defer { off += n * 4 }
    return PocketLayout(pocket: p, off: off, slots: n)
  }
}

/// Port of Gen3SaveFormat: per-game offsets from the decomps' global.h (pokeruby / pokeemerald / pokefirered).
/// `FIRERED_CFRU` keeps FRLG field offsets but uses CFRU's larger flash sector payload (0xFF0) for checksums —
/// Radical Red, Unbound, and other Complete FireRed Upgrade builds.
/// `EMERALD_HNS` is Heart and Soul v2.0.6: SaveBlock2 0xF34, SaveBlock1 0x3D90 with +4 pad before `pos`,
/// party at 0x238/0x23C, money at 0x494 (Android LegacyNativeConfigs).
/// `EMERALD_MODERN` is Modern Emerald 3.6: SaveBlock2 0xF50 with encryption key at +0xBC, Items pocket 90
/// (bag +0xF0 vs retail), sector checksums over 0xFF4 (Android NATIVE_MODERN_EMERALD).
/// `EMERALD_LAZARUS` is Lazarus v2.0: SaveBlock2 0xF34 (sector checksum includes +8 past retail
/// 0xF2C), retail SaveBlock1, encryption key at +0xB0, expansion bag (items 50 / berries 30 /
/// key 20 / balls 70 / TM 46) from live EWRAM.
enum Gen3SaveFormat: CaseIterable {
  case RUBY_SAPPHIRE, EMERALD, EMERALD_HNS, EMERALD_MODERN, EMERALD_LAZARUS, EMERALD_WISHES,
    FIRERED_LEAFGREEN, FIRERED_CFRU

  struct Layout {
    let label: String
    /// sizeof(SaveBlock2) / sizeof(SaveBlock1) / sizeof(PokemonStorage).
    let saveBlock2Size: Int
    let saveBlock1Size: Int
    var storageSize: Int = 0x83D0
    let partyCountOff: Int
    let partyOff: Int
    /// SaveBlock1.money, XORed with SaveBlock2.encryptionKey (-1 = none).
    let moneyOff: Int
    let encryptionKeyOff: Int
    let flagsOff: Int
    let varsOff: Int
    /// SaveBlock1's two copies of the Pokédex "seen" bits.
    let seen1Off: Int
    let seen2Off: Int
    let nationalMagicOff: Int
    let nationalMagic: Int
    let nationalVar: Int
    let nationalVarValue: Int
    let nationalFlag: Int
    let linkRsFlag: Int
    let kanto: Bool
    let coinsOff: Int
    let pockets: [PocketLayout]
    let stackMax: Int
  }

  private var layout: Layout {
    switch self {
    case .RUBY_SAPPHIRE:
      return Layout(
        label: "RUBY / SAPPHIRE", saveBlock2Size: 0x890, saveBlock1Size: 0x3AC0,
        partyCountOff: 0x234, partyOff: 0x238, moneyOff: 0x490, encryptionKeyOff: -1,
        flagsOff: 0x1220, varsOff: 0x1340, seen1Off: 0x938, seen2Off: 0x3A8C,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x836,
        linkRsFlag: -1, kanto: false, coinsOff: 0x494,
        pockets: gen3Pockets(start: 0x560, items: 20, key: 20, balls: 16, tmhm: 64, berries: 46), stackMax: 99)
    case .EMERALD:
      return Layout(
        label: "EMERALD", saveBlock2Size: 0xF2C, saveBlock1Size: 0x3D88,
        partyCountOff: 0x234, partyOff: 0x238, moneyOff: 0x490, encryptionKeyOff: 0xAC,
        flagsOff: 0x1270, varsOff: 0x139C, seen1Off: 0x988, seen2Off: 0x3B24,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x896,
        linkRsFlag: -1, kanto: false, coinsOff: 0x494,
        pockets: gen3Pockets(start: 0x560, items: 30, key: 30, balls: 16, tmhm: 64, berries: 46), stackMax: 99)
    case .EMERALD_HNS:
      // Heart and Soul: +4 bytes before pos; sb2/sb1 grown; retail sector payload 0xF80.
      return Layout(
        label: "EMERALD (Heart and Soul)", saveBlock2Size: 0xF34, saveBlock1Size: 0x3D90,
        partyCountOff: 0x238, partyOff: 0x23C, moneyOff: 0x494, encryptionKeyOff: 0xAC,
        flagsOff: 0x1274, varsOff: 0x13A0, seen1Off: 0x98C, seen2Off: 0x3B28,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x896,
        linkRsFlag: -1, kanto: false, coinsOff: 0x498,
        pockets: gen3Pockets(start: 0x564, items: 30, key: 30, balls: 16, tmhm: 64, berries: 46), stackMax: 99)
    case .EMERALD_MODERN:
      // Items 90 (+0xF0): Key/Balls/TM/Berries and everything after the bag shift; key at SB2+0xBC.
      return Layout(
        label: "EMERALD (Modern Emerald)", saveBlock2Size: 0xF50, saveBlock1Size: 0x3E78,
        storageSize: 0x8F64,
        partyCountOff: 0x234, partyOff: 0x238, moneyOff: 0x490, encryptionKeyOff: 0xBC,
        flagsOff: 0x1360, varsOff: 0x148C, seen1Off: 0xA78, seen2Off: 0x3C14,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x896,
        linkRsFlag: -1, kanto: false, coinsOff: 0x494,
        pockets: gen3Pockets(start: 0x560, items: 90, key: 30, balls: 16, tmhm: 64, berries: 46), stackMax: 99)
    case .EMERALD_LAZARUS:
      // SB2 grown to 0xF34 (device .sav sector-0 checksum); party/money still retail.
      // Bag reorder (items→berries→key→balls→TM) from live EWRAM / companion.
      return Layout(
        label: "EMERALD (Lazarus)", saveBlock2Size: 0xF34, saveBlock1Size: 0x3D88,
        partyCountOff: 0x234, partyOff: 0x238, moneyOff: 0x490, encryptionKeyOff: 0xB0,
        flagsOff: 0x1270, varsOff: 0x139C, seen1Off: 0x988, seen2Off: 0x3B24,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x896,
        linkRsFlag: -1, kanto: false, coinsOff: 0x494,
        pockets: [
          PocketLayout(pocket: .items, off: 0x560, slots: 50),
          PocketLayout(pocket: .berries, off: 0x628, slots: 30),
          PocketLayout(pocket: .key, off: 0x6A0, slots: 20),
          PocketLayout(pocket: .balls, off: 0x6F0, slots: 70),
          PocketLayout(pocket: .tmhm, off: 0x808, slots: 46),
        ], stackMax: 99)
    case .EMERALD_WISHES:
      // Wishes of Tomorrow v1.3.0 GF ROM header: SB2 0xF44 / SB1 0x3D7C; flags/vars 0x1270/0x13A0.
      return Layout(
        label: "EMERALD (Wishes of Tomorrow)", saveBlock2Size: 0xF44, saveBlock1Size: 0x3D7C,
        partyCountOff: 0x234, partyOff: 0x238, moneyOff: 0x490, encryptionKeyOff: 0xAC,
        flagsOff: 0x1270, varsOff: 0x13A0, seen1Off: 0x988, seen2Off: 0x3B24,
        nationalMagicOff: 0x1A, nationalMagic: 0xDA, nationalVar: 0x4046, nationalVarValue: 0x302, nationalFlag: 0x896,
        linkRsFlag: -1, kanto: false, coinsOff: 0x494,
        pockets: gen3Pockets(start: 0x560, items: 30, key: 30, balls: 16, tmhm: 64, berries: 46), stackMax: 99)
    case .FIRERED_LEAFGREEN:
      return Layout(
        label: "FIRERED / LEAFGREEN", saveBlock2Size: 0xF24, saveBlock1Size: 0x3D68,
        partyCountOff: 0x34, partyOff: 0x38, moneyOff: 0x290, encryptionKeyOff: 0xF20,
        flagsOff: 0xEE0, varsOff: 0x1000, seen1Off: 0x5F8, seen2Off: 0x3A18,
        nationalMagicOff: 0x1B, nationalMagic: 0xB9, nationalVar: 0x404E, nationalVarValue: 0x6258, nationalFlag: 0x840,
        linkRsFlag: 0x844, kanto: true, coinsOff: 0x294,
        pockets: gen3Pockets(start: 0x310, items: 42, key: 30, balls: 13, tmhm: 58, berries: 43), stackMax: 999)
    case .FIRERED_CFRU:
      // Same SaveBlock field offsets as FRLG; sector payload is CFRU's 0xFF0 (see chunkSize).
      return Layout(
        label: "FIRERED (CFRU / Unbound / Radical Red)", saveBlock2Size: 0xF24, saveBlock1Size: 0x3D68,
        partyCountOff: 0x34, partyOff: 0x38, moneyOff: 0x290, encryptionKeyOff: 0xF20,
        flagsOff: 0xEE0, varsOff: 0x1000, seen1Off: 0x5F8, seen2Off: 0x3A18,
        nationalMagicOff: 0x1B, nationalMagic: 0xB9, nationalVar: 0x404E, nationalVarValue: 0x6258, nationalFlag: 0x840,
        linkRsFlag: 0x844, kanto: true, coinsOff: 0x294,
        pockets: gen3Pockets(start: 0x310, items: 42, key: 30, balls: 13, tmhm: 58, berries: 43), stackMax: 999)
    }
  }

  var label: String { layout.label }
  var saveBlock2Size: Int { layout.saveBlock2Size }
  var saveBlock1Size: Int { layout.saveBlock1Size }
  var storageSize: Int { layout.storageSize }
  var partyCountOff: Int { layout.partyCountOff }
  var partyOff: Int { layout.partyOff }
  var moneyOff: Int { layout.moneyOff }
  var encryptionKeyOff: Int { layout.encryptionKeyOff }
  var flagsOff: Int { layout.flagsOff }
  var varsOff: Int { layout.varsOff }
  var seen1Off: Int { layout.seen1Off }
  var seen2Off: Int { layout.seen2Off }
  var nationalMagicOff: Int { layout.nationalMagicOff }
  var nationalMagic: Int { layout.nationalMagic }
  var nationalVar: Int { layout.nationalVar }
  var nationalVarValue: Int { layout.nationalVarValue }
  var nationalFlag: Int { layout.nationalFlag }
  var linkRsFlag: Int { layout.linkRsFlag }
  var kanto: Bool { layout.kanto }
  var coinsOff: Int { layout.coinsOff }
  var pockets: [PocketLayout] { layout.pockets }
  /// The most of one item a stack holds: FR / LG 999 everywhere, R/S / E 99 but berries.
  var stackMax: Int { layout.stackMax }

  /// ITEM_HM01: TMs are 289..338, HMs 339..346.
  static let FIRST_HM = 339

  /// How many of `item` one stack in `pocket` may hold: berries 999, an HM 1 (the game hands each out once).
  func stackMax(pocket: BagPocket, item: Int) -> Int {
    if pocket == .tmhm && item >= Gen3SaveFormat.FIRST_HM { return 1 }
    if pocket == .berries { return 999 }
    return stackMax
  }

  func pocket(_ p: BagPocket) -> PocketLayout { pockets.first { $0.pocket == p }! }

  /// SaveBlock2.pokedex: order, mode, ..., owned[] at +0x10, seen[] at +0x44 (the same in all three).
  var pokedexOff: Int { 0x18 }

  /// sSaveSlotLayout's size for sector `id`: SaveBlock2 in 0, SaveBlock1 in 1-4, PokemonStorage in 5-13.
  /// CFRU (Complete Fire-Red Upgrade) uses gSaveSectionOffsets with SECTOR_DATA_SIZE 0xFF0, not retail 0xF80.
  func chunkSize(_ id: Int) -> Int {
    if self == .FIRERED_CFRU {
      switch id {
      case 0: return 0xF24
      case 1, 2, 3: return Gen3SaveFile.DATA_CFRU
      case 4: return 0xD98
      case 5...12: return Gen3SaveFile.DATA_CFRU
      case 13: return 0x450
      default: return 0
      }
    }
    if self == .EMERALD_MODERN {
      // Payload window is 0xFF4 (pre-footer). Last SB1 / storage sectors are the remainders —
      // using a full 0xFF4 for id 13 overflowed storageSize (0x8F64) and crashed on open.
      switch id {
      case 0: return saveBlock2Size
      case 1, 2, 3: return Gen3SaveFile.DATA_MODERN
      case 4: return saveBlock1Size - 3 * Gen3SaveFile.DATA_MODERN
      case 5...12: return Gen3SaveFile.DATA_MODERN
      case 13: return storageSize - 8 * Gen3SaveFile.DATA_MODERN
      default: return 0
      }
    }
    switch id {
    case 0: return saveBlock2Size
    case 1...4: return chunk(saveBlock1Size, id - 1)
    default: return chunk(storageSize, id - 5)
    }
  }

  /// True when this layout packs species:11|extra in the growth u16 (Heart and Soul / TMT2-style).
  var packsSpeciesBits: Bool { self == .EMERALD_HNS }

  /// Byte offset of sector `id`'s payload inside SaveBlock1 (ids 1…4) or PokemonStorage (ids 5…13).
  func blockOffset(forSectorId id: Int) -> Int {
    switch id {
    case 0: return 0
    case 1...4:
      return (1..<id).reduce(0) { $0 + chunkSize($1) }
    case 5...13:
      return (5..<id).reduce(0) { $0 + chunkSize($1) }
    default: return 0
    }
  }

  private func chunk(_ size: Int, _ n: Int) -> Int {
    min(max(size - n * Gen3SaveFile.DATA, 0), Gen3SaveFile.DATA)
  }

  /// The format a ROM's header game code (AXVE, BPRE, ...) saves in. Japanese builds (a `J` last) get none.
  static func forGameCode(_ code: String?) -> Gen3SaveFormat? {
    guard let code, code.count >= 4 else { return nil }
    let chars = Array(code)
    if chars[3] == "J" { return nil }
    switch String(chars[0..<3]) {
    case "AXV", "AXP": return .RUBY_SAPPHIRE
    case "BPE": return .EMERALD
    case "BPR", "BPG": return .FIRERED_LEAFGREEN
    default: return nil
    }
  }

  /// Formats to try when opening a GBA save (CFRU first for known FR hacks).
  static func candidates(forGameCode code: String?, fileName: String) -> [Gen3SaveFormat] {
    let u = fileName.uppercased()
    let cfruHint = ["UNBOUND", "RADICAL", "CFRU", "GAIA", "ROCKET", "ODYSSEY", "AMETHYST", "IMPERIUM",
                    "CRYSTAL ADVANCE", "CRYSTALADVANCE", "ADVANCE REDUX"]
      .contains { u.contains($0) }
    let hnsHint = (u.contains("HEART") && u.contains("SOUL") && !u.contains("HEARTGOLD"))
      || u.contains("HEARTSOUL")
      || (u.contains("CRYSTAL") && u.contains("ENHANCED"))
      || u.contains("CRYSENHA")
    let modernHint = u.contains("MODERN") && u.contains("EMERALD")
    let lazarusHint = u.contains("LAZARUS")
    let wishesHint = u.contains("WISHES")
    guard let base = forGameCode(code) else {
      // Unknown code — still try CFRU FRLG layout for named hacks.
      if modernHint { return [.EMERALD_MODERN, .EMERALD, .FIRERED_CFRU] }
      if hnsHint { return [.EMERALD_HNS, .EMERALD, .FIRERED_CFRU] }
      if lazarusHint { return [.EMERALD_LAZARUS, .EMERALD, .FIRERED_CFRU] }
      if wishesHint { return [.EMERALD_WISHES, .EMERALD, .FIRERED_CFRU] }
      return cfruHint ? [.FIRERED_CFRU, .FIRERED_LEAFGREEN, .EMERALD] : []
    }
    switch base {
    case .FIRERED_LEAFGREEN, .FIRERED_CFRU:
      return cfruHint ? [.FIRERED_CFRU, .FIRERED_LEAFGREEN] : [.FIRERED_LEAFGREEN, .FIRERED_CFRU]
    case .EMERALD, .EMERALD_HNS, .EMERALD_MODERN, .EMERALD_LAZARUS, .EMERALD_WISHES:
      if modernHint { return [.EMERALD_MODERN, .EMERALD] }
      // Heart and Soul needs its own sector sizes; other Emerald hacks try retail first.
      if hnsHint { return [.EMERALD_HNS, .EMERALD] }
      if lazarusHint { return [.EMERALD_LAZARUS, .EMERALD] }
      if wishesHint { return [.EMERALD_WISHES, .EMERALD] }
      return [.EMERALD, .EMERALD_HNS, .EMERALD_MODERN, .EMERALD_LAZARUS, .EMERALD_WISHES]
    case .RUBY_SAPPHIRE:
      return [.RUBY_SAPPHIRE]
    }
  }
}
