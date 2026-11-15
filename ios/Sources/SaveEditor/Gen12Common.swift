import Foundation

// Shared helpers for the Gen 1 / Gen 2 battery-save editors (Gen1Save, Gen2Save).

struct Gen12SaveError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

/// Gen 1 / Gen 2 English text charmap (shared by both generations for the characters we care about).
/// A–Z 0x80+, a–z 0xA0+, 0–9 0xF6+, space 0x7F, 0x50 = terminator.
enum Gen12Text {
  static let terminator: UInt8 = 0x50
  static let nameLength = 11

  private static let extra: [UInt8: Character] = [
    0xBA: "é", 0xE0: "'", 0xE3: "-", 0xE6: "?", 0xE7: "!", 0xE8: ".",
    0xEF: "♂", 0xF3: "/", 0xF4: ",", 0xF5: "♀", 0x7F: " ",
  ]

  private static let reverseExtra: [Character: UInt8] = {
    var d: [Character: UInt8] = [:]
    for (k, v) in extra { d[v] = k }
    return d
  }()

  static func decode(_ b: [UInt8], off: Int, max: Int = nameLength) -> String {
    var s = ""
    var i = 0
    while i < max, off + i < b.count {
      let c = b[off + i]
      if c == terminator || c == 0 { break }
      switch c {
      case 0x80...0x99: s.append(Character(UnicodeScalar(UInt8(c - 0x80 + 65))))
      case 0xA0...0xB9: s.append(Character(UnicodeScalar(UInt8(c - 0xA0 + 97))))
      case 0xF6...0xFF: s.append(Character(UnicodeScalar(UInt8(c - 0xF6 + 48))))
      default:
        if let ch = extra[c] { s.append(ch) }
      }
      i += 1
    }
    return s
  }

  /// Encodes `s` into a `length`-byte field: characters, then 0x50 padding (always at least one terminator).
  /// Unmappable characters are dropped.
  static func encode(_ s: String, length: Int = nameLength) -> [UInt8] {
    var out: [UInt8] = []
    for ch in s {
      if out.count >= length - 1 { break }
      if let a = ch.asciiValue {
        switch a {
        case 65...90: out.append(a - 65 + 0x80); continue
        case 97...122: out.append(a - 97 + 0xA0); continue
        case 48...57: out.append(a - 48 + 0xF6); continue
        default: break
        }
      }
      if let c = reverseExtra[ch] { out.append(c) }
    }
    while out.count < length { out.append(terminator) }
    return out
  }
}

enum Gen12Codec {
  /// Packed BCD (big-endian digits) → integer.
  static func bcd(_ b: [UInt8], off: Int, len: Int) -> Int {
    var v = 0
    for i in 0..<len {
      let x = b[off + i]
      v = v * 100 + Int((x >> 4) & 0xF) * 10 + Int(x & 0xF)
    }
    return v
  }

  /// Integer → packed BCD, clamped to what `len` bytes can hold.
  static func putBCD(_ b: inout [UInt8], off: Int, len: Int, _ value: Int) {
    var maxV = 1
    for _ in 0..<(len * 2) { maxV *= 10 }
    var v = Swift.max(0, Swift.min(value, maxV - 1))
    for i in stride(from: len - 1, through: 0, by: -1) {
      let lo = v % 10; v /= 10
      let hi = v % 10; v /= 10
      b[off + i] = UInt8((hi << 4) | lo)
    }
  }

  @inline(__always) static func be16(_ b: [UInt8], _ o: Int) -> Int { (Int(b[o]) << 8) | Int(b[o + 1]) }

  @inline(__always) static func putBE16(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    b[o] = UInt8(truncatingIfNeeded: v >> 8)
    b[o + 1] = UInt8(truncatingIfNeeded: v)
  }

  @inline(__always) static func be24(_ b: [UInt8], _ o: Int) -> Int {
    (Int(b[o]) << 16) | (Int(b[o + 1]) << 8) | Int(b[o + 2])
  }

  @inline(__always) static func putBE24(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    b[o] = UInt8(truncatingIfNeeded: v >> 16)
    b[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    b[o + 2] = UInt8(truncatingIfNeeded: v)
  }

  /// 8-bit complement-sum used by the Gen 1 save (`~sum(bytes)`).
  static func sum8(_ b: [UInt8], from: Int, to: Int) -> UInt8 {
    var s: UInt8 = 0
    for i in from..<to { s = s &+ b[i] }
    return s
  }

  /// 16-bit additive sum used by the Gen 2 save.
  static func sum16(_ b: [UInt8], from: Int, through: Int) -> Int {
    var s = 0
    for i in from...through { s = (s + Int(b[i])) & 0xFFFF }
    return s
  }

  static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, v)) }
}

/// Gen 1 / 2 stat formula (DVs 0…15, stat exp 0…65535). Callers supply base stats.
enum Gen12Stats {
  /// HP DV is derived from the low bit of the other four DVs.
  static func hpDV(atk: Int, def: Int, spe: Int, spc: Int) -> Int {
    ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1)
  }

  static func calc(base: Int, dv: Int, statExp: Int, level: Int, isHP: Bool) -> Int {
    var root = Int(Double(statExp).squareRoot().rounded(.up))
    if root > 255 { root = 255 }
    let core = ((base + dv) * 2 + root / 4) * level / 100
    return isHP ? core + level + 10 : core + 5
  }
}
