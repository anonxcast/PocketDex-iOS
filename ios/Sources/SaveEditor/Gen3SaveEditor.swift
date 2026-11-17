import Foundation

/// A PC box position: box 0..13, slot 0..29 (rows of 6, as the game lays them out).
struct BoxSlot: Equatable, Hashable {
  var box: Int
  var slot: Int
}

/// Where a Pokémon sits in a save: a party slot or a PC box slot.
enum MonRef: Equatable, Hashable {
  case party(Int)
  case pc(BoxSlot)
}

/// One bag slot: an item and how many.
struct ItemStack: Equatable {
  var item: Int
  var quantity: Int
}

struct Gen3SaveEditError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

/// What a save holds, read from its blocks: the trainer, the party and the 14 PC boxes.
struct Gen3SaveData {
  static let PARTY_SIZE = 6
  static let PARTY_MON_SIZE = 100
  static let BOXES = 14
  static let BOX_SLOTS = 30
  static let BOX_NAMES_OFF = 4 + BOXES * BOX_SLOTS * Gen3BoxMon.SIZE   // 0x8344
  static let BOX_NAME_SIZE = 9
  /// Retail Gen 3 last internal species id (Chimecho = 411; 412 = egg).
  static let MAX_SPECIES_RETAIL = 412
  /// CFRU / expansion hacks (Radical Red, Unbound, Seaglass, …) use much higher internal ids.
  static let MAX_SPECIES_EXPANDED = 2048
  /// Active ceiling for mismatch / edits — raised when opening a known hack save.
  static var MAX_SPECIES = MAX_SPECIES_RETAIL
  static let MAX_MONEY = 999_999
  static let MAX_COINS = 9_999
  static let MAX_ITEM_RETAIL = 377
  static let MAX_ITEM_EXPANDED = 1200
  static var MAX_ITEM = MAX_ITEM_RETAIL
  static let LAST_MOVE_RETAIL = 354
  /// Unbound’s move table tops out past 900 (see `movesUnbound`).
  static let LAST_MOVE_EXPANDED = 1024
  static var LAST_MOVE = LAST_MOVE_RETAIL

  /// Growth/attacks field masks (0xFFFF = full u16). Heart and Soul packs species:11|tera:5.
  static var SPECIES_FIELD_MASK = 0xFFFF
  static var MOVE_FIELD_MASK = 0xFFFF
  static var PP_FIELD_MASK = 0xFF

  static func applySpeciesLimits(expanded: Bool) {
    MAX_SPECIES = expanded ? MAX_SPECIES_EXPANDED : MAX_SPECIES_RETAIL
    MAX_ITEM = expanded ? MAX_ITEM_EXPANDED : MAX_ITEM_RETAIL
    LAST_MOVE = expanded ? LAST_MOVE_EXPANDED : LAST_MOVE_RETAIL
  }

  static func applyFieldPacking(packsSpeciesBits: Bool) {
    if packsSpeciesBits {
      SPECIES_FIELD_MASK = 0x07FF
      MOVE_FIELD_MASK = 0x07FF
      PP_FIELD_MASK = 0x7F
    } else {
      SPECIES_FIELD_MASK = 0xFFFF
      MOVE_FIELD_MASK = 0xFFFF
      PP_FIELD_MASK = 0xFF
    }
  }

  struct Box {
    let name: String
    let mons: [Gen3BoxMon]
  }

  struct PartyMon {
    let mon: Gen3BoxMon
    let level: Int
  }

  let format: Gen3SaveFormat
  let saveBlock2: [UInt8]
  let saveBlock1: [UInt8]
  let storage: [UInt8]

  init(format: Gen3SaveFormat, saveBlock2: [UInt8], saveBlock1: [UInt8], storage: [UInt8]) {
    self.format = format
    self.saveBlock2 = saveBlock2
    self.saveBlock1 = saveBlock1
    self.storage = storage
  }

  init(file: Gen3SaveFile) {
    self.init(format: file.format, saveBlock2: file.saveBlock2, saveBlock1: file.saveBlock1, storage: file.storage)
  }

  var trainerName: String { Gen3Text.decode(saveBlock2, off: 0, max: 7) }
  /// The 8 raw name bytes at the start of SaveBlock2.
  var trainerNameBytes: [UInt8] { Array(saveBlock2[0..<8]) }
  var isFemale: Bool { saveBlock2[8] != 0 }
  var trainerId: Int { saveU16(saveBlock2, 0x0A) }
  var secretId: Int { saveU16(saveBlock2, 0x0C) }
  var playTime: String { String(format: "%d:%02d", saveU16(saveBlock2, 0x0E), Int(saveBlock2[0x10])) }

  var money: Int {
    let key = format.encryptionKeyOff >= 0 ? saveU32(saveBlock2, format.encryptionKeyOff) : 0
    return saveU32(saveBlock1, format.moneyOff) ^ key
  }

  /// The low half of SaveBlock2.encryptionKey: what coins and bag quantities are XORed with (0 on R/S).
  private var key16: Int { format.encryptionKeyOff >= 0 ? saveU16(saveBlock2, format.encryptionKeyOff) : 0 }

  var coins: Int { saveU16(saveBlock1, format.coinsOff) ^ key16 }

  /// A pocket's filled slots, in the save's order.
  func pocket(_ p: BagPocket) -> [ItemStack] {
    let l = format.pocket(p)
    return (0..<l.slots).compactMap { i in
      let o = l.off + i * 4
      let item = saveU16(saveBlock1, o)
      return item == 0 ? nil : ItemStack(item: item, quantity: saveU16(saveBlock1, o + 2) ^ key16)
    }
  }

  var partyCount: Int { Int(saveBlock1[format.partyCountOff]) }

  var party: [PartyMon] {
    (0..<min(partyCount, Gen3SaveData.PARTY_SIZE)).map {
      let off = format.partyOff + $0 * Gen3SaveData.PARTY_MON_SIZE
      return PartyMon(mon: Gen3BoxMon.read(saveBlock1, off), level: Int(saveBlock1[off + 0x54]))
    }
  }

  /// The box the PC opens on.
  var currentBox: Int { Int(storage[0]) }

  var boxes: [Box] {
    (0..<Gen3SaveData.BOXES).map { b in
      Box(
        name: Gen3Text.decode(storage, off: Gen3SaveData.BOX_NAMES_OFF + b * Gen3SaveData.BOX_NAME_SIZE,
                              max: Gen3SaveData.BOX_NAME_SIZE),
        mons: (0..<Gen3SaveData.BOX_SLOTS).map { mon(BoxSlot(box: b, slot: $0)) })
    }
  }

  func mon(_ at: BoxSlot) -> Gen3BoxMon {
    Gen3BoxMon.read(storage, Gen3SaveData.recordOff(at))
  }

  /// The Pokémon at `at` (nil past the party / for an empty slot) and its level: the party's level byte,
  /// a box record's from its EXP.
  func mon(_ at: MonRef) -> (mon: Gen3BoxMon, level: Int)? {
    switch at {
    case .party(let i):
      let p = party
      return i >= 0 && i < p.count ? (p[i].mon, p[i].level) : nil
    case .pc(let slot):
      let m = mon(slot)
      return m.isEmpty ? nil : (m, m.level)
    }
  }

  /// Why these blocks don't look like a `format` save, or nil.
  func mismatch() -> String? {
    let count = partyCount
    if !(0...Gen3SaveData.PARTY_SIZE).contains(count) { return "party count \(count)" }
    for (i, p) in party.enumerated() {
      if !p.mon.checksumOk { return "party Pokémon \(i + 1) doesn't decode" }
      if !(1...Gen3SaveData.MAX_SPECIES).contains(p.mon.species) {
        return "party Pokémon \(i + 1) has species \(p.mon.species)"
      }
      if !p.mon.isEgg && !(1...100).contains(p.level) { return "party Pokémon \(i + 1) is level \(p.level)" }
    }
    for i in count..<Gen3SaveData.PARTY_SIZE {
      let off = format.partyOff + i * Gen3SaveData.PARTY_MON_SIZE
      if saveBlock1[off..<off + Gen3SaveData.PARTY_MON_SIZE].contains(where: { $0 != 0 }) {
        return "party slot \(i + 1) isn't empty"
      }
    }
    if currentBox >= Gen3SaveData.BOXES { return "current box \(currentBox + 1)" }
    let records = (0..<Gen3SaveData.BOXES * Gen3SaveData.BOX_SLOTS).map {
      mon(BoxSlot(box: $0 / Gen3SaveData.BOX_SLOTS, slot: $0 % Gen3SaveData.BOX_SLOTS))
    }
    let used = records.filter { !$0.isEmpty }.count
    let unreadable = records.filter { !$0.isEmpty && ($0.isBadEgg || !(1...Gen3SaveData.MAX_SPECIES).contains($0.species)) }.count
    if used >= 4 && unreadable * 2 > used { return "\(unreadable) of \(used) PC records don't decode" }
    return nil
  }

  static func recordOff(_ at: BoxSlot) -> Int {
    precondition((0..<BOXES).contains(at.box) && (0..<BOX_SLOTS).contains(at.slot), "no box slot \(at)")
    return 4 + (at.box * BOX_SLOTS + at.slot) * Gen3BoxMon.SIZE
  }
}

/// Edits a save's working copies and hands back the file to write. A PC record moves (or two swap) byte for byte;
/// values that can be edited (money, coins, the bag, held item, moves) only take what's in range, and anything else
/// throws before a byte changes. Unlike the Kotlin editor there are no Gen3Legal hard checks: any item id 1...377 and
/// any move 1...354 is accepted.
/// Where Pokédex seen/caught bits live for this save (retail SB2 vs expansion SB1).
struct Gen3DexFlagsLayout: Equatable {
  enum Block { case saveBlock2, saveBlock1 }
  var block: Block
  var seenOff: Int
  var caughtOff: Int
  var bytes: Int
  var nationalCount: Int
  /// Retail anti-cheat copies of `seen` in SaveBlock1 (empty for most hacks).
  var seenCopies: [Int]

  static let retailEmerald = Gen3DexFlagsLayout(
    block: .saveBlock2, seenOff: 0x18 + 0x44, caughtOff: 0x18 + 0x10,
    bytes: 52, nationalCount: 386, seenCopies: [0x938, 0x3A8C] // Emerald defaults; overwritten per format
  )

  static func forRom(fileName: String, format: Gen3SaveFormat) -> Gen3DexFlagsLayout {
    let u = fileName.uppercased()
    if u.contains("SEAGLASS") {
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x28FC, caughtOff: 0x2932,
        bytes: 54, nationalCount: 430, seenCopies: []
      )
    }
    if u.contains("MODERN") && u.contains("EMERALD") {
      // Modern Emerald 3.6 — SB2 pokedex + bag-shifted SB1 seen copies.
      // Bits are NATIONAL_DEX_* (1…432); storage is NUM_SPECIES-sized (58 bytes).
      return Gen3DexFlagsLayout(
        block: .saveBlock2, seenOff: format.pokedexOff + 0x44, caughtOff: format.pokedexOff + 0x10,
        bytes: 58, nationalCount: 432, seenCopies: [format.seen1Off, format.seen2Off]
      )
    }
    if u.contains("UNBOUND") {
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x310, caughtOff: 0x38D,
        bytes: 125, nationalCount: 905, seenCopies: []
      )
    }
    if u.contains("RADICAL") {
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x310, caughtOff: 0x38D,
        bytes: 129, nationalCount: 1025, seenCopies: []
      )
    }
    if u.contains("ROWE") || u.contains("R.O.W.E") {
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x3320, caughtOff: 0x33DC,
        bytes: 188, nationalCount: 1019, seenCopies: []
      )
    }
    if (u.contains("HEART") && u.contains("SOUL") && !u.contains("HEARTGOLD")) || u.contains("HEARTSOUL")
        || (u.contains("CRYSTAL") && u.contains("ENHANCED")) || u.contains("CRYSENHA") {
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x39C0, caughtOff: 0x3A7F,
        bytes: 191, nationalCount: 1080, seenCopies: []
      )
    }
    if u.contains("SOULGOLD") || u.contains("SOUL GOLD") || u.contains("SOULDGOLD") {
      // SoulGold GBA — companion soulgold_v1_2_1 national dex on SB1.
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x31F8, caughtOff: 0x3279,
        bytes: 129, nationalCount: 1025, seenCopies: []
      )
    }
    if u.contains("LAZARUS") {
      // Lazarus v2.0 — companion NATIVE_LAZARUS / POKEDEX_LAZARUS on SB1.
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x32A8, caughtOff: 0x3329,
        bytes: 129, nationalCount: 1028, seenCopies: []
      )
    }
    if u.contains("WISHES") {
      // Wishes of Tomorrow — companion / GF header national dex on SB1.
      return Gen3DexFlagsLayout(
        block: .saveBlock1, seenOff: 0x359C, caughtOff: 0x361D,
        bytes: 129, nationalCount: 1025, seenCopies: []
      )
    }
    // Retail: pokedex struct at SB2+0x18; owned +0x10, seen +0x44 within that struct.
    var layout = Gen3DexFlagsLayout(
      block: .saveBlock2,
      seenOff: format.pokedexOff + 0x44,
      caughtOff: format.pokedexOff + 0x10,
      bytes: 52,
      nationalCount: 386,
      seenCopies: [format.seen1Off, format.seen2Off]
    )
    return layout
  }
}

final class Gen3SaveEditor {
  static let NATIONAL_DEX_COUNT = 386
  static let SPECIES_UNOWN = 201
  static let SPECIES_SPINDA = 308
  private static let MAIL_ITEMS = 121...132

  let file: Gen3SaveFile
  var dexLayout: Gen3DexFlagsLayout
  private(set) var saveBlock2: [UInt8]
  private(set) var saveBlock1: [UInt8]
  private(set) var storage: [UInt8]

  init(file: Gen3SaveFile, dexLayout: Gen3DexFlagsLayout? = nil) {
    self.file = file
    self.dexLayout = dexLayout ?? .retailEmerald
    saveBlock2 = file.saveBlock2
    saveBlock1 = file.saveBlock1
    storage = file.storage
  }

  var data: Gen3SaveData {
    Gen3SaveData(format: file.format, saveBlock2: saveBlock2, saveBlock1: saveBlock1, storage: storage)
  }

  var changed: Bool {
    saveBlock2 != file.saveBlock2 || saveBlock1 != file.saveBlock1 || storage != file.storage
  }

  private var f: Gen3SaveFormat { file.format }

  // MARK: PC records

  /// Moves the Pokémon at `from` to `to`, swapping with whatever is there. Both must be readable records.
  func move(from: BoxSlot, to: BoxSlot) throws {
    if from == to { return }
    let a = data.mon(from)
    let b = data.mon(to)
    guard !a.isEmpty && !a.isBadEgg else { throw Gen3SaveEditError("nothing movable at \(from)") }
    guard b.isEmpty || !b.isBadEgg else { throw Gen3SaveEditError("a Bad Egg sits at \(to)") }
    let ao = Gen3SaveData.recordOff(from)
    let bo = Gen3SaveData.recordOff(to)
    let n = Gen3BoxMon.SIZE
    let tmp = Array(storage[ao..<ao + n])
    for i in 0..<n { storage[ao + i] = storage[bo + i] }
    for i in 0..<n { storage[bo + i] = tmp[i] }
  }

  /// The 80 bytes at `at`, as stored.
  func record(_ at: BoxSlot) -> [UInt8] {
    let o = Gen3SaveData.recordOff(at)
    return Array(storage[o..<o + Gen3BoxMon.SIZE])
  }

  /// Puts a record at `at`: `bytes` must decode, or be all zero (the slot emptied, like ZeroBoxMonData).
  func putRecord(_ at: BoxSlot, _ bytes: [UInt8]) throws {
    guard bytes.count == Gen3BoxMon.SIZE else { throw Gen3SaveEditError("a record is \(Gen3BoxMon.SIZE) bytes") }
    if !bytes.allSatisfy({ $0 == 0 }) {
      let m = Gen3BoxMon.read(bytes, 0)
      guard m.checksumOk && !m.isEmpty else { throw Gen3SaveEditError("not a readable record") }
    }
    let o = Gen3SaveData.recordOff(at)
    for i in 0..<bytes.count { storage[o + i] = bytes[i] }
  }

  // MARK: Flags / variables / dex

  func flag(_ id: Int) -> Bool { (saveBlock1[f.flagsOff + id / 8] >> UInt8(id % 8)) & 1 == 1 }

  private func setFlag(_ id: Int) {
    saveBlock1[f.flagsOff + id / 8] |= UInt8(1 << (id % 8))
  }

  func variable(_ id: Int) -> Int { saveU16(saveBlock1, f.varsOff + (id - 0x4000) * 2) }

  /// IsNationalPokedexEnabled, as each game checks it.
  var nationalDex: Bool {
    Int(saveBlock2[f.nationalMagicOff]) == f.nationalMagic
      && variable(f.nationalVar) == f.nationalVarValue && flag(f.nationalFlag)
  }

  /// Ruby / Sapphire's EnableNationalPokedex.
  func enableNationalDex() throws {
    guard f == .RUBY_SAPPHIRE else { throw Gen3SaveEditError("only Ruby / Sapphire get the National Dex from a trade") }
    saveBlock2[f.nationalMagicOff] = UInt8(f.nationalMagic)
    savePutU16(&saveBlock1, f.varsOff + (f.nationalVar - 0x4000) * 2, f.nationalVarValue)
    setFlag(f.nationalFlag)
    saveBlock2[f.pokedexOff + 1] = 1   // mode: national
    saveBlock2[f.pokedexOff] = 0       // order: numerical
  }

  private func dexBit(_ base: [UInt8], _ off: Int, _ national: Int) -> Bool {
    (base[off + (national - 1) / 8] >> UInt8((national - 1) % 8)) & 1 == 1
  }

  private func setDexBit(_ base: inout [UInt8], _ off: Int, _ national: Int) {
    base[off + (national - 1) / 8] |= UInt8(1 << ((national - 1) % 8))
  }

  private func withDexBlock(_ body: (inout [UInt8], Int, Int) -> Void) {
    switch dexLayout.block {
    case .saveBlock2:
      body(&saveBlock2, dexLayout.seenOff, dexLayout.caughtOff)
    case .saveBlock1:
      body(&saveBlock1, dexLayout.seenOff, dexLayout.caughtOff)
    }
  }

  /// Species id treated as dex bit index for this layout (1…nationalCount).
  private func dexIndex(_ species: Int) -> Int? {
    (1...dexLayout.nationalCount).contains(species) ? species : nil
  }

  /// Owned (+ seen copies when retail).
  func caught(_ species: Int) -> Bool {
    guard let n = dexIndex(species) else { return false }
    var owned = false
    var seen = false
    withDexBlock { base, seenOff, caughtOff in
      owned = dexBit(base, caughtOff, n)
      seen = dexBit(base, seenOff, n)
    }
    guard owned && seen else { return false }
    for copy in dexLayout.seenCopies where copy > 0 {
      if !dexBit(saveBlock1, copy, n) { return false }
    }
    return true
  }

  func dexSummary() -> SaveDexSummary {
    var owned = 0, seen = 0
    let maxN = dexLayout.nationalCount
    withDexBlock { base, seenOff, caughtOff in
      for n in 1...maxN {
        if dexBit(base, caughtOff, n) { owned += 1 }
        if dexBit(base, seenOff, n) { seen += 1 }
      }
    }
    return SaveDexSummary(
      owned: owned, seen: seen, max: maxN, nationalEnabled: nationalDex)
  }

  /// Mark seen (+ copies) then owned. Unown / Spinda personality only on retail SB2 layouts.
  func markCaught(_ species: Int, personality: Int = 0) {
    guard let n = dexIndex(species) else { return }
    let first = !caught(species)
    withDexBlock { base, seenOff, caughtOff in
      setDexBit(&base, seenOff, n)
      if first { setDexBit(&base, caughtOff, n) }
    }
    for copy in dexLayout.seenCopies where copy > 0 {
      setDexBit(&saveBlock1, copy, n)
    }
    if first, dexLayout.block == .saveBlock2 {
      switch species {
      case Gen3SaveEditor.SPECIES_UNOWN: savePutU32(&saveBlock2, f.pokedexOff + 0x04, personality & 0xFFFF_FFFF)
      case Gen3SaveEditor.SPECIES_SPINDA: savePutU32(&saveBlock2, f.pokedexOff + 0x08, personality & 0xFFFF_FFFF)
      default: break
      }
    }
  }

  // MARK: Money / coins / trainer / bag

  private var key16: Int { f.encryptionKeyOff >= 0 ? saveU16(saveBlock2, f.encryptionKeyOff) : 0 }

  /// SetMoney: 0..999,999, stored XORed with the key.
  func setMoney(_ amount: Int) throws {
    guard (0...Gen3SaveData.MAX_MONEY).contains(amount) else { throw Gen3SaveEditError("money \(amount)") }
    let key = f.encryptionKeyOff >= 0 ? saveU32(saveBlock2, f.encryptionKeyOff) : 0
    savePutU32(&saveBlock1, f.moneyOff, (amount ^ key) & 0xFFFF_FFFF)
  }

  /// SetCoins: 0..9,999.
  func setCoins(_ amount: Int) throws {
    guard (0...Gen3SaveData.MAX_COINS).contains(amount) else { throw Gen3SaveEditError("coins \(amount)") }
    savePutU16(&saveBlock1, f.coinsOff, (amount ^ key16) & 0xFFFF)
  }

  /// Player name in SaveBlock2 (7 Western characters + 0xFF).
  func setTrainerName(_ name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Gen3SaveEditError("trainer name is empty") }
    let encoded = Gen3Text.encode(trimmed, length: 8)
    for i in 0..<8 { saveBlock2[i] = encoded[i] }
  }

  /// SaveBlock2 gender byte (0 boy / 1 girl).
  func setTrainerFemale(_ female: Bool) {
    saveBlock2[8] = female ? 1 : 0
  }

  /// Rewrites the nickname at `at` (Western Gen 3 charset).
  func setNickname(_ at: MonRef, nickname: String) throws {
    let (mon, _) = try editable(at)
    let bytes = Gen3Text.encode(nickname, length: Gen3BoxMon.NICKNAME_BYTES)
    try put(at, mon.withChanges(nickname: bytes))
  }

  /// Sets stack `index` of `pocket` to `quantity` (1 up to what a stack holds); 0 takes the stack out (never an HM's).
  func setQuantity(_ pocket: BagPocket, index: Int, quantity: Int) throws {
    var stacks = data.pocket(pocket)
    guard stacks.indices.contains(index) else { throw Gen3SaveEditError("no stack \(index) in \(pocket)") }
    let item = stacks[index].item
    if quantity == 0 {
      // Key items and HMs are handed out once: without them the game can't go on.
      guard pocket != .key && item < Gen3SaveFormat.FIRST_HM else { throw Gen3SaveEditError("item \(item) stays") }
      stacks.remove(at: index)
    } else {
      try requireLegal(pocket, item, quantity)
      stacks[index] = ItemStack(item: item, quantity: quantity)
    }
    try writePocket(pocket, stacks)
  }

  /// Puts `quantity` of `item` in `pocket`. Stacks with an existing copy when present.
  func addItem(_ pocket: BagPocket, item: Int, quantity: Int) throws {
    try requireLegal(pocket, item, quantity)
    var stacks = data.pocket(pocket)
    if let i = stacks.firstIndex(where: { $0.item == item }) {
      let cap = f.stackMax(pocket: pocket, item: item)
      let next = min(cap, stacks[i].quantity + quantity)
      stacks[i] = ItemStack(item: item, quantity: next)
      try writePocket(pocket, stacks)
      return
    }
    guard stacks.count < f.pocket(pocket).slots else { throw Gen3SaveEditError("\(pocket.title) is full") }
    try writePocket(pocket, stacks + [ItemStack(item: item, quantity: quantity)])
  }

  /// Any item id 1...377 and a quantity in the stack's range (no per-game pocket table here).
  private func requireLegal(_ pocket: BagPocket, _ item: Int, _ quantity: Int) throws {
    guard pocket != .key else { throw Gen3SaveEditError("key items aren't edited") }
    guard (1...Gen3SaveData.MAX_ITEM).contains(item) else { throw Gen3SaveEditError("item \(item) doesn't exist") }
    guard (1...f.stackMax(pocket: pocket, item: item)).contains(quantity) else {
      throw Gen3SaveEditError("\(quantity) of item \(item)")
    }
  }

  /// The pocket packed from its first slot, the rest zeroed; TMs and berries by id, as the game sorts them.
  private func writePocket(_ pocket: BagPocket, _ stacks: [ItemStack]) throws {
    let l = f.pocket(pocket)
    let sorted = (pocket == .tmhm || pocket == .berries) ? stacks.sorted { $0.item < $1.item } : stacks
    guard sorted.count <= l.slots else { throw Gen3SaveEditError("\(pocket) is full") }
    for i in 0..<l.slots {
      let s = i < sorted.count ? sorted[i] : nil
      savePutU16(&saveBlock1, l.off + i * 4, s?.item ?? 0)
      savePutU16(&saveBlock1, l.off + i * 4 + 2, s == nil ? 0 : (s!.quantity ^ key16) & 0xFFFF)
    }
  }

  // MARK: Pokémon

  private func recordAt(_ at: MonRef) throws -> Int {
    switch at {
    case .party(let i):
      guard (0..<data.partyCount).contains(i) else { throw Gen3SaveEditError("no party Pokémon \(i)") }
      return f.partyOff + i * Gen3SaveData.PARTY_MON_SIZE
    case .pc(let slot):
      return Gen3SaveData.recordOff(slot)
    }
  }

  private func editable(_ at: MonRef) throws -> (mon: Gen3BoxMon, level: Int) {
    guard let (mon, level) = data.mon(at) else { throw Gen3SaveEditError("nothing at \(at)") }
    if mon.isEgg { throw Gen3SaveEditError("eggs aren't edited") }
    if !mon.checksumOk {
      throw Gen3SaveEditError("This Pokémon couldn't be decrypted for editing")
    }
    // After checksumOk, isBadEgg is only the game's Bad Egg flag bit.
    if mon.isBadEgg { throw Gen3SaveEditError("Bad Eggs aren't edited") }
    return (mon, level)
  }

  private func put(_ at: MonRef, _ bytes: [UInt8]) throws {
    let off = try recordAt(at)
    switch at {
    case .party: for i in 0..<bytes.count { saveBlock1[off + i] = bytes[i] }
    case .pc: for i in 0..<bytes.count { storage[off + i] = bytes[i] }
    }
  }

  /// Gives the Pokémon at `at` `item` to hold (0 = nothing): any item 1...377 (not mail), or the one it has.
  func setHeldItem(_ at: MonRef, item: Int) throws {
    let (mon, _) = try editable(at)
    guard item == 0 || item == mon.heldItem || (1...Gen3SaveData.MAX_ITEM).contains(item) else {
      throw Gen3SaveEditError("item \(item) can't be held")
    }
    guard item == 0 || item == mon.heldItem || !Gen3SaveEditor.MAIL_ITEMS.contains(item) else {
      throw Gen3SaveEditError("mail can't be given from here")
    }
    guard !Gen3SaveEditor.MAIL_ITEMS.contains(mon.heldItem) else { throw Gen3SaveEditError("mail stays with its letter") }
    try put(at, mon.withChanges(heldItem: item))
  }

  /// The Pokémon at `at`'s moves: 1-4 different ones, any move 1...354. A move it keeps keeps its PP and PP Ups
  /// (wherever it moves to); a new one starts with full PP and none.
  func setMoves(_ at: MonRef, moves: [Int]) throws {
    let (mon, _) = try editable(at)
    guard (1...4).contains(moves.count), moves.allSatisfy({ (1...Gen3SaveData.LAST_MOVE).contains($0) }),
          Set(moves).count == moves.count
    else { throw Gen3SaveEditError("moves \(moves)") }
    let known = mon.moves
    let knownPP = mon.pp
    var ids = [Int](repeating: 0, count: 4)
    var pp = [Int](repeating: 0, count: 4)
    var bonuses = 0
    for (i, m) in moves.enumerated() {
      ids[i] = m
      if let was = known.firstIndex(of: m) {
        pp[i] = knownPP[was]
        bonuses |= ((mon.ppBonuses >> (was * 2)) & 3) << (i * 2)
      } else {
        pp[i] = Gen3MovePP.basePP(m)
      }
    }
    try put(at, mon.withChanges(moves: ids, pp: pp, ppBonuses: bonuses))
  }

  /// EVs: six values 0…255 (HP, Atk, Def, Spe, SpA, SpD). Party battle stats are refreshed in-place.
  func setEVs(_ at: MonRef, evs: [Int], tables: Gen3Tables = .national) throws {
    let (mon, level) = try editable(at)
    guard evs.count == 6, evs.allSatisfy({ (0...255).contains($0) }) else {
      throw Gen3SaveEditError("EVs \(evs)")
    }
    try put(at, mon.withChanges(evs: evs))
    try refreshPartyBattleStats(at, level: level, nature: mon.nature, tables: tables)
  }

  /// IVs: six values 0…31. Egg / ability flags are preserved. Party battle stats are refreshed.
  func setIVs(_ at: MonRef, ivs: [Int], tables: Gen3Tables = .national) throws {
    let (mon, level) = try editable(at)
    guard ivs.count == 6, ivs.allSatisfy({ (0...31).contains($0) }) else {
      throw Gen3SaveEditError("IVs \(ivs)")
    }
    try put(at, mon.withChanges(ivs: ivs))
    try refreshPartyBattleStats(at, level: level, nature: mon.nature, tables: tables)
  }

  /// Rebuild personality so the mon is shiny or not (OT / gender / nature preserved as much as possible).
  func setShiny(_ at: MonRef, shiny: Bool, tables: Gen3Tables) throws {
    let (mon, _) = try editable(at)
    if mon.isShiny == shiny { return }
    let gender = Gen3Gender.gender(species: mon.species, personality: mon.personality, tables: tables)
    let pid = Gen3BoxMon.matchingPersonality(
      otId: mon.otId, shiny: shiny, nature: mon.nature, gender: gender, species: mon.species, tables: tables
    )
    try put(at, mon.withPersonality(pid))
  }

  /// Rebuild personality for the requested gender (shiny + nature preserved when possible).
  func setGender(_ at: MonRef, gender: Gen3MonGender, tables: Gen3Tables) throws {
    let (mon, _) = try editable(at)
    let options = Gen3Gender.options(species: mon.species, tables: tables)
    guard options.contains(gender) else {
      throw Gen3SaveEditError("\(Gen3Names.species(mon.species, tables: tables)) can't be \(gender.label.lowercased())")
    }
    let current = Gen3Gender.gender(species: mon.species, personality: mon.personality, tables: tables)
    if current == gender { return }
    let pid = Gen3BoxMon.matchingPersonality(
      otId: mon.otId, shiny: mon.isShiny, nature: mon.nature, gender: gender, species: mon.species, tables: tables
    )
    try put(at, mon.withPersonality(pid))
  }

  /// Rebuild personality for the requested nature (shiny + gender preserved when possible).
  /// Party battle stats are refreshed so the ±10% shows in-game immediately.
  func setNature(_ at: MonRef, nature: Int, tables: Gen3Tables) throws {
    guard (0..<25).contains(nature) else { throw Gen3SaveEditError("nature \(nature)") }
    let (mon, level) = try editable(at)
    if mon.nature == nature { return }
    let gender = Gen3Gender.gender(species: mon.species, personality: mon.personality, tables: tables)
    let pid = Gen3BoxMon.matchingPersonality(
      otId: mon.otId, shiny: mon.isShiny, nature: nature, gender: gender, species: mon.species, tables: tables
    )
    try put(at, mon.withPersonality(pid))
    try refreshPartyBattleStats(at, level: level, nature: nature, tables: tables)
  }

  /// Party struct Pokemon footer (pret `pokemon.h`): status@0x50, level@0x54, hp@0x56,
  /// maxHP@0x58, attack@0x5A … spDefense@0x62. Never write past byte 0x63 — SpD used to be
  /// written at 0x64 and spilled into the next party mon’s personality (Bad Egg).
  private static let partyCurHpOff = 0x56
  private static let partyMaxHpOff = 0x58
  private static let partyStatOff = 0x5A  // Atk, Def, Spe, SpA, SpD as five u16s

  /// Rewrite party footer HP / Atk…SpD after a nature (or EV/IV) change. HP scales with the old ratio.
  private func refreshPartyBattleStats(_ at: MonRef, level: Int, nature: Int, tables: Gen3Tables) throws {
    guard case .party = at else { return }
    guard let (mon, _) = data.mon(at) else { return }
    let off = try recordAt(at)
    let stats = Gen3BaseStats.partyStats(
      species: mon.species, level: level, ivs: mon.ivs, evs: mon.evs, nature: nature, tables: tables
    )
    let curHP = saveU16(saveBlock1, off + Self.partyCurHpOff)
    let oldMax = max(1, saveU16(saveBlock1, off + Self.partyMaxHpOff))
    let newMax = max(1, stats[0])
    let newHP = min(newMax, max(1, curHP * newMax / oldMax))
    savePutU16(&saveBlock1, off + Self.partyCurHpOff, newHP)
    savePutU16(&saveBlock1, off + Self.partyMaxHpOff, newMax)
    for i in 0..<5 {
      savePutU16(&saveBlock1, off + Self.partyStatOff + i * 2, stats[i + 1])
    }
  }

  /// Append a new Pokémon to the party (needs a free slot). Writes box data + battle stats.
  func addPartyMon(
    species: Int,
    level: Int,
    moves: [Int],
    heldItem: Int,
    nickname: String,
    evs: [Int],
    ivs: [Int],
    shiny: Bool,
    gender: Gen3MonGender,
    nature: Int = 0,
    tables: Gen3Tables
  ) throws {
    let count = data.partyCount
    guard count < Gen3SaveData.PARTY_SIZE else { throw Gen3SaveEditError("Party is full") }
    guard (1...Gen3SaveData.MAX_SPECIES).contains(species) else {
      throw Gen3SaveEditError("species \(species) isn't valid for this ROM")
    }
    guard (1...100).contains(level) else { throw Gen3SaveEditError("level \(level)") }
    let cleanedMoves = moves.filter { $0 > 0 }
    guard (1...4).contains(cleanedMoves.count),
          cleanedMoves.allSatisfy({ (1...Gen3SaveData.LAST_MOVE).contains($0) }),
          Set(cleanedMoves).count == cleanedMoves.count
    else { throw Gen3SaveEditError("moves \(moves)") }
    if heldItem != 0 {
      guard (1...Gen3SaveData.MAX_ITEM).contains(heldItem) else {
        throw Gen3SaveEditError("item \(heldItem) can't be held")
      }
    }

    let otId = (data.secretId << 16) | (data.trainerId & 0xFFFF)
    let genderOptions = Gen3Gender.options(species: species, tables: tables)
    let resolvedGender = genderOptions.contains(gender) ? gender : (genderOptions.first ?? .genderless)
    let resolvedNature = ((nature % 25) + 25) % 25
    let box = Gen3BoxMon.create(
      species: species,
      level: level,
      otId: otId,
      otNameBytes: data.trainerNameBytes,
      nickname: nickname,
      moves: cleanedMoves,
      heldItem: heldItem,
      evs: evs,
      ivs: ivs,
      shiny: shiny,
      gender: resolvedGender,
      nature: resolvedNature,
      tables: tables
    )
    let mon = Gen3BoxMon.read(box, 0)
    guard mon.checksumOk else { throw Gen3SaveEditError("created record failed checksum") }

    let stats = Gen3BaseStats.partyStats(
      species: species, level: level, ivs: ivs, evs: evs, nature: mon.nature, tables: tables
    )
    let off = f.partyOff + count * Gen3SaveData.PARTY_MON_SIZE
    for i in 0..<box.count { saveBlock1[off + i] = box[i] }
    // Party footer: status, level, mail, hp… (see refreshPartyBattleStats offsets).
    for i in 80..<Gen3SaveData.PARTY_MON_SIZE { saveBlock1[off + i] = 0 }
    saveBlock1[off + 0x54] = UInt8(level)
    savePutU16(&saveBlock1, off + Self.partyCurHpOff, stats[0])
    savePutU16(&saveBlock1, off + Self.partyMaxHpOff, stats[0])
    for i in 0..<5 {
      savePutU16(&saveBlock1, off + Self.partyStatOff + i * 2, stats[i + 1])
    }
    saveBlock1[f.partyCountOff] = UInt8(count + 1)
    markCaught(species, personality: mon.personality)
  }

  /// The whole file with the edits saved into its other slot (`Gen3SaveFile.withBlocks`).
  func build() throws -> [UInt8] {
    try file.withBlocks(saveBlock2: saveBlock2, saveBlock1: saveBlock1, storage: storage)
  }
}

// MARK: - Model bridging

extension Gen3SaveData {
  var trainer: SaveTrainer {
    SaveTrainer(name: trainerName, money: money, coins: coins, trainerId: trainerId, secretId: secretId,
                isFemale: isFemale, playTime: playTime)
  }

  /// Bag stacks as `SaveItemStack`s (pocket = the pocket's table id).
  func itemStacks(_ p: BagPocket) -> [SaveItemStack] {
    pocket(p).map { SaveItemStack(item: $0.item, quantity: $0.quantity, pocket: p.id) }
  }
}

extension Gen3BoxMon {
  /// A `SaveMon` view of this record. `id` is caller-chosen (e.g. "party-0", "box-3-12"); `level` per `Gen3SaveData.mon(_:)`.
  func saveMon(id: String, level: Int, tables: Gen3Tables = .retail) -> SaveMon {
    SaveMon(
      id: id, species: species, level: level, heldItem: heldItem, friendship: friendship,
      moves: moves, pp: pp, evs: evs, ivs: ivs,
      nickname: Gen3Text.decode(nicknameBytes), shiny: isShiny,
      gender: Gen3Gender.gender(species: species, personality: personality, tables: tables),
      isEgg: isEgg, exp: exp, nature: nature)
  }

  var isShiny: Bool {
    Gen3Decode.shinyValue(personality: UInt32(truncatingIfNeeded: personality), otId: UInt32(truncatingIfNeeded: otId)) < 8
  }
}
