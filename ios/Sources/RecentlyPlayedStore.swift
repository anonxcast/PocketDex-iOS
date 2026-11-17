import Foundation
import Combine

/// Persists last-played timestamps per ROM (`RomItem.sessionKey`) for the library’s Recently Played rows.
@MainActor
final class RecentlyPlayedStore: ObservableObject {
  static let shared = RecentlyPlayedStore()

  private static let defaultsKey = "library.recentlyPlayed.v1"
  private static let maxEntries = 64

  @Published private(set) var datesByKey: [String: Date] = [:]

  private init() {
    load()
  }

  func lastPlayed(for rom: RomItem) -> Date? {
    datesByKey[rom.sessionKey]
  }

  func markPlayed(_ rom: RomItem, at date: Date = Date()) {
    datesByKey[rom.sessionKey] = date
    trimAndSave()
  }

  func remove(sessionKey: String) {
    guard datesByKey.removeValue(forKey: sessionKey) != nil else { return }
    save()
  }

  /// Newest first, capped, only keys still present in `roms`.
  func recent(in roms: [RomItem], limit: Int = 3) -> [RomItem] {
    let byKey = Dictionary(uniqueKeysWithValues: roms.map { ($0.sessionKey, $0) })
    return datesByKey
      .compactMap { key, date -> (RomItem, Date)? in
        guard let rom = byKey[key] else { return nil }
        return (rom, date)
      }
      .sorted { $0.1 > $1.1 }
      .prefix(limit)
      .map(\.0)
  }

  private func load() {
    guard let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] else {
      datesByKey = [:]
      return
    }
    datesByKey = raw.mapValues { Date(timeIntervalSince1970: $0) }
  }

  private func trimAndSave() {
    if datesByKey.count > Self.maxEntries {
      let keep = datesByKey.sorted { $0.value > $1.value }.prefix(Self.maxEntries)
      datesByKey = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
    save()
  }

  private func save() {
    let raw = datesByKey.mapValues { $0.timeIntervalSince1970 }
    UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
  }
}
