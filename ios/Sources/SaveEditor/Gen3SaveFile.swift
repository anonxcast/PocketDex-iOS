import Foundation

/// A Gen 3 save file (Ruby / Sapphire / Emerald / FireRed / LeafGreen's 128 KB flash), read and written the way the
/// games' own save.c does it: two slots of 14 4 KB sectors (0xF80 data bytes + id / checksum / signature / counter
/// footer); an edit is written like a save, into the *other* slot with counter + 1 and rotation + 1.
/// Port of Gen3SaveFile.kt.
struct Gen3SaveFile {
  static let SECTOR = 0x1000
  /// Retail Gen 3 sector payload (Bulbapedia / pret).
  static let DATA = 0xF80
  /// CFRU expanded sector payload (Complete-Fire-Red-Upgrade `SECTOR_DATA_SIZE`).
  static let DATA_CFRU = 0xFF0
  /// Modern Emerald 3.6 checksums the full pre-footer payload (0xFF4), not retail 0xF80.
  static let DATA_MODERN = 0xFF4
  static let SECTORS_PER_SLOT = 14
  static let ID_OFF = 0xFF4
  static let CHECKSUM_OFF = 0xFF6
  static let SIGNATURE_OFF = 0xFF8
  static let COUNTER_OFF = 0xFFC
  /// Retail R/S/E/FR/LG (+ Radical Red).
  static let SIGNATURE_RETAIL = 0x0801_2025
  /// Pokémon Unbound custom sector signature.
  static let SIGNATURE_UNBOUND = 0x0112_1999
  static let SIGNATURE = SIGNATURE_RETAIL
  /// Both slots; Hall of Fame and the rest come after, and aren't needed.
  static let MIN_SIZE = 2 * SECTORS_PER_SLOT * SECTOR

  static func isValidSignature(_ sig: Int) -> Bool {
    sig == SIGNATURE_RETAIL || sig == SIGNATURE_UNBOUND
  }

  enum SlotStatus { case ok, empty, corrupt }

  enum Parsed {
    case ok(Gen3SaveFile)
    case failed(String)
  }

  struct SaveError: Error, CustomStringConvertible {
    let description: String
  }

  let format: Gen3SaveFormat
  /// Sector footer magic this file uses (retail or Unbound) — written back on save.
  let signature: Int
  /// The whole file as read (both slots, the extra sectors, any RTC footer).
  let raw: [UInt8]
  /// The slot the game would load (0 or 1), its save counter and where its id 0 sits.
  let slot: Int
  let counter: Int
  let rotation: Int
  /// The other slot - the game's fallback - as the game would judge it.
  let otherSlot: SlotStatus
  let saveBlock2: [UInt8]
  let saveBlock1: [UInt8]
  let storage: [UInt8]

  /// The file with these blocks saved over it the way the game saves. Throws if the result doesn't read back as
  /// exactly these blocks in that slot (see `verifyWritten`).
  func withBlocks(saveBlock2: [UInt8], saveBlock1: [UInt8], storage: [UInt8]) throws -> [UInt8] {
    guard saveBlock2.count == format.saveBlock2Size, saveBlock1.count == format.saveBlock1Size,
          storage.count == format.storageSize
    else { throw SaveError(description: "block sizes don't match \(format.label)") }
    var out = raw
    let target = 1 - slot
    let newCounter = (counter + 1) & 0xFFFF_FFFF
    let newRotation = (rotation + 1) % Gen3SaveFile.SECTORS_PER_SLOT
    for id in 0..<Gen3SaveFile.SECTORS_PER_SLOT {
      let base = (target * Gen3SaveFile.SECTORS_PER_SLOT + (id + newRotation) % Gen3SaveFile.SECTORS_PER_SLOT)
        * Gen3SaveFile.SECTOR
      for i in base..<base + Gen3SaveFile.SECTOR { out[i] = 0 }
      let size = format.chunkSize(id)
      let block: [UInt8]
      let start: Int
      switch id {
      case 0: block = saveBlock2; start = 0
      case 1...4: block = saveBlock1; start = format.blockOffset(forSectorId: id)
      default: block = storage; start = format.blockOffset(forSectorId: id)
      }
      for i in 0..<size { out[base + i] = block[start + i] }
      savePutU16(&out, base + Gen3SaveFile.ID_OFF, id)
      savePutU16(&out, base + Gen3SaveFile.CHECKSUM_OFF, Gen3SaveFile.checksum(out, base, size))
      savePutU32(&out, base + Gen3SaveFile.SIGNATURE_OFF, signature)
      savePutU32(&out, base + Gen3SaveFile.COUNTER_OFF, newCounter)
    }
    if let why = verifyWritten(out, saveBlock2: saveBlock2, saveBlock1: saveBlock1, storage: storage) {
      throw SaveError(description: "save write check failed: \(why)")
    }
    return out
  }

  /// Why `written` isn't exactly this save with the given blocks saved over it, or nil if it is.
  func verifyWritten(_ written: [UInt8], saveBlock2: [UInt8], saveBlock1: [UInt8], storage: [UInt8]) -> String? {
    if written.count != raw.count { return "size changed" }
    guard case .ok(let again) = Gen3SaveFile.parse(written, format: format) else { return "doesn't read back" }
    if again.slot == slot { return "the game would still load the old slot" }
    if again.counter != ((counter + 1) & 0xFFFF_FFFF) { return "wrong save counter" }
    if again.otherSlot != .ok { return "the previous save didn't survive" }
    if again.saveBlock2 != saveBlock2 || again.saveBlock1 != saveBlock1 || again.storage != storage {
      return "blocks differ after reading back"
    }
    let slotStart = (1 - slot) * Gen3SaveFile.SECTORS_PER_SLOT * Gen3SaveFile.SECTOR
    let slotEnd = slotStart + Gen3SaveFile.SECTORS_PER_SLOT * Gen3SaveFile.SECTOR
    for i in raw.indices where (i < slotStart || i >= slotEnd) && raw[i] != written[i] {
      return "a byte outside the new slot changed (0x\(String(i, radix: 16)))"
    }
    return nil
  }

  /// save.c's CalculateChecksum: the u32 words of `size` bytes summed, both halves folded into a u16.
  static func checksum(_ b: [UInt8], _ off: Int, _ size: Int) -> Int {
    var sum = 0
    for i in 0..<size / 4 { sum += saveU32(b, off + i * 4) }
    sum &= 0xFFFF_FFFF
    return ((sum >> 16) + sum) & 0xFFFF
  }

  static func parse(_ bytes: [UInt8], format: Gen3SaveFormat) -> Parsed {
    if bytes.count < MIN_SIZE { return .failed("Too small for a Gen 3 save (\(bytes.count) bytes)") }
    let slots = (0...1).map { readSlot(bytes, $0, format) }
    let ok = slots.indices.filter { slots[$0].status == .ok }
    if ok.isEmpty {
      return .failed(
        slots.allSatisfy { $0.status == .empty }
          ? "The save is empty - save once in the game first"
          : "Neither save slot is intact - the game would call this save corrupted")
    }
    let pick = ok.count == 1 ? ok[0] : newer(slots[0].counter, slots[1].counter)
    let s = slots[pick]
    if !s.sameCounter { return .failed("The save's sectors disagree on its save counter") }
    let other = slots[1 - pick].status
    var sb2 = [UInt8](repeating: 0, count: format.saveBlock2Size)
    var sb1 = [UInt8](repeating: 0, count: format.saveBlock1Size)
    var storage = [UInt8](repeating: 0, count: format.storageSize)
    for id in 0..<SECTORS_PER_SLOT {
      let base = s.sectorBase[id]
      let size = format.chunkSize(id)
      switch id {
      case 0:
        for i in 0..<size { sb2[i] = bytes[base + i] }
      case 1...4:
        let start = format.blockOffset(forSectorId: id)
        for i in 0..<size { sb1[start + i] = bytes[base + i] }
      default:
        let start = format.blockOffset(forSectorId: id)
        for i in 0..<size { storage[start + i] = bytes[base + i] }
      }
    }
    let rotation = (s.sectorBase[0] / SECTOR) % SECTORS_PER_SLOT
    return .ok(Gen3SaveFile(
      format: format, signature: s.signature, raw: bytes, slot: pick, counter: s.counter,
      rotation: rotation, otherSlot: other,
      saveBlock2: sb2, saveBlock1: sb1, storage: storage))
  }

  /// GetSaveValidStatus's pick between two good slots: the larger counter, with its 0xFFFFFFFF -> 0 wrap.
  private static func newer(_ c0: Int, _ c1: Int) -> Int {
    let wrap = (c0 == 0xFFFF_FFFF && c1 == 0) || (c0 == 0 && c1 == 0xFFFF_FFFF)
    if wrap { return c0 == 0xFFFF_FFFF ? 1 : 0 }
    return c0 < c1 ? 1 : 0
  }

  private struct Slot {
    let status: SlotStatus
    let counter: Int
    let sameCounter: Bool
    let sectorBase: [Int]
    let signature: Int
  }

  private static func readSlot(_ b: [UInt8], _ slot: Int, _ format: Gen3SaveFormat) -> Slot {
    var anySignature = false
    var valid = 0
    var counter = 0
    var seenSig = 0
    var counters = Set<Int>()
    var base = [Int](repeating: -1, count: SECTORS_PER_SLOT)
    for i in 0..<SECTORS_PER_SLOT {
      let off = (slot * SECTORS_PER_SLOT + i) * SECTOR
      let sig = saveU32(b, off + SIGNATURE_OFF)
      if !isValidSignature(sig) { continue }
      anySignature = true
      seenSig = sig
      let id = saveU16(b, off + ID_OFF)
      if id >= SECTORS_PER_SLOT { continue }
      if saveU16(b, off + CHECKSUM_OFF) != checksum(b, off, format.chunkSize(id)) { continue }
      // Each id once: a slot holding one chunk twice isn't one the game wrote.
      if base[id] >= 0 {
        return Slot(status: .corrupt, counter: 0, sameCounter: false, sectorBase: base, signature: seenSig)
      }
      base[id] = off
      valid |= 1 << id
      counter = saveU32(b, off + COUNTER_OFF)
      counters.insert(counter)
    }
    let status: SlotStatus
    if !anySignature {
      status = .empty
    } else if valid == (1 << SECTORS_PER_SLOT) - 1 {
      status = .ok
    } else {
      status = .corrupt
    }
    return Slot(
      status: status, counter: counter, sameCounter: counters.count == 1,
      sectorBase: base, signature: seenSig == 0 ? SIGNATURE_RETAIL : seenSig
    )
  }
}
