import Foundation

/// Gen 4 / Gen 5 Pokémon data crypto, as PKHeX's `PokeCrypto.Decrypt45` / `Encrypt45`.
///
/// A stored record is 136 bytes (header 0x00..<0x08, then four 32-byte blocks A B C D, shuffled by
/// `(PID >> 13) & 31 % 24`). A party record adds a battle-stats tail (100 bytes in Gen 4 -> 236, 84 in Gen 5 -> 220).
///   - bytes 0x08..<0x88 are XORed with an LCRNG stream seeded by the u16 checksum at 0x06,
///   - the tail is XORed with the same LCRNG seeded by the PID,
///   - the checksum is the u16 sum of the *decrypted* 0x08..<0x88 (shuffle-independent).
enum PokeCrypto {
  static let size4Stored = 136
  static let size4Party = 236
  static let size5Party = 220
  static let blockSize = 32
  static let dataStart = 8
  static let storedEnd = 136

  /// Stored position -> logical block (0 A, 1 B, 2 C, 3 D) for each of the 24 shuffle orders (Bulbapedia order,
  /// the same one Gen4Sampler uses on live RAM).
  static let blockOrders: [[Int]] = [
    "ABCD", "ABDC", "ACBD", "ACDB", "ADBC", "ADCB", "BACD", "BADC", "BCAD", "BCDA", "BDAC", "BDCA",
    "CABD", "CADB", "CBAD", "CBDA", "CDAB", "CDBA", "DABC", "DACB", "DBAC", "DBCA", "DCAB", "DCBA",
  ].map { $0.unicodeScalars.map { Int($0.value) - 65 } }

  /// Shuffle index (0..<24) for a personality value.
  static func shuffleIndex(pid: Int) -> Int { ((pid >> 13) & 31) % 24 }

  /// The LCRNG-XOR used by both the data region and the party tail. In place over `range` (u16 steps).
  static func cryptArray(_ b: inout [UInt8], range: Range<Int>, seed: UInt32) {
    var s = seed
    var i = range.lowerBound
    while i + 1 < range.upperBound {
      s = s &* 0x41C6_4E6D &+ 0x6073
      let key = UInt16(truncatingIfNeeded: s >> 16)
      let w = UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
      let x = w ^ key
      b[i] = UInt8(truncatingIfNeeded: x)
      b[i + 1] = UInt8(truncatingIfNeeded: x >> 8)
      i += 2
    }
  }

  /// Decrypts a stored (136) or party (220 / 236) record. Never fails: a wrong-size array is returned as is.
  static func decrypt45(_ raw: [UInt8]) -> [UInt8] {
    guard raw.count == size4Stored || raw.count == size4Party || raw.count == size5Party else { return raw }
    var b = raw
    let pid = saveU32(b, 0)
    let chk = UInt32(saveU16(b, 6))
    cryptArray(&b, range: dataStart..<storedEnd, seed: chk)
    if b.count > size4Stored { cryptArray(&b, range: storedEnd..<b.count, seed: UInt32(truncatingIfNeeded: pid)) }
    return unshuffle(b, order: blockOrders[shuffleIndex(pid: pid)])
  }

  /// Encrypts a decrypted record (the checksum at 0x06 must already be right - `refreshChecksum`).
  static func encrypt45(_ plain: [UInt8]) -> [UInt8] {
    guard plain.count == size4Stored || plain.count == size4Party || plain.count == size5Party else { return plain }
    let pid = saveU32(plain, 0)
    let chk = UInt32(saveU16(plain, 6))
    var b = shuffle(plain, order: blockOrders[shuffleIndex(pid: pid)])
    cryptArray(&b, range: dataStart..<storedEnd, seed: chk)
    if b.count > size4Stored { cryptArray(&b, range: storedEnd..<b.count, seed: UInt32(truncatingIfNeeded: pid)) }
    return b
  }

  /// Stored (shuffled) block `s` holds logical block `order[s]`; returns logical order.
  private static func unshuffle(_ b: [UInt8], order: [Int]) -> [UInt8] {
    var out = b
    for stored in 0..<4 {
      let logical = order[stored]
      for i in 0..<blockSize { out[dataStart + logical * blockSize + i] = b[dataStart + stored * blockSize + i] }
    }
    return out
  }

  /// Logical order -> stored (shuffled) order.
  private static func shuffle(_ b: [UInt8], order: [Int]) -> [UInt8] {
    var out = b
    for stored in 0..<4 {
      let logical = order[stored]
      for i in 0..<blockSize { out[dataStart + stored * blockSize + i] = b[dataStart + logical * blockSize + i] }
    }
    return out
  }

  /// u16 sum of 0x08..<0x88 (works on encrypted or decrypted bytes; only a decrypted record's sum is meaningful).
  static func checksum(_ b: [UInt8]) -> Int {
    var sum = 0
    var i = dataStart
    while i < storedEnd {
      sum += saveU16(b, i)
      i += 2
    }
    return sum & 0xFFFF
  }

  /// Is the stored checksum the one of this decrypted record?
  static func checksumValid(decrypted b: [UInt8]) -> Bool { checksum(b) == saveU16(b, 6) }

  static func refreshChecksum(_ b: inout [UInt8]) { savePutU16(&b, 6, checksum(b)) }

  /// PKHeX `Checksums.CRC16_CCITT`: CRC-16/CCITT (poly 0x1021, init 0xFFFF) over `b[range]`.
  /// Gen 4 saves checksum their two big blocks with it, Gen 5 saves every block.
  static func crc16(_ b: [UInt8], range: Range<Int>) -> Int {
    var top: UInt8 = 0xFF
    var bot: UInt8 = 0xFF
    for i in range {
      var x = b[i] ^ top
      x ^= x >> 4
      top = bot ^ (x >> 3) ^ (x << 4)
      bot = x ^ (x << 5)
    }
    return (Int(top) << 8) | Int(bot)
  }
}
