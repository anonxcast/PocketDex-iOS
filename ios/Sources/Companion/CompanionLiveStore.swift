import Combine
import Foundation

/// Live companion + FPS HUD state — kept off `EmulatorEngine` so sample/fps
/// updates do not rebuild all of PlayView (that alone pinned GB/GBA at ~53–58).
@MainActor
final class CompanionLiveStore: ObservableObject {
  static let shared = CompanionLiveStore()

  @Published private(set) var snapshot: CompanionSnapshot?
  @Published var hint =
    "PocketDex companion will read party / bag / map once a Pokémon game is running."
  @Published private(set) var gameName: String?
  @Published private(set) var match: Gen3Config.MatchKind?

  func setSnapshot(_ snap: CompanionSnapshot?) {
    if snapshot != snap { snapshot = snap }
  }

  func setGameName(_ name: String?) {
    if gameName != name { gameName = name }
  }

  func setMatch(_ kind: Gen3Config.MatchKind?) {
    if match != kind { match = kind }
  }

  func setHint(_ text: String) {
    if hint != text { hint = text }
  }

  func clear() {
    snapshot = nil
    gameName = nil
    match = nil
    hint = "PocketDex companion will read party / bag / map once a Pokémon game is running."
  }
}

@MainActor
final class FpsBadge: ObservableObject {
  static let shared = FpsBadge()
  @Published private(set) var value = 0

  func set(_ n: Int) {
    if value != n { value = n }
  }

  func reset() { value = 0 }
}
