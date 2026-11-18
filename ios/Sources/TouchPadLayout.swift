import Foundation
import SwiftUI

enum PadControlID: String, CaseIterable, Codable, Identifiable {
  case dpad, a, b, x, y, start, select, l, r
  /// HUD-only — opens save states; not a GBA/NDS key bit.
  case save
  /// HUD-only (NDS one-screen) — show/hide the floating touch LCD.
  case touch

  var id: String { rawValue }

  /// GBA / GB pads omit X/Y; NDS needs the full set. (No SAVE / TOUCH — HUD overlays.)
  static let gbaCases: [PadControlID] = [.dpad, .a, .b, .start, .select, .l, .r]
  static let ndsCases: [PadControlID] = [.dpad, .a, .b, .x, .y, .start, .select, .l, .r]
  /// Editor draws game keys + movable SAVE (+ TOUCH on NDS).
  static func editorCases(nds: Bool) -> [PadControlID] {
    var ids = (nds ? ndsCases : gbaCases) + [.save]
    if nds { ids.append(.touch) }
    return ids
  }

  /// True for emulator key bits (PadTouch hits); false for HUD chrome like SAVE / TOUCH.
  var isGameKey: Bool { self != .save && self != .touch }

  var title: String {
    switch self {
    case .dpad: return "D-Pad"
    case .a: return "A"
    case .b: return "B"
    case .x: return "X"
    case .y: return "Y"
    case .start: return "Start"
    case .select: return "Select"
    case .l: return "L"
    case .r: return "R"
    case .save: return "Save"
    case .touch: return "Touch"
    }
  }

  /// Base size before scale (points).
  var baseSize: CGSize {
    switch self {
    case .dpad: return CGSize(width: 148, height: 148)
    case .a, .b, .x, .y: return CGSize(width: 64, height: 64)
    case .start, .select: return CGSize(width: 78, height: 34)
    case .l, .r: return CGSize(width: 84, height: 36)
    case .save, .touch: return CGSize(width: 96, height: 38)
    }
  }

  var cornerRadius: CGFloat {
    switch self {
    case .dpad: return 18
    case .a, .b, .x, .y: return 30
    case .start, .select, .save, .touch: return 14
    case .l, .r: return 15
    }
  }
}

/// Which Duo face owns a pad layout. Cover = front/outer (hinge closed); inner = open phone.
enum PadSurface: String, CaseIterable, Codable, Identifiable {
  case inner
  case cover

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inner: return "Inner"
    case .cover: return "Front"
    }
  }

  var subtitle: String {
    switch self {
    case .inner: return "Open phone"
    case .cover: return "Cover screen"
    }
  }
}

struct PadLayoutProfile: Hashable {
  var surface: PadSurface
  var landscape: Bool

  var title: String {
    "\(surface.title) · \(landscape ? "Landscape" : "Portrait")"
  }
}

struct PadControlPlacement: Codable, Equatable {
  /// Normalized center X in the pad canvas (0…1).
  var x: CGFloat
  /// Normalized center Y in the pad canvas (0…1).
  var y: CGFloat
  /// Size multiplier (0.7…1.6).
  var scale: CGFloat

  init(x: CGFloat, y: CGFloat, scale: CGFloat = 1) {
    self.x = min(1, max(0, x))
    self.y = min(1, max(0, y))
    self.scale = min(1.6, max(0.7, scale))
  }
}

struct TouchPadLayout: Codable, Equatable {
  var controls: [String: PadControlPlacement]

  subscript(_ id: PadControlID) -> PadControlPlacement {
    get { controls[id.rawValue] ?? Self.fallback(id) }
    set { controls[id.rawValue] = newValue }
  }

  static func fallback(_ id: PadControlID) -> PadControlPlacement {
    defaultPortrait()[id]
  }

  /// Full-canvas portrait — controls live in the lower third (LCD(s) sit above).
  static func defaultPortrait() -> TouchPadLayout {
    TouchPadLayout(controls: [
      PadControlID.l.rawValue: .init(x: 0.14, y: 0.66),
      PadControlID.r.rawValue: .init(x: 0.86, y: 0.66),
      PadControlID.dpad.rawValue: .init(x: 0.20, y: 0.84),
      PadControlID.select.rawValue: .init(x: 0.42, y: 0.72),
      PadControlID.start.rawValue: .init(x: 0.58, y: 0.72),
      PadControlID.y.rawValue: .init(x: 0.72, y: 0.76),
      PadControlID.x.rawValue: .init(x: 0.88, y: 0.76),
      PadControlID.b.rawValue: .init(x: 0.72, y: 0.90),
      PadControlID.a.rawValue: .init(x: 0.88, y: 0.90),
      PadControlID.save.rawValue: .init(x: 0.32, y: 0.955),
      PadControlID.touch.rawValue: .init(x: 0.68, y: 0.955),
    ])
  }

  /// Full-canvas landscape — side gutters only (center column reserved for LCD(s)).
  static func defaultLandscape() -> TouchPadLayout {
    TouchPadLayout(controls: [
      PadControlID.l.rawValue: .init(x: 0.08, y: 0.22),
      PadControlID.r.rawValue: .init(x: 0.92, y: 0.22),
      PadControlID.dpad.rawValue: .init(x: 0.11, y: 0.55),
      PadControlID.select.rawValue: .init(x: 0.11, y: 0.88),
      PadControlID.start.rawValue: .init(x: 0.89, y: 0.88),
      PadControlID.y.rawValue: .init(x: 0.82, y: 0.42),
      PadControlID.x.rawValue: .init(x: 0.92, y: 0.42),
      PadControlID.b.rawValue: .init(x: 0.82, y: 0.62),
      PadControlID.a.rawValue: .init(x: 0.92, y: 0.62),
      PadControlID.save.rawValue: .init(x: 0.38, y: 0.92),
      PadControlID.touch.rawValue: .init(x: 0.62, y: 0.92),
    ])
  }

  /// Duo cover/front portrait — short face; tighter lower band + slightly smaller defaults.
  static func defaultCoverPortrait() -> TouchPadLayout {
    TouchPadLayout(controls: [
      PadControlID.l.rawValue: .init(x: 0.13, y: 0.58, scale: 0.9),
      PadControlID.r.rawValue: .init(x: 0.87, y: 0.58, scale: 0.9),
      PadControlID.dpad.rawValue: .init(x: 0.18, y: 0.78, scale: 0.85),
      PadControlID.select.rawValue: .init(x: 0.40, y: 0.64, scale: 0.9),
      PadControlID.start.rawValue: .init(x: 0.60, y: 0.64, scale: 0.9),
      PadControlID.y.rawValue: .init(x: 0.74, y: 0.70, scale: 0.9),
      PadControlID.x.rawValue: .init(x: 0.90, y: 0.70, scale: 0.9),
      PadControlID.b.rawValue: .init(x: 0.74, y: 0.86, scale: 0.9),
      PadControlID.a.rawValue: .init(x: 0.90, y: 0.86, scale: 0.9),
      PadControlID.save.rawValue: .init(x: 0.32, y: 0.94, scale: 0.85),
      PadControlID.touch.rawValue: .init(x: 0.68, y: 0.94, scale: 0.85),
    ])
  }

  /// Duo cover/front landscape — L/R sit below edit chrome so they stay draggable.
  static func defaultCoverLandscape() -> TouchPadLayout {
    TouchPadLayout(controls: [
      PadControlID.l.rawValue: .init(x: 0.07, y: 0.34, scale: 0.9),
      PadControlID.r.rawValue: .init(x: 0.93, y: 0.34, scale: 0.9),
      PadControlID.dpad.rawValue: .init(x: 0.10, y: 0.62, scale: 0.85),
      PadControlID.select.rawValue: .init(x: 0.10, y: 0.90, scale: 0.85),
      PadControlID.start.rawValue: .init(x: 0.90, y: 0.90, scale: 0.85),
      PadControlID.y.rawValue: .init(x: 0.84, y: 0.48, scale: 0.9),
      PadControlID.x.rawValue: .init(x: 0.94, y: 0.48, scale: 0.9),
      PadControlID.b.rawValue: .init(x: 0.84, y: 0.68, scale: 0.9),
      PadControlID.a.rawValue: .init(x: 0.94, y: 0.68, scale: 0.9),
      PadControlID.save.rawValue: .init(x: 0.38, y: 0.93, scale: 0.85),
      PadControlID.touch.rawValue: .init(x: 0.62, y: 0.93, scale: 0.85),
    ])
  }

  /// Pull L/R out from under the editor chrome if a saved cover-landscape layout left them high.
  mutating func ensureCoverLandscapeShouldersClear() {
    let minY: CGFloat = 0.28
    for id in [PadControlID.l, .r] {
      var p = self[id]
      if p.y < minY {
        p.y = 0.34
        self[id] = p
      }
    }
  }

  static func `default`(profile: PadLayoutProfile) -> TouchPadLayout {
    switch (profile.surface, profile.landscape) {
    case (.inner, false): return defaultPortrait()
    case (.inner, true): return defaultLandscape()
    case (.cover, false): return defaultCoverPortrait()
    case (.cover, true): return defaultCoverLandscape()
    }
  }

  /// Ensure HUD SAVE exists after loading older layout blobs.
  mutating func ensuringSavePlacement(landscape: Bool, surface: PadSurface = .inner) {
    guard controls[PadControlID.save.rawValue] == nil else { return }
    let fallback = Self.default(profile: PadLayoutProfile(surface: surface, landscape: landscape))
    controls[PadControlID.save.rawValue] = fallback[.save]
  }

  /// Ensure NDS TOUCH/HIDE exists after loading older layout blobs.
  mutating func ensuringTouchPlacement(landscape: Bool, surface: PadSurface = .inner) {
    guard controls[PadControlID.touch.rawValue] == nil else { return }
    let fallback = Self.default(profile: PadLayoutProfile(surface: surface, landscape: landscape))
    controls[PadControlID.touch.rawValue] = fallback[.touch]
  }

  /// Backfill HUD chrome placements (SAVE + TOUCH) for older saved layouts.
  mutating func ensuringHudPlacements(landscape: Bool, surface: PadSurface = .inner) {
    ensuringSavePlacement(landscape: landscape, surface: surface)
    ensuringTouchPlacement(landscape: landscape, surface: surface)
  }

  mutating func move(_ id: PadControlID, toNormalized point: CGPoint) {
    var p = self[id]
    p.x = min(0.98, max(0.02, point.x))
    p.y = min(0.98, max(0.02, point.y))
    self[id] = p
  }

  mutating func setScale(_ id: PadControlID, _ scale: CGFloat) {
    var p = self[id]
    p.scale = min(1.6, max(0.7, scale))
    self[id] = p
  }
}

@MainActor
final class TouchPadLayoutStore: ObservableObject {
  static let shared = TouchPadLayoutStore()

  private enum Key {
    // v5: separate Duo cover (front) vs inner layouts.
    static let innerPortrait = "touchPad.layout.inner.portrait.v5"
    static let innerLandscape = "touchPad.layout.inner.landscape.v5"
    static let coverPortrait = "touchPad.layout.cover.portrait.v5"
    static let coverLandscape = "touchPad.layout.cover.landscape.v5"
    // v4: orientation only — migrate into inner profiles.
    static let portraitV4 = "touchPad.layout.portrait.v4"
    static let landscapeV4 = "touchPad.layout.landscape.v4"
    static let portraitV3 = "touchPad.layout.portrait.v3"
    static let landscapeV3 = "touchPad.layout.landscape.v3"
  }

  @Published private(set) var innerPortrait: TouchPadLayout
  @Published private(set) var innerLandscape: TouchPadLayout
  @Published private(set) var coverPortrait: TouchPadLayout
  @Published private(set) var coverLandscape: TouchPadLayout

  private init() {
    var ip = Self.load(Key.innerPortrait)
      ?? Self.load(Key.portraitV4)
      ?? Self.load(Key.portraitV3)
      ?? .defaultPortrait()
    var il = Self.load(Key.innerLandscape)
      ?? Self.load(Key.landscapeV4)
      ?? Self.load(Key.landscapeV3)
      ?? .defaultLandscape()
    // Cover starts from cover-tuned defaults (not a copy of inner) so front edits stay independent.
    var cp = Self.load(Key.coverPortrait) ?? .defaultCoverPortrait()
    var cl = Self.load(Key.coverLandscape) ?? .defaultCoverLandscape()
    ip.ensuringHudPlacements(landscape: false, surface: .inner)
    il.ensuringHudPlacements(landscape: true, surface: .inner)
    cp.ensuringHudPlacements(landscape: false, surface: .cover)
    cl.ensuringHudPlacements(landscape: true, surface: .cover)
    cl.ensureCoverLandscapeShouldersClear()
    innerPortrait = ip
    innerLandscape = il
    coverPortrait = cp
    coverLandscape = cl
    // Persist the shoulder nudge once so edit + play stay aligned.
    Self.persist(cl, key: Key.coverLandscape)
  }

  func layout(landscape: Bool, surface: PadSurface = .inner) -> TouchPadLayout {
    layout(PadLayoutProfile(surface: surface, landscape: landscape))
  }

  func layout(_ profile: PadLayoutProfile) -> TouchPadLayout {
    var layout: TouchPadLayout
    switch (profile.surface, profile.landscape) {
    case (.inner, false): layout = innerPortrait
    case (.inner, true): layout = innerLandscape
    case (.cover, false): layout = coverPortrait
    case (.cover, true):
      layout = coverLandscape
      layout.ensureCoverLandscapeShouldersClear()
    }
    layout.ensuringHudPlacements(landscape: profile.landscape, surface: profile.surface)
    return layout
  }

  func save(_ layout: TouchPadLayout, landscape: Bool, surface: PadSurface = .inner) {
    save(layout, profile: PadLayoutProfile(surface: surface, landscape: landscape))
  }

  func save(_ layout: TouchPadLayout, profile: PadLayoutProfile) {
    var next = layout
    next.ensuringHudPlacements(landscape: profile.landscape, surface: profile.surface)
    switch (profile.surface, profile.landscape) {
    case (.inner, false):
      innerPortrait = next
      Self.persist(next, key: Key.innerPortrait)
    case (.inner, true):
      innerLandscape = next
      Self.persist(next, key: Key.innerLandscape)
    case (.cover, false):
      coverPortrait = next
      Self.persist(next, key: Key.coverPortrait)
    case (.cover, true):
      coverLandscape = next
      Self.persist(next, key: Key.coverLandscape)
    }
  }

  func reset(landscape: Bool, surface: PadSurface = .inner) {
    let profile = PadLayoutProfile(surface: surface, landscape: landscape)
    save(.default(profile: profile), profile: profile)
  }

  func resetAll() {
    for surface in PadSurface.allCases {
      reset(landscape: false, surface: surface)
      reset(landscape: true, surface: surface)
    }
  }

  private static func load(_ key: String) -> TouchPadLayout? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(TouchPadLayout.self, from: data)
  }

  private static func persist(_ layout: TouchPadLayout, key: String) {
    if let data = try? JSONEncoder().encode(layout) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}
