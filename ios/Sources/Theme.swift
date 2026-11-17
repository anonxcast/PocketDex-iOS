import SwiftUI
import UIKit

enum CETheme {
  /// Adaptive Music / Liquid Glass surfaces (follow system Light / Dark).
  /// Dark bg is true black so the status-bar band matches the library canvas (no gray bezel).
  static let bg = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor.black
      : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
  })
  static let elevated = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
      : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
  })
  static let card = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.14, green: 0.14, blue: 0.15, alpha: 0.72)
      : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92)
  })
  static let hover = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
      : UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
  })
  static let border = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.black.withAlphaComponent(0.10)
  })
  static let text = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
      : UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
  })
  static let muted = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.68, green: 0.68, blue: 0.70, alpha: 1)
      : UIColor(red: 0.42, green: 0.42, blue: 0.45, alpha: 1)
  })
  /// Poké Ball red — primary CTAs, toggles, selected chrome.
  static let accent = Color(red: 0.93, green: 0.28, blue: 0.32)
  /// Deeper red for secondary emphasis / pressed states.
  static let accent2 = Color(red: 0.72, green: 0.18, blue: 0.24)
  /// Soft ice highlight for status, icons, and “active” labels.
  static let crystal = Color(uiColor: UIColor { t in
    t.userInterfaceStyle == .dark
      ? UIColor(red: 0.42, green: 0.82, blue: 0.96, alpha: 1)
      : UIColor(red: 0.10, green: 0.55, blue: 0.78, alpha: 1)
  })
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

/// Poké Ball mark for the PocketDex wordmark (adapts to Light / Dark).
struct PokeBallMark: View {
  var size: CGFloat = 22
  var body: some View {
    let stroke = max(1.2, size * 0.075)
    ZStack {
      Circle()
        .strokeBorder(CETheme.text, lineWidth: stroke)
      Rectangle()
        .fill(CETheme.text)
        .frame(width: size, height: stroke)
      Circle()
        .fill(CETheme.elevated)
        .frame(width: size * 0.34, height: size * 0.34)
      Circle()
        .strokeBorder(CETheme.text, lineWidth: stroke)
        .frame(width: size * 0.34, height: size * 0.34)
      Circle()
        .strokeBorder(CETheme.text, lineWidth: stroke * 0.85)
        .frame(width: size * 0.16, height: size * 0.16)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Handheld glyphs for the library tab / rail — Delta Emulator’s console silhouettes (template).
struct ConsoleRailIcon: View {
  let kind: ConsoleKind

  private var assetName: String {
    switch kind {
    case .gb: return "DeltaIconGB"
    case .gbc: return "DeltaIconGBC"
    case .gba: return "DeltaIconGBA"
    case .nds: return "DeltaIconDS"
    }
  }

  var body: some View {
    Image(assetName)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      // Keep GBA’s wide aspect (no uniform shrink — that made it look stubby).
      .accessibilityHidden(true)
  }
}

/// Official console wordmarks for the library chrome title (Wikimedia PD-textlogo assets).
struct ConsoleSystemLogo: View {
  let kind: ConsoleKind
  var height: CGFloat = 36

  private var assetName: String {
    switch kind {
    case .gb: return "LogoGB"
    case .gbc: return "LogoGBC"
    case .gba: return "LogoGBA"
    case .nds: return "LogoNDS"
    }
  }

  /// GBC (rainbow) + GBA (indigo/white) stay original; GB/NDS tint with theme text.
  private var usesTemplate: Bool {
    switch kind {
    case .gbc, .gba: return false
    case .gb, .nds: return true
    }
  }

  var body: some View {
    let mark = Image(assetName)
      .renderingMode(usesTemplate ? .template : .original)
      .resizable()
      .interpolation(.high)
      .antialiased(true)
      .scaledToFit()
      .frame(height: kind == .gbc ? height * 1.25 : height)
      .accessibilityLabel(kind.title)
    if usesTemplate {
      mark.foregroundStyle(CETheme.text)
    } else {
      mark
    }
  }
}

/// UITabBar / `tabItem` — Delta’s template console PDFs tint white/selected like SF Symbols.
@MainActor
enum ConsoleTabIcon {
  private static var cache: [ConsoleKind: UIImage] = [:]

  private static func assetName(for kind: ConsoleKind) -> String {
    switch kind {
    case .gb: return "DeltaIconGB"
    case .gbc: return "DeltaIconGBC"
    case .gba: return "DeltaIconGBA"
    case .nds: return "DeltaIconDS"
    }
  }

  /// Max fraction of the tab canvas each silhouette may fill (width × height).
  /// GBA stays wide like Delta — never squash its ~1.86∶1 aspect into a stubby block.
  private static func maxFill(for kind: ConsoleKind) -> CGSize {
    switch kind {
    case .gba: return CGSize(width: 0.78, height: 0.62)
    case .nds: return CGSize(width: 0.90, height: 0.90)
    case .gb, .gbc: return CGSize(width: 0.88, height: 0.92)
    }
  }

  static func image(for kind: ConsoleKind) -> UIImage {
    if let cached = cache[kind] { return cached }
    let name = assetName(for: kind)
    let base = UIImage(named: name) ?? UIImage(systemName: "gamecontroller.fill")!
    // Slightly wider canvas so the GBA silhouette can read long, like Delta’s tab icon.
    let size = CGSize(width: kind == .gba ? 42 : 34, height: 28)
    let fill = maxFill(for: kind)
    let renderer = UIGraphicsImageRenderer(size: size)
    let padded = renderer.image { _ in
      let aspect = base.size.width / max(1, base.size.height)
      let maxW = size.width * fill.width
      let maxH = size.height * fill.height
      let drawW: CGFloat
      let drawH: CGFloat
      if aspect > maxW / maxH {
        drawW = maxW
        drawH = maxW / aspect
      } else {
        drawH = maxH
        drawW = maxH * aspect
      }
      let rect = CGRect(
        x: (size.width - drawW) / 2,
        y: (size.height - drawH) / 2,
        width: drawW,
        height: drawH
      )
      base.draw(in: rect)
    }
    let templated = padded.withRenderingMode(.alwaysTemplate)
    cache[kind] = templated
    return templated
  }
}

