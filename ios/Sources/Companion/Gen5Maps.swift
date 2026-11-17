import Foundation

/// Gen 5 zone id → English place name (Android `mapPlacesBlack` / `mapPlacesBlack2`).
enum Gen5Maps {
  private static let black: [Int: String] = parse(Gen5MapBlobs.zonePlacesBlack)
  private static let black2: [Int: String] = parse(Gen5MapBlobs.zonePlacesBlack2)

  private static func parse(_ blob: String) -> [Int: String] {
    var out: [Int: String] = [:]
    out.reserveCapacity(blob.count / 16)
    for line in blob.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let bar = line.firstIndex(of: "|"),
            let zone = Int(line[line.startIndex..<bar]) else { continue }
      out[zone] = String(line[line.index(after: bar)...])
    }
    return out
  }

  /// `gameId` is Gen5Config.id (`black`, `white`, `black2`, `white2`, …).
  static func placeName(gameId: String, zone: Int) -> String? {
    let id = gameId.lowercased()
    if id.hasPrefix("black2") || id.hasPrefix("white2") {
      return black2[zone]
    }
    if id.hasPrefix("black") || id.hasPrefix("white") {
      return black[zone]
    }
    return black2[zone] ?? black[zone]
  }
}
