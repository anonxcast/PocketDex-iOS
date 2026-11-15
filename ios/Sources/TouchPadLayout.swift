import Foundation
import SwiftUI

enum PadControlID: String, CaseIterable, Codable, Identifiable {
  case dpad, a, b, x, y, start, select, l, r

  var id: String { rawValue }

  /// GBA / GB pads omit X/Y; NDS needs the full set.
  static let gbaCases: [PadControlID] = [.dpad, .a, .b, .start, .select, .l, .r]
  static let ndsCases: [PadControlID] = [.dpad, .a, .b, .x, .y, .start, .select, .l, .r]

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
    }
  }

  /// Base size before scale (points).
  var baseSize: CGSize {
    switch self {
    case .dpad: return CGSize(width: 148, height: 148)
    case .a, .b, .x, .y: return CGSize(width: 64, height: 64)
    case .start, .select: return CGSize(width: 78, height: 34)
    case .l, .r: return CGSize(width: 84, height: 36)
    }
  }

  var cornerRadius: CGFloat {
    switch self {
    case .dpad: return 18
    case .a, .b, .x, .y: return 30
    case .start, .select: return 14
    case .l, .r: return 15
    }
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
    ])
  }

  /// Full-canvas landscape — side gutters only (center column reserved for LCD(s)).
  static func defaultLandscape() -> TouchPadLayout {
    TouchPadLayout(controls: [
      PadControlID.l.rawValue: .init(x: 0.08, y: 0.14),
      PadControlID.r.rawValue: .init(x: 0.92, y: 0.14),
      PadControlID.dpad.rawValue: .init(x: 0.11, y: 0.55),
      PadControlID.select.rawValue: .init(x: 0.11, y: 0.88),
      PadControlID.start.rawValue: .init(x: 0.89, y: 0.88),
      PadControlID.y.rawValue: .init(x: 0.82, y: 0.42),
      PadControlID.x.rawValue: .init(x: 0.92, y: 0.42),
      PadControlID.b.rawValue: .init(x: 0.82, y: 0.62),
      PadControlID.a.rawValue: .init(x: 0.92, y: 0.62),
    ])
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
    // v3: play + edit share one full-canvas coordinate space.
    static let portrait = "touchPad.layout.portrait.v3"
    static let landscape = "touchPad.layout.landscape.v3"
  }

  @Published private(set) var portrait: TouchPadLayout
  @Published private(set) var landscape: TouchPadLayout

  private init() {
    portrait = Self.load(Key.portrait) ?? .defaultPortrait()
    landscape = Self.load(Key.landscape) ?? .defaultLandscape()
  }

  func layout(landscape: Bool) -> TouchPadLayout {
    landscape ? self.landscape : portrait
  }

  func save(_ layout: TouchPadLayout, landscape: Bool) {
    if landscape {
      self.landscape = layout
      Self.persist(layout, key: Key.landscape)
    } else {
      portrait = layout
      Self.persist(layout, key: Key.portrait)
    }
  }

  func reset(landscape: Bool) {
    save(landscape ? .defaultLandscape() : .defaultPortrait(), landscape: landscape)
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
