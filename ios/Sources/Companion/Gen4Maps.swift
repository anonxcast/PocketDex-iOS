import Foundation

/// Gen 4 map-header → place name (HeartGold / SoulSilver share pret's map headers).
enum Gen4Maps {
  private static let heartGold: [Int: String] = {
    var d: [Int: String] = [:]
    for line in Gen4MapBlobs.heartGoldPlaces.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "|", maxSplits: 1)
      guard parts.count == 2, let id = Int(parts[0]) else { continue }
      d[id] = String(parts[1])
    }
    return d
  }()

  static func placeName(gameId: String, header: Int) -> String? {
    // SoulSilver / language variants use the same header table as HeartGold.
    if gameId.hasPrefix("heartgold") || gameId.hasPrefix("soulsilver") {
      return heartGold[header]
    }
    return heartGold[header]
  }
}

/// Reverse wild index: National Dex species → HeartGold map headers where it appears.
enum Gen4Encounters {
  private static let hgSpeciesMaps: [Int: [Int]] = {
    var d: [Int: [Int]] = [:]
    for line in Gen4EncounterBlobs.heartGoldSpeciesMaps.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "|", maxSplits: 1)
      guard parts.count == 2, let sp = Int(parts[0]) else { continue }
      let maps = parts[1].split(separator: ",").compactMap { Int($0) }
      if !maps.isEmpty { d[sp] = maps }
    }
    return d
  }()

  /// Up to `limit` place names where `species` can be found in HeartGold.
  static func foundIn(species: Int, limit: Int = 12) -> [String] {
    guard let headers = hgSpeciesMaps[species] else { return [] }
    var names: [String] = []
    var seen = Set<String>()
    for h in headers {
      let name = Gen4Maps.placeName(gameId: "heartgold", header: h) ?? "Map \(h)"
      if seen.insert(name).inserted {
        names.append(name)
        if names.count >= limit { break }
      }
    }
    return names
  }
}
