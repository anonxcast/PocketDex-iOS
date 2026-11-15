import Foundation

/// Gen 5 (Black / White, Black 2 / White 2) cartridge save editor, after PKHeX `SAV5` / `SAV5BW` / `SAV5B2W2`.
///
/// One 0x80000 file, no backup copy. The first 0x24000 (BW) / 0x26000 (B2W2) bytes are ~70 blocks; every block has
/// a CRC16-CCITT stored right after it *and* mirrored in a table at the end of the main area (`mirrorBase` + 2 * block
/// index), and the table itself carries a footer CRC. Editing a block means fixing all three.
///
/// Party (block 26, 0x18E00 in both games): u32 count at +4, then 6 x 220-byte records from +8.
struct Gen5Save {
  enum Game: CaseIterable {
    case bw, b2w2

    var label: String { self == .bw ? "Black / White" : "Black 2 / White 2" }
    /// End of the main (checksummed) area.
    var mainSize: Int { self == .bw ? 0x24000 : 0x26000 }
    /// Bytes of the checksum-table footer the footer CRC covers.
    var footerInfoLength: Int { self == .bw ? 0x8C : 0x94 }
    /// Where block n's CRC is mirrored: `mirrorBase + 2 * n`.
    var mirrorBase: Int { self == .bw ? 0x23F00 : 0x25F00 }
    var maxItem: Int { self == .bw ? 632 : 638 }

    struct Block {
      let index: Int
      let off: Int
      let length: Int
      /// Where the block's own CRC sits.
      let crcOff: Int
    }

    var inventory: Block {
      self == .bw ? Block(index: 25, off: 0x18400, length: 0x9C0, crcOff: 0x18DC2)
        : Block(index: 25, off: 0x18400, length: 0x9EC, crcOff: 0x18DEE)
    }
    var party: Block { Block(index: 26, off: 0x18E00, length: 0x534, crcOff: 0x19336) }
    var trainer: Block {
      self == .bw ? Block(index: 27, off: 0x19400, length: 0x68, crcOff: 0x1946A)
        : Block(index: 27, off: 0x19400, length: 0xB0, crcOff: 0x194B2)
    }
    /// Badges, money, ...
    var misc: Block {
      self == .bw ? Block(index: 52, off: 0x21200, length: 0xEC, crcOff: 0x212EE)
        : Block(index: 52, off: 0x21100, length: 0xF0, crcOff: 0x211F2)
    }

    /// PKHeX PlayerBag5BW / PlayerBag5B2W2 (the same layout), offsets from the inventory block.
    var pouches: [Gen45Pouch] {
      [
        Gen45Pouch(off: 0x000, slots: 310, pocket: .items),
        Gen45Pouch(off: 0x4D8, slots: 83, pocket: .key, maxQuantity: 1),
        Gen45Pouch(off: 0x624, slots: 109, pocket: .tmhm, maxQuantity: 99, isTMHM: true),
        Gen45Pouch(off: 0x7D8, slots: 48, pocket: .items),
        Gen45Pouch(off: 0x898, slots: 64, pocket: .berries),
      ]
    }
  }

  static let size = 0x80000
  static let maxParty = 6
  static let partyMonSize = PokeCrypto.size5Party
  static let maxMoney = 999_999

  let game: Game
  private(set) var bytes: [UInt8]

  // MARK: Parse

  static func parse(_ data: Data) throws -> Gen5Save {
    guard data.count >= size else {
      throw Gen45SaveError("Gen 5 save too small (\(data.count) bytes, expected \(size))")
    }
    let b = [UInt8](data)
    // PKHeX SaveUtil.IsG5BW / IsG5B2W2: the checksum-table footer's own CRC.
    guard let game = Game.allCases.first(where: { footerValid(b, $0) }) else {
      throw Gen45SaveError("Not a Gen 5 save (checksum footer matches neither B/W nor B2/W2)")
    }
    let save = Gen5Save(game: game, bytes: b)
    try save.validateParty()
    return save
  }

  private init(game: Game, bytes: [UInt8]) {
    self.game = game
    self.bytes = bytes
  }

  private static func footerValid(_ b: [UInt8], _ game: Game) -> Bool {
    let start = game.mainSize - 0x100
    let len = game.footerInfoLength
    return PokeCrypto.crc16(b, range: start..<start + len) == saveU16(b, start + len + 0x0E)
  }

  private func validateParty() throws {
    let n = Int(bytes[game.party.off + 4])
    guard n <= Gen5Save.maxParty else { throw Gen45SaveError("Gen 5 save: party count \(n)") }
    for i in 0..<n where partyMon(at: i) == nil {
      throw Gen45SaveError("Gen 5 save: party Pokémon \(i + 1) doesn't decode (corrupt save)")
    }
  }

  // MARK: Checksums

  private func blockCRC(_ blk: Game.Block) -> Int {
    PokeCrypto.crc16(bytes, range: blk.off..<blk.off + blk.length)
  }

  private func blockValid(_ blk: Game.Block) -> Bool {
    let c = blockCRC(blk)
    return saveU16(bytes, blk.crcOff) == c && saveU16(bytes, game.mirrorBase + blk.index * 2) == c
  }

  /// The blocks this editor reads and writes all check out (a bad one means the file isn't a clean save).
  var checksumIsValid: Bool {
    [game.inventory, game.party, game.trainer, game.misc].allSatisfy(blockValid)
  }

  private mutating func fix(_ blk: Game.Block) {
    let c = blockCRC(blk)
    savePutU16(&bytes, blk.crcOff, c)
    savePutU16(&bytes, game.mirrorBase + blk.index * 2, c)
  }

  /// Rewrites the CRC + mirror of every block the editor can change, then the footer CRC over the mirror table.
  mutating func rewriteChecksums() {
    for blk in [game.inventory, game.party, game.trainer, game.misc] { fix(blk) }
    let start = game.mainSize - 0x100
    let len = game.footerInfoLength
    savePutU16(&bytes, start + len + 0x0E, PokeCrypto.crc16(bytes, range: start..<start + len))
  }

  func build() -> Data {
    var copy = self
    copy.rewriteChecksums()
    return Data(copy.bytes)
  }

  // MARK: Reads

  var partyCount: Int { min(Int(bytes[game.party.off + 4]), Gen5Save.maxParty) }

  private func partyRecordOff(_ slot: Int) -> Int { game.party.off + 8 + slot * Gen5Save.partyMonSize }

  func partyMon(at slot: Int) -> Gen45Mon? {
    guard (0..<partyCount).contains(slot) else { return nil }
    let o = partyRecordOff(slot)
    return Gen45Mon(encrypted: Array(bytes[o..<o + Gen5Save.partyMonSize]), gen5: true)
  }

  func party() -> [SaveMon] {
    (0..<partyCount).compactMap { i in partyMon(at: i)?.saveMon(id: "party-\(i)") }
  }

  private var trainerBase: Int { game.trainer.off }

  var trainerName: String { Gen45Text.decode(bytes, off: trainerBase + 4, maxChars: 7, gen5: true) }
  var money: Int { saveU32(bytes, game.misc.off) }

  func trainer() -> SaveTrainer {
    SaveTrainer(
      name: trainerName, money: money, coins: 0,
      trainerId: saveU16(bytes, trainerBase + 0x14), secretId: saveU16(bytes, trainerBase + 0x16),
      isFemale: bytes[trainerBase + 0x21] == 1,
      playTime: String(format: "%d:%02d", saveU16(bytes, trainerBase + 0x24), Int(bytes[trainerBase + 0x26])))
  }

  func bag() -> [SaveItemStack] {
    Gen45Bag.read(bytes, base: game.inventory.off, pouches: game.pouches)
  }

  // MARK: Writes

  /// Edits one party slot; only the non-nil fields change (see `Gen45Mon.apply`). All-or-nothing.
  mutating func setPartyMon(
    slot: Int, species: Int? = nil, level: Int? = nil, moves: [Int]? = nil, heldItem: Int? = nil,
    evs: [Int]? = nil, ivs: [Int]? = nil, nickname: String? = nil, hp: Int? = nil, healFully: Bool = false,
    nature: Int? = nil, gender: Gen3MonGender? = nil
  ) throws {
    guard var mon = partyMon(at: slot) else { throw Gen45SaveError("Gen 5 party slot \(slot) is empty or unreadable") }
    try mon.apply(
      species: species, level: level, moves: moves, heldItem: heldItem, maxItem: game.maxItem,
      evs: evs, ivs: ivs, nickname: nickname, hp: hp, healFully: healFully,
      nature: nature, gender: gender)
    let o = partyRecordOff(slot)
    let enc = mon.encrypted()
    for i in 0..<enc.count { bytes[o + i] = enc[i] }
  }

  mutating func setMoney(_ v: Int) throws {
    guard (0...Gen5Save.maxMoney).contains(v) else { throw Gen45SaveError("money \(v)") }
    savePutU32(&bytes, game.misc.off, v)
  }

  /// 1-7 characters (UTF-16).
  mutating func setTrainerName(_ name: String) throws {
    guard (1...7).contains(name.count) else { throw Gen45SaveError("trainer name needs 1-7 characters") }
    Gen45Text.encode(name, into: &bytes, off: trainerBase + 4, maxChars: 7, slotChars: 8, gen5: true)
  }

  /// Sets the quantity of an item already in the bag (0 removes it).
  mutating func setItemQuantity(item: Int, quantity: Int) throws {
    try Gen45Bag.setQuantity(
      &bytes, base: game.inventory.off, pouches: game.pouches, item: item, quantity: quantity, maxItem: game.maxItem)
  }
}

/// `Gen5Game.bw / .b2w2`.
typealias Gen5Game = Gen5Save.Game
