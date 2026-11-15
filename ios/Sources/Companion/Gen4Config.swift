import Foundation

/// Minimal Gen 4 battle layout (PokeDaisy `Gen4Battle`) — enough for live move tips.
struct Gen4BattleLayout {
  var fieldSystemPtr: UInt32
  var battleTemplate: UInt32
  var offChild: Int = 4
  var offAppData: Int = 0x1C
  var offBattleType: Int = 0x2C
  var offBattleCtx: Int = 0x30
  var offBattleMons: Int = 0x2D40
  var battleMonSize: Int = 0xC0
}

struct Gen4Config {
  var id: String
  var displayName: String
  var saveDataPtr: UInt32
  var bodyOff: Int
  var trainerOff: Int
  var partyOff: Int
  var bagOff: Int
  var locationOff: Int
  var pokedexOff: Int
  var nationalDexOff: Int
  var dexFlagBytes: Int
  var pocketSizes: [Int]
  /// Companion pocket id per save pocket (items / key / TM / mail→items / medicine→items / berries / balls / battle→items).
  var savePockets: [Int]
  var battle: Gen4BattleLayout
  var maxSpecies: Int = 493
}

enum Gen4ConfigStore {
  private static let pocketItems = Gen3Pocket.items
  private static let pocketKey = Gen3Pocket.keyItems
  private static let pocketTM = Gen3Pocket.tmHm
  private static let pocketBalls = Gen3Pocket.pokeBalls
  private static let pocketBerries = Gen3Pocket.berries

  /// HeartGold / SoulSilver family (USA defaults; DE/FR shift globals).
  private static func heartGoldFamily(
    id: String,
    displayName: String,
    saveDataPtr: UInt32 = 0x021D2228,
    fieldSystemPtr: UInt32 = 0x021D4158,
    battleTemplate: UInt32 = 0x020FA484
  ) -> Gen4Config {
    Gen4Config(
      id: id,
      displayName: displayName,
      saveDataPtr: saveDataPtr,
      bodyOff: 0x10,
      trainerOff: 0x64,
      partyOff: 0x90,
      bagOff: 0x644,
      locationOff: 0x1234,
      pokedexOff: 0x12B8,
      nationalDexOff: 0x337,
      dexFlagBytes: 0x40,
      pocketSizes: [165, 50, 101, 12, 40, 64, 24, 30],
      savePockets: [
        pocketItems, pocketKey, pocketTM, pocketItems,
        pocketItems, pocketBerries, pocketBalls, pocketItems
      ],
      battle: Gen4BattleLayout(fieldSystemPtr: fieldSystemPtr, battleTemplate: battleTemplate)
    )
  }

  private static func platinumFamily(
    id: String,
    displayName: String,
    saveDataPtr: UInt32 = 0x021C0794,
    fieldSystemPtr: UInt32 = 0x021C07DC,
    battleTemplate: UInt32 = 0x020EA358
  ) -> Gen4Config {
    Gen4Config(
      id: id,
      displayName: displayName,
      saveDataPtr: saveDataPtr,
      bodyOff: 0x14,
      trainerOff: 0x68,
      partyOff: 0x98,
      bagOff: 0x630,
      locationOff: 0x1280,
      pokedexOff: 0x1328,
      nationalDexOff: 0x31B,
      dexFlagBytes: 0x40,
      pocketSizes: [165, 50, 100, 12, 40, 64, 15, 30],
      savePockets: [
        pocketItems, pocketKey, pocketTM, pocketItems,
        pocketItems, pocketBerries, pocketBalls, pocketItems
      ],
      battle: Gen4BattleLayout(fieldSystemPtr: fieldSystemPtr, battleTemplate: battleTemplate)
    )
  }

  static let heartGoldUS = heartGoldFamily(id: "heartgold", displayName: "Pokémon HeartGold")
  static let soulSilverUS = heartGoldFamily(id: "soulsilver", displayName: "Pokémon SoulSilver")

  static let heartGoldDE = heartGoldFamily(
    id: "heartgold_de", displayName: "Pokémon HeartGold (DE)",
    saveDataPtr: 0x021D2208, fieldSystemPtr: 0x021D4138, battleTemplate: 0x020FA438
  )
  static let soulSilverDE = heartGoldFamily(
    id: "soulsilver_de", displayName: "Pokémon SoulSilver (DE)",
    saveDataPtr: 0x021D2208, fieldSystemPtr: 0x021D4138, battleTemplate: 0x020FA438
  )
  static let heartGoldFR = heartGoldFamily(
    id: "heartgold_fr", displayName: "Pokémon HeartGold (FR)",
    saveDataPtr: 0x021D2248, fieldSystemPtr: 0x021D4178, battleTemplate: 0x020FA468
  )
  static let soulSilverFR = heartGoldFamily(
    id: "soulsilver_fr", displayName: "Pokémon SoulSilver (FR)",
    saveDataPtr: 0x021D2248, fieldSystemPtr: 0x021D4178, battleTemplate: 0x020FA468
  )

  static let platinumUS = platinumFamily(id: "platinum", displayName: "Pokémon Platinum")
  static let platinumFR = platinumFamily(
    id: "platinum_fr", displayName: "Pokémon Platinum (FR)",
    saveDataPtr: 0x021C0974, fieldSystemPtr: 0x021C09BC, battleTemplate: 0x020EA3E0
  )

  static let heartGoldES = heartGoldFamily(
    id: "heartgold_es", displayName: "Pokémon HeartGold (ES)",
    saveDataPtr: 0x021D2248, fieldSystemPtr: 0x021D4178, battleTemplate: 0x020FA46C
  )
  static let soulSilverES = heartGoldFamily(
    id: "soulsilver_es", displayName: "Pokémon SoulSilver (ES)",
    saveDataPtr: 0x021D2268, fieldSystemPtr: 0x021D4198, battleTemplate: 0x020FA474
  )
  static let heartGoldIT = heartGoldFamily(
    id: "heartgold_it", displayName: "Pokémon HeartGold (IT)",
    saveDataPtr: 0x021D21C8, fieldSystemPtr: 0x021D40F8, battleTemplate: 0x020FA3FC
  )
  static let soulSilverIT = heartGoldFamily(
    id: "soulsilver_it", displayName: "Pokémon SoulSilver (IT)",
    saveDataPtr: 0x021D21C8, fieldSystemPtr: 0x021D40F8, battleTemplate: 0x020FA3FC
  )
  static let heartGoldKR = heartGoldFamily(
    id: "heartgold_kr", displayName: "Pokémon HeartGold (KR)",
    saveDataPtr: 0x021D2C28, fieldSystemPtr: 0x021D4B58, battleTemplate: 0x020FAB30
  )
  static let soulSilverKR = heartGoldFamily(
    id: "soulsilver_kr", displayName: "Pokémon SoulSilver (KR)",
    saveDataPtr: 0x021D2C28, fieldSystemPtr: 0x021D4B58, battleTemplate: 0x020FAB28
  )
  static let heartGoldJP = heartGoldFamily(
    id: "heartgold_jp", displayName: "Pokémon HeartGold (JP)",
    saveDataPtr: 0x021D1768, fieldSystemPtr: 0x021D3698, battleTemplate: 0x020F9C34
  )
  static let soulSilverJP = heartGoldFamily(
    id: "soulsilver_jp", displayName: "Pokémon SoulSilver (JP)",
    saveDataPtr: 0x021D1768, fieldSystemPtr: 0x021D3698, battleTemplate: 0x020F9C34
  )

  /// Detect from NDS game code (4 chars) — mirrors `PK_NDS_PORTS4` (no silent US fallback for JP/ES/…).
  static func detect(code: String) -> Gen4Config? {
    switch code.uppercased() {
    case "IPKE": return heartGoldUS
    case "IPGE": return soulSilverUS
    case "IPKD": return heartGoldDE
    case "IPGD": return soulSilverDE
    case "IPKF": return heartGoldFR
    case "IPGF": return soulSilverFR
    case "IPKS": return heartGoldES
    case "IPGS": return soulSilverES
    case "IPKI": return heartGoldIT
    case "IPGI": return soulSilverIT
    case "IPKK": return heartGoldKR
    case "IPGK": return soulSilverKR
    case "IPKJ": return heartGoldJP
    case "IPGJ": return soulSilverJP
    case "CPUE": return platinumUS
    case "CPUF": return platinumFR
    default:
      let c = code.uppercased()
      if c.hasPrefix("CPU") { return platinumUS }
      return nil
    }
  }
}
