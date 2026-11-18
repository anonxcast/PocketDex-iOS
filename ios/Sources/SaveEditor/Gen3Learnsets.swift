import Foundation

/// Species learnsets for the save-editor move picker (Showdown learnsets ∪ all formes,
/// keyed by National Dex #). Move names are matched to the active ROM’s move id table.
enum Gen3Learnsets {
  private static let bundleName = "LearnsetsNational"
  private static let bundleExt = "bin"

  private static let data: Payload? = {
    let url = Bundle.main.url(forResource: bundleName, withExtension: bundleExt)
      ?? Bundle.main.url(forResource: bundleName, withExtension: bundleExt, subdirectory: nil)
    guard let url, let bytes = try? Data(contentsOf: url) else { return nil }
    return Payload.parse(bytes)
  }()

  /// Move ids this species can learn (level-up / TM / egg / tutor across gens), in the
  /// active name table. Empty when the species or learnset data is unknown.
  static func learnableMoveIds(species: Int, tables: Gen3Tables) -> Set<Int> {
    guard species > 0, let data else { return [] }
    let national: Int?
    if let n = Gen3Names.nationalNumber(species: species, tables: tables) {
      national = n
    } else {
      switch tables {
      case .national, .hns, .yellow, .crystal, .polished, .prism: national = species
      default: national = nil
      }
    }
    guard let national, national > 0, national <= data.maxNational else { return [] }
    let names = data.moveNames(forNational: national)
    guard !names.isEmpty else { return [] }
    let reverse = reverseMoveMap(tables: tables)
    var out = Set<Int>()
    out.reserveCapacity(names.count)
    for name in names {
      if let id = reverse[name] { out.insert(id) }
    }
    return out
  }

  static func canLearn(species: Int, move: Int, tables: Gen3Tables) -> Bool {
    guard move > 0 else { return false }
    return learnableMoveIds(species: species, tables: tables).contains(move)
  }

  // MARK: - Name ↔ id

  private static var reverseCache: [Gen3Tables: [String: Int]] = [:]

  private static func reverseMoveMap(tables: Gen3Tables) -> [String: Int] {
    if let hit = reverseCache[tables] { return hit }
    // Use the same per-game move table as the save-editor catalog (Yellow / Crystal /
    // retail Gen 3 / Unbound / Seaglass / DS), not Unbound-only names.
    let source = Gen3BattleData.moveNames(tables: tables)
    var map: [String: Int] = [:]
    map.reserveCapacity(source.count)
    for (id, name) in source {
      let key = normalize(name)
      // Prefer the lowest id when aliases collide.
      if map[key] == nil { map[key] = id }
    }
    reverseCache[tables] = map
    return map
  }

  static func normalize(_ name: String) -> String {
    var out = ""
    out.reserveCapacity(name.count)
    for ch in name.lowercased() {
      if ch.isLetter || ch.isNumber { out.append(ch) }
    }
    return out
  }

  // MARK: - Binary payload

  /// `PKLS` v1: move-name table + per-National-Dex sorted name indices.
  private struct Payload {
    let moveNameTable: [String]
    let indicesByNational: [[UInt16]]  // 1-based species → indices into moveNameTable
    var maxNational: Int { indicesByNational.count }

    func moveNames(forNational n: Int) -> [String] {
      guard n >= 1, n <= indicesByNational.count else { return [] }
      return indicesByNational[n - 1].compactMap { i in
        let idx = Int(i)
        return moveNameTable.indices.contains(idx) ? moveNameTable[idx] : nil
      }
    }

    static func parse(_ data: Data) -> Payload? {
      guard data.count >= 10 else { return nil }
      var o = 0
      func u8() -> UInt8 { defer { o += 1 }; return data[o] }
      func u16() -> UInt16 {
        defer { o += 2 }
        return UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
      }
      func u32() -> UInt32 {
        defer { o += 4 }
        return UInt32(data[o]) | (UInt32(data[o + 1]) << 8)
          | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
      }
      guard data[0] == 0x50, data[1] == 0x4B, data[2] == 0x4C, data[3] == 0x53 else { return nil } // PKLS
      o = 4
      let version = u32()
      guard version == 1 else { return nil }
      let nameCount = Int(u16())
      var names: [String] = []
      names.reserveCapacity(nameCount)
      for _ in 0..<nameCount {
        let len = Int(u8())
        guard o + len <= data.count else { return nil }
        let s = String(data: data.subdata(in: o..<(o + len)), encoding: .utf8) ?? ""
        o += len
        names.append(s)
      }
      let speciesCount = Int(u16())
      var byNat: [[UInt16]] = []
      byNat.reserveCapacity(speciesCount)
      for _ in 0..<speciesCount {
        let count = Int(u16())
        var idxs: [UInt16] = []
        idxs.reserveCapacity(count)
        for _ in 0..<count { idxs.append(u16()) }
        byNat.append(idxs)
      }
      return Payload(moveNameTable: names, indicesByNational: byNat)
    }
  }
}
