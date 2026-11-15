import Foundation

/// One struct BoxPokemon (80 bytes: the PC's records, and the first 80 bytes of a party mon), with its four 12-byte
/// substructs decrypted (key = personality ^ OT id) and put in logical order: Growth, Attacks, EVs / condition, Misc.
/// `encode()` puts it back the way the game would, so a record that was never changed encodes to its own bytes.
/// Port of Gen3BoxMon.kt.
struct Gen3BoxMon {
  static let SIZE = 80
  static let NICKNAME_BYTES = 10

  /// How the 48-byte substruct block is stored on disk.
  enum Storage {
    /// Standard Gen 3: XOR with PID^OTID, shuffled by PID%24.
    case encrypted
    /// Unbound / some CFRU saves: plaintext G-A-E-M at +0x20 (companion plaintext fallback).
    case plaintext
  }

  private let header: [UInt8]   // first 0x20 bytes
  private let data: [UInt8]     // 48 decrypted bytes, logical order
  let checksumOk: Bool
  let storage: Storage
  /// The record as read: what an unreadable one `encode()`s back to.
  private let original: [UInt8]

  private init(
    header: [UInt8], data: [UInt8], checksumOk: Bool, original: [UInt8],
    storage: Storage = .encrypted
  ) {
    self.header = header
    self.data = data
    self.checksumOk = checksumOk
    self.storage = storage
    self.original = original
  }

  var personality: Int { saveU32(header, 0) }
  var otId: Int { saveU32(header, 4) }
  var nicknameBytes: [UInt8] { Array(header[0x08..<0x12]) }
  var language: Int { Int(header[0x12]) }
  private var flags: Int { Int(header[0x13]) }
  /// True when the game set the Bad Egg flag, or we could not decode the record at all.
  /// Plaintext Unbound mons are `checksumOk` and editable even though 0x1C isn't a retail checksum.
  var isBadEgg: Bool { flags & 1 != 0 || !checksumOk }
  var otNameBytes: [UInt8] { Array(header[0x14..<0x1B]) }

  // Growth (mask strips packed tera/form bits on expansion hacks)
  var species: Int { saveU16(data, 0) & Gen3SaveData.SPECIES_FIELD_MASK }
  var heldItem: Int { saveU16(data, 2) }
  var exp: Int { saveU32(data, 4) }
  var ppBonuses: Int { Int(data[8]) }
  var friendship: Int { Int(data[9]) }
  // Attacks
  var moves: [Int] { (0..<4).map { saveU16(data, 12 + $0 * 2) & Gen3SaveData.MOVE_FIELD_MASK } }
  var pp: [Int] { (0..<4).map { Int(data[20 + $0]) & Gen3SaveData.PP_FIELD_MASK } }
  // EVs / condition
  var evs: [Int] { (0..<6).map { Int(data[24 + $0]) } }
  // Misc
  var metLocation: Int { Int(data[37]) }
  private var origins: Int { saveU16(data, 38) }
  var metLevel: Int { origins & 0x7F }
  /// GAME_VERSION the mon was met in (1 Sapphire, 2 Ruby, 3 Emerald, 4 FireRed, 5 LeafGreen, 15 Colosseum / XD).
  var metGame: Int { (origins >> 7) & 0xF }
  var ball: Int { (origins >> 11) & 0xF }
  private var ivWord: Int { saveU32(data, 40) }
  var ivs: [Int] { (0..<6).map { (ivWord >> ($0 * 5)) & 0x1F } }
  var isEgg: Bool { (ivWord >> 30) & 1 == 1 }
  var abilityNum: Int { (ivWord >> 31) & 1 }
  private var ribbons: Int { saveU32(data, 44) }
  /// The top ribbon bit: the "fateful encounter" the trade code checks on Mew and Deoxys.
  var fatefulEncounter: Bool { (ribbons >> 31) & 1 == 1 }

  var isEmpty: Bool { checksumOk && species == 0 }
  /// PID % 25, XOR mint bits in the language byte (expansion Mints) when present.
  var nature: Int {
    let pidNature = personality % 25
    let mint = Int(header[0x12]) >> 3
    let xored = pidNature ^ mint
    return xored < 25 ? xored : pidNature
  }

  /// Level from experience and the species' growth rate (box records keep no level byte).
  var level: Int { Gen3BoxMon.levelFor(species: species, exp: exp) }

  /// Build a new encrypted box record (for Add to Party / PC).
  static func create(
    species: Int,
    level: Int,
    otId: Int,
    otNameBytes: [UInt8],
    nickname: String,
    moves: [Int],
    heldItem: Int,
    evs: [Int],
    ivs: [Int],
    shiny: Bool,
    gender: Gen3MonGender = .male,
    nature: Int = 0,
    tables: Gen3Tables = .retail,
    friendship: Int = 70,
    language: Int = 2
  ) -> [UInt8] {
    let wantNature = ((nature % 25) + 25) % 25
    let personality = matchingPersonality(
      otId: otId, shiny: shiny, nature: wantNature, gender: gender, species: species, tables: tables
    )
    var h = [UInt8](repeating: 0xFF, count: 0x20)
    savePutU32(&h, 0, personality & 0xFFFF_FFFF)
    savePutU32(&h, 4, otId & 0xFFFF_FFFF)
    let nick = Gen3Text.encode(nickname.isEmpty ? "POKEMON" : nickname, length: NICKNAME_BYTES)
    for i in 0..<NICKNAME_BYTES { h[0x08 + i] = nick[i] }
    h[0x12] = UInt8(language)
    h[0x13] = 0 // flags
    let ot = Array((otNameBytes + [UInt8](repeating: 0xFF, count: 7)).prefix(7))
    for i in 0..<7 { h[0x14 + i] = ot[i] }
    h[0x1B] = 0 // marking

    var d = [UInt8](repeating: 0, count: 48)
    savePutU16(&d, 0, species)
    savePutU16(&d, 2, heldItem)
    let exp = expForLevel(level, rate: growthRateForSpecies(species))
    savePutU32(&d, 4, exp & 0xFFFF_FFFF)
    d[8] = 0 // pp bonuses
    d[9] = UInt8(max(0, min(255, friendship)))
    let moveList = Array((moves.filter { $0 > 0 } + [0, 0, 0, 0]).prefix(4))
    for i in 0..<4 {
      savePutU16(&d, 12 + i * 2, moveList[i])
      d[20 + i] = UInt8(moveList[i] > 0 ? Gen3MovePP.basePP(moveList[i]) : 0)
    }
    let ev = Array((evs + [0, 0, 0, 0, 0, 0]).prefix(6))
    for i in 0..<6 { d[24 + i] = UInt8(max(0, min(255, ev[i]))) }
    // Misc: met location / origins left 0 (Poké Ball = 4 << 11 when writing origins if needed)
    var origins = 0
    origins |= (4 & 0xF) << 11 // Poké Ball
    origins |= (level & 0x7F)  // met level
    savePutU16(&d, 38, origins)
    var ivWord = 0
    let iv = Array((ivs + [0, 0, 0, 0, 0, 0]).prefix(6))
    for i in 0..<6 { ivWord |= (max(0, min(31, iv[i])) & 0x1F) << (i * 5) }
    savePutU32(&d, 40, ivWord & 0xFFFF_FFFF)

    return Gen3BoxMon(header: h, data: d, checksumOk: true, original: [UInt8](repeating: 0, count: SIZE)).encode()
  }

  /// PID matching shiny, nature (% 25), and gender (low byte vs species ratio).
  static func matchingPersonality(
    otId: Int, shiny: Bool, nature: Int, gender: Gen3MonGender, species: Int, tables: Gen3Tables
  ) -> Int {
    let wantNature = ((nature % 25) + 25) % 25
    let genderByte = Gen3Gender.personalityByte(for: gender, species: species, tables: tables)
    var pid = Int.random(in: 0...0x7FFF_FFFF)
    for _ in 0..<400_000 {
      let candidate = (pid & ~0xFF) | genderByte
      let sv = Gen3Decode.shinyValue(
        personality: UInt32(truncatingIfNeeded: candidate),
        otId: UInt32(truncatingIfNeeded: otId)
      )
      if (sv < 8) == shiny && candidate % 25 == wantNature {
        return candidate
      }
      pid = (pid &+ 0x100) & 0x7FFF_FFFF
    }
    // Fallback: lock gender byte; approximate shiny via TID/SID on upper half.
    let tid = otId & 0xFFFF
    let sid = (otId >> 16) & 0xFFFF
    if shiny {
      var p1 = Int.random(in: 0...0xFFFF)
      for _ in 0..<10_000 {
        let p2 = ((tid ^ sid ^ p1) & 0xFFF8) | (genderByte & 0x7)
        let candidate = (p1 << 16) | (p2 & 0xFF00) | genderByte
        if Gen3Decode.shinyValue(
          personality: UInt32(truncatingIfNeeded: candidate),
          otId: UInt32(truncatingIfNeeded: otId)
        ) < 8 {
          return candidate
        }
        p1 = (p1 &+ 1) & 0xFFFF
      }
    }
    return (wantNature &* 0x100) | genderByte
  }

  /// Back-compat alias used by shiny-only rewrites.
  static func shinyPersonality(otId: Int, shiny: Bool, nature: Int) -> Int {
    matchingPersonality(
      otId: otId, shiny: shiny, nature: nature, gender: .male, species: 1, tables: .retail
    )
  }

  /// This record with the given fields changed, encoded with a new checksum. Only for a record that read correctly.
  func withChanges(
    species: Int? = nil, heldItem: Int? = nil, nickname: [UInt8]? = nil,
    moves: [Int]? = nil, pp: [Int]? = nil, ppBonuses: Int? = nil,
    evs: [Int]? = nil, ivs: [Int]? = nil
  ) -> [UInt8] {
    precondition(checksumOk, "an unreadable record is never changed")
    var h = header
    var d = data
    if let species {
      let packed = (saveU16(d, 0) & ~Gen3SaveData.SPECIES_FIELD_MASK)
        | (species & Gen3SaveData.SPECIES_FIELD_MASK)
      savePutU16(&d, 0, packed)
    }
    if let heldItem { savePutU16(&d, 2, heldItem) }
    if let ppBonuses { d[8] = UInt8(truncatingIfNeeded: ppBonuses) }
    if let moves {
      precondition(moves.count == 4)
      for i in 0..<4 {
        let packed = (saveU16(d, 12 + i * 2) & ~Gen3SaveData.MOVE_FIELD_MASK)
          | (moves[i] & Gen3SaveData.MOVE_FIELD_MASK)
        savePutU16(&d, 12 + i * 2, packed)
      }
    }
    if let pp {
      precondition(pp.count == 4)
      for i in 0..<4 {
        let packed = (Int(d[20 + i]) & ~Gen3SaveData.PP_FIELD_MASK)
          | (pp[i] & Gen3SaveData.PP_FIELD_MASK)
        d[20 + i] = UInt8(truncatingIfNeeded: packed)
      }
    }
    if let evs {
      precondition(evs.count == 6)
      for i in 0..<6 { d[24 + i] = UInt8(truncatingIfNeeded: max(0, min(255, evs[i]))) }
    }
    if let ivs {
      precondition(ivs.count == 6)
      // Preserve egg (bit 30) + ability (bit 31); replace the six 5-bit IV fields.
      var w = ivWord & ~0x3FFF_FFFF
      for i in 0..<6 {
        w |= (max(0, min(31, ivs[i])) & 0x1F) << (i * 5)
      }
      savePutU32(&d, 40, w & 0xFFFF_FFFF)
    }
    if let nickname {
      precondition(nickname.count == Gen3BoxMon.NICKNAME_BYTES)
      for i in 0..<nickname.count { h[0x08 + i] = nickname[i] }
    }
    return Gen3BoxMon(
      header: h, data: d, checksumOk: true, original: original, storage: storage
    ).encode()
  }

  /// This record under another personality (nature / gender / shiny). Plaintext keeps G-A-E-M on disk.
  /// Clears expansion Mint bits in the language byte so the new PID % 25 is the nature the game uses.
  func withPersonality(_ personality: Int, clearMint: Bool = true) -> [UInt8] {
    precondition(checksumOk, "an unreadable record is never changed")
    var h = header
    savePutU32(&h, 0, personality & 0xFFFF_FFFF)
    if clearMint {
      h[0x12] = h[0x12] & 0x07  // keep language; drop mint (bits 3…7)
    }
    return Gen3BoxMon(
      header: h, data: data, checksumOk: true, original: original, storage: storage
    ).encode()
  }

  /// The record's 80 bytes, checksum recomputed and stored the way this mon was read.
  func encode() -> [UInt8] {
    if !checksumOk { return original }   // never re-encode a record we couldn't read
    var out = [UInt8](repeating: 0, count: Gen3BoxMon.SIZE)
    for i in 0..<header.count { out[i] = header[i] }
    var sum = 0
    for i in 0..<24 { sum = (sum + saveU16(data, i * 2)) & 0xFFFF }

    if storage == .plaintext {
      // Unbound-style: raw G-A-E-M. Keep CFRU backupSpecies at 0x1C when that was on disk.
      let origCheck = original.count > 0x1D ? saveU16(original, 0x1C) : 0
      let origSpecies = original.count > 0x21 ? saveU16(original, 0x20) : 0
      if origCheck == origSpecies || origCheck == species {
        savePutU16(&out, 0x1C, species & 0xFFFF)
      } else {
        savePutU16(&out, 0x1C, sum)
      }
      for i in 0..<48 { out[0x20 + i] = data[i] }
      return out
    }

    savePutU16(&out, 0x1C, sum)
    let order = Gen3Decode.substructOrder[personality % 24]
    let key = personality ^ otId
    for slot in 0..<4 {
      let logical = order[slot]
      for w in 0..<3 {
        savePutU32(&out, 0x20 + slot * 12 + w * 4, (saveU32(data, logical * 12 + w * 4) ^ key) & 0xFFFF_FFFF)
      }
    }
    return out
  }

  static func read(_ b: [UInt8], _ off: Int) -> Gen3BoxMon {
    let original = Array(b[off..<min(b.count, off + SIZE)])
    guard original.count >= SIZE else {
      return Gen3BoxMon(
        header: [UInt8](repeating: 0, count: 0x20),
        data: [UInt8](repeating: 0, count: 48),
        checksumOk: false,
        original: original
      )
    }
    let encrypted = readEncrypted(b, off, original: original)
    // Packed-species hacks (HnS / TMT2) must stay on the encrypted path. Treating a
    // failed decrypt as "plaintext" and re-encoding it produces a Bad Egg in-game.
    let packsBits = Gen3SaveData.SPECIES_FIELD_MASK != 0xFFFF
    if encrypted.checksumOk && isPlausibleSpecies(encrypted.species) {
      return encrypted
    }
    if !packsBits,
       let plain = readPlaintext(b, off, original: original),
       isPlausibleSpecies(plain.species) {
      return plain
    }
    // Last resort: try every substruct order with PID^OTID; keep a checksum-valid
    // layout whose species is in the Unbound/retail tables (fixes odd CFRU PIDs).
    if let recovered = readBestEffort(b, off, original: original) {
      return recovered
    }
    // Prefer a checksum-valid encrypted record even when species looks odd (masked
    // expansion ids); never return an editable plaintext fake for packed formats.
    if encrypted.checksumOk { return encrypted }
    return encrypted
  }

  /// Standard Gen 3 decrypt (PID^OTID, substruct order by PID%24, checksum at +0x1C).
  private static func readEncrypted(_ b: [UInt8], _ off: Int, original: [UInt8]) -> Gen3BoxMon {
    decrypt(b, off, original: original, orderIndex: saveU32(b, off) % 24)
  }

  private static func decrypt(
    _ b: [UInt8], _ off: Int, original: [UInt8], orderIndex: Int
  ) -> Gen3BoxMon {
    let header = Array(b[off..<off + 0x20])
    let key = saveU32(b, off) ^ saveU32(b, off + 4)
    let order = Gen3Decode.substructOrder[orderIndex % 24]
    var data = [UInt8](repeating: 0, count: 48)
    var sum = 0
    for slot in 0..<4 {
      let logical = order[slot]
      for w in 0..<3 {
        let word = (saveU32(b, off + 0x20 + slot * 12 + w * 4) ^ key) & 0xFFFF_FFFF
        savePutU32(&data, logical * 12 + w * 4, word)
        sum = (sum + (word & 0xFFFF) + ((word >> 16) & 0xFFFF)) & 0xFFFF
      }
    }
    return Gen3BoxMon(
      header: header,
      data: data,
      checksumOk: sum == saveU16(b, off + 0x1C),
      original: original
    )
  }

  /// Plaintext GAEM layout (no XOR / no reorder) — Unbound-style fallback used by companion.
  /// Marked editable (`checksumOk`) so Apply / gender / nature can rewrite the same layout.
  private static func readPlaintext(_ b: [UInt8], _ off: Int, original: [UInt8]) -> Gen3BoxMon? {
    guard b.count >= off + SIZE else { return nil }
    let header = Array(b[off..<off + 0x20])
    let box = off + 0x20
    let species = saveU16(b, box)
    guard species > 0 else { return nil }
    var data = [UInt8](repeating: 0, count: 48)
    for i in 0..<48 { data[i] = b[box + i] }
    return Gen3BoxMon(
      header: header, data: data, checksumOk: true, original: original, storage: .plaintext
    )
  }

  private static func readBestEffort(_ b: [UInt8], _ off: Int, original: [UInt8]) -> Gen3BoxMon? {
    var best: Gen3BoxMon?
    for orderIndex in 0..<24 {
      let candidate = decrypt(b, off, original: original, orderIndex: orderIndex)
      guard candidate.checksumOk, isPlausibleSpecies(candidate.species) else { continue }
      // Prefer the PID%24 order when it works; otherwise first plausible hit.
      if orderIndex == saveU32(b, off) % 24 { return candidate }
      if best == nil { best = candidate }
    }
    return best
  }

  /// Species id the Unbound / retail / National name tables would recognize.
  private static func isPlausibleSpecies(_ id: Int) -> Bool {
    guard id > 0, id <= Gen3SaveData.MAX_SPECIES_EXPANDED else { return false }
    if id == 412 { return true } // Bad Egg / Egg slot in retail tables
    return Gen3Names.speciesUnbound[id] != nil
      || Gen3Names.speciesRetail[id] != nil
      || Gen3Names.speciesNational[id] != nil
  }

  // MARK: Level

  /// Growth-rate groups (0 medium fast, 1 erratic, 2 fluctuating, 3 medium slow, 4 fast, 5 slow).
  /// No per-species rate table is bundled in the iOS port yet, so by default every species is medium fast;
  /// set `growthRateForSpecies` to plug a real table in.
  static var growthRateForSpecies: (Int) -> Int = { _ in 0 }

  /// Experience needed to reach `level` (1...100) on `rate`.
  static func expForLevel(_ level: Int, rate: Int) -> Int {
    let n = max(1, min(level, 100))
    let n3 = n * n * n
    switch rate {
    case 1:  // erratic
      if n <= 50 { return n3 * (100 - n) / 50 }
      if n <= 68 { return n3 * (150 - n) / 100 }
      if n <= 98 { return n3 * ((1911 - 10 * n) / 3) / 500 }
      return n3 * (160 - n) / 100
    case 2:  // fluctuating
      if n <= 15 { return n3 * ((n + 1) / 3 + 24) / 50 }
      if n <= 35 { return n3 * (n + 14) / 50 }
      return n3 * (n / 2 + 32) / 50
    case 3: return max(0, 6 * n3 / 5 - 15 * n * n + 100 * n - 140)   // medium slow
    case 4: return 4 * n3 / 5                                          // fast
    case 5: return 5 * n3 / 4                                          // slow
    default: return n3                                                 // medium fast
    }
  }

  /// Level 1...100 from experience; 0 for species 0.
  static func levelFor(species: Int, exp: Int) -> Int {
    guard species > 0 else { return 0 }
    let rate = growthRateForSpecies(species)
    var level = 1
    while level < 100 && exp >= expForLevel(level + 1, rate: rate) { level += 1 }
    return level
  }
}
