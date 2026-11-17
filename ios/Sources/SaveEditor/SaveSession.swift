import Foundation

struct SaveSessionError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

/// One open save file (Gen 1 ... Gen 5) behind a single interface: read the party / trainer / bag, make edits,
/// `commit()` them. The save sits at `RomLibrary.savePath(forRom:)`; a session refuses to write while the emulator
/// has that same ROM loaded (it would overwrite the edit from its own save RAM), and `commit()` keeps the previous
/// file as `<save>.bak` first.
final class SaveSession: ObservableObject {
  let romURL: URL
  let saveURL: URL
  let generation: SaveGeneration
  @Published var readOnly: Bool
  var readOnlyReason: String?
  /// Bumped after every edit / commit so views can refresh.
  @Published private(set) var revision = 0
  /// Edits made since the last `commit()`.
  @Published private(set) var hasChanges = false

  private enum Backend {
    case gen1(Gen1Save)
    case gen2(Gen2Save)
    case gen3(Gen3SaveEditor)
    case gen4(Gen4Save)
    case gen5(Gen5Save)
  }

  private var backend: Backend

  private init(romURL: URL, saveURL: URL, generation: SaveGeneration, backend: Backend,
               readOnlyReason: String?) {
    self.romURL = romURL
    self.saveURL = saveURL
    self.generation = generation
    self.backend = backend
    self.readOnlyReason = readOnlyReason
    self.readOnly = readOnlyReason != nil
  }

  // MARK: Open

  /// Opens the ROM's save, or nil if there's no save yet or it isn't one this editor reads.
  /// Detection is by ROM extension: gb -> Gen 1, gbc -> Gen 2 (each falls back to the other), gba -> Gen 3 by the
  /// header game code, nds -> Gen 4 then Gen 5. `engineLoadedStem` is the stem of the ROM the emulator is running (if
  /// any); a match makes the session read-only.
  static func open(rom: URL, engineLoadedStem: String?) -> SaveSession? {
    let saveURL = RomLibrary.savePath(forRom: rom)
    guard let data = try? Data(contentsOf: saveURL), !data.isEmpty else { return nil }

    var found: (SaveGeneration, Backend, String?)?
    switch rom.pathExtension.lowercased() {
    case "gb":
      found = openGen1(data) ?? openGen2(data)
    case "gbc":
      found = openGen2(data) ?? openGen1(data)
    case "gba":
      found = openGen3(rom: rom, data: data)
    case "nds":
      found = openGen4(data) ?? openGen5(data)
    default:
      return nil
    }
    guard let (gen, backend, reason) = found else { return nil }

    var why = reason
    if why == nil, let stem = engineLoadedStem, Self.sameStem(stem, rom.deletingPathExtension().lastPathComponent) {
      why = "This game is running in the emulator. Close it first, or it would overwrite the edit with its own save."
    }
    return SaveSession(romURL: rom, saveURL: saveURL, generation: gen, backend: backend, readOnlyReason: why)
  }

  private static func sameStem(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String {
      s.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_").lowercased()
    }
    return norm(a) == norm(b)
  }

  private static func openGen1(_ data: Data) -> (SaveGeneration, Backend, String?)? {
    guard let s = try? Gen1Save.parse(data) else { return nil }
    return (.gen1, .gen1(s), s.checksumIsValid ? nil : "The save's checksum doesn't match, so it is open read-only.")
  }

  private static func openGen2(_ data: Data) -> (SaveGeneration, Backend, String?)? {
    guard let s = try? Gen2Save.parse(data) else { return nil }
    return (.gen2, .gen2(s), nil)
  }

  private static func openGen3(rom: URL, data: Data) -> (SaveGeneration, Backend, String?)? {
    let code = gameCode(rom: rom, offset: 0xAC, length: 4)
    let fileName = rom.lastPathComponent
    var formats = Gen3SaveFormat.candidates(forGameCode: code, fileName: fileName)
    guard !formats.isEmpty else { return nil }
    let unboundSave = Self.saveLooksLikeUnbound(data)
    // Unbound’s sector magic → prefer CFRU payload sizes even without “UNBOUND” in the filename.
    if unboundSave {
      formats = [.FIRERED_CFRU] + formats.filter { $0 != .FIRERED_CFRU }
    }
    let expanded = OptimizedRomCatalog.usesExpandedSpecies(fileName: fileName)
      || formats.contains(.FIRERED_CFRU)
      || unboundSave
    Gen3SaveData.applySpeciesLimits(expanded: expanded)
    Gen3SaveData.applyFieldPacking(packsSpeciesBits: false)
    let bytes = [UInt8](data)
    var file: Gen3SaveFile?
    var formatUsed: Gen3SaveFormat?
    for format in formats {
      if case .ok(let f) = Gen3SaveFile.parse(bytes, format: format) {
        file = f
        formatUsed = format
        break
      }
    }
    guard let file, let formatUsed else { return nil }
    // Keep expanded limits if we landed on CFRU / Unbound even without a filename hint.
    if formatUsed == .FIRERED_CFRU || file.signature == Gen3SaveFile.SIGNATURE_UNBOUND {
      Gen3SaveData.applySpeciesLimits(expanded: true)
    }
    Gen3SaveData.applyFieldPacking(packsSpeciesBits: formatUsed.packsSpeciesBits)
    let dexLayout = Gen3DexFlagsLayout.forRom(fileName: fileName, format: formatUsed)
    let editor = Gen3SaveEditor(file: file, dexLayout: dexLayout)
    if let why = editor.data.mismatch() {
      // Expanded / CFRU / Seaglass often leave non-zero junk past partyCount, or high species ids.
      // Those stay writable; only hard structural failures (bad party count, wrong box index) lock.
      let soft = why.contains("species")
        || why.contains("PC records")
        || why.contains("doesn't decode")
        || why.contains("isn't empty")
        || why.contains("is level")
      if soft && (expanded || formatUsed == .FIRERED_CFRU || formatUsed == .EMERALD_HNS
                  || formatUsed == .EMERALD_MODERN || formatUsed == .EMERALD_LAZARUS) {
        return (.gen3, .gen3(editor), nil)
      }
      return (.gen3, .gen3(editor), "This save doesn't look like \(formatUsed.label) (\(why)), so it is open read-only.")
    }
    return (.gen3, .gen3(editor), nil)
  }

  private static func openGen4(_ data: Data) -> (SaveGeneration, Backend, String?)? {
    guard let s = try? Gen4Save.parse(data) else { return nil }
    return (.gen4, .gen4(s), s.checksumIsValid ? nil : "The save's checksum doesn't match, so it is open read-only.")
  }

  private static func openGen5(_ data: Data) -> (SaveGeneration, Backend, String?)? {
    guard let s = try? Gen5Save.parse(data) else { return nil }
    return (.gen5, .gen5(s), s.checksumIsValid ? nil : "The save's checksums don't match, so it is open read-only.")
  }

  /// The ASCII at `offset` in the ROM header (GBA game code at 0xAC), without reading the whole ROM.
  private static func gameCode(rom: URL, offset: UInt64, length: Int) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: rom) else { return nil }
    defer { try? fh.close() }
    do {
      try fh.seek(toOffset: offset)
      guard let d = try fh.read(upToCount: length), d.count == length else { return nil }
      return String(bytes: d, encoding: .ascii)
    } catch {
      return nil
    }
  }

  // MARK: Reads

  /// A human label for the save's game, e.g. "Platinum".
  var gameLabel: String {
    switch backend {
    case .gen1: return "Gen 1"
    case .gen2: return "Gen 2"
    case .gen3(let e): return e.file.format.label
    case .gen4(let s): return s.game.label
    case .gen5(let s): return s.game.label
    }
  }

  func party() -> [SaveMon] {
    switch backend {
    case .gen1(let s): return s.party()
    case .gen2(let s): return s.party()
    case .gen3(let e):
      let tables = nameTables
      return e.data.party.enumerated().map {
        $1.mon.saveMon(id: "party-\($0)", level: $1.level, tables: tables)
      }
    case .gen4(let s): return s.party()
    case .gen5(let s): return s.party()
    }
  }

  func trainer() -> SaveTrainer? {
    switch backend {
    case .gen1(let s): return s.trainer()
    case .gen2(let s): return s.trainer()
    case .gen3(let e): return e.data.trainer
    case .gen4(let s): return s.trainer()
    case .gen5(let s): return s.trainer()
    }
  }

  func bag() -> [SaveItemStack] {
    switch backend {
    case .gen1(let s): return s.bag()
    case .gen2(let s): return s.bag()
    case .gen3(let e): return BagPocket.allCases.flatMap { e.data.itemStacks($0) }
    case .gen4(let s): return s.bag()
    case .gen5(let s): return s.bag()
    }
  }

  /// PC boxes (Gen 3: all 14; Gen 1: current box only; others empty until wired).
  func boxes() -> [SaveBox] {
    switch backend {
    case .gen1(let s): return s.currentBox()
    case .gen2: return []
    case .gen3(let e):
      let tables = nameTables
      return e.data.boxes.enumerated().map { i, box in
        SaveBox(
          index: i,
          name: box.name.isEmpty ? "Box \(i + 1)" : box.name,
          mons: box.mons.enumerated().compactMap { slot, mon in
            guard !mon.isEmpty else { return nil }
            return mon.saveMon(id: "box-\(i)-\(slot)", level: mon.level, tables: tables)
          }
        )
      }
    case .gen4, .gen5: return []
    }
  }

  func dex() -> SaveDexSummary? {
    switch backend {
    case .gen1(let s): return s.dexSummary()
    case .gen2(let s): return s.dexSummary()
    case .gen3(let e): return e.dexSummary()
    case .gen4, .gen5: return nil
    }
  }

  /// Gen 3 only: mark a National Dex species caught (and seen).
  func markDexCaught(_ species: Int) throws {
    try requireWritable()
    guard case .gen3(let e) = backend else {
      throw SaveSessionError("Pokédex flag edits are Gen 3 only for now")
    }
    e.markCaught(species)
    didEdit()
  }

  /// Gen 3 bag quantity (0 removes a non-key / non-HM stack).
  func setBagQuantity(pocket: BagPocket, index: Int, quantity: Int) throws {
    try requireWritable()
    guard case .gen3(let e) = backend else {
      throw SaveSessionError("Bag edits are Gen 3 only for now")
    }
    try e.setQuantity(pocket, index: index, quantity: quantity)
    didEdit()
  }

  /// Gen 3: add (or stack) an item into a pocket.
  func addBagItem(pocket: BagPocket, item: Int, quantity: Int) throws {
    try requireWritable()
    guard case .gen3(let e) = backend else {
      throw SaveSessionError("Bag edits are Gen 3 only for now")
    }
    try e.addItem(pocket, item: item, quantity: quantity)
    didEdit()
  }

  func setCoins(_ amount: Int) throws {
    try requireWritable()
    switch backend {
    case .gen1(var s): s.setCoins(amount); backend = .gen1(s)
    case .gen2(var s): s.setCoins(amount); backend = .gen2(s)
    case .gen3(let e): try e.setCoins(amount)
    case .gen4(var s): try s.setCoins(amount); backend = .gen4(s)
    case .gen5: throw SaveSessionError("Coins aren't on Gen 5 saves")
    }
    didEdit()
  }

  func setTrainerName(_ name: String) throws {
    try requireWritable()
    switch backend {
    case .gen3(let e): try e.setTrainerName(name)
    case .gen4(var s): try s.setTrainerName(name); backend = .gen4(s)
    case .gen5(var s): try s.setTrainerName(name); backend = .gen5(s)
    default: throw SaveSessionError("Trainer name edits aren't supported for this generation yet")
    }
    didEdit()
  }

  func setTrainerFemale(_ female: Bool) throws {
    try requireWritable()
    guard case .gen3(let e) = backend else {
      throw SaveSessionError("Trainer gender edits are Gen 3 only for now")
    }
    e.setTrainerFemale(female)
    didEdit()
  }

  /// Underlying Gen 3 editor when this session is Gen 3 (for same-gen trade).
  var gen3Editor: Gen3SaveEditor? {
    if case .gen3(let e) = backend { return e }
    return nil
  }

  // MARK: Edits

  private func requireWritable() throws {
    if readOnly { throw SaveSessionError(readOnlyReason ?? "This save is read-only.") }
  }

  private func didEdit() {
    hasChanges = true
    revision += 1
  }

  /// Marks the session dirty after an in-place Gen 3 trade (editors are reference types).
  func noteMutated() {
    guard !readOnly else { return }
    didEdit()
  }

  /// Edits one party slot; only the non-nil fields change. Throws (changing nothing) on anything out of range.
  /// - Gen 3: moves, held item, nickname, EVs, IVs (species / level not rewritten yet).
  /// - Gen 1 / 2: nickname; `heldItem` is Gen 2 only; level / species don't recompute stats.
  /// - Gen 4 / 5: species, level (EXP follows growth), moves, held item, nickname, EVs, IVs; stats recomputed.
  func editParty(
    slot: Int, species: Int? = nil, level: Int? = nil, moves: [Int]? = nil,
    heldItem: Int? = nil, nickname: String? = nil, evs: [Int]? = nil, ivs: [Int]? = nil,
    shiny: Bool? = nil, gender: Gen3MonGender? = nil, nature: Int? = nil
  ) throws {
    try requireWritable()
    switch backend {
    case .gen1(var s):
      if heldItem != nil { throw SaveSessionError("Gen 1 has no held items") }
      if evs != nil || ivs != nil { throw SaveSessionError("Gen 1 EV / IV edits aren't supported yet") }
      if shiny != nil { throw SaveSessionError("Gen 1 shiny edits aren't supported yet") }
      if gender != nil { throw SaveSessionError("Gen 1 gender edits aren't supported yet") }
      if nature != nil { throw SaveSessionError("Gen 1 has no natures") }
      try s.setPartyMon(slot: slot, species: species, level: level, moves: moves, nickname: nickname)
      backend = .gen1(s)
    case .gen2(var s):
      if evs != nil || ivs != nil { throw SaveSessionError("Gen 2 EV / IV edits aren't supported yet") }
      if shiny != nil { throw SaveSessionError("Gen 2 shiny edits aren't supported yet") }
      if nature != nil { throw SaveSessionError("Gen 2 has no natures") }
      try s.setPartyMon(
        slot: slot, species: species, level: level, moves: moves, heldItem: heldItem,
        nickname: nickname, gender: gender
      )
      backend = .gen2(s)
    case .gen3(let e):
      if species != nil || level != nil { throw SaveSessionError("Gen 3 species / level edits aren't supported yet") }
      if let heldItem { try e.setHeldItem(.party(slot), item: heldItem) }
      if let moves { try e.setMoves(.party(slot), moves: moves) }
      if let nickname { try e.setNickname(.party(slot), nickname: nickname) }
      if let evs { try e.setEVs(.party(slot), evs: evs, tables: nameTables) }
      if let ivs { try e.setIVs(.party(slot), ivs: ivs, tables: nameTables) }
      if let shiny { try e.setShiny(.party(slot), shiny: shiny, tables: nameTables) }
      if let gender { try e.setGender(.party(slot), gender: gender, tables: nameTables) }
      if let nature { try e.setNature(.party(slot), nature: nature, tables: nameTables) }
    case .gen4(var s):
      try s.setPartyMon(
        slot: slot, species: species, level: level, moves: moves, heldItem: heldItem,
        evs: evs, ivs: ivs, nickname: nickname, nature: nature, gender: gender
      )
      backend = .gen4(s)
    case .gen5(var s):
      try s.setPartyMon(
        slot: slot, species: species, level: level, moves: moves, heldItem: heldItem,
        evs: evs, ivs: ivs, nickname: nickname, nature: nature, gender: gender
      )
      backend = .gen5(s)
    }
    didEdit()
  }

  /// Gen 3: create a Pokémon in the next free party slot.
  func addPartyMon(
    species: Int, level: Int, moves: [Int], heldItem: Int, nickname: String,
    evs: [Int], ivs: [Int], shiny: Bool, gender: Gen3MonGender, nature: Int = 0
  ) throws {
    try requireWritable()
    guard case .gen3(let e) = backend else {
      throw SaveSessionError("Adding Pokémon is only supported for Gen 3 saves right now")
    }
    try e.addPartyMon(
      species: species, level: level, moves: moves, heldItem: heldItem, nickname: nickname,
      evs: evs, ivs: ivs, shiny: shiny, gender: gender, nature: nature, tables: nameTables
    )
    didEdit()
  }

  var partyCount: Int { party().count }
  var canAddPartyMon: Bool { generation == .gen3 && !readOnly && partyCount < 6 }

  /// Name / icon / learnset tables for this ROM (all gens + optimized hacks).
  var nameTables: Gen3Tables {
    switch generation {
    case .gen1: return .yellow
    case .gen2:
      let fn = romURL.lastPathComponent.uppercased()
      return fn.contains("POLISHED") ? .polished : .crystal
    case .gen3:
      if isUnboundSave { return .unbound }
      let fn = romURL.lastPathComponent.uppercased()
      if fn.contains("MODERN") && fn.contains("EMERALD") {
        return .modernEmerald
      }
      // Radical Red / Seaglass use National-order ids. Unbound must stay on `.unbound`
      // (FireRed-order + expansions) — never this branch.
      if fn.contains("SEAGLASS") || fn.contains("RADICAL") || fn.contains("ROCKET") {
        return .national
      }
      if OptimizedRomCatalog.usesExpandedSpecies(fileName: romURL.lastPathComponent),
         !fn.contains("UNBOUND") {
        return .national
      }
      return .retail
    case .gen4, .gen5: return .national
    }
  }

  /// Unbound: filename, optimized catalog, or the save’s custom sector signature.
  private var isUnboundSave: Bool {
    let name = romURL.lastPathComponent
    let u = name.uppercased()
    if u.contains("UNBOUND") { return true }
    if OptimizedRomCatalog.entry(matchingFileName: name)?.id == "unbound" { return true }
    if case .gen3(let editor) = backend, editor.file.signature == Gen3SaveFile.SIGNATURE_UNBOUND {
      return true
    }
    return false
  }

  /// Peek sector footers for Unbound’s `0x01121999` magic (filename-agnostic).
  private static func saveLooksLikeUnbound(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count >= Gen3SaveFile.MIN_SIZE else { return false }
    for slot in 0...1 {
      for sector in 0..<Gen3SaveFile.SECTORS_PER_SLOT {
        let base = (slot * Gen3SaveFile.SECTORS_PER_SLOT + sector) * Gen3SaveFile.SECTOR
        let off = base + Gen3SaveFile.SIGNATURE_OFF
        guard off + 4 <= bytes.count else { continue }
        let sig = Int(bytes[off])
          | (Int(bytes[off + 1]) << 8)
          | (Int(bytes[off + 2]) << 16)
          | (Int(bytes[off + 3]) << 24)
        if sig == Gen3SaveFile.SIGNATURE_UNBOUND { return true }
      }
    }
    return false
  }

  /// Sets the trainer's money (each game's own cap).
  func setMoney(_ amount: Int) throws {
    try requireWritable()
    switch backend {
    case .gen1(var s): s.setMoney(amount); backend = .gen1(s)
    case .gen2(var s): s.setMoney(amount); backend = .gen2(s)
    case .gen3(let e): try e.setMoney(amount)
    case .gen4(var s): try s.setMoney(amount); backend = .gen4(s)
    case .gen5(var s): try s.setMoney(amount); backend = .gen5(s)
    }
    didEdit()
  }

  // MARK: Commit

  /// Writes the edits to `saveURL`, keeping the file it replaces as `<save>.bak`. Throws if read-only or nothing
  /// could be written; the live save is only replaced by a complete, re-parsed result.
  func commit() throws {
    try requireWritable()
    guard hasChanges else { return }

    let out: Data
    switch backend {
    case .gen1(let s): out = s.build()
    case .gen2(let s): out = s.build()
    case .gen3(let e): out = Data(try e.build())
    case .gen4(let s): out = s.build()
    case .gen5(let s): out = s.build()
    }

    // The result must read back as the same kind of save before it replaces anything.
    let reopened: Backend
    switch backend {
    case .gen1: reopened = .gen1(try Gen1Save.parse(out))
    case .gen2: reopened = .gen2(try Gen2Save.parse(out))
    case .gen3(let e):
      guard case .ok(let file) = Gen3SaveFile.parse([UInt8](out), format: e.file.format) else {
        throw SaveSessionError("The edited save doesn't read back; nothing was written.")
      }
      reopened = .gen3(Gen3SaveEditor(file: file))
    case .gen4: reopened = .gen4(try Gen4Save.parse(out))
    case .gen5: reopened = .gen5(try Gen5Save.parse(out))
    }

    let fm = FileManager.default
    let bak = URL(fileURLWithPath: saveURL.path + ".bak")
    if fm.fileExists(atPath: saveURL.path) {
      if fm.fileExists(atPath: bak.path) { try fm.removeItem(at: bak) }
      try fm.copyItem(at: saveURL, to: bak)
    }
    try out.write(to: saveURL, options: .atomic)

    backend = reopened
    hasChanges = false
    revision += 1
  }
}
