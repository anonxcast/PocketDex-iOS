import Foundation
import SwiftUI

/// What happens when you tap a game in the library.
enum LibraryOpenMode: String, CaseIterable, Identifiable {
  case gamePage
  case quickPlay

  var id: String { rawValue }

  var title: String {
    switch self {
    case .gamePage: return "Game Page"
    case .quickPlay: return "Quick Play"
    }
  }

  var subtitle: String {
    switch self {
    case .gamePage: return "Open the game’s page (art, summary, achievements, Play)"
    case .quickPlay: return "Show the Play bubble at your finger — jump straight in"
    }
  }
}

/// App chrome Light / Dark — default follows iOS Appearance.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// PokeDaisy-style aspect modes. Expand uses native pk_wide (more map, not a stretch).
enum GameAspectMode: String, CaseIterable, Identifiable {
  case original, stretch, expand
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: return "Original"
    case .stretch: return "Stretch"
    case .expand: return "Expand"
    }
  }
  var subtitle: String {
    switch self {
    case .original: return "True 4:3 / console ratio — letterboxed, never squashed"
    case .stretch: return "Fill the play area (pixels may stretch)"
    case .expand: return "Ultrawide: show more map left/right (WIDE)"
    }
  }
  mutating func cycle() {
    switch self {
    case .original: self = .stretch
    case .stretch: self = .expand
    case .expand: self = .original
    }
  }
}

enum ScreenFilter: String, CaseIterable, Identifiable {
  case none, lcd, lcdPaper, scanlines, crt
  var id: String { rawValue }
  var title: String {
    switch self {
    case .none: return "None"
    case .lcd: return "LCD"
    case .lcdPaper: return "LCD Paper"
    case .scanlines: return "Scanlines"
    case .crt: return "CRT"
    }
  }
  var hasGrid: Bool { self == .lcd || self == .lcdPaper }

  mutating func cycle() {
    let all = Self.allCases
    self = all[(all.firstIndex(of: self)! + 1) % all.count]
  }
}

enum GridStrength: String, CaseIterable, Identifiable {
  case soft, medium, strong
  var id: String { rawValue }
  var title: String {
    switch self {
    case .soft: return "Soft"
    case .medium: return "Medium"
    case .strong: return "Strong"
    }
  }
  /// Darkening amount for LCD grid lines (from PokeDaisy ScreenShaders.kt).
  var lcdDarken: CGFloat {
    switch self {
    case .soft: return 0.20
    case .medium: return 0.35
    case .strong: return 0.50
    }
  }
  mutating func cycle() {
    let all = Self.allCases
    self = all[(all.firstIndex(of: self)! + 1) % all.count]
  }
}

enum SmoothingMode: String, CaseIterable, Identifiable {
  case off, soft
  var id: String { rawValue }
  var title: String {
    switch self {
    case .off: return "Off"
    case .soft: return "On"
    }
  }
  mutating func cycle() {
    self = self == .off ? .soft : .off
  }
}

enum StatusBarMode: String, CaseIterable, Identifiable {
  case off, game
  var id: String { rawValue }
  var title: String {
    switch self {
    case .off: return "Off"
    case .game: return "Game"
    }
  }
  mutating func cycle() {
    self = self == .off ? .game : .off
  }
}

/// PokeDaisy DS LAYOUT on a single display (Duo fold still uses both panes).
enum DsLayoutMode: String, CaseIterable, Identifiable {
  case oneScreen, stacked
  var id: String { rawValue }
  var title: String {
    switch self {
    case .oneScreen: return "One Screen"
    case .stacked: return "Stacked"
    }
  }
  var subtitle: String {
    switch self {
    case .oneScreen: return "Game fills the screen; touch pops up when needed"
    case .stacked: return "Top and touch LCDs stacked like an open DS"
    }
  }
  mutating func cycle() {
    self = self == .oneScreen ? .stacked : .oneScreen
  }
}

/// Zoom step index when Expand is on (0 = 1× close / full frame; higher = more map visible).
/// Actual step count depends on the play-area size vs pk_wide’s 800×800 buffer — cycle with `cycle(available:)`.
enum ZoomLevel: Int, CaseIterable, Identifiable {
  case x1 = 0, x2, x3, x4
  var id: Int { rawValue }
  /// Fallback label when no live display size is known yet.
  var title: String {
    switch self {
    case .x1: return "1× (close)"
    case .x2: return "2× out"
    case .x3: return "3× out"
    case .x4: return "4× out"
    }
  }
  mutating func cycle() {
    cycle(available: Self.allCases.count)
  }
  /// Wrap within the number of distinct WIDE zoom steps the current screen actually supports.
  mutating func cycle(available: Int) {
    let n = max(1, min(Self.allCases.count, available))
    let next = (rawValue + 1) % n
    self = ZoomLevel(rawValue: next) ?? .x1
  }
}
