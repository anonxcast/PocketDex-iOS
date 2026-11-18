import Combine
import Foundation

/// Live companion + FPS HUD state — kept off `EmulatorEngine` so sample/fps
/// updates do not rebuild all of PlayView (that alone pinned GB/GBA at ~53–58).
@MainActor
final class CompanionLiveStore: ObservableObject {
  static let shared = CompanionLiveStore()

  @Published private(set) var snapshot: CompanionSnapshot?
  /// Reactive Smart Island tip (memory + phrase bank + tap cycle).
  @Published private(set) var islandAdvice: Gen3BattleCoach.Advice?
  /// One-shot island FX (ball throw / catch result) — independent of tip text.
  @Published private(set) var islandFXPulse: SmartIslandFXPulse?
  /// Full pulse batch from the latest sample (throw + result in one tick).
  @Published private(set) var islandFXBatch: [SmartIslandFXPulse] = []
  @Published var hint =
    "PocketDex companion will read party / bag / map once a Pokémon game is running."
  @Published private(set) var gameName: String?
  @Published private(set) var match: Gen3Config.MatchKind?
  /// Short charismatic line after a fight ends (win / lose); cleared after a few seconds.
  @Published private(set) var battleEpilogue: String?

  private var epilogueClearTask: Task<Void, Never>?

  func setSnapshot(_ snap: CompanionSnapshot?) {
    if let line = Gen3BattleCoach.battleEpilogue(previous: snapshot, current: snap) {
      publishEpilogue(line)
    }
    if snapshot != snap { snapshot = snap }
    let next = SmartIslandMemory.shared.observe(snap)
    if islandAdvice != next { islandAdvice = next }
    flushPulses()
  }

  /// Tap the island to flip secondary tips for the current situation.
  func cycleIslandTip() {
    SmartIslandMemory.shared.cycleTip()
    guard let snap = snapshot else { return }
    let next = SmartIslandMemory.shared.observe(snap)
    if islandAdvice != next { islandAdvice = next }
    flushPulses()
  }

  private func flushPulses() {
    let batch = SmartIslandMemory.shared.consumeAllPulses()
    guard !batch.isEmpty else { return }
    islandFXBatch = batch
    islandFXPulse = batch.last
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
    epilogueClearTask?.cancel()
    epilogueClearTask = nil
    snapshot = nil
    islandAdvice = nil
    islandFXPulse = nil
    islandFXBatch = []
    gameName = nil
    match = nil
    battleEpilogue = nil
    SmartIslandMemory.shared.reset()
    hint = "PocketDex companion will read party / bag / map once a Pokémon game is running."
  }

  private func publishEpilogue(_ line: String) {
    battleEpilogue = line
    epilogueClearTask?.cancel()
    epilogueClearTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      if battleEpilogue == line { battleEpilogue = nil }
    }
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
