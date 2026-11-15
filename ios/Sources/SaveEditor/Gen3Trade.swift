import Foundation

/// One side of a Gen 3 PC trade (a save the player picked, plus its ROM game code).
struct Gen3TradeSide {
  var label: String
  var editor: Gen3SaveEditor
  /// ROM header game code (BPRE, AXVE, …). English games end in `E`.
  var gameCode: String

  var format: Gen3SaveFormat { editor.file.format }
  var english: Bool { gameCode.uppercased().hasSuffix("E") }
}

struct Gen3TradeRefused: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

struct Gen3TradeEvolution {
  let species: Int
  let item: Int   // 0 = any trade; otherwise must hold this item (consumed)
  let into: Int
}

/// PC-box trading between two Gen 3 saves (pret trade.c / PokeDaisy Gen3Trade).
enum Gen3Trade {
  static let SPECIES_MEW = 151
  static let SPECIES_DEOXYS = 410
  static let ITEM_EVERSTONE = 195
  static let ITEM_ENIGMA_BERRY = 175
  static let MAIL_ITEMS = 121...132
  static let KANTO_COUNT = 151
  static let HOENN_DEX_COUNT = 202
  private static let EOS: UInt8 = 0xFF

  static let tradeEvolutions: [Gen3TradeEvolution] = [
    .init(species: 61, item: 187, into: 186),
    .init(species: 64, item: 0, into: 65),
    .init(species: 67, item: 0, into: 68),
    .init(species: 75, item: 0, into: 76),
    .init(species: 79, item: 187, into: 199),
    .init(species: 93, item: 0, into: 94),
    .init(species: 95, item: 199, into: 208),
    .init(species: 117, item: 201, into: 230),
    .init(species: 123, item: 199, into: 212),
    .init(species: 137, item: 218, into: 233),
    .init(species: 373, item: 192, into: 374),
    .init(species: 373, item: 193, into: 375),
  ]

  /// Hoenn Dex number per internal species (non-Hoenn are > 202). Port of SpeciesDexGen.kt.
  static let speciesHoennDex: [Int] = [
    0, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221,
    222, 223, 224, 225, 226, 156, 157, 112, 113, 227, 228, 229, 230, 231, 232, 233, 234, 153, 154, 138,
    139, 63, 64, 88, 89, 90, 235, 236, 237, 238, 239, 240, 241, 242, 158, 159, 243, 244, 245, 246,
    247, 248, 249, 39, 40, 41, 73, 74, 75, 250, 251, 252, 66, 67, 57, 58, 59, 253, 254, 255,
    256, 82, 83, 257, 92, 93, 258, 259, 106, 107, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269,
    84, 85, 270, 271, 272, 273, 274, 275, 276, 108, 109, 169, 170, 277, 278, 279, 184, 185, 50, 51,
    143, 144, 280, 281, 282, 283, 284, 167, 285, 52, 53, 286, 287, 288, 289, 290, 291, 292, 293, 294,
    295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314,
    315, 316, 317, 318, 319, 320, 321, 322, 323, 65, 181, 182, 155, 324, 137, 325, 326, 162, 163, 327,
    328, 329, 91, 55, 56, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344,
    345, 346, 161, 164, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 168, 357, 358, 359, 103, 104,
    360, 361, 180, 362, 363, 364, 365, 115, 366, 367, 186, 165, 166, 368, 369, 370, 371, 372, 373, 374,
    375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394,
    395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 1, 2, 3,
    4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    24, 42, 43, 44, 25, 26, 34, 35, 114, 27, 28, 32, 33, 99, 100, 61, 62, 145, 131, 132,
    60, 105, 68, 127, 128, 183, 129, 130, 140, 141, 97, 98, 116, 117, 118, 48, 49, 78, 79, 101,
    102, 173, 174, 175, 119, 120, 171, 172, 125, 126, 54, 110, 111, 80, 81, 69, 76, 77, 121, 122,
    160, 148, 149, 94, 36, 37, 38, 95, 96, 150, 45, 46, 47, 176, 177, 178, 152, 146, 147, 124,
    123, 179, 70, 71, 72, 142, 86, 87, 133, 134, 135, 136, 29, 30, 31, 187, 188, 189, 190, 191,
    192, 193, 194, 195, 198, 199, 200, 196, 197, 201, 202, 151,
  ]

  static func inRegionalDex(species: Int, format: Gen3SaveFormat) -> Bool {
    if format.kanto { return (1...KANTO_COUNT).contains(species) }
    guard species >= 0, species < speciesHoennDex.count else { return false }
    let n = speciesHoennDex[species]
    return (1...HOENN_DEX_COUNT).contains(n)
  }

  static func linkBlocker(a: Gen3TradeSide, b: Gen3TradeSide) -> String? {
    let frlg = [a, b].filter { $0.format == .FIRERED_LEAFGREEN || $0.format == .FIRERED_CFRU }
    guard frlg.count == 1 else { return nil }
    let side = frlg[0]
    let flag = side.format.linkRsFlag
    if flag >= 0, side.editor.flag(flag) { return nil }
    return "\(side.label) links with Ruby/Sapphire/Emerald only after the Sevii Islands"
  }

  static func blocker(mon: Gen3BoxMon, from: Gen3TradeSide, to: Gen3TradeSide) -> String? {
    if mon.isEmpty { return nil }
    if mon.isBadEgg { return "A Bad Egg can't be traded" }
    if let link = linkBlocker(a: from, b: to) { return link }
    for side in [from, to] {
      if side.format == .RUBY_SAPPHIRE || side.editor.nationalDex { continue }
      if mon.isEgg { return "\(side.label) has no National Dex yet, so no eggs" }
      if !inRegionalDex(species: mon.species, format: side.format) {
        return "\(side.label) has no National Dex yet, so no #\(mon.species)"
      }
    }
    if (mon.species == SPECIES_MEW || mon.species == SPECIES_DEOXYS) && !mon.fatefulEncounter {
      return "This #\(mon.species) isn't from an event, so the games won't trade it"
    }
    if MAIL_ITEMS.contains(mon.heldItem) || mon.heldItem == ITEM_ENIGMA_BERRY {
      return "Mail and Enigma Berries stay with their save — take it off in-game first"
    }
    return nil
  }

  static func evolution(mon: Gen3BoxMon, to: Gen3TradeSide) -> Gen3TradeEvolution? {
    if mon.isEmpty || mon.isBadEgg || mon.isEgg || !to.english { return nil }
    if mon.heldItem == ITEM_EVERSTONE { return nil }
    return tradeEvolutions.first { $0.species == mon.species && ($0.item == 0 || $0.item == mon.heldItem) }
  }

  /// Sends the Pokémon at `at` into an empty slot on `dest`.
  static func send(src: Gen3TradeSide, at: BoxSlot, dest: Gen3TradeSide, to: BoxSlot, evolve: Bool = true) throws {
    let mon = src.editor.data.mon(at)
    if mon.isEmpty { throw Gen3TradeRefused("There's no Pokémon there") }
    if !dest.editor.data.mon(to).isEmpty { throw Gen3TradeRefused("That slot isn't empty") }
    if let why = blocker(mon: mon, from: src, to: dest) { throw Gen3TradeRefused(why) }
    let arriving = try arrive(mon: mon, to: dest, evolve: evolve)
    try src.editor.putRecord(at, [UInt8](repeating: 0, count: Gen3BoxMon.SIZE))
    try dest.editor.putRecord(to, arriving)
    try afterTrade(a: src, b: dest)
  }

  /// Swaps two occupied PC slots (with optional trade evolutions).
  static func swap(a: Gen3TradeSide, atA: BoxSlot, b: Gen3TradeSide, atB: BoxSlot,
                   evolveA: Bool = true, evolveB: Bool = true) throws {
    let monA = a.editor.data.mon(atA)
    let monB = b.editor.data.mon(atB)
    if monA.isEmpty || monB.isEmpty { throw Gen3TradeRefused("There's no Pokémon there") }
    if let why = blocker(mon: monA, from: a, to: b) { throw Gen3TradeRefused(why) }
    if let why = blocker(mon: monB, from: b, to: a) { throw Gen3TradeRefused(why) }
    let toB = try arrive(mon: monA, to: b, evolve: evolveA)
    let toA = try arrive(mon: monB, to: a, evolve: evolveB)
    try b.editor.putRecord(atB, toB)
    try a.editor.putRecord(atA, toA)
    try afterTrade(a: a, b: b)
  }

  private static func arrive(mon: Gen3BoxMon, to: Gen3TradeSide, evolve: Bool) throws -> [UInt8] {
    if !mon.isEgg { to.editor.markCaught(mon.species, personality: mon.personality) }
    guard let evo = evolution(mon: mon, to: to), evolve else { return mon.encode() }
    let oldName = englishName(species: mon.species)
    let renamed = oldName != nil && nicknamePrefix(mon.nicknameBytes) == nicknamePrefix(oldName!)
    let record = mon.withChanges(
      species: evo.into,
      heldItem: evo.item != 0 ? 0 : nil,
      nickname: renamed ? englishName(species: evo.into) : nil
    )
    to.editor.markCaught(evo.into, personality: mon.personality)
    return record
  }

  private static func afterTrade(a: Gen3TradeSide, b: Gen3TradeSide) throws {
    for (side, partner) in [(a, b), (b, a)] {
      if side.format == .RUBY_SAPPHIRE && partner.format != .RUBY_SAPPHIRE && !side.editor.nationalDex {
        try side.editor.enableNationalDex()
      }
    }
  }

  private static func nicknamePrefix(_ b: [UInt8]) -> [UInt8] {
    Array(b.prefix { $0 != EOS })
  }

  /// Caps English species name in the Western Gen 3 charset, or nil.
  static func englishName(species: Int) -> [UInt8]? {
    let name = Gen3Names.species(species, tables: .retail).uppercased()
    guard !name.isEmpty, name.first != "#" else { return nil }
    var out = [UInt8](repeating: 0, count: Gen3BoxMon.NICKNAME_BYTES)
    guard name.count <= out.count else { return nil }
    for (i, ch) in name.enumerated() {
      guard let code = western[ch] else { return nil }
      out[i] = UInt8(code)
    }
    if name.count < out.count { out[name.count] = EOS }
    return out
  }

  private static let western: [Character: Int] = {
    var m: [Character: Int] = [" ": 0x00, "É": 0x1B, ".": 0xAD, "-": 0xAE, "♂": 0xB5, "♀": 0xB6, "'": 0xB4]
    for i in 0...9 { m[Character(String(i))] = 0xA1 + i }
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for (i, c) in letters.enumerated() { m[c] = 0xBB + i }
    return m
  }()
}
