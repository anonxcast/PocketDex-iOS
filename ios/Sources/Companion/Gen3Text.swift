import Foundation

/// Gen 3 (Western) text: the byte charset nicknames, OT names and map names are stored in.
/// Port of `Gen3Text` (Pokedex.kt). Bytes with no mapping decode to `unknown`.
enum Gen3Text {
  static let unknown: Character = "\u{FFFD}"

  private static let table: [Character] = {
    var t = [Character](repeating: unknown, count: 256)
    t[0x00] = " "
    t[0x1B] = "é"
    for i in 0...9 { t[0xA1 + i] = Character(UnicodeScalar(UInt8(ascii: "0") + UInt8(i))) }
    t[0xAB] = "!"; t[0xAC] = "?"; t[0xAD] = "."; t[0xAE] = "-"; t[0xB0] = "…"
    t[0xB1] = "“"; t[0xB2] = "”"; t[0xB3] = "‘"; t[0xB4] = "’"
    t[0xB5] = "♂"; t[0xB6] = "♀"; t[0xB8] = ","; t[0xBA] = "/"
    for i in 0..<26 {
      t[0xBB + i] = Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(i)))
      t[0xD5 + i] = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i)))
    }
    t[0xF0] = ":"
    t[0x2D] = "&"; t[0x2E] = "+"; t[0x5B] = "%"; t[0x5C] = "("; t[0x5D] = ")"
    t[0x2A] = "°"
    t[0x35] = "="; t[0x36] = ";"
    // Western accented letters (charmap.txt), from 0x01.
    for (i, c) in Array("ÀÁÂÇÈÉÊËÌ ÎÏÒÓÔŒÙÚÛÑßàá çèéêëì îïòóôœùúûñ").enumerated() where c != " " {
      t[0x01 + i] = c
    }
    t[0x2B] = "ª"; t[0x51] = "¿"; t[0x52] = "¡"; t[0x5A] = "Í"; t[0x68] = "â"; t[0x6F] = "í"
    t[0x85] = "<"; t[0x86] = ">"; t[0xAF] = "·"; t[0xB9] = "×"
    for (i, c) in Array("ÄÖÜäöü").enumerated() { t[0xF1 + i] = c }
    return t
  }()

  /// Argument bytes after an 0xFC control code, by code (charmap.txt EXT_CTRL_CODE_*).
  private static let fcArgs: [Int] = [0, 1, 1, 1, 3, 1, 1, 0, 1, 0, 0, 2, 1, 1, 1, 0, 2, 1, 1, 1, 1, 0, 0, 0, 0]

  /// Glyphs that draw several letters, arrows, spacer, yen.
  private static let western: [Int: String] = [
    0x53: "PK", 0x54: "MN", 0x55: "PO", 0x56: "Ké", 0x34: "Lv", 0x2C: "er", 0x84: "e", 0xA0: "re",
    0x79: "↑", 0x7A: "↓", 0x7B: "←", 0x7C: "→", 0x77: "", 0xB7: "¥",
    0x57: "BL", 0x58: "OC", 0x59: "K",
  ]

  /// Encode a short nickname / OT into Gen 3 Western bytes (padded with 0xFF).
  static func encode(_ s: String, length: Int = 10) -> [UInt8] {
    var rev: [Character: UInt8] = [:]
    for (i, ch) in table.enumerated() where ch != unknown {
      if rev[ch] == nil { rev[ch] = UInt8(i) }
    }
    rev[" "] = 0x00
    var out = [UInt8](repeating: 0xFF, count: length)
    var i = 0
    for ch in s {
      guard i < length else { break }
      let upper = Character(ch.uppercased())
      if let b = rev[ch] ?? rev[upper] {
        out[i] = b
        i += 1
      }
    }
    return out
  }

  /// Up to `max` bytes from `off`, stopping at 0xFF. Line breaks become spaces; control codes (0xFC + args)
  /// and placeholders (0xFD + id) are dropped.
  static func decode(_ b: [UInt8], off: Int = 0, max: Int? = nil) -> String {
    guard off >= 0, off < b.count else { return "" }
    let end = min(b.count, off + (max ?? (b.count - off)))
    var out = ""
    var i = off
    while i < end {
      let c = Int(b[i])
      if c == 0xFF { break }
      if c == 0xFC, i + 1 < end {
        let code = Int(b[i + 1])
        i += 2 + (code < fcArgs.count ? fcArgs[code] : 0)
        continue
      }
      if c == 0xFD {
        i += 2
        continue
      }
      if c == 0xFE || c == 0xFA || c == 0xFB {
        out.append(" ")
      } else if let s = western[c] {
        out.append(s)
      } else {
        out.append(table[c])
      }
      i += 1
    }
    return out.trimmingCharacters(in: .whitespaces)
  }
}
