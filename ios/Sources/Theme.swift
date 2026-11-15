import SwiftUI
import UIKit

enum CETheme {
  /// Music / Liquid Glass canvas — soft graphite, not crushed black.
  static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
  static let elevated = Color(red: 0.10, green: 0.10, blue: 0.11)
  static let card = Color(red: 0.14, green: 0.14, blue: 0.15).opacity(0.72)
  static let hover = Color(red: 0.20, green: 0.20, blue: 0.22)
  static let border = Color.white.opacity(0.14)
  static let text = Color(red: 0.98, green: 0.98, blue: 0.99)
  static let muted = Color(red: 0.68, green: 0.68, blue: 0.70)
  /// Poké Ball red — primary CTAs, toggles, selected chrome.
  static let accent = Color(red: 0.93, green: 0.28, blue: 0.32)
  /// Deeper red for secondary emphasis / pressed states.
  static let accent2 = Color(red: 0.72, green: 0.18, blue: 0.24)
  /// Soft ice highlight for status, icons, and “active” labels.
  static let crystal = Color(red: 0.42, green: 0.82, blue: 0.96)
  static let radius: CGFloat = 18

  static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = "IBMPlexSans-Bold"
    case .semibold: name = "IBMPlexSans-SemiBold"
    case .medium: name = "IBMPlexSans-Medium"
    default: name = "IBMPlexSans-Regular"
    }
    // Fall back to system if the bundled face failed to register (avoids broken SF Symbol glyphs).
    if UIFont(name: name, size: size) != nil {
      return .custom(name, size: size)
    }
    return .system(size: size, weight: weight)
  }

  static func mono(_ size: CGFloat) -> Font {
    if UIFont(name: "IBMPlexMono-Medium", size: size) != nil {
      return .custom("IBMPlexMono-Medium", size: size)
    }
    return .system(size: size, design: .monospaced)
  }
}

enum ConsoleKind: String, CaseIterable, Identifiable {
  case gb, gbc, gba, nds
  var id: String { rawValue }
  var title: String {
    switch self {
    case .gb: return "Game Boy"
    case .gbc: return "Game Boy Color"
    case .gba: return "Game Boy Advance"
    case .nds: return "Nintendo DS"
    }
  }
  /// Compact label for the library console rail.
  var shortTitle: String {
    switch self {
    case .gb: return "GB"
    case .gbc: return "GBC"
    case .gba: return "GBA"
    case .nds: return "DS"
    }
  }
  var fileExtensions: [String] {
    switch self {
    case .gb: return ["gb"]
    case .gbc: return ["gbc"]
    case .gba: return ["gba"]
    case .nds: return ["nds"]
    }
  }
  /// Delta / Riley Testut game type identifiers used inside .deltaskin info.json
  var deltaGameType: String {
    switch self {
    case .gb: return "com.rileytestut.delta.game.gb"
    case .gbc: return "com.rileytestut.delta.game.gbc"
    case .gba: return "com.rileytestut.delta.game.gba"
    case .nds: return "com.rileytestut.delta.game.ds"
    }
  }
  static func from(romExtension ext: String) -> ConsoleKind? {
    switch ext.lowercased() {
    case "gb": return .gb
    case "gbc": return .gbc
    case "gba": return .gba
    case "nds": return .nds
    default: return nil
    }
  }
}

/// White Poké Ball mark for the PocketDex wordmark.
struct PokeBallMark: View {
  var size: CGFloat = 22
  var body: some View {
    let stroke = max(1.2, size * 0.075)
    ZStack {
      // Outer shell
      Circle()
        .strokeBorder(Color.white, lineWidth: stroke)
      // Equator
      Rectangle()
        .fill(Color.white)
        .frame(width: size, height: stroke)
      // Button ring + core
      Circle()
        .fill(CETheme.elevated)
        .frame(width: size * 0.34, height: size * 0.34)
      Circle()
        .strokeBorder(Color.white, lineWidth: stroke)
        .frame(width: size * 0.34, height: size * 0.34)
      Circle()
        .strokeBorder(Color.white, lineWidth: stroke * 0.85)
        .frame(width: size * 0.16, height: size * 0.16)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Handheld glyphs for the library side pill (template white / black when selected).
struct ConsoleRailIcon: View {
  let kind: ConsoleKind
  var body: some View {
    GeometryReader { geo in
      let s = min(geo.size.width, geo.size.height)
      Group {
        switch kind {
        case .gb:
          DMGGlyph().frame(width: s * 0.58, height: s * 0.92)
        case .gbc:
          GBCGlyph().frame(width: s * 0.58, height: s * 0.92)
        case .gba:
          // Exact AGB silhouette from reference art (template asset).
          Image("ConsoleGBA")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: s * 0.98, height: s * 0.56)
        case .nds:
          NDSGlyph().frame(width: s * 0.70, height: s * 0.92)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .accessibilityHidden(true)
  }
}

/// UITabBar / `tabItem` only reliably shows `UIImage` templates — not live SwiftUI Paths.
@MainActor
enum ConsoleTabIcon {
  private static var cache: [ConsoleKind: UIImage] = [:]

  static func image(for kind: ConsoleKind) -> UIImage {
    if let cached = cache[kind] { return cached }
    let size: CGFloat = 28
    let content = ConsoleRailIcon(kind: kind)
      .foregroundStyle(Color.black)
      .frame(width: size, height: size)
      .padding(2)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 3
    let raw = renderer.uiImage ?? UIImage()
    let templated = raw.withRenderingMode(.alwaysTemplate)
    cache[kind] = templated
    return templated
  }
}

// MARK: - Console glyphs

private struct GlyphDPad: View {
  var body: some View {
    GeometryReader { g in
      let s = min(g.size.width, g.size.height)
      ZStack {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .frame(width: s, height: s * 0.36)
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .frame(width: s * 0.36, height: s)
      }
      .frame(width: g.size.width, height: g.size.height)
    }
  }
}

/// Original Game Boy (DMG) — tall brick, screen, D-pad, A/B, speaker.
private struct DMGGlyph: View {
  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height
      ZStack {
        RoundedRectangle(cornerRadius: w * 0.13, style: .continuous)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .frame(width: w * 0.64, height: h * 0.28)
          .position(x: w * 0.5, y: h * 0.26)
          .blendMode(.destinationOut)
        GlyphDPad()
          .frame(width: w * 0.30, height: w * 0.30)
          .position(x: w * 0.30, y: h * 0.60)
          .blendMode(.destinationOut)
        Circle().frame(width: w * 0.16, height: w * 0.16)
          .position(x: w * 0.60, y: h * 0.55)
          .blendMode(.destinationOut)
        Circle().frame(width: w * 0.16, height: w * 0.16)
          .position(x: w * 0.78, y: h * 0.66)
          .blendMode(.destinationOut)
        VStack(spacing: h * 0.02) {
          ForEach(0..<4, id: \.self) { _ in
            Capsule().frame(width: w * 0.30, height: h * 0.012)
          }
        }
        .position(x: w * 0.70, y: h * 0.84)
        .blendMode(.destinationOut)
      }
      .compositingGroup()
    }
  }
}

/// Game Boy Color — rounder shell, power LED, ridges.
private struct GBCGlyph: View {
  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height
      ZStack {
        RoundedRectangle(cornerRadius: w * 0.20, style: .continuous)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .frame(width: w * 0.68, height: h * 0.26)
          .position(x: w * 0.5, y: h * 0.24)
          .blendMode(.destinationOut)
        Circle()
          .frame(width: w * 0.10, height: w * 0.10)
          .position(x: w * 0.80, y: h * 0.10)
          .blendMode(.destinationOut)
        GlyphDPad()
          .frame(width: w * 0.30, height: w * 0.30)
          .position(x: w * 0.30, y: h * 0.58)
          .blendMode(.destinationOut)
        Circle().frame(width: w * 0.16, height: w * 0.16)
          .position(x: w * 0.60, y: h * 0.53)
          .blendMode(.destinationOut)
        Circle().frame(width: w * 0.16, height: w * 0.16)
          .position(x: w * 0.78, y: h * 0.64)
          .blendMode(.destinationOut)
        VStack(spacing: h * 0.025) {
          ForEach(0..<3, id: \.self) { _ in
            Capsule().frame(width: w * 0.62, height: h * 0.012)
          }
        }
        .position(x: w * 0.5, y: h * 0.86)
        .blendMode(.destinationOut)
      }
      .compositingGroup()
    }
  }
}

/// Nintendo DS — open clamshell, dual screens, hinge mic.
private struct NDSGlyph: View {
  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height
      let r = w * 0.09
      ZStack {
        RoundedRectangle(cornerRadius: r, style: .continuous)
          .frame(width: w, height: h * 0.40)
          .position(x: w * 0.5, y: h * 0.20)
        RoundedRectangle(cornerRadius: r, style: .continuous)
          .frame(width: w, height: h * 0.40)
          .position(x: w * 0.5, y: h * 0.78)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .frame(width: w * 0.88, height: h * 0.10)
          .position(x: w * 0.5, y: h * 0.49)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .frame(width: w * 0.76, height: h * 0.26)
          .position(x: w * 0.5, y: h * 0.20)
          .blendMode(.destinationOut)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .frame(width: w * 0.76, height: h * 0.26)
          .position(x: w * 0.5, y: h * 0.76)
          .blendMode(.destinationOut)
        Circle()
          .frame(width: w * 0.09, height: w * 0.09)
          .position(x: w * 0.5, y: h * 0.49)
          .blendMode(.destinationOut)
      }
      .compositingGroup()
    }
  }
}
