import Foundation

/// Generation 2 (GBC) RAM layout — addresses from PokeDaisy Gen2Reader (pret/pokecrystal / pokegold / Polished Crystal).
/// Bank-1 D000–DFFF symbols use `wramx(1, addr)` so reads hit WRAM bank 1 even when SVBK switched.
struct Gen2Config {
  var id: String
  var displayName: String
  var tables: Gen3Tables
  var polished: Bool
  var partyCount: UInt32
  var partyMons: UInt32
  var numItems: UInt32
  var numKeyItems: UInt32
  var numBalls: UInt32
  var tmsHms: UInt32
  var money: UInt32
  var mapGroup: UInt32
  var backupMapGroup: UInt32
  var battleMode: UInt32
  var battleMon: UInt32
  var enemyMon: UInt32
  var otPartyCount: UInt32
  var otPartyMons: UInt32
  var curOTMon: UInt32
  var dexCaught: UInt32
  var dexSeen: UInt32
  var itemsMax: Int
  var ballsMax: Int
  var keyItemsMax: Int
  var speciesCount: Int
  var battleMonSize: Int
  var tmItems: [Int]
}

enum Gen2ConfigStore {
  static let partyMonSize = 48
  static let battleMonSize = 32
  static let nameLen = 11
  static let nicknamesAfterMons = 6 * partyMonSize + 6 * nameLen
  static let eggSpecies = 0xFD
  static let tmsHmsCount = 57

  /// WRAM bank `bank`'s byte at `addr` (D000–DFFF), matching Android `wramx`.
  static func wramx(_ bank: Int, _ addr: UInt32) -> UInt32 {
    UInt32(bank << 16) | addr
  }

  static let tmItemsCrystal: [Int] = [
    191, 192, 193, 194, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210,
    211, 212, 213, 214, 215, 216, 217, 218, 219, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230,
    231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249
  ]

  static let crystal = Gen2Config(
    id: "crystal",
    displayName: "Pokémon Crystal",
    tables: .crystal,
    polished: false,
    partyCount: wramx(1, 0xDCD7),
    partyMons: wramx(1, 0xDCDF),
    numItems: wramx(1, 0xD892),
    numKeyItems: wramx(1, 0xD8BC),
    numBalls: wramx(1, 0xD8D7),
    tmsHms: wramx(1, 0xD859),
    money: wramx(1, 0xD84E),
    mapGroup: wramx(1, 0xDCB5),
    backupMapGroup: wramx(1, 0xDCAD),
    battleMode: wramx(1, 0xD22D),
    battleMon: 0xC62C,
    enemyMon: wramx(1, 0xD206),
    otPartyCount: wramx(1, 0xD280),
    otPartyMons: wramx(1, 0xD288),
    curOTMon: 0xC663,
    dexCaught: wramx(1, 0xDE99),
    dexSeen: wramx(1, 0xDEB9),
    itemsMax: 20,
    ballsMax: 12,
    keyItemsMax: 25,
    speciesCount: 251,
    battleMonSize: battleMonSize,
    tmItems: tmItemsCrystal
  )

  /// Polished Crystal 3.2.x — own WRAM map, 35-byte battle_struct, remapped move ids (PokeDaisy GEN2_POLISHED_CRYSTAL).
  static let polishedCrystal = Gen2Config(
    id: "polished_crystal",
    displayName: "Polished Crystal",
    tables: .polished,
    polished: true,
    partyCount: wramx(1, 0xDCCE),
    partyMons: wramx(1, 0xDCD6),
    numItems: wramx(1, 0xD827),
    numKeyItems: wramx(1, 0xD800),
    numBalls: wramx(1, 0xD90B),
    tmsHms: wramx(1, 0xD7F5),
    money: wramx(1, 0xD7E5),
    mapGroup: wramx(1, 0xDCAC),
    backupMapGroup: wramx(1, 0xDCA7),
    battleMode: wramx(1, 0xD233),
    battleMon: 0xC4A5,
    enemyMon: wramx(1, 0xD209),
    otPartyCount: wramx(1, 0xD283),
    otPartyMons: wramx(1, 0xD28B),
    curOTMon: 0xC4DD,
    dexCaught: wramx(1, 0xDE7B),
    dexSeen: wramx(1, 0xDEAD),
    itemsMax: 75,
    ballsMax: 25,
    keyItemsMax: 38,
    speciesCount: Gen2Polished.numSpecies,
    battleMonSize: Gen2Polished.battleMonSize,
    tmItems: tmItemsCrystal
  )

  static let gold = Gen2Config(
    id: "gold",
    displayName: "Pokémon Gold",
    tables: .crystal,
    polished: false,
    partyCount: wramx(1, 0xDA22),
    partyMons: wramx(1, 0xDA2A),
    numItems: wramx(1, 0xD5B7),
    numKeyItems: wramx(1, 0xD5E1),
    numBalls: wramx(1, 0xD5FC),
    tmsHms: wramx(1, 0xD57E),
    money: wramx(1, 0xD573),
    mapGroup: wramx(1, 0xDA00),
    backupMapGroup: wramx(1, 0xD9F6),
    battleMode: wramx(1, 0xD116),
    battleMon: 0xCB0C,
    enemyMon: wramx(1, 0xD0EF),
    otPartyCount: wramx(1, 0xDD55),
    otPartyMons: wramx(1, 0xDD5D),
    curOTMon: 0xCB41,
    dexCaught: wramx(1, 0xDBE4),
    dexSeen: wramx(1, 0xDC04),
    itemsMax: 20,
    ballsMax: 12,
    keyItemsMax: 25,
    speciesCount: 251,
    battleMonSize: battleMonSize,
    tmItems: tmItemsCrystal
  )

  static var silver: Gen2Config {
    var c = gold
    c.id = "silver"
    c.displayName = "Pokémon Silver"
    return c
  }

  /// Known Polished Crystal 3.2.x release SHA-1s (from PokeDaisy polishedCrystalAddrs).
  static let polishedSha1s: Set<String> = [
    "6930b48af5844d373e3c9130f26d6dd1084cf4ed",
    "beb8b38280af59e9ef84be12684a6ecf09021c9b",
    "79ebf9984eac8081f488d15a35a6c5d11b4f84e2",
    "e55859484c5cda70e05daed59b14662e0a0f8eac",
    "3ff091a8e94a0c031372b6f0275e12620fe3d766",
    "e63b1e52a9f71c3948e3e7e515e9939d728fc679",
    "666f8edfb9efd8c301adbc14d38ccfaae33a047d",
    "b012f6d55c34c972778f5566e1cc910962dd7ab5",
  ]

  static func detect(title: String, manufacturer: String? = nil, sha1: String? = nil) -> Gen2Config? {
    if let sha1, polishedSha1s.contains(sha1.lowercased()) {
      return polishedCrystal
    }
    let t = title.uppercased().replacingOccurrences(of: " ", with: "_")
    let mfr = (manufacturer ?? "").uppercased()
    // Polished Crystal 3.2.x header is "PKPCRYSTAL" / maker "PKPC" — must win over plain "CRYSTAL".
    if t.contains("POLISH") || t.hasPrefix("PKPCRYSTAL") || mfr == "PKPC" {
      return polishedCrystal
    }
    if t.contains("CRYSTAL") || t.contains("PM_CRYSTAL") || t.hasPrefix("PM_C") {
      var c = crystal
      if t.contains("CLEAR") { c.displayName = "Crystal Clear (best-effort Crystal RAM)" }
      else if t.contains("PRISM") { c.displayName = "Pokémon Prism (best-effort Crystal RAM)" }
      else if t.contains("LEGACY") { c.displayName = "Crystal Legacy (best-effort Crystal RAM)" }
      else if t.contains("ENHANCED") { c.displayName = "Crystal Enhanced (best-effort Crystal RAM)" }
      return c
    }
    if t.contains("GOLD") || t.contains("POKEMON_GLD") || t.contains("_GLD") {
      return gold
    }
    if t.contains("SILVER") || t.contains("POKEMON_SLV") || t.contains("_SLV") {
      return silver
    }
    return nil
  }
}
