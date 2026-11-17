import Foundation

/// Gen 5 battle proc layout (PokeDaisy `Gen5Battle`) — enough for live move tips.
struct Gen5BattleLayout {
  var gameSystemPtr: UInt32
  var offProcSys: Int = 0x08
  var offCurrentProc: Int = 0x08
  var offProcOverlay: Int = 0x04
  var battleOverlay: Int
  var offProcParam: Int = 0x10
  var offProcWork: Int = 0x14
  var offCompetitor: Int = 0x00
  var offRule: Int = 0x04
  var offPlayerParty: Int = 0x24
  var offFoeParty: Int = 0x28
  var offParties: Int = 0xCC
  var partyStride: Int = 0x1C
}

/// Where one Gen 5 cart keeps the companion’s save image + battle hooks (Android `Gen5Config`).
struct Gen5Config {
  var id: String
  var displayName: String
  var saveControlPtr: UInt32
  var offBackupSystem: Int = 0x10
  var offImage: Int = 0x34
  var imageSize: Int
  var partyOff: Int = 0x18E00
  var trainerOff: Int = 0x19400
  var bagOff: Int = 0x18400
  var pocketSizes: [Int] = [310, 83, 109, 48, 64]
  var savePockets: [Int]
  var moneyOff: Int
  var locationOff: Int = 0x19500
  var gameSystemPtr: UInt32
  var offGameData: Int = 0x1C
  var offZone: Int = 0x114
  var pokedexOff: Int
  var maxSpecies: Int = 649
  var battle: Gen5BattleLayout
}

enum Gen5ConfigStore {
  private static let pocketItems = Gen3Pocket.items
  private static let pocketKey = Gen3Pocket.keyItems
  private static let pocketTM = Gen3Pocket.tmHm
  private static let pocketMedicine = Gen3Pocket.items
  private static let pocketBerries = Gen3Pocket.berries

  private static let pockets = [
    pocketItems, pocketKey, pocketTM, pocketMedicine, pocketBerries
  ]

  /// Pokémon Black (USA / Europe, IRBO).
  static let blackUS = Gen5Config(
    id: "black",
    displayName: "Pokémon Black",
    saveControlPtr: 0x020A7298,
    imageSize: 0x24000,
    savePockets: pockets,
    moneyOff: 0x21200,
    gameSystemPtr: 0x02146248,
    pokedexOff: 0x21600,
    battle: Gen5BattleLayout(gameSystemPtr: 0x02146248, battleOverlay: 93)
  )

  /// Pokémon White (USA / Europe, IRAO).
  static let whiteUS = Gen5Config(
    id: "white",
    displayName: "Pokémon White",
    saveControlPtr: 0x020A72B8,
    imageSize: 0x24000,
    savePockets: pockets,
    moneyOff: 0x21200,
    gameSystemPtr: 0x02146268,
    pokedexOff: 0x21600,
    battle: Gen5BattleLayout(gameSystemPtr: 0x02146268, battleOverlay: 93)
  )

  /// Pokémon Black 2 (USA / Europe, IREO).
  static let black2US = Gen5Config(
    id: "black2",
    displayName: "Pokémon Black 2",
    saveControlPtr: 0x0209A338,
    imageSize: 0x26000,
    savePockets: pockets,
    moneyOff: 0x21100,
    gameSystemPtr: 0x021410F4,
    pokedexOff: 0x21400,
    battle: Gen5BattleLayout(gameSystemPtr: 0x021410F4, battleOverlay: 167)
  )

  /// Pokémon White 2 (USA / Europe, IRDO).
  static let white2US = Gen5Config(
    id: "white2",
    displayName: "Pokémon White 2",
    saveControlPtr: 0x0209A378,
    imageSize: 0x26000,
    savePockets: pockets,
    moneyOff: 0x21100,
    gameSystemPtr: 0x02141134,
    pokedexOff: 0x21400,
    battle: Gen5BattleLayout(gameSystemPtr: 0x02141134, battleOverlay: 167)
  )

  /// Detect from NDS game code (4 chars).
  static func detect(code: String) -> Gen5Config? {
    switch code.uppercased() {
    case "IRBO": return blackUS
    case "IRAO": return whiteUS
    case "IREO": return black2US
    case "IRDO": return white2US
    // Common language ports — same save layout as US with shifted statics (Android DsPorts).
    case "IRBF": // Black FR
      var c = blackUS
      c.id = "black_fr"; c.displayName = "Pokémon Black (FR)"
      c.saveControlPtr = 0x020A7218; c.gameSystemPtr = 0x021461C8
      c.battle.gameSystemPtr = 0x021461C8
      return c
    case "IRAF":
      var c = whiteUS
      c.id = "white_fr"; c.displayName = "Pokémon White (FR)"
      c.saveControlPtr = 0x020A7238; c.gameSystemPtr = 0x021461E8
      c.battle.gameSystemPtr = 0x021461E8
      return c
    default:
      let c = code.uppercased()
      if c.hasPrefix("IRE") { return black2US }
      if c.hasPrefix("IRD") { return white2US }
      if c.hasPrefix("IRB") { return blackUS }
      if c.hasPrefix("IRA") { return whiteUS }
      return nil
    }
  }
}
