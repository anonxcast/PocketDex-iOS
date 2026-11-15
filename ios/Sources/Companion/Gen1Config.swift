import Foundation

/// Generation 1 (GB) RAM layout — addresses from PokeDaisy Gen1Reader (pret/pokeyellow / pokered).
struct Gen1Config {
  var id: String
  var displayName: String
  var partyCount: UInt32
  var partyMons: UInt32
  var bagCount: UInt32
  var money: UInt32
  var curMap: UInt32
  var yCoord: UInt32
  var xCoord: UInt32
  var isInBattle: UInt32
  var battleMon: UInt32
  var enemyMon: UInt32
  var enemyMonPartyPos: UInt32
  var enemyPartyCount: UInt32
  var enemyMons: UInt32
  var bagSlots: Int
  var internalToDex: [Int]
  /// wPokedexOwned / wPokedexSeen — 19 bytes, bit n-1 = National Dex No. n.
  var dexOwned: UInt32
  var dexSeen: UInt32
  var dexCount: Int = 151

  func dex(_ internalId: Int) -> Int {
    guard internalToDex.indices.contains(internalId) else { return 0 }
    return internalToDex[internalId]
  }
}

enum Gen1ConfigStore {
  static let partyMonSize = 44
  static let battleMonSize = 29
  static let nameLen = 11
  static let nicknamesAfterMons = 6 * partyMonSize + 6 * nameLen

  /// pret/pokeyellow PokedexOrder (internal index → National Dex).
  static let internalToDexYellow: [Int] = [
0,
    112,
    115,
    32,
    35,
    21,
    100,
    34,
    80,
    2,
    103,
    108,
    102,
    88,
    94,
    29,
    31,
    104,
    111,
    131,
    59,
    151,
    130,
    90,
    72,
    92,
    123,
    120,
    9,
    127,
    114,
    0,
    0,
    58,
    95,
    22,
    16,
    79,
    64,
    75,
    113,
    67,
    122,
    106,
    107,
    24,
    47,
    54,
    96,
    76,
    0,
    126,
    0,
    125,
    82,
    109,
    0,
    56,
    86,
    50,
    128,
    0,
    0,
    0,
    83,
    48,
    149,
    0,
    0,
    0,
    84,
    60,
    124,
    146,
    144,
    145,
    132,
    52,
    98,
    0,
    0,
    0,
    37,
    38,
    25,
    26,
    0,
    0,
    147,
    148,
    140,
    141,
    116,
    117,
    0,
    0,
    27,
    28,
    138,
    139,
    39,
    40,
    133,
    136,
    135,
    134,
    66,
    41,
    23,
    46,
    61,
    62,
    13,
    14,
    15,
    0,
    85,
    57,
    51,
    49,
    87,
    0,
    0,
    10,
    11,
    12,
    68,
    0,
    55,
    97,
    42,
    150,
    143,
    129,
    0,
    0,
    89,
    0,
    99,
    91,
    0,
    101,
    36,
    110,
    53,
    105,
    0,
    93,
    63,
    65,
    17,
    18,
    121,
    1,
    3,
    73,
    0,
    118,
    119,
    0,
    0,
    0,
    0,
    77,
    78,
    19,
    20,
    33,
    30,
    74,
    137,
    142,
    0,
    81,
    0,
    0,
    4,
    7,
    5,
    8,
    6,
    0,
    0,
    0,
    0,
    43,
    44,
    45,
    69,
    70,
    71
  ]

  static let yellow = Gen1Config(
    id: "yellow",
    displayName: "Pokémon Yellow",
    partyCount: 0xD162,
    partyMons: 0xD16A,
    bagCount: 0xD31C,
    money: 0xD346,
    curMap: 0xD35D,
    yCoord: 0xD360,
    xCoord: 0xD361,
    isInBattle: 0xD056,
    battleMon: 0xD013,
    enemyMon: 0xCFE4,
    enemyMonPartyPos: 0xCFE7,
    enemyPartyCount: 0xD89B,
    enemyMons: 0xD8A3,
    bagSlots: 20,
    internalToDex: internalToDexYellow,
    dexOwned: 0xD2F6,
    dexSeen: 0xD309
  )

  static let yellowEurope = Gen1Config(
    id: "yellow_eu",
    displayName: "Pokémon Yellow",
    partyCount: 0xD167,
    partyMons: 0xD16F,
    bagCount: 0xD321,
    money: 0xD34B,
    curMap: 0xD362,
    yCoord: 0xD365,
    xCoord: 0xD366,
    isInBattle: 0xD05B,
    battleMon: 0xD018,
    enemyMon: 0xCFE9,
    enemyMonPartyPos: 0xCFEC,
    enemyPartyCount: 0xD8A0,
    enemyMons: 0xD8A8,
    bagSlots: 20,
    internalToDex: internalToDexYellow,
    dexOwned: 0xD2F6,
    dexSeen: 0xD309
  )

  static let red = Gen1Config(
    id: "red",
    displayName: "Pokémon Red",
    partyCount: 0xD163,
    partyMons: 0xD16B,
    bagCount: 0xD31D,
    money: 0xD347,
    curMap: 0xD35E,
    yCoord: 0xD361,
    xCoord: 0xD362,
    isInBattle: 0xD057,
    battleMon: 0xD014,
    enemyMon: 0xCFE5,
    enemyMonPartyPos: 0xCFE8,
    enemyPartyCount: 0xD89C,
    enemyMons: 0xD8A4,
    bagSlots: 20,
    internalToDex: internalToDexYellow,
    dexOwned: 0xD2F7,
    dexSeen: 0xD30A
  )

  static var blue: Gen1Config {
    var c = red
    c.id = "blue"
    c.displayName = "Pokémon Blue"
    return c
  }

  /// Detect from GB cart title / manufacturer (0x134 / 0x13F).
  static func detect(title: String, manufacturer: String) -> Gen1Config? {
    let t = title.uppercased()
    let m = manufacturer.uppercased()
    if ["APSD", "APSF", "APSI", "APSS"].contains(m) {
      var c = yellowEurope
      c.displayName = "Pokémon Yellow (\(m))"
      return c
    }
    if t.contains("YELLOW") || t.hasPrefix("POKEMON Y") {
      return yellow
    }
    // Japanese Green (Midori) header is "POKEMON GREEN" — no dedicated JP RAM map yet;
    // English Red addresses are a best-effort companion (play + save editor still work).
    if t.contains("GREEN") || t.contains("MIDORI") {
      var c = red
      c.id = "green"
      c.displayName = "Pokémon Green (best-effort)"
      return c
    }
    if t.contains("RED") && !t.contains("FIRED") {
      var c = red
      if t.contains("PURE") { c.displayName = "PureRed (best-effort Red RAM)" }
      return c
    }
    if t.contains("BLUE") {
      var c = blue
      if t.contains("PURE") { c.displayName = "PureBlue (best-effort Blue RAM)" }
      return c
    }
    // Recharged Yellow / Yellow Legacy / other Yellow forks often keep Yellow's title fragment.
    if t.contains("POKEMON") && (t.contains("YEL") || t.contains("Pik")) {
      return yellow
    }
    return nil
  }
}
