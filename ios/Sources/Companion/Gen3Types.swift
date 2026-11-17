import Foundation

// Value types for the Gen 3 companion (PocketDex). Ported from PokeDaisy's Telemetry.kt / Gen3Mon.kt.

enum Gen3Const {
  static let monStructSize = 100
  static let boxMonSize = 80
  static let partySize = 6
  static let numMoves = 4
  static let battlePokemonSize = 0x58
  static let expansionBattlePokemonSize = 0x60
  /// Default `shinyValue < 8` check of vanilla FireRed / Emerald (and CFRU).
  static let shinyBelow = 8
}

/// `struct BattlePokemon` field map — vanilla/CFRU vs pokeemerald-expansion.
struct BattleMonLayout: Equatable {
  var size: Int
  var species: Int
  var moves: Int
  var pp: Int
  var hp: Int
  var level: Int
  var maxHp: Int
  var item: Int
  var status1: Int
  var personality: Int
  var otId: Int

  /// FireRed / Emerald / CFRU (Unbound, Radical Red, Gaia, …).
  static let vanilla = BattleMonLayout(
    size: Gen3Const.battlePokemonSize,
    species: 0x00, moves: 0x0C, pp: 0x24,
    hp: 0x28, level: 0x2A, maxHp: 0x2C, item: 0x2E,
    status1: 0x4C, personality: 0x48, otId: 0x54
  )

  /// pokeemerald-expansion 0x60-byte layout (Seaglass, Lazarus, Imperium, …).
  static let expansion = BattleMonLayout(
    size: Gen3Const.expansionBattlePokemonSize,
    species: 0x00, moves: 0x0C, pp: 0x25,
    hp: 0x2A, level: 0x2C, maxHp: 0x2E, item: 0x30,
    status1: 0x50, personality: 0x4C, otId: 0x58
  )

  /// Heart and Soul 0x88-byte BattlePokemon (Android NATIVE_HEART_AND_SOUL).
  static let heartAndSoul = BattleMonLayout(
    size: 0x88,
    species: 0x00, moves: 0x0C, pp: 0x25,
    hp: 0x2A, level: 0x2C, maxHp: 0x2E, item: 0x30,
    status1: 0x50, personality: -1, otId: -1
  )

  /// SoulGold GBA 0x98-byte expansion battle mon (SOULGOLD_BATTLE_MON).
  static let soulGold = BattleMonLayout(
    size: 0x98,
    species: 0x00, moves: 0x0C, pp: 0x25,
    hp: 0x2A, level: 0x2C, maxHp: 0x2E, item: 0x30,
    status1: 0x54, personality: 0x50, otId: 0x88
  )
}

/// Party struct decode path — vanilla encrypted box vs hack-specific layouts.
enum PartyMonKind: Equatable {
  case vanilla
  /// SoulGold plaintext 96-byte party (species masked, optional packed attacks).
  case soulGold(packedAttacks: Bool)
  /// R.O.W.E. 0x4C-byte bit-packed plaintext.
  case rowe
}

/// Stable, game-independent bag pocket ids (NOT either game's engine constants; see Telemetry.kt).
enum Gen3Pocket {
  static let items = 0
  static let pokeBalls = 1
  static let tmHm = 2
  static let berries = 3
  static let keyItems = 4

  static let ordered: [Int] = [items, pokeBalls, tmHm, berries, keyItems]

  static func name(_ pocket: Int) -> String {
    switch pocket {
    case items: return "Items"
    case pokeBalls: return "Poké Balls"
    case tmHm: return "TMs & HMs"
    case berries: return "Berries"
    case keyItems: return "Key Items"
    default: return "Pocket \(pocket)"
    }
  }

  static func symbol(_ pocket: Int) -> String {
    switch pocket {
    case items: return "bag.fill"
    case pokeBalls: return "circle.circle.fill"
    case tmHm: return "opticaldisc.fill"
    case berries: return "leaf.fill"
    case keyItems: return "key.fill"
    default: return "bag"
    }
  }
}

enum Gen3Stat {
  static let hp = 0
  static let attack = 1
  static let defense = 2
  static let speed = 3
  static let spAttack = 4
  static let spDefense = 5
  static let names = ["HP", "Atk", "Def", "Spe", "SpA", "SpD"]
}

/// The 25 natures in game order (PID % 25). Each raises stat index (n / 5 + 1) and lowers (n % 5 + 1)
/// in Atk, Def, Spe, SpA, SpD order; equal indices are neutral.
enum Gen3Natures {
  static let names: [String] = [
    "Hardy", "Lonely", "Brave", "Adamant", "Naughty",
    "Bold", "Docile", "Relaxed", "Impish", "Lax",
    "Timid", "Hasty", "Serious", "Jolly", "Naive",
    "Modest", "Mild", "Quiet", "Bashful", "Rash",
    "Calm", "Gentle", "Sassy", "Careful", "Quirky",
  ]

  static func name(_ nature: Int) -> String {
    names.indices.contains(nature) ? names[nature] : "Nature #\(nature)"
  }

  /// Stat index (1...5 into [Gen3Stat.names]) a nature raises, or nil when neutral.
  static func raises(_ nature: Int) -> Int? {
    guard nature >= 0, nature < 25 else { return nil }
    let up = nature / 5, down = nature % 5
    return up == down ? nil : up + 1
  }

  static func lowers(_ nature: Int) -> Int? {
    guard nature >= 0, nature < 25 else { return nil }
    let up = nature / 5, down = nature % 5
    return up == down ? nil : down + 1
  }
}

/// Smart nature grades from a species' base stats (Atk / Def / Spe / SpA / SpD).
/// Green = boosts a primary offensive/speed stat and cuts a dump stat; gray = neutral;
/// red = cuts a primary or boosts a dump.
enum Gen3NatureGrade: String {
  case best, neutral, poor

  var label: String {
    switch self {
    case .best: return "Best"
    case .neutral: return "Neutral"
    case .poor: return "Bad"
    }
  }
}

enum Gen3NatureAdvice {
  /// Grade every nature 0…24 for `baseStats` `[HP, Atk, Def, Spe, SpA, SpD]`.
  static func grade(_ nature: Int, baseStats: [Int]) -> Gen3NatureGrade {
    guard baseStats.count >= 6 else { return .neutral }
    guard let up = Gen3Natures.raises(nature), let down = Gen3Natures.lowers(nature) else {
      return .neutral
    }
    let prefer = preferred(baseStats: baseStats)
    let raisesGood = prefer.raise.contains(up)
    let lowersGood = prefer.lower.contains(down)
    let raisesDump = prefer.lower.contains(up)
    let lowersPrimary = prefer.raise.contains(down)

    if lowersPrimary || raisesDump { return .poor }
    if raisesGood && lowersGood { return .best }
    if raisesGood { return .best } // e.g. Adamant −Def on a physical sweeper
    return .poor
  }

  static func grade(nature: Int, species: Int, tables: Gen3Tables) -> Gen3NatureGrade {
    grade(nature, baseStats: Gen3BaseStats.stats(species: species, tables: tables))
  }

  /// Natures sorted best → neutral → poor, then by name.
  static func rankedNatures(species: Int, tables: Gen3Tables) -> [Int] {
    let base = Gen3BaseStats.stats(species: species, tables: tables)
    return (0..<25).sorted { a, b in
      let ga = grade(a, baseStats: base), gb = grade(b, baseStats: base)
      if ga != gb {
        return rank(ga) < rank(gb)
      }
      return Gen3Natures.name(a) < Gen3Natures.name(b)
    }
  }

  private static func rank(_ g: Gen3NatureGrade) -> Int {
    switch g {
    case .best: return 0
    case .neutral: return 1
    case .poor: return 2
    }
  }

  /// Preferred raise / lower Gen3Stat indices (1 Atk … 5 SpD) from base stats.
  private static func preferred(baseStats: [Int]) -> (raise: Set<Int>, lower: Set<Int>) {
    let atk = baseStats[1], def = baseStats[2], spe = baseStats[3]
    let spa = baseStats[4], spd = baseStats[5]
    var raise = Set<Int>()
    var lower = Set<Int>()

    // Primary attacking side.
    if atk > spa + 5 {
      raise.insert(Gen3Stat.attack)
      lower.insert(Gen3Stat.spAttack)
    } else if spa > atk + 5 {
      raise.insert(Gen3Stat.spAttack)
      lower.insert(Gen3Stat.attack)
    } else {
      // Mixed — either attack boost is fine; still OK to drop the slightly weaker one.
      raise.insert(Gen3Stat.attack)
      raise.insert(Gen3Stat.spAttack)
      if atk <= spa { lower.insert(Gen3Stat.attack) }
      if spa <= atk { lower.insert(Gen3Stat.spAttack) }
    }

    // Speed: prefer +Spe when it is a real asset for this mon.
    let peakOffense = max(atk, spa)
    if spe >= 70 || spe + 10 >= peakOffense {
      raise.insert(Gen3Stat.speed)
    } else if spe <= 40 {
      lower.insert(Gen3Stat.speed)
    }

    // Prefer cutting the weaker defense (never both as "primary").
    if def <= spd { lower.insert(Gen3Stat.defense) }
    else { lower.insert(Gen3Stat.spDefense) }

    // Don't mark a preferred raise as a preferred lower.
    lower.subtract(raise)
    return (raise, lower)
  }
}

struct MonStats: Equatable {
  /// HP, Atk, Def, Spe, SpA, SpD (PokeDaisy's in-RAM order: HP, ATTACK, DEFENSE, SPEED, SP.ATK, SP.DEF).
  var ivs: [Int]
  var evs: [Int]
  var nature: Int
  /// Computed stats from the party struct (max HP first). Empty when unavailable.
  var stats: [Int]
}

struct Mon: Identifiable, Equatable {
  var id: Int { slot }

  var slot: Int = 0
  var species: Int
  var level: Int
  var hp: Int
  var maxHp: Int
  var status: UInt32
  var moves: [Int]
  var pp: [Int]
  var exp: UInt32?
  var personality: UInt32
  var otId: UInt32
  var stats: MonStats?
  var heldItem: Int
  var nickname: String?
  var shiny: Bool
  var isEgg: Bool

  /// Status1: bits 0-2 sleep counter, 3 poison, 4 burn, 5 freeze, 6 paralysis, 7 bad poison.
  var statusLabel: String? {
    if status & 0x07 != 0 { return "SLP" }
    if status & 0x88 != 0 { return "PSN" }
    if status & 0x10 != 0 { return "BRN" }
    if status & 0x20 != 0 { return "FRZ" }
    if status & 0x40 != 0 { return "PAR" }
    return nil
  }
}

/// A foe from gBattleMons (the live battler, not the full encrypted enemy party).
struct BattleMon: Equatable {
  var species: Int
  var level: Int
  var hp: Int
  var maxHp: Int
  var moves: [Int]
  var pp: [Int]
  var item: Int
  var status1: UInt32
  var shiny: Bool
}

struct BagItem: Identifiable, Equatable {
  var id: String { "\(pocket)-\(itemId)-\(index)" }
  var itemId: Int
  var quantity: Int
  var pocket: Int
  var index: Int = 0
}

struct DexSummary: Equatable {
  var seen: Int
  var caught: Int
  /// Game Pokédex numbers (1-based) seen / caught. Retail = National; Seaglass = Hoenn-first.
  var seenSet: Set<Int>
  var caughtSet: Set<Int>
  var total: Int
  var nationalUnlocked: Bool
}

/// Which species-id table / name set a ROM uses.
enum Gen3Tables {
  /// Retail FireRed / Emerald: Gen 3 internal species ids (Hoenn's start at 277).
  case retail
  /// Unbound's own expanded table.
  case unbound
  /// National Dex numbers (Gen 4/5 party species, Seaglass-style tables).
  case national
  /// Modern Emerald v3.6: Emerald ids through 411, then 50 extras (Sylveon=444, …); own items/moves.
  case modernEmerald
  /// Gen 1 Yellow / Red / Blue type ids, moves, and chart (Gust = Normal, Ghost vs Psychic immune).
  case yellow
  /// Gen 2 Crystal / Gold / Silver type ids, moves, and chart (Steel / Dark era).
  case crystal
  /// Polished Crystal's remapped move / species / type ids (Fairy included).
  case polished
}

struct CompanionSnapshot: Equatable {
  var gameName: String
  var tables: Gen3Tables
  /// NativeConfig.id — used for Seaglass-style dex-number remaps.
  var configId: String = ""
  var frameCounter: UInt32 = 0

  var party: [Mon] = []
  var bag: [BagItem] = []
  var money: Int?

  var mapGroup: Int = 0
  var mapNum: Int = 0
  var mapSec: Int = 0
  var mapSecName: String?
  var x: Int = 0
  var y: Int = 0

  var inBattle: Bool = false
  var isDouble: Bool = false
  var isTrainer: Bool?
  /// gBattleMons by battler position (0 = player left, 1 = foe left, 2 = player right, 3 = foe right).
  var battleMons: [BattleMon?] = [nil, nil, nil, nil]
  /// The foe's whole party when a gEnemyParty address is known (trainer battles).
  var foeParty: [Mon] = []

  var dex: DexSummary?

  var partyCount: Int { party.count }

  var bagByPocket: [(pocket: Int, items: [BagItem])] {
    Gen3Pocket.ordered.compactMap { p in
      let items = bag.filter { $0.pocket == p }
      return items.isEmpty ? nil : (p, items)
    }
  }

  static func == (lhs: CompanionSnapshot, rhs: CompanionSnapshot) -> Bool {
    lhs.gameName == rhs.gameName
      && lhs.party == rhs.party
      && lhs.bag == rhs.bag
      && lhs.money == rhs.money
      && lhs.mapGroup == rhs.mapGroup && lhs.mapNum == rhs.mapNum && lhs.mapSec == rhs.mapSec
      && lhs.x == rhs.x && lhs.y == rhs.y
      && lhs.inBattle == rhs.inBattle && lhs.isDouble == rhs.isDouble && lhs.isTrainer == rhs.isTrainer
      && lhs.battleMons == rhs.battleMons
      && lhs.foeParty == rhs.foeParty
      && lhs.dex == rhs.dex
  }
}
