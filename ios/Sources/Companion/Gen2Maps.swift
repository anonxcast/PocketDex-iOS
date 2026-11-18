import Foundation

/// Gen 2 landmark lookup (group*256+num → landmark id → place name), matching PokeDaisy `gen2Landmark`.
enum Gen2Maps {
  private static func parsePairs(_ blob: String) -> [Int: Int] {
    var out: [Int: Int] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      let p = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      guard p.count == 2, let k = Int(p[0]), let v = Int(p[1]) else { continue }
      out[k] = v
    }
    return out
  }

  private static func parseNames(_ blob: String) -> [Int: String] {
    var out: [Int: String] = [:]
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"), let id = Int(line[line.startIndex..<bar]) else { continue }
      out[id] = String(line[line.index(after: bar)...])
    }
    return out
  }

  private static let landmarksPolished = parsePairs(Gen2MapBlobs.landmarksPolished)
  private static let namesPolished = parseNames(Gen2MapBlobs.namesPolished)
  private static let landmarksCrystal = parsePairs(Gen2MapBlobs.landmarksCrystal)
  private static let namesCrystal = parseNames(Gen2MapBlobs.namesCrystal)
  private static let landmarksGoldSilver = parsePairs(Gen2MapBlobs.landmarksGoldSilver)
  private static let namesGoldSilver = parseNames(Gen2MapBlobs.namesGoldSilver)
  private static let landmarksPrism = parsePairs(Gen2MapBlobs.landmarksPrism)
  private static let namesPrism = parseNames(Gen2MapBlobs.namesPrism)

  private static func tables(forGameId id: String) -> (landmarks: [Int: Int], names: [Int: String]) {
    switch id {
    case "polished_crystal": return (landmarksPolished, namesPolished)
    case "prism": return (landmarksPrism, namesPrism)
    case "gold", "silver": return (landmarksGoldSilver, namesGoldSilver)
    default: return (landmarksCrystal, namesCrystal)
    }
  }

  static func landmarkId(
    gameId: String,
    group: Int,
    num: Int,
    backupGroup: Int,
    backupNum: Int
  ) -> Int {
    let landmarks = tables(forGameId: gameId).landmarks
    let lm = landmarks[group * 256 + num] ?? 0
    if lm == 0 {
      return landmarks[backupGroup * 256 + backupNum] ?? 0
    }
    return lm
  }

  static func placeName(gameId: String, landmark: Int) -> String? {
    guard landmark > 0 else { return nil }
    let names = tables(forGameId: gameId).names
    guard let n = names[landmark], n != "?" else { return nil }
    return n
  }

  static func resolve(
    gameId: String,
    group: Int,
    num: Int,
    backupGroup: Int,
    backupNum: Int
  ) -> String {
    let id = landmarkId(
      gameId: gameId, group: group, num: num,
      backupGroup: backupGroup, backupNum: backupNum
    )
    if let name = placeName(gameId: gameId, landmark: id) { return name }
    return "Map \(group)-\(num)"
  }
}
