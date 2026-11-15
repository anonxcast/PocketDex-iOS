import Foundation

/// Gen 4 (Diamond / Pearl, Platinum, HeartGold / SoulSilver) cartridge save editor, after PKHeX `SAV4` / `SAV4DP` /
/// `SAV4Pt` / `SAV4HGSS`.
///
/// A save is two 0x40000 partitions (a game writes the *other* one each time). Each holds a "general" block (trainer,
/// party, bag, ...) and a "storage" block (PC boxes). The general block ends in a 0x14 footer:
///
///     end-0x14 save counter (u32)   end-0x10 block counter (u32)   end-0x0C size (u32)
///     end-0x08 magic 0x20060623 (0x20070903 Korean)                end-0x02 CRC16-CCITT of the block minus its footer
///
/// (the CRC leaves out 0x14 bytes on D/P and Pt but only 0x10 on HG/SS, as PKHeX does). The active partition is the one
/// with the larger counters; edits go into it in place, so the game still loads it. Only the general block is touched
/// (party, money, trainer, bag), so only its CRC is rewritten.
struct Gen4Save {
  enum Game: CaseIterable {
    case dp, pt, hgss

    var label: String {
      switch self {
      case .dp: return "Diamond / Pearl"
      case .pt: return "Platinum"
      case .hgss: return "HeartGold / SoulSilver"
      }
    }

    var generalSize: Int {
      switch self {
      case .dp: return 0xC100
      case .pt: return 0xCF2C
      case .hgss: return 0xF628
      }
    }

    /// Bytes at the end of the general block the CRC leaves out.
    var crcFooterSize: Int { self == .hgss ? 0x10 : 0x14 }
    var trainerOff: Int { self == .pt ? 0x68 : 0x64 }
    /// First party record; the party count byte sits 4 before it.
    var partyOff: Int { self == .pt ? 0xA0 : 0x98 }
    var bagOff: Int {
      switch self {
      case .dp: return 0x624
      case .pt: return 0x630
      case .hgss: return 0x644
      }
    }

    var maxItem: Int {
      switch self {
      case .dp: return 464
      case .pt: return 467
      case .hgss: return 536
      }
    }

    /// PKHeX PlayerBag4DP / Pt / HGSS pouches (offsets from the bag's base).
    var pouches: [Gen45Pouch] {
      switch self {
      case .dp, .pt:
        return [
          Gen45Pouch(off: 0x000, slots: 165, pocket: .items),
          Gen45Pouch(off: 0x294, slots: 50, pocket: .key, maxQuantity: 1),
          Gen45Pouch(off: 0x35C, slots: 100, pocket: .tmhm, maxQuantity: 99, isTMHM: true),
          Gen45Pouch(off: 0x4EC, slots: 12, pocket: .items),
          Gen45Pouch(off: 0x51C, slots: 40, pocket: .items),
          Gen45Pouch(off: 0x5BC, slots: 64, pocket: .berries),
          Gen45Pouch(off: 0x6BC, slots: 15, pocket: .balls),
          Gen45Pouch(off: 0x6F8, slots: 30, pocket: .items),
        ]
      case .hgss:
        return [
          Gen45Pouch(off: 0x000, slots: 165, pocket: .items),
          Gen45Pouch(off: 0x294, slots: 50, pocket: .key, maxQuantity: 1),
          Gen45Pouch(off: 0x35C, slots: 101, pocket: .tmhm, maxQuantity: 99, isTMHM: true),
          Gen45Pouch(off: 0x4F0, slots: 12, pocket: .items),
          Gen45Pouch(off: 0x520, slots: 40, pocket: .items),
          Gen45Pouch(off: 0x5C0, slots: 64, pocket: .berries),
          Gen45Pouch(off: 0x6C0, slots: 24, pocket: .balls),
          Gen45Pouch(off: 0x720, slots: 30, pocket: .items),
        ]
      }
    }
  }

  static let partitionSize = 0x40000
  static let minSize = 0x80000
  static let maxParty = 6
  static let partyMonSize = PokeCrypto.size4Party
  static let maxMoney = 999_999
  static let maxCoins = 50_000
  static let magics: Set<Int> = [0x2006_0623, 0x2007_0903]

  let game: Game
  /// 0 or 1: the partition being edited (the one the game would load).
  let partition: Int
  private(set) var bytes: [UInt8]

  /// Start of the active general block.
  var base: Int { partition * Gen4Save.partitionSize }

  // MARK: Parse

  static func parse(_ data: Data) throws -> Gen4Save {
    guard data.count >= minSize else {
      throw Gen45SaveError("Gen 4 save too small (\(data.count) bytes, expected \(minSize))")
    }
    let b = [UInt8](data)
    for game in Game.allCases {
      let valid = (0...1).filter { footerValid(b, game: game, partition: $0) }
      guard !valid.isEmpty else { continue }
      let pick = valid.count == 1 ? valid[0] : activePartition(b, game: game)
      let save = Gen4Save(game: game, partition: pick, bytes: b)
      try save.validateParty()
      return save
    }
    throw Gen45SaveError("Not a Gen 4 save (no D/P, Pt or HG/SS block footer found)")
  }

  private init(game: Game, partition: Int, bytes: [UInt8]) {
    self.game = game
    self.partition = partition
    self.bytes = bytes
  }

  private static func footerValid(_ b: [UInt8], game: Game, partition: Int) -> Bool {
    let end = partition * partitionSize + game.generalSize
    guard end <= b.count else { return false }
    return saveU32(b, end - 0xC) == game.generalSize && magics.contains(saveU32(b, end - 0x8))
  }

  /// SAV4BlockDetection.CompareFooters on the two general blocks: bigger save counter, then bigger block counter.
  private static func activePartition(_ b: [UInt8], game: Game) -> Int {
    let o1 = game.generalSize - 0x14
    let o2 = o1 + partitionSize
    let major = compareCounters(saveU32(b, o1), saveU32(b, o2))
    if major != 2 { return major }
    return compareCounters(saveU32(b, o1 + 4), saveU32(b, o2 + 4)) == 1 ? 1 : 0
  }

  /// 0 first is newer, 1 second is newer, 2 same.
  private static func compareCounters(_ c1: Int, _ c2: Int) -> Int {
    let max = 0xFFFF_FFFF
    if c1 == max && c2 != max - 1 { return 1 }
    if c2 == max && c1 != max - 1 { return 0 }
    if c1 > c2 { return 0 }
    if c1 < c2 { return 1 }
    return 2
  }

  private func validateParty() throws {
    let n = Int(bytes[base + game.partyOff - 4])
    guard n <= Gen4Save.maxParty else { throw Gen45SaveError("Gen 4 save: party count \(n)") }
    for i in 0..<n where partyMon(at: i) == nil {
      throw Gen45SaveError("Gen 4 save: party Pokémon \(i + 1) doesn't decode (wrong game or corrupt save)")
    }
  }

  // MARK: Checksum

  private var crcRange: Range<Int> { base..<(base + game.generalSize - game.crcFooterSize) }
  private var crcOff: Int { base + game.generalSize - 2 }

  var computedChecksum: Int { PokeCrypto.crc16(bytes, range: crcRange) }
  var storedChecksum: Int { saveU16(bytes, crcOff) }
  var checksumIsValid: Bool { computedChecksum == storedChecksum }

  mutating func rewriteChecksums() { savePutU16(&bytes, crcOff, computedChecksum) }

  /// The full file with the general block's CRC fixed.
  func build() -> Data {
    var copy = self
    copy.rewriteChecksums()
    return Data(copy.bytes)
  }

  // MARK: Reads

  var partyCount: Int { min(Int(bytes[base + game.partyOff - 4]), Gen4Save.maxParty) }

  private func partyRecordOff(_ slot: Int) -> Int { base + game.partyOff + slot * Gen4Save.partyMonSize }

  func partyMon(at slot: Int) -> Gen45Mon? {
    guard (0..<partyCount).contains(slot) else { return nil }
    let o = partyRecordOff(slot)
    return Gen45Mon(encrypted: Array(bytes[o..<o + Gen4Save.partyMonSize]), gen5: false)
  }

  func party() -> [SaveMon] {
    (0..<partyCount).compactMap { i in partyMon(at: i)?.saveMon(id: "party-\(i)") }
  }

  private var trainerBase: Int { base + game.trainerOff }

  var trainerName: String { Gen45Text.decode(bytes, off: trainerBase, maxChars: 7, gen5: false) }
  var money: Int { saveU32(bytes, trainerBase + 0x14) }
  var coins: Int { saveU16(bytes, trainerBase + 0x20) }

  func trainer() -> SaveTrainer {
    SaveTrainer(
      name: trainerName, money: money, coins: coins,
      trainerId: saveU16(bytes, trainerBase + 0x10), secretId: saveU16(bytes, trainerBase + 0x12),
      isFemale: bytes[trainerBase + 0x18] == 1,
      playTime: String(format: "%d:%02d", saveU16(bytes, trainerBase + 0x22), Int(bytes[trainerBase + 0x24])))
  }

  func bag() -> [SaveItemStack] {
    Gen45Bag.read(bytes, base: base + game.bagOff, pouches: game.pouches)
  }

  // MARK: Writes

  /// Edits one party slot; only the non-nil fields change (see `Gen45Mon.apply`). All-or-nothing.
  mutating func setPartyMon(
    slot: Int, species: Int? = nil, level: Int? = nil, moves: [Int]? = nil, heldItem: Int? = nil,
    evs: [Int]? = nil, ivs: [Int]? = nil, nickname: String? = nil, hp: Int? = nil, healFully: Bool = false,
    nature: Int? = nil, gender: Gen3MonGender? = nil
  ) throws {
    guard var mon = partyMon(at: slot) else { throw Gen45SaveError("Gen 4 party slot \(slot) is empty or unreadable") }
    try mon.apply(
      species: species, level: level, moves: moves, heldItem: heldItem, maxItem: game.maxItem,
      evs: evs, ivs: ivs, nickname: nickname, hp: hp, healFully: healFully,
      nature: nature, gender: gender)
    let o = partyRecordOff(slot)
    let enc = mon.encrypted()
    for i in 0..<enc.count { bytes[o + i] = enc[i] }
  }

  mutating func setMoney(_ v: Int) throws {
    guard (0...Gen4Save.maxMoney).contains(v) else { throw Gen45SaveError("money \(v)") }
    savePutU32(&bytes, trainerBase + 0x14, v)
  }

  mutating func setCoins(_ v: Int) throws {
    guard (0...Gen4Save.maxCoins).contains(v) else { throw Gen45SaveError("coins \(v)") }
    savePutU16(&bytes, trainerBase + 0x20, v)
  }

  /// 1-7 characters (Gen 4 charset; anything else becomes '?').
  mutating func setTrainerName(_ name: String) throws {
    guard (1...7).contains(name.count) else { throw Gen45SaveError("trainer name needs 1-7 characters") }
    Gen45Text.encode(name, into: &bytes, off: trainerBase, maxChars: 7, slotChars: 8, gen5: false)
  }

  /// Sets the quantity of an item already in the bag (0 removes it).
  mutating func setItemQuantity(item: Int, quantity: Int) throws {
    try Gen45Bag.setQuantity(
      &bytes, base: base + game.bagOff, pouches: game.pouches, item: item, quantity: quantity, maxItem: game.maxItem)
  }
}

/// `Gen4Game.dp / .pt / .hgss`.
typealias Gen4Game = Gen4Save.Game

struct Gen45SaveError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}
